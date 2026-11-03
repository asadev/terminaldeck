using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

// stream step 2 (dc2): the test kit shared by the Core link tests (in-memory link, on the Mac) and the Windows tests
// (real WebRTC through tdlink.dll + libwebrtc.dll, on the PC): a simulated relay, a contract-exact dc2 client, the
// real RelayHostConnection + PhoneLink host, and an in-memory stand-in for a WebRTC stack.

internal static class LinkKit
{
  public const double RelayOneWayMs = 132;

  public static (DeviceTrust Trust, string Credential, NoiseIdentity Phone) Approved(PhoneAccess access = PhoneAccess.Full)
  {
    var phone = NoiseIdentity.Generate();
    var trust = new DeviceTrust(new LinkTrustStore());
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Approve(receipt.DeviceId, access);
    return (trust, receipt.Credential, phone);
  }

  /// A phone's hello: `link` = it answers a direct link (`link.dc2`); `only` = it speaks link only (`link.only`, §11).
  public static byte[] Hello(string token, bool link, bool only = true, string platform = "iOS 26.1") => JsonSerializer.SerializeToUtf8Bytes(new
  {
    t = "hello", protocol = 1, token, device = new { name = "Phone", platform },
    capabilities = link ? only ? new[] { "device.access", "link.dc2", "link.only" } : ["device.access", "link.dc2"] : ["device.access"]
  });

  public static double Median(IReadOnlyList<double> values) { var s = values.Order().ToArray(); return s.Length == 0 ? double.NaN : s.Length % 2 == 1 ? s[s.Length / 2] : (s[s.Length / 2 - 1] + s[s.Length / 2]) / 2; }
  public static double P90(IReadOnlyList<double> values) { var s = values.Order().ToArray(); return s.Length == 0 ? double.NaN : s[Math.Min(s.Length - 1, (int)Math.Ceiling(s.Length * 0.9) - 1)]; }
}

internal sealed class LinkTrustStore : IDeviceTrustPersistence
{
  private IReadOnlyList<StoredDevice> rows = [];
  public IReadOnlyList<StoredDevice> Load() => rows;
  public void Save(IReadOnlyList<StoredDevice> devices) => rows = devices;
}

internal sealed class LinkSessionView : IPhoneSessionView
{
  public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => [];
}

/// The client end of a link: an answerer.
internal interface ILinkAnswerer
{
  Task<string> AnswerAsync(string offer);
  void AddCandidate(string candidate, string? mid, int index);
  bool Send(ReadOnlySpan<byte> message, LinkLane lane);
  void Close();
}

internal sealed class LinkHarness : IAsyncDisposable
{
  public required RelayHostConnection Connection { get; init; }
  public required LinkClient Client { get; init; }
  public required EchoApplication App { get; init; }
  public required string ChannelHex { get; init; }
  public required CancellationTokenSource Stop { get; init; }
  public required Task Running { get; init; }
  public required NoiseIdentity Host { get; init; }
  public required NoiseIdentity Phone { get; init; }
  public required SimRelay Relay { get; init; }

  /// A host with `setup` (null = no link stack) and a dc2 client whose answerer `answerer` makes, on a simulated relay.
  public static async Task<LinkHarness> StartAsync(LinkSetup? setup, Func<LinkServers, LinkEvents, ILinkAnswerer> answerer, bool askLink,
    bool forge = false, double oneWayMs = LinkKit.RelayOneWayMs, bool neverMark = false, bool waitMoved = true, EchoApplication? application = null,
    PhoneAccess access = PhoneAccess.Full, bool only = true)
  {
    var host = NoiseIdentity.Generate();
    var (trust, credential, phone) = LinkKit.Approved(access);
    var app = application ?? new EchoApplication(trust);
    app.Trust = trust;
    // Who may have a link and a TURN login comes from this trust store (Security M2), as in the app.
    var connection = new RelayHostConnection(host, app, linkSetup: setup is null ? null : setup with { Eligible = LinkEligibility.For(trust) });
    var relay = new SimRelay(oneWayMs);
    var client = new LinkClient(answerer, phone, relay, forge, neverMark) { Only = askLink && only };
    relay.ToClient = new Pipe(oneWayMs, client.FromRelay);
    var stop = new CancellationTokenSource();
    // As the relay client runs it: the connection may outlive this relay socket (a link-only phone's link, §11.4).
    var running = connection.RunAsync(relay.HostSocket, stop.Token, keepLinks: true);
    await client.OpenAsync(host.PublicKey);
    await client.SendAsync(LinkKit.Hello(credential, askLink, only));
    // Direct only: a client that cannot make the link is refused at the hello (no welcome; the channel closes).
    await client.WaitAsync(() => client.Welcome is not null || client.Closed, 5_000);
    if (askLink && setup is not null) Assert.NotNull(client.Welcome);
    var run = new LinkHarness { Connection = connection, Client = client, App = app, ChannelHex = Convert.ToHexStringLower(client.ChannelId), Stop = stop, Running = running, Host = host, Phone = phone, Relay = relay };
    if (askLink && waitMoved && setup is not null)
    {
      await client.WaitAsync(() => client.MovedAt is not null && connection.LinkRoute(run.ChannelHex) is not null, 15_000);
      Assert.NotNull(connection.LinkRoute(run.ChannelHex));
    }
    return run;
  }

