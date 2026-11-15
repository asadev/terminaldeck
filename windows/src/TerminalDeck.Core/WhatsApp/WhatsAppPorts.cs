using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.WhatsApp;

// The doors the WhatsApp engine reaches the rest of the app through (DESIGN-WHATSAPP.md sections 4 and 5). A port of the
// Mac's BackendWhatsAppPorts.swift. The engine depends on nothing else, so tests run it with fakes.

/// One WhatsApp agent as every computer of his keeps it: a synced app setting `whatsapp.agent.&lt;id&gt;` (a JSON text,
/// newest change wins). Never the key (that travels in saved passwords). The JSON is the Mac's Codable shape exactly, so a
/// record written on Windows is read on the Mac and back (see ToJson/FromJson).
public sealed record WhatsAppAgentRecord
{
  public required string Id { get; init; }
  public required string Name { get; init; }
  public required WhatsAppReceiver Receiver { get; init; }
  /// The computer that polls this agent (its receiver's computer). null = none (received nowhere).
  public string? ReaderId { get; init; }
  public string? ReaderName { get; init; }
  /// True when ReaderId took it over by itself (the other computer was off for more than 10 minutes).
  public bool TakenOver { get; init; }
  /// The agent's creator ("user:&lt;id&gt;"), learned from his first message; the only address ever written to.
  public string? Creator { get; init; }
  /// Where the next poll starts (WhatsApp's next_offset). null = never read: the first read only learns the head.
  public long? Offset { get; init; }
  /// His last message (ms since 1970).
  public double? LastMessageAt { get; init; }
  /// WhatsApp refused the key (orange row) until a new key is given.
  public bool Refused { get; init; }
  /// A session receiver ended: the next message is answered once with "That session has ended...".
  public bool EndedSession { get; init; }
  /// Removed in the app (a mark, so the removal travels like any change; the key goes by the delete rule).
  public bool Removed { get; init; }
  /// When he added it (ms), for the list's order.
  public double AddedAt { get; init; }
  /// The switch: null or true = answers and approvals go to WhatsApp; false = nothing is sent there.
  public bool? Sending { get; init; } = true;
  public bool IsSending => Sending != false;
  /// Security review fault 1: the first 16 hex of the key's SHA-256 (not the key). A computer reads the agent only while
  /// its own stored key has this fingerprint.
  public string? KeyId { get; init; }
  /// The session receiver's Cloud id (the same on every computer, unlike its local id): how a session that moves to another
  /// Mac takes its WhatsApp agent with it. Windows cannot take a session, so it only carries this field unchanged through
  /// its own writes (dropping it would erase it on every computer) and clears it when it sets a new receiver, as the Mac does.
  public string? CloudSessionId { get; init; }

  // ---- the Mac's JSON shape (Swift synthesized Codable: nil optionals left out, enum cases as one-key objects) ----

  public string ToJson()
  {
    var o = new JsonObject
    {
      ["id"] = Id,
      ["name"] = Name,
      ["receiver"] = ReceiverJson(Receiver),
    };
    if (ReaderId is not null) o["readerID"] = ReaderId;
    if (ReaderName is not null) o["readerName"] = ReaderName;
    o["takenOver"] = TakenOver;
    if (Creator is not null) o["creator"] = Creator;
    if (Offset is long off) o["offset"] = off;
    if (LastMessageAt is double last) o["lastMessageAt"] = last;
    o["refused"] = Refused;
    o["endedSession"] = EndedSession;
    o["removed"] = Removed;
    o["addedAt"] = AddedAt;
    if (Sending is bool s) o["sending"] = s;
    if (KeyId is not null) o["keyID"] = KeyId;
    if (CloudSessionId is not null) o["cloudSessionID"] = CloudSessionId;
    return o.ToJsonString();
  }

  private static JsonObject ReceiverJson(WhatsAppReceiver r) => r.Kind switch
  {
    WhatsAppReceiverKind.Hoot => new JsonObject { ["hoot"] = new JsonObject() },
    WhatsAppReceiverKind.Agent => new JsonObject { ["agent"] = new JsonObject { ["id"] = r.Id, ["name"] = r.Name } },
    WhatsAppReceiverKind.Session => new JsonObject { ["session"] = new JsonObject { ["id"] = r.Id, ["name"] = r.Name } },
    _ => new JsonObject { ["nowhere"] = new JsonObject() },
  };

