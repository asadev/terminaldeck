using TerminalDeck.Core.Integration;

namespace TerminalDeck.Core.Remote;

// One owner chain serves both transports. Publisher registration by one
// transport cannot silence the other, and the original serial ownership holds.
public sealed class PhoneTransportHub(IRelayPhoneApplication next) : IRelayPhoneApplication, IW9PhonePushApplication
{
  private readonly SemaphoreSlim calls = new(1, 1);
  private Func<string, byte[], CancellationToken, ValueTask>? remote;
  private Func<string, byte[], CancellationToken, ValueTask>? local;
  public IReadOnlyCollection<byte[]> KnownPeers => next.KnownPeers;
  public bool PairingOpen => next.PairingOpen;
  public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publisher)
  { remote = publisher; Bind(); }
  public void SetLocalPublisher(Func<string, byte[], CancellationToken, ValueTask>? publisher)
  { local = publisher; Bind(); }
  private void Bind()
  {
    if (next is IW9PhonePushApplication push) push.SetPublisher((channel, bytes, ct) =>
      (channel.StartsWith("local-web:", StringComparison.Ordinal) ? local : remote)?.Invoke(channel, bytes, ct) ?? ValueTask.CompletedTask);
  }
  public async ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> key, CancellationToken ct)
  { await calls.WaitAsync(ct); try { return await next.OpenedAsync(channel, key, ct); } finally { calls.Release(); } }
  public async ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> key, ReadOnlyMemory<byte> plain, CancellationToken ct)
  { await calls.WaitAsync(ct); try { return await next.ReceiveAsync(channel, key, plain, ct); } finally { calls.Release(); } }
  public async ValueTask DisconnectedAsync(string channel)
  { await calls.WaitAsync(); try { await next.DisconnectedAsync(channel); } finally { calls.Release(); } }
}
