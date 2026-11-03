using TerminalDeck.Core.Remote;
namespace TerminalDeck.Core.Tests.Remote;
public sealed class ReceiverTransportTests
{
  private sealed class Receiver : IRelayReceiverApplication
  {
    public List<RelayKind> Received = []; public int Disconnected;
    public ValueTask ConnectedAsync(Func<RelayPacket, CancellationToken, ValueTask> send, CancellationToken ct) => send(new(RelayKind.ReceiverSync, new byte[16], [1]), ct);
    public ValueTask FrameAsync(RelayPacket packet, CancellationToken ct) { Received.Add(packet.Kind); return ValueTask.CompletedTask; }
    public ValueTask DisconnectedAsync() { Disconnected++; return ValueTask.CompletedTask; }
  }
  private sealed class Phone : IRelayPhoneApplication
  { public IReadOnlyCollection<byte[]> KnownPeers => []; public bool PairingOpen => false; public ValueTask DisconnectedAsync(string channel) => ValueTask.CompletedTask; public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peer, ReadOnlyMemory<byte> plain, CancellationToken ct) => throw new InvalidOperationException("Receiver frames must not reach phone input."); }
  private sealed class Socket : IRelaySocket
  {
    public List<byte[]> Sent = []; private bool delivered;
    public Task ConnectAsync(Uri host, ReadOnlyMemory<byte> secret, CancellationToken ct) => Task.CompletedTask;
    public ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken ct) { Sent.Add(packet.ToArray()); return ValueTask.CompletedTask; }
    public ValueTask<byte[]?> ReceiveAsync(CancellationToken ct) { if (delivered) return ValueTask.FromResult<byte[]?>(null); delivered = true; return ValueTask.FromResult<byte[]?>(new RelayPacket(RelayKind.ReceiverDelivery, new byte[16], [1,2]).Encode()); }
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
  [Fact] public async Task ReceiverSyncAndDeliveryUseTheirOwnDoorAndReleaseEpoch()
  {
    using var identity = NoiseIdentity.Generate(); var receiver = new Receiver(); var socket = new Socket();
    await using var connection = new RelayHostConnection(identity, new Phone(), receiver: receiver);
    await connection.RunAsync(socket, default);
    Assert.Equal(RelayKind.ReceiverSync, RelayPacket.Decode(Assert.Single(socket.Sent)).Kind);
    Assert.Equal(RelayKind.ReceiverDelivery, Assert.Single(receiver.Received)); Assert.Equal(1, receiver.Disconnected);
  }
}
