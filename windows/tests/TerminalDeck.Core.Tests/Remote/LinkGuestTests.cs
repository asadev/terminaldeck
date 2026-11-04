using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

// "Other computers" on the direct link (contract §11): the production desktop guest (LinkGuest) against the real
// RelayHostConnection + PhoneLink host, on the simulated relay and the in-memory link.
public sealed class LinkGuestTests
{
  private sealed class Guest
  {
    public readonly byte[] ChannelId = RandomNumberGenerator.GetBytes(16);
    public readonly ConcurrentQueue<JsonElement> Inbox = new();
    public readonly ConcurrentQueue<JsonElement> FromRelayDelivered = new();
    public NoiseTransport? Transport;
    public LinkGuest? Link;
    public volatile bool Welcomed;
    public volatile Exception? Failed;
    public volatile bool RelayClosed;
    private NoisePending? pending;
    private readonly TaskCompletionSource handshake = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly SimRelay relay;
    private readonly object gate = new();
    public Guest(SimRelay relay) => this.relay = relay;

    public async Task OpenAsync(NoiseIdentity me, byte[] hostKey, ILinkAnswerEngine engine)
    {
      var start = NoiseChannel.Start(me, hostKey);
      pending = start.Pending;
      relay.ToHost.Carry(new RelayPacket(RelayKind.Open, ChannelId, []).Encode());
      relay.ToHost.Carry(new RelayPacket(RelayKind.Data, ChannelId, RelayPacket.FrameHandshake(start.Message)).Encode());
      await handshake.Task.WaitAsync(TimeSpan.FromSeconds(5));
      Link = new LinkGuest(engine, Transport!.ChannelBinding, (message, _) => { Seal(message); return Task.CompletedTask; }, m => Inbox.Enqueue(m), ex => Failed = ex);
    }

    public void Seal(byte[] message) { lock (gate) relay.ToHost.Carry(new RelayPacket(RelayKind.Data, ChannelId, Transport!.Send(message)).Encode()); }

    public void FromRelay(byte[] frame)
    {
      var packet = RelayPacket.Decode(frame);
      if (packet.Kind == RelayKind.Close) { RelayClosed = true; Link?.RelayClosed(); return; }
      if (Transport is null) { Transport = NoiseChannel.Finish(pending!, RelayPacket.ReadHandshake(packet.Payload, false)); handshake.TrySetResult(); return; }
      using var doc = JsonDocument.Parse(Transport.Receive(packet.Payload));
      var message = doc.RootElement.Clone();
      if (Welcomed && Link!.FromRelay(message)) return;
      if (!Welcomed && message.GetProperty("t").GetString() == "welcome") { Link!.Welcomed(message); Welcomed = true; }
      FromRelayDelivered.Enqueue(message);
    }

    public static Task WaitAsync(Func<bool> done, int ms) => Task.Run(async () =>
    {
      var until = Stopwatch.GetTimestamp() + ms * Stopwatch.Frequency / 1000;
      while (Stopwatch.GetTimestamp() < until && !done()) await Task.Delay(10);
    });
  }

  // Records the ICE servers the guest hands its engine.
  private sealed class Recording(MemoryNet net) : ILinkAnswerEngine
  {
    public LinkServers? Servers;
    public ILinkAnswerConnection ConnectAnswerer(LinkServers servers, LinkEvents events) { Servers = servers; return net.Make(events, offerer: false); }
  }

  private static async Task<(RelayHostConnection Host, Guest Guest, EchoApplication App, SimRelay Relay, Task Running, CancellationTokenSource Stop)> StartAsync(MemoryNet net, bool hostHasLink = true,
    ILinkAnswerEngine? engine = null, IReadOnlyList<LinkIceServer>? ice = null)
  {
    var host = NoiseIdentity.Generate();
    var (trust, credential, me) = LinkKit.Approved();
    var app = new EchoApplication(trust); app.Trust = trust;
    var setup = hostHasLink ? new LinkSetup(new MemoryEngine(net), (_, _) => ValueTask.FromResult(new LinkServers(ice ?? [LinkPaths.CloudflareStun], "all"))) { Eligible = LinkEligibility.For(trust), ReleaseAfter = TimeSpan.Zero } : null;
    var connection = new RelayHostConnection(host, app, linkSetup: setup);
    var relay = new SimRelay(20);
    var guest = new Guest(relay);
    relay.ToClient = new Pipe(20, guest.FromRelay);
    var stop = new CancellationTokenSource();
    var running = connection.RunAsync(relay.HostSocket, stop.Token, keepLinks: true);
    await guest.OpenAsync(me, host.PublicKey, engine ?? new MemoryAnswerEngine(net));
    guest.Seal(LinkKit.Hello(credential, link: true, only: true, platform: "win32"));
    await Guest.WaitAsync(() => guest.Welcomed, 5_000);
    Assert.True(guest.Welcomed);
    return (connection, guest, app, relay, running, stop);
  }

  [Theory]
  [InlineData("[]", true, "Update the host on your server to connect directly.")]
  [InlineData("[\"link.dc2\",\"link.only\"]", false, "Can't reach your server — this network blocks the direct connection.")]
  public void AServerCannotKeepLegacyRelayData(string caps, bool canMakeLink, string reason)
  {
    using var welcome = JsonDocument.Parse("{\"hostKind\":\"headless\",\"token\":null,\"capabilities\":" + caps + "}");
    Assert.Equal(reason, Assert.Throws<ProtocolException>(() => LinkGuest.ValidateServerWelcome(welcome.RootElement, canMakeLink)).Message);
  }

