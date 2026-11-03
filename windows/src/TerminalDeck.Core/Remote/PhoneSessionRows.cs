using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Remote;

// Session rows and chat conversations in the shapes the phones read from a Mac
// (BackendRemoteHost.sessionValue, BackendPhoneChats): one place, so the
// welcome, `list`, `sessions` pushes and `created` can never disagree.
public static class PhoneSessionRows
{
  public const int MaximumRows = 200;

  // The phones treat "waiting" and "input" as "Needs you". A terminal on this
  // PC has no reader that can tell it is asking something, so it is never sent
  // as waiting: it is working while its output moves, else idle.
  public static string TerminalStatus(SessionRecord session, bool working) => session.State switch
  {
    SessionState.Exited => "exited",
    SessionState.Running when working => "working",
    _ => "idle"
  };

  // A chat waits for the person only when an approval is open or it hit a problem it cannot pass alone.
  public static string ChatStatus(ChatRecord chat)
  {
    if (chat.Ended) return "exited";
    if (chat.Problem is not null || ChatProjection.Rows(chat).Any(r => r.Kind == "approval" && r.Waiting)) return "waiting";
    return chat.Busy || chat.Stopping ? "working" : "idle";
  }

  public static JsonObject Terminal(SessionRecord session, bool working, long? lastActivity = null, string? observedStatus = null) => new()
  {
    ["id"] = session.Definition.Id, ["title"] = Title(session.Definition.Title, session.Definition.Provider), ["cwd"] = session.Definition.Cwd,
    ["provider"] = session.Definition.Provider, ["status"] = session.State == SessionState.Running ? observedStatus ?? TerminalStatus(session, working) : TerminalStatus(session, working),
    ["exitCode"] = session.State == SessionState.Exited ? session.ExitCode ?? 0 : null,
    ["lastActivityAt"] = Math.Max(lastActivity ?? 0, session.CreatedAt)
  };

  public static JsonObject Chat(ChatRecord chat) => new()
  {
    ["id"] = chat.Definition.Id, ["title"] = Title(chat.Definition.Title, chat.Definition.Provider), ["cwd"] = chat.Definition.Cwd,
    ["provider"] = chat.Definition.Provider, ["status"] = ChatStatus(chat), ["exitCode"] = chat.Ended ? 0 : null,
    ["lastActivityAt"] = chat.Events.LastOrDefault()?.At.ToUnixTimeMilliseconds() ?? 0, ["chat"] = true
  };

  private static string Title(string title, string provider) => title.Length > 0 ? title : provider;

  // Newest activity first is the phone's own sort; the cap keeps a sessions frame under the 64 KiB message limit.
  public static JsonArray Bounded(IEnumerable<JsonObject> rows)
  {
    var list = new JsonArray(); var bytes = 2;
    foreach (var row in rows.OrderByDescending(r => r["lastActivityAt"]?.GetValue<long>() ?? 0).Take(MaximumRows))
    {
      var size = JsonSerializer.SerializeToUtf8Bytes(row).Length + 1;
      if (bytes + size > PhoneWire.MaximumMessageBytes - 1024) break;
      bytes += size; list.Add(row);
    }
    return list;
  }

  // The phone's permission words (ChatWords.permissionModes) and this PC's modes.
  public static string PermissionWord(AiPermissionMode mode) => mode switch
  {
    AiPermissionMode.Ask => "ask", AiPermissionMode.Plan => "plan", AiPermissionMode.Bypass => "bypass", _ => "changes"
  };
  public static AiPermissionMode? PermissionMode(string? word, string provider) => word switch
  {
    "ask" => AiPermissionMode.Ask, "plan" => AiPermissionMode.Plan, "bypass" => AiPermissionMode.Bypass,
    "changes" => ChatPermissionModes.Supported(provider).Contains(AiPermissionMode.AcceptEdits) ? AiPermissionMode.AcceptEdits : AiPermissionMode.Auto,
    _ => null
  };

