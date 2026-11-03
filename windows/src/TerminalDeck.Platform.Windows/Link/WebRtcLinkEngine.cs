using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Platform.Windows.Link;

// stream step 2 (dc2): the Windows link's WebRTC stack. tdlink.dll (src/TerminalDeck.Link.Native) is a small C ABI
// over webrtc-sdk's libwebrtc.dll m150 (Google's WebRTC, the same engine as the Mac, iPhone and Android ends). This
// class is the ILinkEngine the host's RelayHostConnection drives: one peer connection with the three negotiated
// channels, part framing, the selected path's name, and the contract's failure rules (ICE failed or closed, a channel
// closing, ICE disconnected for more than 5 s). The protocol itself (binding, hand-over, hold) is in Core.
//
// Every libwebrtc callback is copied and queued; one task per link hands them on in order. So the host's handlers
// (which may close the link) never run on a libwebrtc thread.
public sealed class WebRtcLinkEngine : ILinkEngine, ILinkAnswerEngine
{
  private static readonly object Gate = new();
  private static WebRtcLinkEngine? shared;
  private static string? failure;

  public static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(20);
  internal readonly Native Api;
  private WebRtcLinkEngine(Native api) => Api = api;

  /// The process's engine, or null with the reason (tdlink.dll / libwebrtc.dll missing, refused to start).
  public static WebRtcLinkEngine? TryCreate(out string? problem, string? directory = null)
  {
    lock (Gate)
    {
      if (shared is null && failure is null)
      {
        // libwebrtc starts its threads (and the PC's audio devices, which it always opens) here. On a PC where that
        // never returns, every link fails with this reason and the phone is told (direct only: never the relay instead);
        // the app goes on.
        Native? loaded = null; Exception? error = null;
        var start = new Thread(() =>
        {
          try { loaded = Native.Load(directory ?? AppContext.BaseDirectory); }
          catch (Exception ex) { error = ex; }
        }) { IsBackground = true, Name = "td-link-start" };
        start.Start();
        if (!start.Join(StartTimeout)) failure = "The direct link's engine did not start within " + StartTimeout.TotalSeconds + " s.";
        else if (loaded is not null) shared = new WebRtcLinkEngine(loaded);
        else failure = error is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or InvalidOperationException or IOException
          ? error.Message : "The direct link's engine did not start (" + error?.GetType().Name + ": " + error?.Message + ").";
        if (failure is not null) Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " link: engine unavailable: " + failure);
      }
      problem = failure;
      return shared;
    }
  }

  /// The app's engine, started on the first link (not at app start). When tdlink.dll / libwebrtc.dll are not next to the
  /// app, every link fails with that reason and the phone is told (direct only: never the relay instead).
  public static ILinkEngine Lazy(string? directory = null)
  {
    var folder = directory ?? AppContext.BaseDirectory;
    return File.Exists(System.IO.Path.Combine(folder, "tdlink.dll")) && File.Exists(System.IO.Path.Combine(folder, "libwebrtc.dll"))
      ? new LazyEngine(folder) : new UnavailableLinkEngine("This computer's direct-link engine (tdlink.dll, libwebrtc.dll) is missing next to the app.");
  }

  private sealed class LazyEngine(string directory) : ILinkEngine, ILinkAnswerEngine
  {
    private WebRtcLinkEngine Started() => TryCreate(out var problem, directory) ?? throw new InvalidOperationException(problem ?? "The direct link's engine did not start.");
    public ILinkConnection Connect(LinkServers servers, LinkEvents events) => Started().Connect(servers, events);
    public ILinkAnswerConnection ConnectAnswerer(LinkServers servers, LinkEvents events) => Started().ConnectAnswerer(servers, events);
  }

  public ILinkConnection Connect(LinkServers servers, LinkEvents events) => WebRtcLink.Create(this, servers, events, offerer: true);

  /// How often libwebrtc asked for the PC's audio devices or echo canceller and was given none (it never opens audio).
  public int AudioRefused => Api.AudioRefused();

  /// The answering side (a desktop guest, tests, measurements): the same channels and rules.
  public WebRtcLink ConnectAnswerer(LinkServers servers, LinkEvents events) => WebRtcLink.Create(this, servers, events, offerer: false);
  ILinkAnswerConnection ILinkAnswerEngine.ConnectAnswerer(LinkServers servers, LinkEvents events) => ConnectAnswerer(servers, events);

  // ---- tdlink.dll ----------------------------------------------------------------------------------------------

  internal sealed class Native
  {
    [StructLayout(LayoutKind.Sequential)]
    private struct Callbacks { public IntPtr Candidate, State, Message, Sdp, Stats; }
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void CandidateFn(IntPtr ctx, IntPtr candidate, IntPtr mid, int index);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void StateFn(IntPtr ctx, int what, int value);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void MessageFn(IntPtr ctx, int lane, IntPtr data, int size);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void SdpFn(IntPtr ctx, int op, int ok, IntPtr text);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void StatsFn(IntPtr ctx, IntPtr json);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int InitFn(ref Callbacks callbacks);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int LogFn(IntPtr path);
    // Only pointers and numbers cross: strings go as UTF-8 copies (Utf8), arrays pinned by the caller.
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate IntPtr CreateFn(IntPtr ctx, int count, IntPtr urls, IntPtr usernames, IntPtr credentials, int policy);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void HandleFn(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void TextFn(IntPtr handle, IntPtr text);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate void CandidateInFn(IntPtr handle, IntPtr candidate, IntPtr mid, int index);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int SendFn(IntPtr handle, int lane, IntPtr data, int size);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate ulong BufferedFn(IntPtr handle, int lane);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] internal delegate int CountFn();

    // Kept alive for the process: libwebrtc calls these.
    private static readonly CandidateFn OnCandidate = (ctx, candidate, mid, index) => Safely(() =>
      WebRtcLink.Find(ctx)?.Queue(new WebRtcLink.Event.Candidate(Marshal.PtrToStringUTF8(candidate) ?? "", mid == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(mid), index)));
    private static readonly StateFn OnState = (ctx, what, value) => Safely(() => WebRtcLink.Find(ctx)?.Queue(new WebRtcLink.Event.State(what, value)));
    private static readonly MessageFn OnMessage = (ctx, lane, data, size) => Safely(() =>
    {
      var link = WebRtcLink.Find(ctx);
      if (link is null || size < 0) return;
      var copy = new byte[size];
      if (size > 0) Marshal.Copy(data, copy, 0, size);
      link.Queue(new WebRtcLink.Event.Message(lane, copy));
    });
    private static readonly SdpFn OnSdp = (ctx, op, ok, text) => Safely(() => WebRtcLink.Find(ctx)?.Described(op, ok == 1, Marshal.PtrToStringUTF8(text) ?? ""));
    private static readonly StatsFn OnStats = (ctx, json) => Safely(() => WebRtcLink.Find(ctx)?.Measured(Marshal.PtrToStringUTF8(json) ?? "[]"));

    private static void Safely(Action action)
    {
      // Nothing may escape into libwebrtc's threads.
      try { action(); }
      catch (Exception ex) { Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " link: callback failed (" + ex.GetType().Name + ")"); }
    }

    public required CreateFn Create { get; init; }
    public required HandleFn Offer { get; init; }
    public required TextFn Answer { get; init; }
    public required TextFn Accept { get; init; }
    public required CandidateInFn AddCandidate { get; init; }
    public required SendFn Send { get; init; }
    public required BufferedFn Buffered { get; init; }
    public required HandleFn Stats { get; init; }
    public required HandleFn Close { get; init; }
    public required CountFn AudioRefused { get; init; }

    private const uint LoadLibrarySearchDllLoadDir = 0x00000100, LoadLibrarySearchSystem32 = 0x00000800;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string fileName, IntPtr file, uint flags);

    public static Native Load(string directory)
    {
      var path = Path.Combine(directory, "tdlink.dll");
      if (!File.Exists(path) || !File.Exists(Path.Combine(directory, "libwebrtc.dll")))
        throw new DllNotFoundException("The direct link's engine (tdlink.dll, libwebrtc.dll) is not next to the app.");
      // Only this folder and System32 may supply the engine's DLLs (Security D1): never the current directory or PATH,
      // even unpackaged or on a PC missing one of libwebrtc's system DLLs.
      var library = LoadLibraryExW(path, IntPtr.Zero, LoadLibrarySearchDllLoadDir | LoadLibrarySearchSystem32);
      if (library == IntPtr.Zero) throw new DllNotFoundException("The direct link's engine could not be loaded (Windows error " + Marshal.GetLastWin32Error() + ").");
      T Export<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(library, name));
      var callbacks = new Callbacks
      {
        Candidate = Marshal.GetFunctionPointerForDelegate(OnCandidate), State = Marshal.GetFunctionPointerForDelegate(OnState),
        Message = Marshal.GetFunctionPointerForDelegate(OnMessage), Sdp = Marshal.GetFunctionPointerForDelegate(OnSdp),
        Stats = Marshal.GetFunctionPointerForDelegate(OnStats)
      };