  [Fact]
  public void AServerWithTheLinkAndAPairingReceiptAreAdmitted()
  {
    using var linked = JsonDocument.Parse("""{"hostKind":"headless","token":null,"capabilities":["link.dc2","link.only"]}""");
    LinkGuest.ValidateServerWelcome(linked.RootElement, canMakeLink: true);
    using var pairing = JsonDocument.Parse("""{"hostKind":"headless","token":"one-use","capabilities":[]}""");
    LinkGuest.ValidateServerWelcome(pairing.RootElement, canMakeLink: false);
  }

  [Fact]
  public async Task AnotherComputerRunsEntirelyOnTheLinkAndOutlivesTheRelay()
  {
    var net = new MemoryNet();
    var (host, guest, app, relay, running, stop) = await StartAsync(net);
    try
    {
      Assert.True(guest.Link!.Offered);
      // Sent before the link is up: it waits, in order, and goes on td.ctl.
      await guest.Link.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 1 }), CancellationToken.None);
      await Guest.WaitAsync(() => guest.Inbox.Any(m => m.GetProperty("t").GetString() == "test.echoed"), 5_000);
      Assert.True(guest.Link.Moved);
      Assert.Equal([1], app.Applied());
      // A screen frame (video) on its own channel reaches the guest too.
      var channel = Convert.ToHexStringLower(guest.ChannelId);
      Assert.Equal(true, host.SendDirect(channel, "{\"t\":\"sims.video\",\"id\":\"mac:1\",\"seq\":1}"u8, LinkLane.Still));
      await Guest.WaitAsync(() => guest.Inbox.Any(m => m.GetProperty("t").GetString() == "sims.video"), 5_000);
      Assert.Contains(guest.Inbox, m => m.GetProperty("t").GetString() == "sims.video");
      // Over the relay: the welcome and nothing else.
      Assert.Equal(["welcome"], guest.FromRelayDelivered.Select(m => m.GetProperty("t").GetString()));
      // This PC's relay socket goes (Cloudflare resets it): the other computer stays on the link (§11.4).
      relay.EndHostSocket();
      await running.WaitAsync(TimeSpan.FromSeconds(5));
      await guest.Link.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 2 }), CancellationToken.None);
      await Guest.WaitAsync(() => app.Applied().Contains(2), 5_000);
      Assert.Equal([1, 2], app.Applied());
      Assert.Null(guest.Failed);
    }
    finally { guest.Link?.Dispose(); await stop.CancelAsync(); await host.DisposeAsync(); }
  }

  [Fact]
  public async Task NoDirectPathIsSaidPlainlyAndNothingGoesOverTheRelay()
  {
    var net = new MemoryNet { NeverConnect = true };
    var (host, guest, app, _, _, stop) = await StartAsync(net);
    try
    {
      var send = guest.Link!.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 1 }), CancellationToken.None);
      await Guest.WaitAsync(() => guest.Failed is not null, 14_000);
      Assert.Equal(LinkGuest.Unreachable, guest.Failed?.Message);
      var refused = await Assert.ThrowsAsync<IOException>(() => send);
      Assert.Equal(LinkGuest.Unreachable, refused.Message);
      Assert.Empty(app.Applied());
    }
    finally { guest.Link?.Dispose(); await stop.CancelAsync(); await host.DisposeAsync(); }
  }

  [Fact]
  public async Task AnOlderHostWithoutTheLinkKeepsTheRelayConnection()
  {
    var (host, guest, _, _, _, stop) = await StartAsync(new MemoryNet(), hostHasLink: false);
    try
    {
      // A desktop guest keeps today's relay connection when the host offers no link (§11.5).
      Assert.False(guest.Link!.Offered);
      Assert.Contains(guest.FromRelayDelivered, m => m.GetProperty("t").GetString() == "welcome");
    }
    finally { guest.Link?.Dispose(); await stop.CancelAsync(); await host.DisposeAsync(); }
  }

  // Security S3 (#27): the video channels carry the screen and nothing else; the offer's ICE servers are STUN/TURN only.
  [Fact]
  public async Task OnlyScreenVideoComesOffTheVideoChannelsAndOnlyStunTurnServersAreUsed()
  {
    var net = new MemoryNet();
    var engine = new Recording(net);
    var (host, guest, _, _, _, stop) = await StartAsync(net, engine: engine,
      ice: [LinkPaths.CloudflareStun, new(["turns:turn.example:443?transport=tcp", "http://evil.example/x"], "u", "p")]);
    try
    {
      await guest.Link!.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "test.echo", n = 1 }), CancellationToken.None);
      await Guest.WaitAsync(() => guest.Inbox.Any(m => m.GetProperty("t").GetString() == "test.echoed"), 5_000);
      Assert.DoesNotContain(engine.Servers!.Servers.SelectMany(s => s.Urls), u => u.StartsWith("http", StringComparison.Ordinal));
      Assert.Contains(engine.Servers.Servers.SelectMany(s => s.Urls), u => u.StartsWith("turns:", StringComparison.Ordinal));
      var channel = Convert.ToHexStringLower(guest.ChannelId);
      Assert.Equal(true, host.SendDirect(channel, "{\"t\":\"test.push\",\"n\":7}"u8, LinkLane.Still));
      Assert.Equal(true, host.SendDirect(channel, "{\"t\":\"sims.video\",\"id\":\"mac:1\",\"seq\":1}"u8, LinkLane.Moving));
      await Guest.WaitAsync(() => guest.Inbox.Any(m => m.GetProperty("t").GetString() == "sims.video"), 5_000);
      await Task.Delay(200);
      Assert.DoesNotContain(guest.Inbox, m => m.GetProperty("t").GetString() == "test.push");
      Assert.Null(guest.Failed);
    }
    finally { guest.Link?.Dispose(); await stop.CancelAsync(); await host.DisposeAsync(); }
  }
}
