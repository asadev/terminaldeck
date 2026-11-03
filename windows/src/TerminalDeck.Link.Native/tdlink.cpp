// Terminal Deck: the Windows link's WebRTC engine (stream step 2, dc2), a small C ABI over webrtc-sdk's libwebrtc.dll
// (libwebrtc.m150.7871.07: Google's WebRTC M150, the same engine as the Mac, iPhone and Android ends). The protocol
// (binding, hand-over, hold, fail-stop) lives in C# (TerminalDeck.Core.Remote); this file only owns one peer
// connection with the contract's three negotiated data channels and reports what libwebrtc says.
//
// Build: build.ps1 next to this file (MSVC x64, C++17). Licences: licenses/ next to this file.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <share.h>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

#include "libwebrtc.h"
#include "rtc_data_channel.h"
#include "rtc_logging.h"
#include "rtc_ice_candidate.h"
#include "rtc_mediaconstraints.h"
#include "rtc_peerconnection.h"
#include "rtc_peerconnection_factory.h"

using namespace libwebrtc;

extern "C" {
typedef void (*tdl_candidate_fn)(intptr_t ctx, const char* candidate, const char* mid, int index);
// what: 0 peer connection state, 1 ICE connection state, 10 + lane a channel's state.
typedef void (*tdl_state_fn)(intptr_t ctx, int what, int value);
typedef void (*tdl_message_fn)(intptr_t ctx, int lane, const uint8_t* data, int size);
// op: 0 offer made (local set), 1 answer made (local set), 2 remote answer applied.
typedef void (*tdl_sdp_fn)(intptr_t ctx, int op, int ok, const char* text);
typedef void (*tdl_stats_fn)(intptr_t ctx, const char* json);
struct tdl_callbacks {
  tdl_candidate_fn candidate;
  tdl_state_fn state;
  tdl_message_fn message;
  tdl_sdp_fn sdp;
  tdl_stats_fn stats;
};
}

namespace {

// ---- no audio ------------------------------------------------------------------------------------------------------
// libwebrtc's factory always opens the PC's audio devices (its voice engine needs an audio device module), even for a
// link that only carries data. Measured on a PC (2 Nov, saba-pc): the audio stack (MMDevApi, AudioSes, the voice
// capture echo canceller) left the process unable to exit. Terminal Deck never sends sound, so libwebrtc's own
// CoCreateInstance (its import, nobody else's) is pointed here: the audio device enumerator it gets has no devices,
// and the echo canceller does not exist. The audio device module then starts with nothing to open.

class EmptyDevices final : public IMMDeviceCollection {
 public:
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { ULONG left = --refs_; if (!left) delete this; return left; }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMDeviceCollection)) { *out = static_cast<IMMDeviceCollection*>(this); AddRef(); return S_OK; }
    *out = nullptr; return E_NOINTERFACE;
  }
  HRESULT STDMETHODCALLTYPE GetCount(UINT* count) override { if (!count) return E_POINTER; *count = 0; return S_OK; }
  HRESULT STDMETHODCALLTYPE Item(UINT, IMMDevice** device) override { if (device) *device = nullptr; return E_INVALIDARG; }
 private:
  std::atomic<ULONG> refs_{1};
};

class NoAudioDevices final : public IMMDeviceEnumerator {
 public:
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { ULONG left = --refs_; if (!left) delete this; return left; }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IMMDeviceEnumerator)) { *out = static_cast<IMMDeviceEnumerator*>(this); AddRef(); return S_OK; }
    *out = nullptr; return E_NOINTERFACE;
  }
  HRESULT STDMETHODCALLTYPE EnumAudioEndpoints(EDataFlow, DWORD, IMMDeviceCollection** devices) override {
    if (!devices) return E_POINTER;
    *devices = new EmptyDevices();
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDefaultAudioEndpoint(EDataFlow, ERole, IMMDevice** device) override {
    if (device) *device = nullptr;
    return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
  }
  HRESULT STDMETHODCALLTYPE GetDevice(LPCWSTR, IMMDevice** device) override {
    if (device) *device = nullptr;
    return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
  }
  HRESULT STDMETHODCALLTYPE RegisterEndpointNotificationCallback(IMMNotificationClient*) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE UnregisterEndpointNotificationCallback(IMMNotificationClient*) override { return S_OK; }
 private:
  std::atomic<ULONG> refs_{1};
};

