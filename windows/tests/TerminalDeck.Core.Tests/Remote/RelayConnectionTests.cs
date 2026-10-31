using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class RelayConnectionTests
{
  private static readonly byte[] ChannelId = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
  private static byte[] Packet(RelayKind kind, byte[] payload, byte[]? id = null) => new RelayPacket(kind, id ?? ChannelId, payload).Encode();

  private static async Task<NoiseTransport> Open(RelayHostConnection connection, NoiseIdentity host, NoiseIdentity phone)
  {
    Assert.Empty(await connection.ProcessAsync(Packet(RelayKind.Open, [])));
    var start = NoiseChannel.Start(phone, host.PublicKey);
    var frames = await connection.ProcessAsync(Packet(RelayKind.Data, RelayPacket.FrameHandshake(start.Message)));
    var reply = RelayPacket.Decode(frames[0]);
    Assert.Equal(RelayKind.Data, reply.Kind);
    return NoiseChannel.Finish(start.Pending, RelayPacket.ReadHandshake(reply.Payload, false));
  }

  private static byte[] Hello(string token) => JsonSerializer.SerializeToUtf8Bytes(new
  {
    t = "hello", protocol = 1, token, device = new { name = "Test phone", platform = "ios" }, capabilities = new[] { "chats", "browser.control" }
  });

  [Fact]
  public async Task PendingPairingHasNoSessionsAndClosesUntilDesktopApproval()
  {
    using var host = NoiseIdentity.Generate(); using var phone = NoiseIdentity.Generate();
    var trust = new DeviceTrust(new TestTrustStore()); var view = new TestSessionView();
    var offer = trust.Pairing.Create();
    var link = new PhoneLink(trust, "Test PC", "0.1", view);
    await using var connection = new RelayHostConnection(host, link);
    using var client = await Open(connection, host, phone);
    var packets = await connection.ProcessAsync(Packet(RelayKind.Data, client.Send(Hello(offer.Code))));
    Assert.Equal(3, packets.Count);
    using var welcome = JsonDocument.Parse(client.Receive(RelayPacket.Decode(packets[0]).Payload));
    Assert.Equal("welcome", welcome.RootElement.GetProperty("t").GetString());
    Assert.Empty(welcome.RootElement.GetProperty("sessions").EnumerateArray());
    Assert.Empty(welcome.RootElement.GetProperty("capabilities").EnumerateArray());
    Assert.False(string.IsNullOrEmpty(welcome.RootElement.GetProperty("token").GetString()));
    using var error = JsonDocument.Parse(client.Receive(RelayPacket.Decode(packets[1]).Payload));
    Assert.Equal("unauthorized", error.RootElement.GetProperty("code").GetString());
    Assert.Equal(RelayKind.Close, RelayPacket.Decode(packets[2]).Kind);
    Assert.Equal(0, view.Reads);
  }

  [Fact]
  public async Task ApprovedDeviceCanListButRevokedOpenConnectionIsClosed()
  {
    using var host = NoiseIdentity.Generate(); using var phone = NoiseIdentity.Generate();
    var trust = new DeviceTrust(new TestTrustStore()); var view = new TestSessionView();
    var receipt = trust.Redeem(trust.Pairing.Create().Code, "Phone", "ios", phone.PublicKey);
    trust.Approve(receipt.DeviceId, PhoneAccess.Work);
    await using var connection = new RelayHostConnection(host, new PhoneLink(trust, "Test PC", "0.1", view));
    using var client = await Open(connection, host, phone);
    var welcomeFrames = await connection.ProcessAsync(Packet(RelayKind.Data, client.Send(Hello(receipt.Credential))));
    using var welcome = JsonDocument.Parse(client.Receive(RelayPacket.Decode(Assert.Single(welcomeFrames)).Payload));
    Assert.Equal("win32", welcome.RootElement.GetProperty("hostPlatform").GetString());
    Assert.Equal(1, view.Reads);
    var listed = await connection.ProcessAsync(Packet(RelayKind.Data, client.Send(JsonSerializer.SerializeToUtf8Bytes(new { t = "list" }))));
    using var sessions = JsonDocument.Parse(client.Receive(RelayPacket.Decode(Assert.Single(listed)).Payload));
    Assert.Equal("sessions", sessions.RootElement.GetProperty("t").GetString());
    Assert.Equal(2, view.Reads);
    trust.Revoke(receipt.DeviceId);
    var refused = await connection.ProcessAsync(Packet(RelayKind.Data, client.Send(JsonSerializer.SerializeToUtf8Bytes(new { t = "list" }))));
    Assert.Equal(RelayKind.Close, RelayPacket.Decode(Assert.Single(refused)).Kind);
    Assert.Equal(2, view.Reads);
  }

  [Fact]
  public async Task RendezvousSendsOfferImmediatelyWithoutWaitingForHello()
  {
    var clock = new TestClock();
    using var derived = PairingCode.Derive("482913"); using var phone = NoiseIdentity.Generate(); using var host = NoiseIdentity.Generate();
    var offer = new MachineOffer(RelayEndpoint.Default, PairingCode.HostId(new byte[32]), host.PublicKey, "Test PC", "win32");
    await using var connection = new RelayHostConnection(derived.Keys, new RendezvousBeacon(offer, clock.Now.AddSeconds(60), clock));
    await connection.ProcessAsync(Packet(RelayKind.Open, []));
    var start = NoiseChannel.Start(phone, derived.Keys.PublicKey);
    var frames = await connection.ProcessAsync(Packet(RelayKind.Data, RelayPacket.FrameHandshake(start.Message)));
    Assert.Equal(2, frames.Count);
    using var client = NoiseChannel.Finish(start.Pending, RelayPacket.ReadHandshake(RelayPacket.Decode(frames[0]).Payload, false));
    var parsed = MachineOffer.Decode(client.Receive(RelayPacket.Decode(frames[1]).Payload));
    Assert.Equal(offer.HostId, parsed.HostId); Assert.Equal("win32", parsed.Platform); Assert.Equal(host.PublicKey, parsed.PublicKey);
  }

  [Fact]
  public async Task UnknownPeersOutsidePairingGetOnlyAChannelClose()
  {
    using var host = NoiseIdentity.Generate(); using var phone = NoiseIdentity.Generate();
    var app = new TestApplication(); await using var connection = new RelayHostConnection(host, app);
    await connection.ProcessAsync(Packet(RelayKind.Open, []));
    var start = NoiseChannel.Start(phone, host.PublicKey);
    var frames = await connection.ProcessAsync(Packet(RelayKind.Data, RelayPacket.FrameHandshake(start.Message)));
    var closed = RelayPacket.Decode(Assert.Single(frames));
    Assert.Equal(RelayKind.Close, closed.Kind); Assert.Empty(closed.Payload);
    Assert.Equal(1, app.Disconnections); start.Pending.Dispose();
  }

  [Fact]
  public async Task ChannelLimitDuplicateOpenAndMcpPacketsDoNotReachPhoneHandlers()
  {
    using var host = NoiseIdentity.Generate(); var app = new TestApplication();
    await using var connection = new RelayHostConnection(host, app);
    for (var i = 0; i < 16; i++)
    {
      var id = new byte[16]; id[0] = (byte)i;
      Assert.Empty(await connection.ProcessAsync(Packet(RelayKind.Open, [], id)));
    }
    Assert.Empty(await connection.ProcessAsync(Packet(RelayKind.Open, [], new byte[16])));
    var extra = new byte[16]; extra[0] = 16;
    Assert.Equal(RelayKind.Close, RelayPacket.Decode(Assert.Single(await connection.ProcessAsync(Packet(RelayKind.Open, [], extra)))).Kind);
    Assert.Empty(await connection.ProcessAsync(Packet(RelayKind.McpRequest, [1, 2, 3])));
    Assert.Equal(0, app.Messages);
  }

  [Fact]
  public async Task ReplayClosesOnlyThatChannel()
  {
    using var host = NoiseIdentity.Generate(); using var phone = NoiseIdentity.Generate();
    var app = new TestApplication { PairingOpen = true };
    await using var connection = new RelayHostConnection(host, app);
    using var client = await Open(connection, host, phone);
    var message = Packet(RelayKind.Data, client.Send(JsonSerializer.SerializeToUtf8Bytes(new { t = "ping" })));
    Assert.Empty(await connection.ProcessAsync(message));
    var replay = RelayPacket.Decode(Assert.Single(await connection.ProcessAsync(message)));
    Assert.Equal(RelayKind.Close, replay.Kind); Assert.Equal(1, app.Messages);
  }

  [Fact]
  public async Task EndOfSocketReleasesEveryChannelAttachment()
  {
    using var host = NoiseIdentity.Generate(); var app = new TestApplication();
    await using var socket = new TestSocket([Packet(RelayKind.Open, []), Packet(RelayKind.Open, [], new byte[16])]);
    await using var connection = new RelayHostConnection(host, app);
    await connection.RunAsync(socket, CancellationToken.None);
    Assert.Equal(2, app.Disconnections);
    await Assert.ThrowsAsync<ObjectDisposedException>(async () => await connection.ProcessAsync(Packet(RelayKind.Open, [])));
  }

  [Fact]
  public async Task CancelledClientDoesNotDialOrRetry()
  {
    using var host = NoiseIdentity.Generate(); var calls = 0; using var stop = new CancellationTokenSource(); stop.Cancel();
    using var client = new RelayHostClient(RelayEndpoint.Default, new byte[32], host, new TestApplication(), () => { calls++; return new TestSocket([]); });
    var states = new List<RelayConnectionState>(); client.StateChanged += states.Add;
    await client.RunAsync(stop.Token);
    Assert.Equal(0, calls); Assert.Equal([RelayConnectionState.Stopped], states);
  }
}