#if DEBUG
      // Diagnostics, debug builds only (W5: the log holds connection addresses): TD_LINK_LOG=<file> appends libwebrtc's log.
      if (Environment.GetEnvironmentVariable("TD_LINK_LOG") is { Length: > 0 } log) { using var logPath = new Utf8(log); _ = Export<LogFn>("tdl_log")(logPath.Pointer); }
#endif
      if (Export<InitFn>("tdl_init")(ref callbacks) != 1) throw new InvalidOperationException("The direct link's engine did not start.");
      return new Native
      {
        Create = Export<CreateFn>("tdl_create"), Offer = Export<HandleFn>("tdl_offer"), Answer = Export<TextFn>("tdl_answer"),
        Accept = Export<TextFn>("tdl_accept"), AddCandidate = Export<CandidateInFn>("tdl_add_candidate"), Send = Export<SendFn>("tdl_send"),
        Buffered = Export<BufferedFn>("tdl_buffered"), Stats = Export<HandleFn>("tdl_stats"), Close = Export<HandleFn>("tdl_close"),
        AudioRefused = Export<CountFn>("tdl_audio_refused")
      };
    }
  }
}

/// One peer connection with the contract's three channels (td.rt 1, td.rel 2, td.ctl 3), as libwebrtc runs it.
public sealed class WebRtcLink : ILinkConnection, ILinkAnswerConnection
{
  /// A td.ctl message is refused (the link has failed) when this much already waits to go.
  public const long MostQueuedControl = 8 * 1024 * 1024;