// CLSID_CWMAudioAEC, the voice capture DSP (echo canceller).
const CLSID kVoiceCaptureDsp = {0x745057c7, 0xf353, 0x4f2d, {0xa7, 0xee, 0x58, 0x43, 0x44, 0x77, 0x73, 0x0e}};
using CoCreateFn = HRESULT(WINAPI*)(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*);
CoCreateFn g_co_create = nullptr;
std::atomic<int> g_audio_refused{0};

HRESULT WINAPI CreateWithoutAudio(REFCLSID clsid, LPUNKNOWN outer, DWORD context, REFIID iid, LPVOID* out) {
  if (clsid == __uuidof(MMDeviceEnumerator)) {
    g_audio_refused++;
    if (!out) return E_POINTER;
    auto* devices = new NoAudioDevices();
    HRESULT hr = devices->QueryInterface(iid, out);
    devices->Release();
    return hr;
  }
  if (clsid == kVoiceCaptureDsp) {
    g_audio_refused++;
    if (out) *out = nullptr;
    return REGDB_E_CLASSNOTREG;
  }
  return g_co_create(clsid, outer, context, iid, out);
}

// Points one import of `module` (dll!name) at `hook`; the original is kept in `original`.
bool Redirect(HMODULE module, const char* dll, const char* name, void* hook, void** original) {
  auto* base = reinterpret_cast<BYTE*>(module);
  auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
  auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
  const auto& directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (!directory.VirtualAddress) return false;
  for (auto* import = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + directory.VirtualAddress); import->Name; import++) {
    if (_stricmp(reinterpret_cast<const char*>(base + import->Name), dll) != 0) continue;
    auto* names = reinterpret_cast<IMAGE_THUNK_DATA*>(base + (import->OriginalFirstThunk ? import->OriginalFirstThunk : import->FirstThunk));
    auto* slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base + import->FirstThunk);
    for (; names->u1.AddressOfData; names++, slots++) {
      if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
      auto* byName = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
      if (strcmp(reinterpret_cast<const char*>(byName->Name), name) != 0) continue;
      DWORD previous = 0;
      if (!VirtualProtect(&slots->u1.Function, sizeof(slots->u1.Function), PAGE_READWRITE, &previous)) return false;
      *original = reinterpret_cast<void*>(slots->u1.Function);
      slots->u1.Function = reinterpret_cast<ULONG_PTR>(hook);
      VirtualProtect(&slots->u1.Function, sizeof(slots->u1.Function), previous, &previous);
      FlushInstructionCache(GetCurrentProcess(), &slots->u1.Function, sizeof(slots->u1.Function));
      return true;
    }
  }
  return false;
}

tdl_callbacks g_cb{};
// The factory and the live links are never destroyed at process exit: Windows has already ended libwebrtc's threads
// by then, and tearing a peer connection down waits on them (a process that quits with a link open would never end).
// So both live on the heap for the life of the process, on purpose.
std::mutex& FactoryLock() { static auto* lock = new std::mutex(); return *lock; }
scoped_refptr<RTCPeerConnectionFactory>& Factory() { static auto* factory = new scoped_refptr<RTCPeerConnectionFactory>(); return *factory; }

const char* const kLabels[3] = {"td.rt", "td.rel", "td.ctl"};

struct Link;

struct Lane final : RTCDataChannelObserver {
  Link* owner = nullptr;
  int lane = 0;
  scoped_refptr<RTCDataChannel> channel;
  std::atomic<int> state{RTCDataChannelConnecting};
  void OnStateChange(RTCDataChannelState value) override;
  void OnMessage(const char* buffer, int length, bool binary) override;
};

