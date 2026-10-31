namespace TerminalDeck.Core.Remote;

// The lookup phone sends no application message. The host must send its offer
// immediately after the sealed handshake, not wait for a hello that never comes.
public sealed class RendezvousBeacon(MachineOffer offer, DateTimeOffset expiresAt, TimeProvider clock) : IRelayPhoneApplication
{
  public IReadOnlyCollection<byte[]> KnownPeers => [];
  public bool PairingOpen => clock.GetUtcNow() < expiresAt;
  public ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> peerKey, CancellationToken cancellationToken)
  {
    cancellationToken.ThrowIfCancellationRequested();
    if (!PairingOpen) throw new ProtocolException("The pairing code expired.");
    return ValueTask.FromResult(new PhoneApplicationReply([offer.Encode()]));
  }
  public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey,
    ReadOnlyMemory<byte> plaintext, CancellationToken cancellationToken) => ValueTask.FromResult(new PhoneApplicationReply([]));
  public ValueTask DisconnectedAsync(string channel) => ValueTask.CompletedTask;
}
