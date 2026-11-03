using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Quality;

public sealed record ReviewedProjectChange(string Token, string Folder, string File, string? Before, string After, DateTimeOffset ExpiresAt);
public sealed record ReadinessPreferences(Dictionary<string, string[]> Hidden);

public sealed partial class ProjectReadiness
{
  private readonly Dictionary<string, ReviewedProjectChange> changes = [];
  private readonly Dictionary<string, ReviewedProjectChange> applied = [];
  private readonly object changeGate = new();
  public ReviewedProjectChange PreviewChange(string folder, string fix)
  {
    folder = Root(folder);
    string file; string after;
    if (fix == "patch-ignore")
    {
      file = ".gitignore"; var current = ReadProjectText(folder, file) ?? "";
      var lines = current.Split('\n').Select(l => l.Trim()).ToHashSet(StringComparer.Ordinal);
      after = current.TrimEnd() + "\n\n# Environment and private keys\n" + string.Join('\n', SecretRules.Where(r => !lines.Contains(r))) + "\n";
    }
    else if (fix.StartsWith("script-", StringComparison.Ordinal))
    {
      file = "package.json"; var document = JsonNode.Parse(ReadProjectText(folder, file) ?? throw new IOException("package.json is missing."))!.AsObject();
      var key = fix[7..]; var choice = ScriptChoices(key).FirstOrDefault(c => (document["dependencies"] as JsonObject)?.ContainsKey(c.Dependency) == true || (document["devDependencies"] as JsonObject)?.ContainsKey(c.Dependency) == true);
      if (choice.Dependency is null) throw new InvalidOperationException("The required dependency is not declared.");
      var command = choice.Command;
      var scripts = document["scripts"] as JsonObject;
      if (scripts is null) { scripts = new(); document["scripts"] = scripts; }
      if (scripts[key] is { } old && !string.IsNullOrWhiteSpace(old.GetValue<string>()) && !old.GetValue<string>().Contains("no test specified", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("A useful script already exists. Edit it in Files.");
      scripts[key] = command; after = document.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n";
    }
    else
    {
      file = fix switch { "instructions" => "AGENTS.md", "claude-instructions" => "CLAUDE.md", "gemini-instructions" => "GEMINI.md", "readme" => "README.md", "ignore" => ".gitignore", _ => throw new ArgumentException("Choose a supported reviewed fix.") };
      if (ReadProjectText(folder, file) is not null) throw new IOException("That file already exists.");
      after = file == ".gitignore" ? "node_modules/\ndist/\nbuild/\n" + string.Join('\n', SecretRules) + "\n" : "# " + Path.GetFileName(folder) + "\n\nDescribe this project and its purpose.\n\n## Run\n\nAdd the actual setup and start commands.\n\n## Verify\n\nAdd the actual test and check commands.\n\n## Conventions\n\nAdd the project conventions and files that need special care.\n";
    }
    var change = new ReviewedProjectChange(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24)), folder, file, ReadProjectText(folder, file), after, DateTimeOffset.UtcNow.AddMinutes(10));
    lock (changeGate)
    {
      foreach (var stale in changes.Values.Where(v => v.ExpiresAt <= DateTimeOffset.UtcNow).ToArray()) changes.Remove(stale.Token);
      if (changes.Count >= 64) throw new InvalidOperationException("Finish an existing preview first.");
      changes.Add(change.Token, change);
    }
    return change;
  }
  public string ApplyChange(string folder, string token)
  {
    folder = Root(folder);
    lock (changeGate)
    {
      if (!changes.TryGetValue(token, out var change) || change.ExpiresAt <= DateTimeOffset.UtcNow || change.Folder != folder) throw new InvalidOperationException("Preview again: this review expired or belongs to another project.");
      if (ReadProjectText(folder, change.File) != change.Before) throw new IOException("The file changed after preview. Nothing was written; preview again.");
      WriteReviewed(change, change.Before, change.After); changes.Remove(token); applied[token] = change;
      return Path.Combine(folder, change.File);
    }
  }
  public void RollbackChange(string folder, string token)
  {
    folder = Root(folder);
    lock (changeGate)
    {
      if (!applied.TryGetValue(token, out var change) || change.Folder != folder) throw new InvalidOperationException("No applied change belongs to that project and token.");
      if (ReadProjectText(folder, change.File) != change.After) throw new IOException("The file changed after this fix. Rollback would erase later edits; review it in Files.");
      if (change.Before is null) File.Delete(SafeFile(folder, change.File)); else WriteReviewed(change, change.After, change.Before);
      applied.Remove(token);
    }
  }
  private static void WriteReviewed(ReviewedProjectChange change, string? expected, string text)
  {
    var path = SafeFile(change.Folder, change.File);
    if (expected is null)
    {
      using var target = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
      target.Write(Encoding.UTF8.GetBytes(text)); target.Flush(true); return;
    }
    // A sharing lock prevents edits between the final comparison and the write on Windows.
    using var existing = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
    using var reader = new StreamReader(existing, Encoding.UTF8, true, 4096, leaveOpen: true);
    if (reader.ReadToEnd() != expected) throw new IOException("The file changed while the fix was being applied.");
    existing.Position = 0; var bytes = Encoding.UTF8.GetBytes(text); existing.Write(bytes); existing.SetLength(bytes.Length); existing.Flush(true);
  }
}

public sealed class ReadinessDismissals(IStateStore<ReadinessPreferences> store)
{
  private readonly object gate = new();
  private static string Scope(string folder) => folder == "*machine*" ? folder : Path.GetFullPath(folder);
  public string[] Hidden(string folder) { lock (gate) return (store.Load()?.Hidden.GetValueOrDefault(Scope(folder)) ?? []).ToArray(); }
  public void Set(string folder, string id, bool hidden)
  {
    if (string.IsNullOrWhiteSpace(id) || id.Length > 120) throw new ArgumentException("Choose a readiness check.");
    lock (gate)
    {
      var map = store.Load()?.Hidden ?? new(StringComparer.OrdinalIgnoreCase); var root = Scope(folder);
      var ids = map.GetValueOrDefault(root, []).ToHashSet(StringComparer.Ordinal); if (hidden) ids.Add(id); else ids.Remove(id);
      if (ids.Count == 0) map.Remove(root); else map[root] = ids.Order().ToArray(); store.Save(new(map));
    }
  }
}