struct Link final : RTCPeerConnectionObserver {
  intptr_t ctx = 0;
  std::atomic<bool> closed{false};
  scoped_refptr<RTCPeerConnection> pc;
  scoped_refptr<RTCMediaConstraints> constraints;
  Lane lanes[3];
  std::weak_ptr<Link> self;

  bool live() const { return !closed.load(); }
  void OnSignalingState(RTCSignalingState) override {}
  void OnPeerConnectionState(RTCPeerConnectionState value) override { if (live()) g_cb.state(ctx, 0, static_cast<int>(value)); }
  void OnIceGatheringState(RTCIceGatheringState) override {}
  void OnIceConnectionState(RTCIceConnectionState value) override { if (live()) g_cb.state(ctx, 1, static_cast<int>(value)); }
  void OnIceCandidate(scoped_refptr<RTCIceCandidate> candidate) override {
    if (!live() || !candidate.get()) return;
    const string sdp = candidate->candidate();
    const string mid = candidate->sdp_mid();
    g_cb.candidate(ctx, sdp.c_string(), mid.c_string(), candidate->sdp_mline_index());
  }
  void OnAddStream(scoped_refptr<RTCMediaStream>) override {}
  void OnRemoveStream(scoped_refptr<RTCMediaStream>) override {}
  void OnDataChannel(scoped_refptr<RTCDataChannel>) override {}
  void OnRenegotiationNeeded() override {}
  void OnTrack(scoped_refptr<RTCRtpTransceiver>) override {}
  void OnAddTrack(vector<scoped_refptr<RTCMediaStream>>, scoped_refptr<RTCRtpReceiver>) override {}
  void OnRemoveTrack(scoped_refptr<RTCRtpReceiver>) override {}
};

void Lane::OnStateChange(RTCDataChannelState value) {
  state.store(value);
  if (owner && owner->live()) g_cb.state(owner->ctx, 10 + lane, static_cast<int>(value));
}

void Lane::OnMessage(const char* buffer, int length, bool) {
  if (owner && owner->live()) g_cb.message(owner->ctx, lane, reinterpret_cast<const uint8_t*>(buffer), length);
}

// libwebrtc may still be inside a callback into a closed link for a moment (its observer pointers are read without
// a lock), so a closed link's memory is kept a while before it goes. For the same reason the observers are never
// DE-registered: RTCPeerConnectionImpl::OnIceCandidate checks observer_ and then reads it again to call it (m150,
// libwebrtc.dll RVA 0x1a8e9), so a de-register from another thread in between was a null call that killed the
// process (review 25: saba-pc testhost, W8A, a phone dropping while candidates were still being gathered). A closed
// link's callbacks see closed and return; its memory outlives them (Retire). After those 30 s no callback can still be
// on its way, so the observers are de-registered then, just before the memory goes (Security, Windows re-check 2): no
// freed Link or Lane ever stays registered with libwebrtc.
void Retire(std::shared_ptr<Link> link) {
  std::thread([keep = std::move(link)]() mutable {
    std::this_thread::sleep_for(std::chrono::seconds(30));
    for (Lane& lane : keep->lanes)
      if (lane.channel.get()) lane.channel->UnregisterObserver();
    if (keep->pc.get()) keep->pc->DeRegisterRTCPeerConnectionObserver();
    keep.reset();
  }).detach();
}

// Handles are opaque ids, never pointers: a call with a closed or unknown id finds nothing and does nothing, and an id
// is never reused, so a late call can never reach another link (W8).
std::mutex& HandlesLock() { static auto* lock = new std::mutex(); return *lock; }
std::unordered_map<intptr_t, std::shared_ptr<Link>>& Handles() { static auto* handles = new std::unordered_map<intptr_t, std::shared_ptr<Link>>(); return *handles; }
intptr_t g_next_handle = 0;

std::shared_ptr<Link> Find(void* handle) {
  std::lock_guard<std::mutex> lock(HandlesLock());
  auto found = Handles().find(reinterpret_cast<intptr_t>(handle));
  if (found == Handles().end() || !found->second || found->second->closed.load()) return nullptr;
  return found->second;
}

}  // namespace

