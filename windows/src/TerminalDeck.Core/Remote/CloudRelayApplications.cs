using System.Text.Json;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Remote;

// These sit only on the relay side of the hub. The localhost publisher, local
// tool door and direct SSH owners never pass through this subscription fence.
public sealed class CloudRelayPhoneApplication(IRelayPhoneApplication next, Func<bool> allowed) : IRelayPhoneApplication, IW9PhonePushApplication
{
  public IReadOnlyCollection<byte[]> KnownPeers => allowed() ? next.KnownPeers : [];
  public bool PairingOpen => allowed() && next.PairingOpen;
  private static PhoneApplicationReply Refused() => new([JsonSerializer.SerializeToUtf8Bytes(new { t = "error", code = "subscription_required", message = CloudRelayLifecycle.SubscriptionRequired })], true);
  public ValueTask<PhoneApplicationReply> OpenedAsync(string channel, ReadOnlyMemory<byte> key, CancellationToken ct) => allowed() ? next.OpenedAsync(channel, key, ct) : ValueTask.FromResult(Refused());
  public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> key, ReadOnlyMemory<byte> bytes, CancellationToken ct) => allowed() ? next.ReceiveAsync(channel, key, bytes, ct) : ValueTask.FromResult(Refused());
  public ValueTask DisconnectedAsync(string channel) => next.DisconnectedAsync(channel);
  public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publish)
  {
    if (next is not IW9PhonePushApplication push) return;
    if (publish is null) { push.SetPublisher(null); return; }
    push.SetPublisher((channel, bytes, ct) => allowed() ? publish(channel, bytes, ct) : ValueTask.CompletedTask);
  }
}

public sealed class CloudRelayReceiverApplication(IRelayReceiverApplication next, Func<bool> allowed) : IRelayReceiverApplication
{
  private void RequireAllowed() { if (!allowed()) throw new ProtocolException(CloudRelayLifecycle.SubscriptionRequired); }
  public ValueTask ConnectedAsync(Func<RelayPacket, CancellationToken, ValueTask> send, CancellationToken ct)
  {
    RequireAllowed();
    return next.ConnectedAsync((packet, token) => { RequireAllowed(); return send(packet, token); }, ct);
  }
  public ValueTask FrameAsync(RelayPacket packet, CancellationToken ct) { RequireAllowed(); return next.FrameAsync(packet, ct); }
  public ValueTask DisconnectedAsync() => next.DisconnectedAsync();
}

public sealed class CloudRelayMcpApplication(IRelayMcpApplication next, Func<bool> allowed) : IRelayMcpApplication
{
  public ValueTask<IReadOnlyList<byte[]>> ReceiveAsync(ReadOnlyMemory<byte> bytes, CancellationToken ct) => allowed()
    ? next.ReceiveAsync(bytes, ct)
    : ValueTask.FromResult(McpRelayCodec.EncodeReply(new McpHttpReply(402, JsonSerializer.SerializeToUtf8Bytes(new { code = "subscription_required", message = CloudRelayLifecycle.SubscriptionRequired }))));
}
