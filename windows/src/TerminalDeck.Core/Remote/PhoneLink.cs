using System.Text.Json;

namespace TerminalDeck.Core.Remote;

// Implementations filter sessions using this device's current folder/session
// grants. The default view offers nothing, even to an approved device.
public interface IPhoneSessionView
{
  IReadOnlyList<JsonElement> Read(ApprovedDevice device);
}

public sealed class PhoneLink(DeviceTrust trust, string hostName, string appVersion, IPhoneSessionView sessionView) : IRelayPhoneApplication
{
  private readonly Dictionary<string, string> authenticated = [];
  public IReadOnlyCollection<byte[]> KnownPeers => trust.KnownPeers;
  public bool PairingOpen => trust.Pairing.IsOpen;

  public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> peerKey,
    ReadOnlyMemory<byte> plaintext, CancellationToken cancellationToken)
  {
    cancellationToken.ThrowIfCancellationRequested();
    var message = PhoneWire.ParseClient(plaintext.Span);
    if (message.Type == "hello")
    {
      if (authenticated.ContainsKey(channel)) throw new ProtocolException("This connection already said hello.");
      if (message.Value.GetProperty("protocol").GetInt32() != 1)
        return Reply(Error("version", "This phone and computer speak different versions. Update whichever is older."), close: true);
      var token = message.Text("token");
      if (!token.Contains('.'))
      {
        var device = message.Value.GetProperty("device");
        var paired = trust.Redeem(token, device.GetProperty("name").GetString()!, device.GetProperty("platform").GetString()!, peerKey.Span);
        return ValueTask.FromResult(new PhoneApplicationReply([
          PhoneWire.PendingWelcome(paired.DeviceId, paired.DeviceName, paired.Credential),
          Error("unauthorized", "Paired. Approve this device on this computer, then reconnect.")], Close: true));
      }
      var approved = trust.Authenticate(token, peerKey.Span);
      var welcome = PhoneWire.ApprovedWelcome(approved.Id, approved.Name, hostName, appVersion, sessionView.Read(approved), []);
      trust.Connected(approved.Id, channel); authenticated[channel] = approved.Id;
      return Reply(welcome);
    }
    if (!authenticated.TryGetValue(channel, out var id)) throw new ProtocolException("Say hello before using this connection.");
    var current = trust.RequireCurrent(id, peerKey.Span);
    return message.Type switch
    {
      "ping" => Reply(JsonSerializer.SerializeToUtf8Bytes(new { t = "pong" })),
      "list" => Reply(JsonSerializer.SerializeToUtf8Bytes(new { t = "sessions", sessions = sessionView.Read(current) })),
      _ => Reply(Error("unavailable", "This session action is not implemented yet."))
    };
  }

  public ValueTask DisconnectedAsync(string channel) { authenticated.Remove(channel); trust.Disconnected(channel); return ValueTask.CompletedTask; }
  private static ValueTask<PhoneApplicationReply> Reply(byte[] message, bool close = false) => ValueTask.FromResult(new PhoneApplicationReply([message], close));
  private static byte[] Error(string code, string message) => JsonSerializer.SerializeToUtf8Bytes(new { t = "error", code, message });
}