namespace {
FILE* g_log = nullptr;
std::mutex g_log_lock;
void LogLine(const string& message) {
  std::lock_guard<std::mutex> lock(g_log_lock);
  if (!g_log) return;
  SYSTEMTIME now;
  GetLocalTime(&now);
  fprintf(g_log, "%02d:%02d:%02d.%03d %s", now.wHour, now.wMinute, now.wSecond, now.wMilliseconds, message.c_string());
  fflush(g_log);
}
}  // namespace

extern "C" {

__declspec(dllexport) int tdl_version() { return 1; }

// How many times libwebrtc asked for an audio device enumerator or the echo canceller (and got none).
__declspec(dllexport) int tdl_audio_refused() { return g_audio_refused.load(); }

// Diagnostics: libwebrtc's own log (info and above) appended to `path`. Call before tdl_init.
__declspec(dllexport) int tdl_log(const char* path) {
  std::lock_guard<std::mutex> lock(g_log_lock);
  if (g_log || !path) return g_log ? 1 : 0;
  g_log = _fsopen(path, "a", _SH_DENYNO);
  if (!g_log) return 0;
  LibWebRTCLogging::setLogSink(Info, LogLine);
  return 1;
}

// Once per process: SSL, threads, the factory. 1 = ready.
__declspec(dllexport) int tdl_init(const tdl_callbacks* callbacks) {
  std::lock_guard<std::mutex> lock(FactoryLock());
  if (Factory().get()) return 1;
  if (!callbacks || !callbacks->candidate || !callbacks->state || !callbacks->message || !callbacks->sdp || !callbacks->stats) return 0;
  g_cb = *callbacks;
  // No audio, or no link at all.
  if (!g_co_create) {
    HMODULE webrtc = GetModuleHandleW(L"libwebrtc.dll");
    if (!webrtc || !Redirect(webrtc, "ole32.dll", "CoCreateInstance", reinterpret_cast<void*>(&CreateWithoutAudio), reinterpret_cast<void**>(&g_co_create)) || !g_co_create) return 0;
  }
  if (!LibWebRTC::Initialize()) return 0;
  scoped_refptr<RTCPeerConnectionFactory> factory = LibWebRTC::CreateRTCPeerConnectionFactory();
  if (!factory.get() || !factory->Initialize()) return 0;
  Factory() = factory;
  return 1;
}

// A peer connection with the three negotiated channels (contract §4). policy: 0 all, 1 nohost, 2 relay.
// Returns null when libwebrtc refuses the configuration.
__declspec(dllexport) void* tdl_create(intptr_t ctx, int count, const char** urls, const char** usernames, const char** credentials, int policy) {
  scoped_refptr<RTCPeerConnectionFactory> factory;
  {
    std::lock_guard<std::mutex> lock(FactoryLock());
    factory = Factory();
  }
  if (!factory.get() || count < 0 || count > kMaxIceServerSize) return nullptr;
  RTCConfiguration config;
  for (int i = 0; i < count; i++) {
    config.ice_servers[i].uri = string(urls[i] ? urls[i] : "");
    config.ice_servers[i].username = string(usernames[i] ? usernames[i] : "");
    config.ice_servers[i].password = string(credentials[i] ? credentials[i] : "");
  }
  config.type = policy == 2 ? IceTransportsType::kRelay : policy == 1 ? IceTransportsType::kNoHost : IceTransportsType::kAll;
  // No TCP candidates: they would mean a listening TCP socket on every interface while a link is up (W1). TURN over
  // TCP/TLS (the Worker's turn:…?transport=tcp / turns: servers) still works: those are outgoing connections.
  config.tcp_candidate_policy = TcpCandidatePolicy::kTcpCandidatePolicyDisabled;
  config.bundle_policy = kBundlePolicyMaxBundle;
  config.rtcp_mux_policy = RtcpMuxPolicy::kRtcpMuxPolicyRequire;
  config.sdp_semantics = SdpSemantics::kUnifiedPlan;
  config.offer_to_receive_audio = false;
  config.offer_to_receive_video = false;

  auto link = std::make_shared<Link>();
  link->self = link;
  link->ctx = ctx;
  link->constraints = RTCMediaConstraints::Create();
  {
    std::lock_guard<std::mutex> lock(FactoryLock());
    link->pc = factory->Create(config, link->constraints);
  }
  if (!link->pc.get()) return nullptr;
  // A configuration libwebrtc refused leaves the wrapper without a connection; its GetStats then fails at once,
  // on this thread (it never touches the missing connection).
  static thread_local bool refused;
  refused = false;
  link->pc->GetStats([](const vector<scoped_refptr<MediaRTCStats>>) {}, [](const char*) { refused = true; });
  if (refused) {
    std::lock_guard<std::mutex> lock(FactoryLock());
    factory->Delete(link->pc);
    return nullptr;
  }
  link->pc->RegisterRTCPeerConnectionObserver(link.get());
  for (int i = 0; i < 3; i++) {
    RTCDataChannelInit init;
    init.ordered = true;
    init.negotiated = true;
    init.id = i + 1;
    if (i == 0) { init.reliable = false; init.maxRetransmitTime = 150; }   // td.rt: maxPacketLifeTime 150 ms
    Lane& lane = link->lanes[i];
    lane.owner = link.get();
    lane.lane = i + 1;
    lane.channel = link->pc->CreateDataChannel(string(kLabels[i]), &init);
    if (!lane.channel.get()) {
      link->closed = true;  // observers stay registered (see Retire)
      link->pc->Close();
      std::lock_guard<std::mutex> lock(FactoryLock());
      factory->Delete(link->pc);
      Retire(link);
      return nullptr;
    }
    lane.channel->RegisterObserver(&lane);
  }
  std::lock_guard<std::mutex> lock(HandlesLock());
  intptr_t id = ++g_next_handle;
  Handles()[id] = link;
  return reinterpret_cast<void*>(id);
}

// Offerer: create the offer and set it as the local description → sdp(0, ok, sdp | error).
__declspec(dllexport) void tdl_offer(void* handle) {
  auto link = Find(handle);
  if (!link) return;
  std::weak_ptr<Link> weak = link;
  link->pc->CreateOffer(
      [weak](const string sdp, const string type) {
        auto l = weak.lock();
        if (!l || !l->live()) return;
        const std::string text = sdp.std_string(), kind = type.std_string();
        l->pc->SetLocalDescription(string(text), string(kind),
            [weak, text]() { if (auto x = weak.lock(); x && x->live()) g_cb.sdp(x->ctx, 0, 1, text.c_str()); },
            [weak](const char* error) { if (auto x = weak.lock(); x && x->live()) g_cb.sdp(x->ctx, 0, 0, error ? error : "set local failed"); });
      },
      [weak](const char* error) { if (auto l = weak.lock(); l && l->live()) g_cb.sdp(l->ctx, 0, 0, error ? error : "offer failed"); },
      link->constraints);
}

// Answerer (the test client): apply the offer, create the answer, set it local → sdp(1, ok, sdp | error).
__declspec(dllexport) void tdl_answer(void* handle, const char* offer) {
  auto link = Find(handle);
  if (!link) return;
  std::weak_ptr<Link> weak = link;
  link->pc->SetRemoteDescription(string(offer ? offer : ""), string("offer"),
      [weak]() {
        auto l = weak.lock();
        if (!l || !l->live()) return;
        l->pc->CreateAnswer(
            [weak](const string sdp, const string type) {
              auto a = weak.lock();
              if (!a || !a->live()) return;
              const std::string text = sdp.std_string(), kind = type.std_string();
              a->pc->SetLocalDescription(string(text), string(kind),
                  [weak, text]() { if (auto x = weak.lock(); x && x->live()) g_cb.sdp(x->ctx, 1, 1, text.c_str()); },
                  [weak](const char* error) { if (auto x = weak.lock(); x && x->live()) g_cb.sdp(x->ctx, 1, 0, error ? error : "set local failed"); });
            },
            [weak](const char* error) { if (auto a = weak.lock(); a && a->live()) g_cb.sdp(a->ctx, 1, 0, error ? error : "answer failed"); },
            l->constraints);
      },
      [weak](const char* error) { if (auto l = weak.lock(); l && l->live()) g_cb.sdp(l->ctx, 1, 0, error ? error : "set remote failed"); });
}

// Offerer: apply the answer → sdp(2, ok, "" | error).
__declspec(dllexport) void tdl_accept(void* handle, const char* answer) {
  auto link = Find(handle);
  if (!link) return;
  std::weak_ptr<Link> weak = link;
  link->pc->SetRemoteDescription(string(answer ? answer : ""), string("answer"),
      [weak]() { if (auto l = weak.lock(); l && l->live()) g_cb.sdp(l->ctx, 2, 1, ""); },
      [weak](const char* error) { if (auto l = weak.lock(); l && l->live()) g_cb.sdp(l->ctx, 2, 0, error ? error : "set remote failed"); });
}

// A remote candidate. libwebrtc queues it until the remote description is set.
__declspec(dllexport) void tdl_add_candidate(void* handle, const char* candidate, const char* mid, int index) {
  auto link = Find(handle);
  if (!link || !candidate) return;
  link->pc->AddCandidate(string(mid ? mid : ""), index, string(candidate));
}

// One binary data-channel message (≤ 200 000 bytes; the caller cuts parts). 1 = queued, 0 = the channel is not open.
__declspec(dllexport) int tdl_send(void* handle, int lane, const uint8_t* data, int size) {
  auto link = Find(handle);
  if (!link || lane < 1 || lane > 3 || size < 0 || (size > 0 && !data)) return 0;
  Lane& l = link->lanes[lane - 1];
  if (l.state.load() != RTCDataChannelOpen || !l.channel.get()) return 0;
  l.channel->Send(data, static_cast<uint32_t>(size), true);
  return 1;
}

__declspec(dllexport) uint64_t tdl_buffered(void* handle, int lane) {
  auto link = Find(handle);
  if (!link || lane < 1 || lane > 3 || !link->lanes[lane - 1].channel.get()) return 0;
  return link->lanes[lane - 1].channel->buffered_amount();
}

__declspec(dllexport) int tdl_channel_state(void* handle, int lane) {
  auto link = Find(handle);
  return !link || lane < 1 || lane > 3 ? RTCDataChannelClosed : link->lanes[lane - 1].state.load();
}

// Every stats report as one JSON array → stats(json). The path name comes from the selected candidate pair.
__declspec(dllexport) void tdl_stats(void* handle) {
  auto link = Find(handle);
  if (!link) return;
  std::weak_ptr<Link> weak = link;
  link->pc->GetStats(
      [weak](const vector<scoped_refptr<MediaRTCStats>> reports) {
        auto l = weak.lock();
        if (!l || !l->live()) return;
        std::string json = "[";
        for (size_t i = 0; i < reports.size(); i++) {
          if (i) json += ",";
          json += reports[i]->ToJson().std_string();
        }
        json += "]";
        g_cb.stats(l->ctx, json.c_str());
      },
      [weak](const char*) { if (auto l = weak.lock(); l && l->live()) g_cb.stats(l->ctx, "[]"); });
}

// Close and forget: no callback comes after this returns.
__declspec(dllexport) void tdl_close(void* handle) {
  std::shared_ptr<Link> link;
  {
    std::lock_guard<std::mutex> lock(HandlesLock());
    auto found = Handles().find(reinterpret_cast<intptr_t>(handle));
    if (found == Handles().end()) return;
    link = std::move(found->second);
    Handles().erase(found);
  }
  if (!link || link->closed.exchange(true)) return;
  // Observers stay registered (see Retire): closed already silences every callback.
  for (Lane& lane : link->lanes)
    if (lane.channel.get()) lane.channel->Close();
  link->pc->Close();
  {
    std::lock_guard<std::mutex> lock(FactoryLock());
    if (Factory().get()) Factory()->Delete(link->pc);
  }
  Retire(std::move(link));
}

}  // extern "C"
