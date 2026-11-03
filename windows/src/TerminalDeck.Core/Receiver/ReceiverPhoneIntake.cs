using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Receiver;

// The phone connection calls this AFTER DeviceTrust.RequireCurrent for every
// message. Destination visibility is not a write grant: the supplied check must
// also consult PhoneSessionGrants and current Look/Work/Full access.
public sealed class ReceiverPhoneIntake(IReceiver receiver, Func<ApprovedDevice, string, bool> canSend,
  Func<ApprovedDevice, string, string> sourceForSession)
{
  public byte[] SendToSession(ApprovedDevice device, ReadOnlySpan<byte> plaintext)
  {
    var message = PhoneWire.ParseClient(plaintext);
    if (message.Type != "session.send") throw new ProtocolException("Choose send to session.");
    var id = message.Text("id"); var rid = message.Text("rid");
    if (device.Access == PhoneAccess.Look || !canSend(device, id)) throw new ProtocolException("This phone cannot send to that session.");
    var item = receiver.Receive(new(sourceForSession(device, id), "Sent from " + device.Name, message.Text("data"), ExternalId: RequestKey(device.Id, id, rid)));
    if (item.Status is InboxStatus.Unrouted or InboxStatus.Held) receiver.Hold(item.Id, new(RouteKind.Session, id));
    // Stored is not delivered: never emit session.sent before the destination
    // actually acknowledges a send. The Mac-side inbox still asks the owner.
    return JsonSerializer.SerializeToUtf8Bytes(new { t = "session.sent", rid, id, ok = item.Status == InboxStatus.Delivered,
      message = item.Status == InboxStatus.Delivered ? "Delivered." : "Saved to the computer's inbox for approval. Your draft has not been sent to the session.", receiverItemId = item.Id });
  }
  public ReceiverItem Report(ApprovedDevice device, string sessionId, string title, string details, string requestId)
  {
    if (device.Access == PhoneAccess.Look || !canSend(device, sessionId)) throw new ProtocolException("This phone cannot report to that session.");
    ReceiverStore.Check(requestId, 128);
    var item = receiver.Receive(new(sourceForSession(device, sessionId), title, details, ExternalId: RequestKey(device.Id, sessionId, "report:" + requestId)));
    if (item.Status is InboxStatus.Unrouted or InboxStatus.Held) receiver.Hold(item.Id, new(RouteKind.Session, sessionId));
    return item;
  }
  private static string RequestKey(string device, string session, string request) => Convert.ToHexStringLower(
    System.Security.Cryptography.SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new[] { device, session, request })));
}
