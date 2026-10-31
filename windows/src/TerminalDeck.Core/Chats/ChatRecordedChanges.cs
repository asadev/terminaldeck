using System.Text.Json;
namespace TerminalDeck.Core.Chats;

public sealed record ChatRecordedChange(string Path, string? Diff, string? Before, string? After, int? Added, int? Deleted, long SourceSequence, bool Truncated);
public static class ChatRecordedChanges
{
  public static IReadOnlyList<ChatRecordedChange> Read(ChatRecord chat)
  {
    var changes = new List<ChatRecordedChange>();
    foreach (var entry in chat.Events.Where(e => e.Kind == "toolResult"))
    {
      if (entry.Data is { ValueKind: JsonValueKind.Object } data)
      {
        if (data.TryGetProperty("is_error", out var error) && error.ValueKind == JsonValueKind.True) continue;
        if (data.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.String && status.GetString() == "failed") continue;
        if (data.TryGetProperty("changes", out var list) && list.ValueKind == JsonValueKind.Array)
        {
          foreach (var item in list.EnumerateArray()) Add(item, entry.Sequence);
          continue;
        }
      }
      var tool = chat.Events.LastOrDefault(e => e.Kind == "toolCall" && e.Id == entry.Id && e.Sequence < entry.Sequence);
      if (tool?.Text is not ("Write" or "Edit" or "MultiEdit")) continue;
      var assembled = chat.Events.LastOrDefault(e => e.Kind == "toolInputDelta" && e.Id == entry.Id && e.Sequence < entry.Sequence)?.Text;
      try
      {
        using var input = JsonDocument.Parse(assembled ?? tool.Data?.GetRawText() ?? "{}"); Add(input.RootElement, entry.Sequence);
      }
      catch (JsonException) { }
    }
    return changes;
    void Add(JsonElement value, long source)
    {
      string? Text(params string[] names)
      { foreach (var name in names) if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String) return v.GetString(); return null; }
      var path = Text("path", "file_path", "filePath"); if (string.IsNullOrWhiteSpace(path) || path.Any(char.IsControl)) return;
      var diff = Text("diff", "patch"); var before = Text("old_string", "oldText"); var after = Text("new_string", "newText", "content");
      int? added = null; int? deleted = null;
      if (diff is not null)
      {
        var lines = diff.Replace("\r\n", "\n").Split('\n');
        added = lines.Count(l => l.StartsWith('+') && !l.StartsWith("+++", StringComparison.Ordinal));
        deleted = lines.Count(l => l.StartsWith('-') && !l.StartsWith("---", StringComparison.Ordinal));
      }
      var truncated = new[] { diff, before, after }.Any(t => t?.Length > 20000);
      string? Bound(string? text) => text is { Length: > 20000 } ? text[..20000] : text;
      changes.Add(new(path, Bound(diff), Bound(before), Bound(after), added, deleted, source, truncated));
    }
  }
}
