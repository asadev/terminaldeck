using System.Globalization;
using System.Text.Json;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Accounts;

// Following a terminal's conversation so a restart (update, crash, reboot) resumes it.
// Claude Code writes <config>/sessions/<pid>.json for each running program: the
// conversation it is in now and whether it is busy. Files stay behind after a program
// ends, so a file counts only for the exact live program (number + start time).
// Transcripts are the fallback once the program has gone.
public sealed partial class ConversationFiles
{
  private const int MaximumRecentTranscripts = 64;
  public LiveConversation? Live(SessionDefinition definition, int processId, long startedAtMs)
  {
    if (definition.Provider != "claude" || definition.Purpose is not null || processId <= 0) return null;
    try
    {
      var path = Path.Combine(Home(definition), "sessions", processId.ToString(CultureInfo.InvariantCulture) + ".json");
      NoLinks(path);
      var file = new FileInfo(path);
      if (!file.Exists || file.Length > 64 * 1024) return null;
      using var json = JsonDocument.Parse(File.ReadAllBytes(path)); var data = json.RootElement;
      if (data.ValueKind != JsonValueKind.Object || !data.TryGetProperty("pid", out var pid) || !pid.TryGetInt32(out var number) || number != processId) return null;
      // Left by an earlier program that had the same number.
      if (startedAtMs > 0 && data.TryGetProperty("startedAt", out var started) && started.TryGetInt64(out var at) && at < startedAtMs - 5000) return null;
      var id = data.TryGetProperty("sessionId", out var session) && session.ValueKind == JsonValueKind.String && Guid.TryParse(session.GetString(), out _) ? session.GetString() : null;
      bool? busy = data.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.String
        ? status.GetString() switch { "busy" => true, "idle" => false, _ => null } : null;
      return new(id, busy);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException) { return null; }
  }

  public string? Discover(SessionRecord session, IReadOnlySet<string> claimed)
  {
    var definition = session.Definition;
    if (definition.Provider is not ("claude" or "codex") || definition.Purpose is not null) return null;
    try
    {
      var since = DateTimeOffset.FromUnixTimeMilliseconds(session.CreatedAt).UtcDateTime.AddSeconds(-5);
      var found = RecentTranscripts(definition, since)
        .Select(path => (Meta: SafeIdentity(path, definition.Provider), Written: File.GetLastWriteTimeUtc(path)))
        .Where(x => x.Meta.Id is { } id && Guid.TryParse(id, out _) && !claimed.Contains(id) && x.Meta.Folder is { } folder && SameFolder(folder, definition.Cwd))
        .GroupBy(x => x.Meta.Id!).Select(g => (Id: g.Key, Written: g.Max(x => x.Written))).ToArray();
      if (definition.ConversationId is { } current)
      {
        var mine = found.FirstOrDefault(x => x.Id == current);
        var moved = found.Where(x => x.Id != current && (mine.Id is null || x.Written > mine.Written)).ToArray();
        return moved.Length == 1 ? moved[0].Id : null;
      }
      return found.Length == 1 ? found[0].Id : null;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or ArgumentException) { return null; }
  }

  public string? Newest(SessionRecord session)
  {
    var definition = session.Definition;
    if (definition.Provider is not ("claude" or "codex") || definition.Purpose is not null) return null;
    try
    {
      var since = DateTimeOffset.FromUnixTimeMilliseconds(session.CreatedAt).UtcDateTime.AddSeconds(-5);
      return RecentTranscripts(definition, since).Select(path => SafeIdentity(path, definition.Provider))
        .FirstOrDefault(x => x.Id is { } id && Guid.TryParse(id, out _) && x.Folder is { } folder && SameFolder(folder, definition.Cwd)).Id;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException) { return null; }
  }

  public bool CanResume(SessionDefinition definition)
  {
    if (definition.Provider != "claude" || definition.ConversationId is not { } id || !Guid.TryParse(id, out _)) return true;
    try
    {
      var projects = Path.Combine(Home(definition), "projects");
      if (File.Exists(Path.Combine(projects, ClaudeProjectFolder(definition.Cwd), id + ".jsonl"))) return true;
      return Directory.Exists(projects) && Directory.EnumerateDirectories(projects).Take(4096).Any(folder => File.Exists(Path.Combine(folder, id + ".jsonl")));
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException) { return true; }
  }

  // Claude Code files a folder's conversations under the folder path with every
  // character other than A-Z, a-z and 0-9 turned into '-'.
  public static string ClaudeProjectFolder(string cwd) => string.Concat(cwd.Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-'));

  private IEnumerable<string> RecentTranscripts(SessionDefinition definition, DateTime sinceUtc)
  {
    var home = Home(definition);
    IEnumerable<string> paths;
    if (definition.Provider == "claude")
    {
      var folder = Path.Combine(home, "projects", ClaudeProjectFolder(definition.Cwd));
      NoLinks(Path.Combine(folder, "placeholder"));
      paths = Directory.Exists(folder) ? Directory.EnumerateFiles(folder, "*.jsonl", new EnumerationOptions { AttributesToSkip = FileAttributes.ReparsePoint }) : [];
    }
    else
    {
      // Codex files rollouts under sessions/yyyy/MM/dd; read only the days since the session started.
      var root = Path.Combine(home, "sessions"); NoLinks(Path.Combine(root, "placeholder"));
      var first = sinceUtc.ToLocalTime().Date.AddDays(-1); var last = DateTime.Now.Date.AddDays(1);
      if (last - first > TimeSpan.FromDays(31)) first = last.AddDays(-31);
      var days = new List<string>();
      for (var day = first; day <= last; day = day.AddDays(1))
      {
        var folder = Path.Combine(root, day.ToString("yyyy", CultureInfo.InvariantCulture), day.ToString("MM", CultureInfo.InvariantCulture), day.ToString("dd", CultureInfo.InvariantCulture));
        if (Directory.Exists(folder)) days.AddRange(Directory.EnumerateFiles(folder, "rollout-*.jsonl", new EnumerationOptions { AttributesToSkip = FileAttributes.ReparsePoint }));
      }
      paths = days;
    }
    return paths.Where(path => File.GetLastWriteTimeUtc(path) >= sinceUtc).OrderByDescending(File.GetLastWriteTimeUtc).Take(MaximumRecentTranscripts).ToArray();
  }
  private static (string? Id, string? Folder) SafeIdentity(string path, string provider)
  {
    try { return Identity(path, provider); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return (null, null); }
  }
  private static bool SameFolder(string a, string b) => Path.GetFullPath(a).TrimEnd('\\', '/').Equals(Path.GetFullPath(b).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);
}