  internal abstract record Event
  {
    internal sealed record Candidate(string Sdp, string? Mid, int Index) : Event;
    internal sealed record State(int What, int Value) : Event;
    internal sealed record Message(int Lane, byte[] Data) : Event;
  }

  private static readonly ConcurrentDictionary<IntPtr, WebRtcLink> Live = new();
  private static long nextId;

  private readonly WebRtcLinkEngine.Native api;
  private readonly LinkEvents events;
  private readonly IntPtr id;
  private readonly IntPtr handle;
  private readonly System.Threading.Channels.Channel<Event> queue =
    System.Threading.Channels.Channel.CreateUnbounded<Event>(new System.Threading.Channels.UnboundedChannelOptions { SingleReader = true });
  private readonly MemoryStream?[] joining = new MemoryStream?[4];
  private readonly object[] laneGates = [new(), new(), new(), new()];
  private readonly int[] channelStates = new int[4];
  private readonly object closeGate = new();
  private TaskCompletionSource<string>? described;
  private TaskCompletionSource<string>? measured;
  private CancellationTokenSource? disconnected;
  private int closed;
  private bool announced;
  // libwebrtc drops a candidate added before the remote description is set: hold them until then (contract §2.4).
  private bool remoteSet;
  private readonly List<(string Candidate, string? Mid, int Index)> early = [];
  public bool Offerer { get; }
  public string Path { get; private set; } = "";
  /// The selected path crosses TCP (a TURN leg over TCP/TLS on either side): video then goes the reliable way (M5).
  public bool OverTcp { get; private set; }

  private WebRtcLink(WebRtcLinkEngine.Native api, LinkEvents events, IntPtr id, IntPtr handle, bool offerer)
  {
    this.api = api; this.events = events; this.id = id; this.handle = handle; Offerer = offerer;
  }