  // One chat as the phone's chats.events page (the Hoot event stream's version-1 shape):
  // a whole page from `before` back (null: the newest), bounded under the message limit.
  public static byte[] ChatEvents(ChatRecord chat, int? before = null)
  {
    var id = chat.Definition.Id; var provider = chat.Definition.Provider;
    var rows = ChatProjection.Rows(chat).Where(r => r.Kind != "reasoning").ToList();
    var sequences = Sequences(chat);
    var top = sequences.Count == 0 ? 0 : sequences.Values.Max();
    var end = Math.Clamp(before ?? rows.Count, 0, rows.Count); var first = Math.Max(0, end - 500);
    long extra = top * 2 + 1;
    var events = new List<JsonObject>();
    var at = chat.Events.LastOrDefault()?.At.ToUnixTimeMilliseconds() ?? 0;
    for (var i = first; i < end; i++)
    {
      var row = rows[i];
      var sequence = sequences.TryGetValue(Key(row), out var known) ? known * 2 : extra++;
      events.Add(Event(id, provider, sequence, at, Kind(row), row.Id, Value(row)));
    }
    if (before is null && !chat.Busy && !chat.Stopping && rows.Count > 0 && rows[^1].Kind != "user")
      events.Add(Event(id, provider, extra++, at, "completed", "complete:" + (rows[^1].Id.Length <= 400 ? rows[^1].Id : rows[^1].Id[..400]), new JsonObject { ["text"] = "" }));
    while (true)
    {
      var page = new JsonObject
      {
        ["t"] = "chats.events", ["id"] = id, ["busy"] = chat.Busy, ["conversationId"] = id, ["reset"] = before is null, ["older"] = before is not null,
        ["first"] = first, ["total"] = rows.Count, ["events"] = new JsonArray(events.Select(e => (JsonNode)e.DeepClone()).ToArray())
      };
      var bytes = JsonSerializer.SerializeToUtf8Bytes(page);
      if (bytes.Length <= PhoneWire.MaximumMessageBytes - 512 || events.Count == 0) return bytes;
      events.RemoveAt(0); first++;
    }
  }

  private static JsonObject Event(string conversation, string provider, long sequence, long at, string kind, string messageId, JsonObject value) => new()
  {
    ["version"] = 1, ["id"] = conversation + ":" + sequence, ["sequence"] = sequence, ["conversationId"] = conversation, ["turnId"] = "",
    ["provider"] = provider, ["kind"] = kind, ["messageId"] = messageId.Length <= 480 ? messageId : messageId[..480], ["at"] = at, ["value"] = value
  };

  private static string Kind(ChatRow row) => row.Kind switch
  {
    "user" => "user", "assistant" => "message", "tool" => row.Waiting ? "toolCall" : "toolResult",
    "approval" => row.Waiting ? "approval" : "approvalResolved", "error" => "error", "status" => "interrupted", _ => "message"
  };

  private static JsonObject Value(ChatRow row) => row.Kind switch
  {
    "tool" => new JsonObject { ["text"] = Clip(row.Output, 6000), ["name"] = Clip(row.Text, 200), ["input"] = Clip(row.Input, 2000), ["toolId"] = Clip(row.Id, 500),
      ["status"] = row.Status is "failed" or "Failed" ? "failed" : row.Waiting ? "running" : "done" },
    "approval" => new JsonObject { ["text"] = Clip(row.Text, 6000), ["requestId"] = Clip(row.Id, 500), ["input"] = Clip(row.Details, 2000) },
    "error" => new JsonObject { ["text"] = Clip(row.Text, 6000), ["isError"] = true, ["status"] = "failed" },
    _ => new JsonObject { ["text"] = Clip(row.Text, 6000) }
  };

  // The newest worker sequence that shaped each row, so a new message always
  // carries a larger sequence than anything the phone already has.
  private static Dictionary<string, long> Sequences(ChatRecord chat)
  {
    var map = new Dictionary<string, long>();
    foreach (var e in chat.Events)
    {
      var group = e.Kind switch
      {
        "textDelta" or "message" => "assistant", "toolCall" or "toolInputDelta" or "toolResult" => "tool",
        "approval" or "approvalResolved" or "approvalSending" => "approval", "stopped" => "status", _ => e.Kind
      };
      var key = group + ":" + (e.Kind == "error" && e.Id.Length == 0 ? "error:" + e.Sequence : e.Id);
      map[key] = Math.Max(map.GetValueOrDefault(key), Math.Max(1, e.Sequence));
    }
    return map;
  }
  private static string Key(ChatRow row) => (row.Kind == "reasoning" ? "reasoningDelta" : row.Kind) + ":" + row.Id;

  private static string Clip(string? value, int limit) => value is null ? "" : value.Length <= limit ? value : value[..limit] + "\n[Read the rest on the computer.]";
}
