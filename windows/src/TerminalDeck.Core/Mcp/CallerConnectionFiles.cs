using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Mcp;

// The private setup file owns the display name. Tokens and grants never leave this class.
public sealed class CallerConnectionFiles(AppDataRoot root)
{
  private string DirectoryPath => Path.Combine(root.DirectoryPath, "mcp", "callers");
  public IReadOnlyDictionary<string, string> Names(IEnumerable<string> callerIds)
  {
    var ids = callerIds.ToHashSet(StringComparer.Ordinal);
    if (ids.Count == 0) return new Dictionary<string, string>();
    var matches = Read(ids).GroupBy(m => m.CallerId).ToDictionary(g => g.Key, g => g.ToArray());
    return ids.ToDictionary(id => id, id => matches.TryGetValue(id, out var rows) && rows.Length == 1 && ReadName(rows[0].Data) is { } name ? name : id);
  }
  public string Rename(string callerId, string name)
  {
    var clean = ValidName(name) ?? throw new McpRefusal("Enter an app name with 1–80 characters and no control characters.");
    var matches = Read([callerId]);
    if (matches.Count != 1) throw new McpRefusal("This app’s setup file could not be read uniquely. Reconnect it before renaming it.");
    var match = matches[0]; match.Data["name"] = clean;
    var temporary = match.Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
      { JsonSerializer.Serialize(output, match.Data); output.Flush(flushToDisk: true); }
      File.Move(temporary, match.Path, overwrite: true);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
    return clean;
  }
  private sealed record Match(string CallerId, string Path, JsonObject Data);
  private List<Match> Read(HashSet<string> ids)
  {
    var found = new List<Match>();
    if (!Directory.Exists(DirectoryPath)) return found;
    foreach (var path in Directory.EnumerateFiles(DirectoryPath, "*.json"))
    {
      if (!Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out _)) continue;
      try
      {
        var info = new FileInfo(path);
        if (info.Length > 256 * 1024 || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
        if (JsonNode.Parse(File.ReadAllBytes(path)) is not JsonObject data || data["callerId"] is not JsonValue idValue || !idValue.TryGetValue<string>(out var id) || !ids.Contains(id)) continue;
        found.Add(new(id, path, data));
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException) { }
    }
    return found;
  }
  private static string? ReadName(JsonObject data) => data["name"] is JsonValue value && value.TryGetValue<string>(out var text) ? ValidName(text) : null;
  private static string? ValidName(string? value) => value is not null && !string.IsNullOrWhiteSpace(value) && value.Length <= 80 && !value.Any(char.IsControl) ? value.Trim() : null;
}
