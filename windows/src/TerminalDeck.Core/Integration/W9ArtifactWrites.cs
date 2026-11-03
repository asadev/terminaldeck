using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Integration;

public sealed record W9ArtifactWrite(long Sequence, string Path, DateTimeOffset At);
public static class W9ArtifactWrites
{
  // Only successful provider write events establish provenance. Text that names
  // a file, directory scans, and failed tools never create an artifact row.
  public static IReadOnlyList<W9ArtifactWrite> Read(ChatRecord chat, long after)
  {
    var rows = new List<W9ArtifactWrite>();
    foreach (var ev in chat.Events.Where(e => e.Sequence > after && e.Kind == "toolResult" && e.Data is { ValueKind: JsonValueKind.Object }))
    {
      var data = ev.Data!.Value;
      if (chat.Definition.Provider == "codex" && S(data, "type") == "fileChange" && S(data, "status") == "completed" &&
          data.TryGetProperty("changes", out var changes) && changes.ValueKind == JsonValueKind.Array)
        foreach (var change in changes.EnumerateArray()) { var path = S(change, "path"); if (path.Length > 0) rows.Add(new(ev.Sequence, path, ev.At)); }
      else if (chat.Definition.Provider == "claude" && S(data, "type") == "tool_result" &&
               (!data.TryGetProperty("is_error", out var failed) || failed.ValueKind == JsonValueKind.False))
      {
        var call = chat.Events.LastOrDefault(e => e.Id == ev.Id && e.Kind == "toolCall" && e.Sequence < ev.Sequence && e.Text is "Write" or "Edit");
        if (call?.Data is { ValueKind: JsonValueKind.Object } input && S(input, "file_path") is { Length: > 0 } path) rows.Add(new(ev.Sequence, path, ev.At));
      }
    }
    return rows;
  }
  private static string S(JsonElement value, string name) => value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString()! : "";
}