  internal static WebRtcLink Create(WebRtcLinkEngine engine, LinkServers servers, LinkEvents events, bool offerer)
  {
    // One libwebrtc entry per URL, the server's login on each; at most 8, only stun:/turn:/turns: (libwebrtc refuses
    // the whole configuration for one bad URL).
    var rows = servers.Servers.SelectMany(s => s.Urls.Select(u => (Url: u, s.Username, s.Credential)))
      .Where(r => r.Url.Length <= 512 && !r.Url.Any(char.IsWhiteSpace) && !r.Url.Any(char.IsControl) &&
        (r.Url.StartsWith("stun:", StringComparison.Ordinal) || r.Url.StartsWith("turn:", StringComparison.Ordinal) || r.Url.StartsWith("turns:", StringComparison.Ordinal)))
      .Take(8).ToArray();
    var policy = servers.Policy switch { "nohost" => 1, "relay" => 2, _ => 0 };
    var id = (IntPtr)Interlocked.Increment(ref nextId);
    var texts = rows.SelectMany(r => new[] { r.Url, r.Username ?? "", r.Credential ?? "" }).Select(t => new Utf8(t)).ToArray();
    IntPtr made;
    try
    {
      IntPtr[] Column(int at) => Enumerable.Range(0, rows.Length).Select(i => texts[i * 3 + at].Pointer).ToArray();
      var urls = GCHandle.Alloc(Column(0), GCHandleType.Pinned);
      var usernames = GCHandle.Alloc(Column(1), GCHandleType.Pinned);
      var credentials = GCHandle.Alloc(Column(2), GCHandleType.Pinned);
      try { made = engine.Api.Create(id, rows.Length, urls.AddrOfPinnedObject(), usernames.AddrOfPinnedObject(), credentials.AddrOfPinnedObject(), policy); }
      finally { urls.Free(); usernames.Free(); credentials.Free(); }
    }
    finally { foreach (var text in texts) text.Dispose(); }
    if (made == IntPtr.Zero) throw new InvalidOperationException("The direct link could not be made with these ICE servers.");
    var link = new WebRtcLink(engine.Api, events, id, made, offerer);
    // Callbacks that came before the link was registered are lost; libwebrtc sends none before offer/answer.
    Live[id] = link;
    _ = Task.Run(link.PumpAsync);
    return link;
  }

  internal static WebRtcLink? Find(IntPtr id) => Live.TryGetValue(id, out var link) ? link : null;

  internal void Queue(Event item) { if (Volatile.Read(ref closed) == 0) queue.Writer.TryWrite(item); }

  internal void Described(int op, bool ok, string text)
  {
    var waiting = Interlocked.Exchange(ref described, null);
    // Off libwebrtc's thread: adding a candidate blocks on that thread.
    if (ok && op is 1 or 2) _ = Task.Run(RemoteReady);
    if (ok) waiting?.TrySetResult(text);
    else waiting?.TrySetException(new InvalidOperationException("WebRTC: " + text));
  }

  internal void Measured(string json) => Interlocked.Exchange(ref measured, null)?.TrySetResult(json);

  // Every native call on this link runs under `closeGate` after a closed check, so none can reach a handle `Shut` has
  // closed (W8: a phone disconnecting right after hello closed the link while the offer was being made). The tdl_*
  // calls only start libwebrtc's work and return, so holding the lock cannot deadlock.
  private Task<string> Describe(Action start, CancellationToken ct)
  {
    var waiting = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
    lock (closeGate)
    {
      if (closed != 0) return Task.FromException<string>(new InvalidOperationException("The direct link closed."));
      if (Interlocked.CompareExchange(ref described, waiting, null) is not null) throw new InvalidOperationException("One description at a time.");
      start();
    }
    return waiting.Task.WaitAsync(TimeSpan.FromSeconds(10), ct);
  }

  public Task<string> OfferAsync(CancellationToken cancellationToken) => Describe(() => api.Offer(handle), cancellationToken);
  public Task<string> AnswerAsync(string offer, CancellationToken cancellationToken) => Describe(() => { using var text = new Utf8(offer); api.Answer(handle, text.Pointer); }, cancellationToken);
  public Task AcceptAsync(string answer, CancellationToken cancellationToken) => Describe(() => { using var text = new Utf8(answer); api.Accept(handle, text.Pointer); }, cancellationToken);

  public void AddCandidate(string candidate, string? mid, int index)
  {
    lock (closeGate)
    {
      if (closed != 0) return;
      if (!remoteSet) { if (early.Count < 64) early.Add((candidate, mid, index)); return; }
      Add(candidate, mid, index);
    }
  }

  private void Add(string candidate, string? mid, int index)
  {
    using var c = new Utf8(candidate);
    using var m = new Utf8(mid);
    api.AddCandidate(handle, c.Pointer, m.Pointer, index);
  }

