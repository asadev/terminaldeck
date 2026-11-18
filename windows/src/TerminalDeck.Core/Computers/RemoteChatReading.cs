using System.Text.Json;

namespace TerminalDeck.Core.Computers;

public sealed record RemoteChatRow(string Kind, string Text, string Title = "", string? Request = null, string Id = "");
public static class RemoteChatReading
{
  public static IReadOnlyList<RemoteChatRow> Rows(IEnumerable<JsonElement> events)
  {
    var rows = new List<RemoteChatRow>(); var positions = new Dictionary<string, int>();
    foreach (var entry in events.OrderBy(e => RemoteSessionReading.Field(e, "sequence") is { ValueKind: JsonValueKind.Number } number && number.TryGetInt64(out var seq) ? seq : 0))
    {
      var kind = RemoteSessionReading.Text(entry, "kind"); var value = RemoteSessionReading.Field(entry, "value");
      var text = RemoteSessionReading.Text(value, "text"); var id = RemoteSessionReading.Text(entry, "messageId", RemoteSessionReading.Text(entry, "id"));
      var request = RemoteSessionReading.Text(value, "requestId", id);
      var key = kind is "approval" or "approvalResolved" ? "approval:" + request : kind is "toolCall" or "toolResult" ? "tool:" + id : kind == "user" ? "user:" + id : "message:" + id;
      if (kind == "approvalResolved") { if (positions.TryGetValue(key, out var resolved)) rows[resolved] = new("status", "Permission answered"); continue; }
      if (kind is not ("user" or "message" or "textDelta" or "approval" or "toolCall" or "toolResult" or "error")) continue;
      var exists = positions.TryGetValue(key, out var index);
      var shown = kind switch { "user" => "user", "approval" => "approval", "toolCall" or "toolResult" => "tool", _ => "assistant" };
      if (kind == "textDelta" && exists) text = rows[index].Text + text;
      var row = new RemoteChatRow(shown, text, RemoteSessionReading.Text(value, "name", "Tool"), kind == "approval" ? request : null, key);
      if (exists) rows[index] = row; else { positions[key] = rows.Count; rows.Add(row); }
    }
    return rows;
  }
}
