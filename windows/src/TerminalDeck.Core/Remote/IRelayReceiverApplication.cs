namespace TerminalDeck.Core.Remote;

public interface IRelayReceiverApplication
{
  ValueTask ConnectedAsync(Func<RelayPacket, CancellationToken, ValueTask> send, CancellationToken ct);
  ValueTask FrameAsync(RelayPacket packet, CancellationToken ct);
  ValueTask DisconnectedAsync();
}