  private void RemoteReady()
  {
    lock (closeGate)
    {
      if (closed != 0 || remoteSet) return;
      remoteSet = true;
      foreach (var (candidate, mid, index) in early) Add(candidate, mid, index);
      early.Clear();
    }
  }

  public bool Send(ReadOnlySpan<byte> message, LinkLane lane)
  {
    var number = (int)lane;
    if (number is < 1 or > 3) return false;
    // One message's parts go together: two senders on one channel (two watched screens) never interleave parts.
    lock (laneGates[number])
    lock (closeGate)
    {
      if (closed != 0 || Volatile.Read(ref channelStates[number]) != 1) return false;
      var queued = (long)api.Buffered(handle, number);
      if (lane == LinkLane.Moving && queued > LinkFrames.MostQueuedMoving) return false;
      if (queued + message.Length > MostQueuedControl) return false;
      foreach (var part in LinkFrames.Parts(message))
      {
        var pinned = GCHandle.Alloc(part, GCHandleType.Pinned);
        try { if (api.Send(handle, number, pinned.AddrOfPinnedObject(), part.Length) != 1) return false; }
        finally { pinned.Free(); }
      }
      return true;
    }
  }

  public long Queued(LinkLane lane) { lock (closeGate) return closed != 0 ? 0 : (long)api.Buffered(handle, (int)lane); }

  public void Close() => Shut(null);