  /// null when the text is not a record (the Mac's decoder refuses it too: required fields missing).
  public static WhatsAppAgentRecord? FromJson(string text)
  {
    try
    {
      if (JsonNode.Parse(text) is not JsonObject o) return null;
      if (Str(o, "id") is not { } id || Str(o, "name") is not { } name || o["receiver"] is not JsonObject r) return null;
      WhatsAppReceiver receiver;
      if (r.ContainsKey("nowhere")) receiver = WhatsAppReceiver.Nowhere;
      else if (r.ContainsKey("hoot")) receiver = WhatsAppReceiver.Hoot;
      else if (r["agent"] is JsonObject a && Str(a, "id") is { } aid) receiver = WhatsAppReceiver.Agent(aid, Str(a, "name") ?? "");
      else if (r["session"] is JsonObject s && Str(s, "id") is { } sid) receiver = WhatsAppReceiver.Session(sid, Str(s, "name") ?? "");
      else return null;
      if (Bool(o, "takenOver") is not bool takenOver || Bool(o, "refused") is not bool refused || Bool(o, "endedSession") is not bool ended
        || Bool(o, "removed") is not bool removed || Num(o, "addedAt") is not double addedAt) return null;
      return new WhatsAppAgentRecord
      {
        Id = id, Name = name, Receiver = receiver, ReaderId = Str(o, "readerID"), ReaderName = Str(o, "readerName"), TakenOver = takenOver,
        Creator = Str(o, "creator"), Offset = Num(o, "offset") is double off ? (long)off : null, LastMessageAt = Num(o, "lastMessageAt"),
        Refused = refused, EndedSession = ended, Removed = removed, AddedAt = addedAt, Sending = Bool(o, "sending"), KeyId = Str(o, "keyID"),
        CloudSessionId = Str(o, "cloudSessionID"),
      };
    }
    catch (JsonException) { return null; }
    catch (InvalidOperationException) { return null; }
    catch (FormatException) { return null; }
  }

  private static string? Str(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
  private static bool? Bool(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
  private static double? Num(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue<double>(out var d) ? d : null;
}

/// Where the records live (the synced settings).
public interface IWhatsAppSettingsPort
{
  Task<IReadOnlyList<WhatsAppAgentRecord>> RecordsAsync();
  Task SaveAsync(WhatsAppAgentRecord record);
  /// Called after any record changed (here or arriving from another computer).
  void Observe(Action changed);
}

/// This computer and the account's other computers.
public sealed record WhatsAppComputer(string Id, string Name);

public interface IWhatsAppPresencePort
{
  WhatsAppComputer ThisComputer();
  /// When the account last saw that computer; null = unknown.
  Task<DateTimeOffset?> LastSeenAsync(string computerId);
  Task<string?> NameAsync(string computerId);
}

/// The session that takes a WhatsApp agent's messages: a chat session (Hoot's lasting conversation and an agent's
/// lasting chat are chat sessions too) or a terminal session.
public sealed record WhatsAppTarget(string SessionId, bool IsTerminal);

/// One approval the receiver waits for: what it wants in one line and the command or file exactly.
public sealed record WhatsAppApproval(string Id, string Summary, string Detail);

public enum WhatsAppTurnKind { Idle, Working, NeedsApproval, Done, Failed }

/// The receiver's turn now. Answer: the final answer (Done) or the reason (Failed). Approvals: for NeedsApproval.
public sealed record WhatsAppTurn(string? TurnId, WhatsAppTurnKind Kind, string? Answer = null, IReadOnlyList<WhatsAppApproval>? Approvals = null)
{
  public IReadOnlyList<WhatsAppApproval> Waiting => Approvals ?? [];
  public static WhatsAppTurn Idle(string? id) => new(id, WhatsAppTurnKind.Idle);
  public static WhatsAppTurn Working(string? id) => new(id, WhatsAppTurnKind.Working);
  public static WhatsAppTurn Done(string? id, string answer) => new(id, WhatsAppTurnKind.Done, answer);
  public static WhatsAppTurn Failed(string? id, string reason) => new(id, WhatsAppTurnKind.Failed, reason);
  public static WhatsAppTurn Asking(string? id, params WhatsAppApproval[] approvals) => new(id, WhatsAppTurnKind.NeedsApproval, null, approvals);
}

/// A picture or a document he sent, as the chat takes it.
public sealed record WhatsAppAttachment(byte[] Data, string MimeType, string? FileName)
{
  public override string ToString() => $"WhatsAppAttachment {{ {Data.Length} bytes, {MimeType} }}";
}

public interface IWhatsAppReceiverPort
{
  /// The session for this receiver now. For Hoot and an agent: their ONE lasting conversation named conversationName,
  /// made on first use and kept (keyed by agentId). For a session: itself; null when it ended.
  Task<WhatsAppTarget?> TargetAsync(WhatsAppReceiver receiver, string conversationName, string agentId);
  /// His message into the chat as if he had typed it there.
  Task SayAsync(WhatsAppTarget target, string text, IReadOnlyList<WhatsAppAttachment> attachments);
  Task<WhatsAppTurn?> TurnAsync(WhatsAppTarget target);
  Task<bool> ApproveAsync(WhatsAppTarget target, string approvalId, bool allow);
  /// A terminal: typed in (the text carries its own Return).
  Task TypeAsync(WhatsAppTarget target, string text);
  /// A terminal's screen text now (its last lines).
  Task<string?> ScreenAsync(WhatsAppTarget target);
  Task<bool> IsOpenAsync(WhatsAppTarget target);
  /// Whether a tool call carrying sessionId comes from this target (its own id, or for Hoot's lasting conversation the
  /// AI process behind it).
  Task<bool> IsToolSessionAsync(WhatsAppTarget target, string sessionId);
  /// A local session's Cloud id (the same on every computer); null when unknown. Windows sessions have none yet.
  Task<string?> CloudSessionIdAsync(string sessionId) => Task.FromResult<string?>(null);
}
