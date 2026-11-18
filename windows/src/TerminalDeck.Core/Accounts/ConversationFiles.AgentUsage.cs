using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Accounts;

public sealed partial class ConversationFiles
{
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, (long Length, DateTime Written, IReadOnlyList<AgentUsageSample> Samples)> usageCache = new(StringComparer.OrdinalIgnoreCase);
  public string UsageHome(SessionDefinition definition) => Home(definition);
  // Reuses this owner's exact conversation locator and account/path checks. Never chooses the newest transcript.
  public IReadOnlyList<AgentUsageSample>? AgentUsage(SessionRecord session, out long bytesRead, long maximumBytes = 32 * 1024 * 1024)
  {
    bytesRead = 0;
    if (session.Definition.ConversationId is not { Length: > 0 }) return null;
    try
    {
      var definition = session.Definition;
      var id = definition.ConversationId!;
      if (!Guid.TryParse(id, out _)) return null;
      var directory = Path.Combine(Home(definition), definition.Provider switch { "claude" => "projects", "codex" => "sessions", "gemini" => Path.Combine(".gemini", "tmp"), _ => "unavailable" });
      NoLinks(Path.Combine(directory, "placeholder"));
      if (!Directory.Exists(directory)) return null;
      var pattern = definition.Provider == "gemini" ? "*" + id[..8] + "*.json" : "*" + id + "*.jsonl";
      var candidates = Directory.EnumerateFiles(directory, pattern, new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }).Take(5).ToArray();
      var matches = candidates.Where(path => Identity(path, definition.Provider).Id == id).ToArray();
      if (matches.Length != 1) return null;
      var path = matches[0]; NoLinks(path);
      var identity = Identity(path, definition.Provider);
      if (identity.Folder is { } folder && !Path.GetFullPath(folder).Equals(Path.GetFullPath(definition.Cwd), StringComparison.OrdinalIgnoreCase)) return null;
      var metadata = new FileInfo(path);
      if (metadata.Length > Math.Min(32 * 1024 * 1024, maximumBytes)) return null;
      if (usageCache.TryGetValue(path, out var cached) && cached.Length == metadata.Length && cached.Written == metadata.LastWriteTimeUtc) return cached.Samples;
      bytesRead = metadata.Length;
      using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      if (session.Definition.Provider == "gemini")
      {
        using var doc = System.Text.Json.JsonDocument.Parse(stream);
        var values = AgentUsageReadings.Gemini(doc.RootElement); usageCache[path] = (metadata.Length, metadata.LastWriteTimeUtc, values); return values;
      }
      using var reader = new StreamReader(stream);
      var lines = new List<string>(); long bytes = 0;
      while (reader.ReadLine() is { } line)
      {
        bytes += line.Length;
        if (line.Length > 4 * 1024 * 1024 || bytes > 32 * 1024 * 1024) return null;
        lines.Add(line);
      }
      var samples = AgentUsageReadings.Transcript(session.Definition.Provider, lines);
      if (usageCache.Count >= 128) usageCache.Clear();
      usageCache[path] = (metadata.Length, metadata.LastWriteTimeUtc, samples);
      return samples;
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or InvalidOperationException or ArgumentException) { return null; }
  }
}