  // `why` null = closed by its owner (no Closed event, contract: never after Close()).
  private void Shut(string? why)
  {
    lock (closeGate)
    {
      if (closed != 0) return;
      closed = 1;
      Live.TryRemove(id, out _);
      queue.Writer.TryComplete();
      disconnected?.Cancel();
      api.Close(handle);
    }
    Interlocked.Exchange(ref described, null)?.TrySetException(new InvalidOperationException("The direct link closed."));
    Interlocked.Exchange(ref measured, null)?.TrySetResult("[]");
    if (why is not null)
    {
      try { events.Closed(why); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " link: closed handler failed (" + ex.GetType().Name + ")"); }
    }
  }

  private async Task PumpAsync()
  {
    try
    {
      await foreach (var item in queue.Reader.ReadAllAsync().ConfigureAwait(false))
      {
        if (Volatile.Read(ref closed) != 0) return;
        switch (item)
        {
          case Event.Candidate c: events.Candidate(c.Sdp, c.Mid, c.Index); break;
          case Event.Message m when m.Lane is >= 1 and <= 3:
            switch (LinkFrames.Join(m.Data, ref joining[m.Lane], out var whole))
            {
              case LinkFrames.Result.Whole: events.Message(whole!, (LinkLane)m.Lane); break;
              case LinkFrames.Result.Failure: Shut("The direct connection sent a broken message."); return;
            }
            break;
          case Event.State s: await StateAsync(s.What, s.Value).ConfigureAwait(false); break;
        }
      }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Shut("The direct link stopped (" + ex.GetType().Name + ")."); }
  }

  // libwebrtc's states (webrtc-sdk include/rtc_peerconnection.h, rtc_data_channel.h).
  private async Task StateAsync(int what, int value)
  {
    if (what == 0)
    {
      // Peer connection: 2 connected, 4 failed, 5 closed.
      if (value == 4) Shut("The direct connection failed.");
      else if (value == 5) Shut("The direct connection closed.");
      else if (value == 2) await AnnounceIfOpenAsync().ConfigureAwait(false);
      return;
    }
    if (what == 1)
    {
      // ICE: 2 completed, 3 connected, 4 failed, 5 disconnected (may recover: 5 s), 6 closed.
      switch (value)
      {
        case 4: Shut("The direct connection failed."); break;
        case 6: Shut("The direct connection closed."); break;
        case 5:
          if (disconnected is null)
          {
            var wait = disconnected = new CancellationTokenSource();
            _ = Task.Delay(LinkFrames.Disconnected, wait.Token).ContinueWith(t => { if (!t.IsCanceled) Shut("The direct connection was lost."); }, TaskScheduler.Default);
          }
          break;
        case 2: case 3:
          disconnected?.Cancel(); disconnected = null;
          break;
      }
      return;
    }
    var lane = what - 10;
    if (lane is < 1 or > 3) return;
    // Channel: 1 open, 3 closed.
    Volatile.Write(ref channelStates[lane], value);
    if (value == 3) Shut("The direct connection closed.");
    else if (value == 1) await AnnounceIfOpenAsync().ConfigureAwait(false);
  }

  private async Task AnnounceIfOpenAsync()
  {
    if (announced || channelStates[1] != 1 || channelStates[2] != 1 || channelStates[3] != 1) return;
    announced = true;
    var stats = await StatsAsync().ConfigureAwait(false);
    Path = stats is null ? "unknown" : PathFrom(stats);
    OverTcp = stats is not null && OverTcpFrom(stats);
    if (Volatile.Read(ref closed) == 0) events.Open(Path);
  }

  /// "host", "internet" or "turn": the selected candidate pair from libwebrtc's stats.
  public async Task<string> PathAsync() => await StatsAsync().ConfigureAwait(false) is { } json ? PathFrom(json) : "unknown";

  private async Task<string?> StatsAsync()
  {
    var waiting = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
    lock (closeGate)
    {
      if (closed != 0) return null;
      Interlocked.Exchange(ref measured, waiting)?.TrySetResult("[]");
      api.Stats(handle);
    }
    try { return await waiting.Task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false); }
    catch (TimeoutException) { return null; }
  }

  public static string PathFrom(string json)
  {
    try
    {
      if (SelectedPair(json) is not { } pair) return "unknown";
      var (local, remote) = pair;
      return LinkPaths.Name(local.ValueKind == JsonValueKind.Object ? Text(local, "candidateType") : null, local.ValueKind == JsonValueKind.Object ? Text(local, "address") ?? Text(local, "ip") : null,
        remote.ValueKind == JsonValueKind.Object ? Text(remote, "candidateType") : null, remote.ValueKind == JsonValueKind.Object ? Text(remote, "address") ?? Text(remote, "ip") : null);
    }
    catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or ArgumentException) { return "unknown"; }
  }

  /// M5: whether the selected pair crosses TCP. This side's relayed candidate says how it reaches its TURN server
  /// (`relayProtocol` tcp / tls); the other side's says it in its priority (libwebrtc's type preference, the top byte:
  /// relayed UDP 2, TCP 1, TLS 0).
  public static bool OverTcpFrom(string json)
  {
    try
    {
      if (SelectedPair(json) is not { } pair) return false;
      var (local, remote) = pair;
      if (local.ValueKind == JsonValueKind.Object && Text(local, "candidateType") == "relay" && Text(local, "relayProtocol") is "tcp" or "tls") return true;
      return remote.ValueKind == JsonValueKind.Object && Text(remote, "candidateType") == "relay" && remote.TryGetProperty("priority", out var priority) &&
        priority.ValueKind == JsonValueKind.Number && priority.TryGetInt64(out var value) && value >= 0 && (value >> 24) < 2;
    }
    catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException or ArgumentException) { return false; }
  }

  static string? Text(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

  /// The selected candidate pair's local and remote candidate reports (either may be missing), or null.
  static (JsonElement Local, JsonElement Remote)? SelectedPair(string json)
  {
    using var document = JsonDocument.Parse(json);
    var reports = document.RootElement.EnumerateArray().Where(r => r.ValueKind == JsonValueKind.Object && r.TryGetProperty("id", out _))
      .ToDictionary(r => r.GetProperty("id").GetString()!, r => r.Clone());
    var pair = reports.Values.Where(r => Text(r, "type") == "transport").Select(r => Text(r, "selectedCandidatePairId")).FirstOrDefault(p => p is not null) is { } selected && reports.TryGetValue(selected, out var chosen)
      ? chosen
      : reports.Values.FirstOrDefault(r => Text(r, "type") == "candidate-pair" && Text(r, "state") == "succeeded" && r.TryGetProperty("nominated", out var n) && n.ValueKind == JsonValueKind.True);
    if (pair.ValueKind != JsonValueKind.Object) return null;
    reports.TryGetValue(Text(pair, "localCandidateId") ?? "", out var local);
    reports.TryGetValue(Text(pair, "remoteCandidateId") ?? "", out var remote);
    return (local, remote);
  }
}

/// A UTF-8, zero-terminated copy of a string for the native side (null stays null).
internal sealed class Utf8(string? text) : IDisposable
{
  public IntPtr Pointer { get; private set; } = text is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(text);
  public void Dispose() { if (Pointer != IntPtr.Zero) { Marshal.FreeCoTaskMem(Pointer); Pointer = IntPtr.Zero; } }
}