internal sealed class TestSessionView : IPhoneSessionView
{
  public int Reads { get; private set; }
  public IReadOnlyList<JsonElement> Read(ApprovedDevice device) { Reads++; return []; }
}

internal sealed class TestApplication : IRelayPhoneApplication
{
  public IReadOnlyCollection<byte[]> KnownPeers => [];
  public bool PairingOpen { get; set; }
  public int Messages { get; private set; }
  public int Disconnections { get; private set; }
  public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey, ReadOnlyMemory<byte> plaintext, CancellationToken cancellationToken)
  { Messages++; return ValueTask.FromResult(new PhoneApplicationReply([])); }
  public ValueTask DisconnectedAsync(string channel) { Disconnections++; return ValueTask.CompletedTask; }
}

internal sealed class TestSocket(IEnumerable<byte[]> frames) : IRelaySocket
{
  private readonly Queue<byte[]> incoming = new(frames);
  public Task ConnectAsync(Uri hostAddress, ReadOnlyMemory<byte> hostSecret, CancellationToken cancellationToken) => Task.CompletedTask;
  public ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken cancellationToken) => ValueTask.CompletedTask;
  public ValueTask<byte[]?> ReceiveAsync(CancellationToken cancellationToken) => ValueTask.FromResult(incoming.TryDequeue(out var frame) ? frame : null);
  public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