  // `count` keystroke-style round trips, one at a time: the times in ms.
  public async Task<List<double>> EchoesAsync(int count)
  {
    var times = new List<double>();
    for (var n = 0; n < count; n++)
    {
      var waiter = Client.EchoWaiter(1_000_000 + n);
      var started = Stopwatch.GetTimestamp();
      await Client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 1_000_000 + n }));
      await waiter.WaitAsync(TimeSpan.FromSeconds(5));
      times.Add(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
      await Task.Delay(20);
    }
    return times;
  }

  public async ValueTask DisposeAsync()
  {
    Client.Close();
    await Stop.CancelAsync();
    try { await Running; } catch (OperationCanceledException) { }
    await Connection.DisposeAsync();
    Host.Dispose(); Phone.Dispose();
  }
}

// The host's chain: PhoneLink for the hello (a real approved device), plus a numbered echo and host pushes.
internal class EchoApplication(DeviceTrust? trust = null) : IRelayPhoneApplication, IW9PhonePushApplication
{
  private PhoneLink? inner;
  public DeviceTrust Trust { get => trust!; set { trust = value; inner = new PhoneLink(value, "Test PC", "0.1", new LinkSessionView()); } }
  private readonly List<int> applied = [];
  public Func<string, byte[], CancellationToken, ValueTask>? Publisher { get; private set; }
  public IReadOnlyCollection<byte[]> KnownPeers => trust!.KnownPeers;
  public bool PairingOpen => false;
  public int[] Applied() { lock (applied) return [.. applied.Where(n => n < 1_000_000)]; }
  public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publisher) => Publisher = publisher;
  /// A test's own messages (video, ...) before the echo and PhoneLink; null = not handled.
  protected virtual ValueTask<PhoneApplicationReply>? Extra(string channel, string type, JsonElement message, CancellationToken ct) => null;
  public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, CancellationToken ct)
  {
    using var doc = JsonDocument.Parse(plaintext);
    if (Extra(channel, doc.RootElement.GetProperty("t").GetString() ?? "", doc.RootElement, ct) is { } extra) return extra;
    if (doc.RootElement.GetProperty("t").GetString() == "ping" && doc.RootElement.TryGetProperty("slowMs", out var slowMs))
    {
      // A meeting frame that takes a while to answer: the hand-over hold must wait for it (W7).
      Thread.Sleep(slowMs.GetInt32());
      return ValueTask.FromResult(new PhoneApplicationReply([JsonSerializer.SerializeToUtf8Bytes(new { t = "pong" })]));
    }
    if (doc.RootElement.GetProperty("t").GetString() == "test.slow")
    {
      // A request that takes a while to answer (a slow attach): the hand-over hold must wait for it (W7).
      Thread.Sleep(doc.RootElement.GetProperty("ms").GetInt32());
      return ValueTask.FromResult(new PhoneApplicationReply([JsonSerializer.SerializeToUtf8Bytes(new { t = "test.slowed" })]));
    }
    if (doc.RootElement.GetProperty("t").GetString() == "test.echo")
    {
      var n = doc.RootElement.GetProperty("n").GetInt32();
      lock (applied) applied.Add(n);
      return ValueTask.FromResult(new PhoneApplicationReply([JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echoed", n })]));
    }
    return inner!.ReceiveAsync(channel, peerKey, plaintext, ct);
  }
  public virtual ValueTask DisconnectedAsync(string channel) => inner!.DisconnectedAsync(channel);
}

// ---- the simulated relay ------------------------------------------------------------------------------------------

// One direction: in order, each packet `oneWayMs` after it was given.
internal sealed class Pipe
{
  private readonly System.Threading.Channels.Channel<(byte[] Data, long Due)> queue = System.Threading.Channels.Channel.CreateUnbounded<(byte[], long)>();
  private readonly long delay;
  private volatile bool open = true;
  public Pipe(double oneWayMs, Action<byte[]> deliver)
  {
    delay = (long)(oneWayMs * Stopwatch.Frequency / 1000);
    _ = Task.Run(async () =>
    {
      await foreach (var (data, due) in queue.Reader.ReadAllAsync())
      {
        var wait = (due - Stopwatch.GetTimestamp()) * 1000.0 / Stopwatch.Frequency;
        if (wait > 1) await Task.Delay(TimeSpan.FromMilliseconds(wait));
        if (open) deliver(data);
      }
    });
  }
  public void Carry(byte[] data) { if (open) queue.Writer.TryWrite((data, Stopwatch.GetTimestamp() + delay)); }
  public void Shut() { open = false; queue.Writer.TryComplete(); }
}

internal sealed class SimRelay
{
  private readonly System.Threading.Channels.Channel<byte[]> hostInbox = System.Threading.Channels.Channel.CreateUnbounded<byte[]>();
  public Pipe ToHost { get; }
  public Pipe? ToClient { get; set; }
  public IRelaySocket HostSocket { get; }
  /// The host's relay socket ends (Cloudflare resets it): everything on it goes, the phone's too.
  public void EndHostSocket() { ToHost.Shut(); ToClient?.Shut(); hostInbox.Writer.TryComplete(); }
  public SimRelay(double oneWayMs)
  {
    ToHost = new Pipe(oneWayMs, data => hostInbox.Writer.TryWrite(data));
    HostSocket = new Socket(this);
  }
  private sealed class Socket(SimRelay relay) : IRelaySocket
  {
    public Task ConnectAsync(Uri hostAddress, ReadOnlyMemory<byte> hostSecret, CancellationToken cancellationToken) => Task.CompletedTask;
    public ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken cancellationToken) { relay.ToClient?.Carry(packet.ToArray()); return ValueTask.CompletedTask; }
    public async ValueTask<byte[]?> ReceiveAsync(CancellationToken cancellationToken)
    {
      try { return await relay.hostInbox.Reader.ReadAsync(cancellationToken); }
      catch (System.Threading.Channels.ChannelClosedException) { return null; }
    }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
}

// ---- a dc2 client exactly as the contract says (§2–§7) --------------------------------------------------------------

internal sealed class LinkClient(Func<LinkServers, LinkEvents, ILinkAnswerer> makeAnswerer, NoiseIdentity phone, SimRelay relay, bool forge, bool neverMark)
{
  public byte[] ChannelId { get; } = RandomNumberGenerator.GetBytes(16);
  private NoisePending? pending;
  private NoiseTransport? transport;
  private readonly TaskCompletionSource handshake = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private readonly SemaphoreSlim sendGate = new(1, 1);
  private readonly object gate = new();
  private ILinkAnswerer? link;
  private bool moved, hostMoved;
  /// This client speaks link only (§11): every message after the hello on the link (pings too), the host's td.ctl
  /// taken at once when the welcome says `link.only`, late candidates from td.ctl.
  public bool Only { get; init; }
  private bool hostOnly;
  private readonly List<byte[]> held = [];
  private readonly ConcurrentDictionary<int, TaskCompletionSource> echoWaiters = new();
  private readonly long started = Stopwatch.GetTimestamp();
  private double? welcomedAt;
  public volatile bool Closed;
  public JsonElement? Welcome;
  public JsonElement? Offer;
  public double? MovedAt;
  public double ConnectMs => MovedAt is { } m && welcomedAt is { } w ? m - w : double.NaN;
  public volatile bool EndFromHost;
  public string? LinkEnded;
  public readonly List<int> Echoed = [], Pushed = [];
  /// Any other message (video, …), under the client's lock and in arrival order.
  public Action<JsonElement, bool, LinkLane>? Other { get; set; }
  public int ViaLink, ViaRelay, EchoesFromRelay, PushesFromRelay, PongsViaLink, PongsViaRelay, PingsOnRelay, CandidatesFromHost, CandidatesAfterHostMoved, CandidatesOnLink, VideoOnMoving, VideoOnStill;
  /// `error` messages as (code, rid, message, via the link).
  public readonly List<(string? Code, string? Rid, string? Message, bool ViaLink)> Errors = [];
  private double Now => Stopwatch.GetElapsedTime(started).TotalMilliseconds;

  public async Task OpenAsync(byte[] hostKey)
  {
    var start = NoiseChannel.Start(phone, hostKey);
    pending = start.Pending;
    relay.ToHost.Carry(new RelayPacket(RelayKind.Open, ChannelId, []).Encode());
    relay.ToHost.Carry(new RelayPacket(RelayKind.Data, ChannelId, RelayPacket.FrameHandshake(start.Message)).Encode());
    await handshake.Task.WaitAsync(TimeSpan.FromSeconds(5));
  }

  public Task WaitAsync(Func<bool> done, int ms) => Task.Run(async () =>
  {
    var deadline = Stopwatch.GetTimestamp() + ms * Stopwatch.Frequency / 1000;
    while (Stopwatch.GetTimestamp() < deadline) { lock (gate) if (done()) return; await Task.Delay(10); }
  });

  public Task EchoWaiter(int n) => echoWaiters.GetOrAdd(n, _ => new(TaskCreationOptions.RunContinuationsAsynchronously)).Task;

  // Link only (§11): after the hello everything waits for this side's move and goes on the link's td.ctl, pings
  // included. An older dc2 client (Only false): the relay until it moved, the link after it, `ping` always the relay.
  // SendOnRelayAsync is the test's way to put anything on the relay anyway.
  public async Task SendAsync(byte[] message)
  {
    var type = LinkAsk.Type(message);
    if (Only && type != "hello") await WaitAsync(() => moved || Closed || EndFromHost, 20_000);
    await sendGate.WaitAsync();
    try
    {
      if (type == "hello" || (!Only && (!moved || type == "ping"))) { if (type == "ping" && moved) Interlocked.Increment(ref PingsOnRelay); Relay(message); return; }
      if (!moved) { LinkEnded ??= "no link to send on"; return; }
      if (link?.Send(message, LinkLane.Control) != true) LinkEnded ??= "a send on the link was refused";
    }
    finally { sendGate.Release(); }
  }

  /// A message over the relay as is, whatever this side's state (the host must refuse anything but the meeting).
  public async Task SendOnRelayAsync(byte[] message)
  {
    await sendGate.WaitAsync();
    try { Relay(message); }
    finally { sendGate.Release(); }
  }

  // Signalling: always the relay.
  private async Task SignalAsync(object frame)
  {
    await sendGate.WaitAsync();
    try { Relay(JsonSerializer.SerializeToUtf8Bytes(frame)); }
    finally { sendGate.Release(); }
  }

  private void Relay(byte[] message) => relay.ToHost.Carry(new RelayPacket(RelayKind.Data, ChannelId, transport!.Send(message)).Encode());

  public void FromRelay(byte[] frame)
  {
    var packet = RelayPacket.Decode(frame);
    if (packet.Kind == RelayKind.Close) { Closed = true; link?.Close(); return; }
    if (transport is null)
    {
      transport = NoiseChannel.Finish(pending!, RelayPacket.ReadHandshake(packet.Payload, false));
      handshake.TrySetResult();
      return;
    }
    using var doc = JsonDocument.Parse(transport.Receive(packet.Payload));
    var root = doc.RootElement.Clone();
    switch (root.GetProperty("t").GetString())
    {
      case "link.peer": Signal(root); break;
      case "link.moved":
        lock (gate)
        {
          hostMoved = true;
          foreach (var data in held) Handle(Parse(data), viaLink: true);
          held.Clear();
        }
        break;
      default: lock (gate) Handle(root, viaLink: false); break;
    }
  }

  private static JsonElement Parse(byte[] data) { using var doc = JsonDocument.Parse(data); return doc.RootElement.Clone(); }

  private void Signal(JsonElement value)
  {
    switch (value.GetProperty("op").GetString())
    {
      case "offer":
      {
        Offer = value;
        var sdp = value.GetProperty("sdp").GetString()!; var fp = value.GetProperty("fp").GetString()!;
        if (LinkBinding.Fingerprint(sdp) != fp || !LinkBinding.Check(value.GetProperty("bind").GetString(), transport!.ChannelBinding, "host", fp))
        { _ = SignalAsync(new { t = "link.peer", op = "end" }); return; }
        var events = new LinkEvents(
          (c, mid, idx) => _ = SignalAsync(new { t = "link.peer", op = "cand", c, mid, idx }),
          route => _ = OpenedAsync(),
          why => LinkEnded ??= why,
          (data, lane) =>
          {
            var parsed = Parse(data);
            // §11.4: a link-only host's late candidates come on td.ctl too.
            if (Only && hostOnly && lane == LinkLane.Control && parsed.GetProperty("t").GetString() == "link.peer")
            {
              if (parsed.GetProperty("op").GetString() == "cand") { Interlocked.Increment(ref CandidatesOnLink); link?.AddCandidate(parsed.GetProperty("c").GetString()!, null, 0); }
              return;
            }
            lock (gate)
            {
              // §5: td.ctl waits for the host's marker, unless both speak link only (§11.2).
              if (lane == LinkLane.Control && !hostMoved && !(Only && hostOnly)) { held.Add(data); return; }
              Handle(parsed, viaLink: true, lane);
            }
          });
        var servers = new LinkServers(value.GetProperty("ice").EnumerateArray().Select(s => new LinkIceServer(
          s.GetProperty("urls").EnumerateArray().Select(u => u.GetString()!).ToArray(),
          s.TryGetProperty("username", out var u) ? u.GetString() : null, s.TryGetProperty("credential", out var c) ? c.GetString() : null)).ToArray(),
          value.GetProperty("policy").GetString() ?? "all");
        // A client that has closed never opens a link afterwards (an offer may still be on its way in).
        if (clientClosed) return;
        var made = link = makeAnswerer(servers, events);
        if (clientClosed) { made.Close(); return; }
        _ = AnswerAsync(made, sdp);
        break;
      }
      case "cand":
        Interlocked.Increment(ref CandidatesFromHost);
        lock (HostCandidates) HostCandidates.Add(value.GetProperty("c").GetString()!);
        lock (gate) if (hostMoved) CandidatesAfterHostMoved++;
        link?.AddCandidate(value.GetProperty("c").GetString()!, value.TryGetProperty("mid", out var mid) ? mid.GetString() : null, value.GetProperty("idx").GetInt32());
        break;
      case "end":
        EndFromHost = true; link?.Close(); link = null;
        break;
    }
  }

  private async Task AnswerAsync(ILinkAnswerer made, string offer)
  {
    string answer;
    try { answer = await made.AnswerAsync(offer); }
    catch (Exception ex) { LinkEnded ??= "answer failed: " + ex.Message; return; }
    var mine = LinkBinding.Fingerprint(answer)!;
    var key = forge ? Enumerable.Repeat((byte)1, 32).ToArray() : transport!.ChannelBinding;
    await SignalAsync(new { t = "link.peer", op = "answer", sdp = answer, fp = mine, bind = LinkBinding.Make(key, "client", mine) });
    AnswerSent = true;
  }
  /// The answer is on its way to the host (anything sent after this reaches it after the answer).
  public volatile bool AnswerSent;

  // Every channel open: the marker as the last relay message, then everything on the link.
  private async Task OpenedAsync()
  {
    await sendGate.WaitAsync();
    try
    {
      if (moved) return;
      if (!neverMark) Relay(RelayHostConnection.MovedText);
      moved = true;
      MovedAt = Now;
    }
    finally { sendGate.Release(); }
  }

  // Called holding `gate`.
  private void Handle(JsonElement value, bool viaLink, LinkLane lane = LinkLane.Control)
  {
    var type = value.GetProperty("t").GetString();
    if (viaLink) ViaLink++; else ViaRelay++;
    switch (type)
    {
      case "welcome":
        Welcome = value; welcomedAt = Now;
        hostOnly = value.TryGetProperty("capabilities", out var caps) && caps.EnumerateArray().Any(c => c.GetString() == LinkBinding.OnlyCapability);
        break;
      case "test.echoed":
      {
        var n = value.GetProperty("n").GetInt32();
        if (n < 1_000_000) { Echoed.Add(n); if (!viaLink) EchoesFromRelay++; }
        echoWaiters.GetOrAdd(n, _ => new(TaskCreationOptions.RunContinuationsAsynchronously)).TrySetResult();
        break;
      }
      case "test.push": Pushed.Add(value.GetProperty("n").GetInt32()); if (!viaLink) PushesFromRelay++; break;
      case "pong": if (viaLink) PongsViaLink++; else PongsViaRelay++; break;
      case "error":
        Errors.Add((value.TryGetProperty("code", out var code) ? code.GetString() : null, value.TryGetProperty("rid", out var rid) ? rid.GetString() : null,
          value.TryGetProperty("message", out var text) ? text.GetString() : null, viaLink));
        break;
      case "test.video": if (lane == LinkLane.Moving) VideoOnMoving++; else if (lane == LinkLane.Still) VideoOnStill++; break;
      default: Other?.Invoke(value, viaLink, lane); break;
    }
  }

  public void KillLink() => link?.Close();
  /// The host's candidates as they arrived (inside the sealed channel).
  public readonly List<string> HostCandidates = [];
  /// A message on one of the link's channels as is (the host must refuse video channels from a client — W3).
  public bool SendOnLane(byte[] message, LinkLane lane) => link?.Send(message, lane) == true;
  /// Candidates of our own choosing, as `link.peer cand` over the relay (W6).
  public Task SendCandidateAsync(string candidate) => SignalAsync(new { t = "link.peer", op = "cand", c = candidate, mid = "0", idx = 0 });
  /// The client goes away (the relay's Close for this channel), as a phone that drops right after hello.
  public void CloseChannel() => relay.ToHost.Carry(new RelayPacket(RelayKind.Close, ChannelId, []).Encode());
  private volatile bool clientClosed;
  public void Close() { clientClosed = true; link?.Close(); relay.ToHost.Shut(); relay.ToClient?.Shut(); }
}

// ---- an in-memory stand-in for a WebRTC stack -----------------------------------------------------------------------

internal sealed class MemoryNet
{
  public double OneWayMs { get; init; } = 0.3;
  public bool NeverConnect { get; init; }
  public int HostCandidatesAdded;
  private readonly ConcurrentDictionary<string, MemoryLink> byFingerprint = new();
  public MemoryLink Make(LinkEvents events, bool offerer) => new(this, events, offerer);
  internal void Register(MemoryLink link) => byFingerprint[link.Fingerprint] = link;
  internal MemoryLink? Find(string fingerprint) => byFingerprint.GetValueOrDefault(fingerprint);
}

/// The answering side for a desktop guest (LinkGuest), in memory.
internal sealed class MemoryAnswerEngine(MemoryNet net) : ILinkAnswerEngine
{
  public ILinkAnswerConnection ConnectAnswerer(LinkServers servers, LinkEvents events) => net.Make(events, offerer: false);
}

internal sealed class MemoryEngine(MemoryNet net) : ILinkEngine
{
  public int Connects;
  public ILinkConnection Connect(LinkServers servers, LinkEvents events) { Interlocked.Increment(ref Connects); return net.Make(events, offerer: true); }
}

internal sealed class MemoryLink : ILinkConnection, ILinkAnswerer, ILinkAnswerConnection
{
  private readonly MemoryNet net;
  private readonly LinkEvents events;
  private readonly bool offerer;
  private readonly System.Threading.Channels.Channel<(byte[] Part, LinkLane Lane, long Due)> incoming = System.Threading.Channels.Channel.CreateUnbounded<(byte[], LinkLane, long)>(new() { SingleReader = true });
  private readonly MemoryStream?[] joining = new MemoryStream?[4];
  private string? remoteFingerprint;
  private MemoryLink? peer;
  private volatile bool open;
  private int closed;
  private long movingQueued;
  public string Fingerprint { get; } = "sha-256 " + string.Join(":", RandomNumberGenerator.GetBytes(32).Select(b => b.ToString("X2")));

  public MemoryLink(MemoryNet net, LinkEvents events, bool offerer) { this.net = net; this.events = events; this.offerer = offerer; }

  private string Sdp() => "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" +
    "a=fingerprint:" + Fingerprint + "\r\na=setup:" + (offerer ? "actpass" : "active") + "\r\na=mid:0\r\n";

  private void Later(Action action, int ms = 1) => _ = Task.Run(async () => { await Task.Delay(ms); if (Volatile.Read(ref closed) == 0) action(); });

  public Task<string> OfferAsync(CancellationToken cancellationToken)
  {
    net.Register(this);
    Later(() => events.Candidate("candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host generation 0", "0", 0));
    return Task.FromResult(Sdp());
  }

  public Task<string> AnswerAsync(string offer) => Task.FromResult(Answer(offer));
  public Task<string> AnswerAsync(string offer, CancellationToken cancellationToken) => AnswerAsync(offer);

  public string Answer(string offer)
  {
    remoteFingerprint = LinkBinding.Fingerprint(offer);
    net.Register(this);
    Later(() => events.Candidate("candidate:1 1 udp 2122260223 192.168.1.21 50001 typ host generation 0", "0", 0));
    return Sdp();
  }

  // DTLS as a real stack does it: only the endpoint holding the answer's fingerprint can finish, and only if it pinned ours.
  public Task AcceptAsync(string answer, CancellationToken cancellationToken)
  {
    remoteFingerprint = LinkBinding.Fingerprint(answer) ?? throw new InvalidOperationException("The answer has no fingerprint.");
    var other = net.Find(remoteFingerprint);
    if (net.NeverConnect || other is null || other.remoteFingerprint != Fingerprint) return Task.CompletedTask;
    peer = other; other.peer = this;
    Later(() => { other.Opened(); Opened(); }, 20);
    return Task.CompletedTask;
  }

  private void Opened()
  {
    if (Volatile.Read(ref closed) != 0) return;
    open = true;
    _ = Task.Run(PumpAsync);
    events.Open("host");
    // A late candidate after the move (continual gathering).
    if (offerer) Later(() => events.Candidate("candidate:2 1 udp 1686052607 10.0.0.9 50002 typ srflx raddr 0.0.0.0 rport 0 generation 0", "0", 0), 400);
  }

  public void AddCandidate(string candidate, string? mid, int index) { if (offerer) Interlocked.Increment(ref net.HostCandidatesAdded); }

  public bool Send(ReadOnlySpan<byte> message, LinkLane lane)
  {
    var other = peer;
    if (!open || Volatile.Read(ref closed) != 0 || other is null) return false;
    if (lane == LinkLane.Moving && Interlocked.Read(ref movingQueued) > LinkFrames.MostQueuedMoving) return false;
    var due = Stopwatch.GetTimestamp() + (long)(net.OneWayMs * Stopwatch.Frequency / 1000);
    foreach (var part in LinkFrames.Parts(message))
    {
      if (lane == LinkLane.Moving) Interlocked.Add(ref movingQueued, part.Length);
      if (!other.incoming.Writer.TryWrite((part, lane, due))) return false;
    }
    return true;
  }

  private async Task PumpAsync()
  {
    await foreach (var (part, lane, due) in incoming.Reader.ReadAllAsync())
    {
      var wait = (due - Stopwatch.GetTimestamp()) * 1000.0 / Stopwatch.Frequency;
      if (wait > 1) await Task.Delay(TimeSpan.FromMilliseconds(wait));
      if (lane == LinkLane.Moving && peer is { } sender) Interlocked.Add(ref sender.movingQueued, -part.Length);
      if (Volatile.Read(ref closed) != 0) return;
      switch (LinkFrames.Join(part, ref joining[(int)lane], out var whole))
      {
        case LinkFrames.Result.Whole: events.Message(whole!, lane); break;
        case LinkFrames.Result.Failure: Lost("The direct connection sent a broken message."); return;
      }
    }
  }

  public void Close()
  {
    if (Interlocked.Exchange(ref closed, 1) != 0) return;
    open = false;
    incoming.Writer.TryComplete();
    var other = peer;
    if (other is not null) _ = Task.Run(() => other.Lost("The direct connection closed."));
  }

  private void Lost(string why)
  {
    if (Interlocked.Exchange(ref closed, 1) != 0) return;
    open = false;
    incoming.Writer.TryComplete();
    events.Closed(why);
  }
}
