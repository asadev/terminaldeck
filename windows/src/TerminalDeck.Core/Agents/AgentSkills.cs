namespace TerminalDeck.Core.Agents;

public sealed record InstalledSkill(string Name, string Description, string Folder, string Where);

// The skills really installed for a project: each <root>/<name>/SKILL.md under the
// project's .claude/skills and .agents/skills folders and the person's own
// ~/.claude/skills, ~/.codex/skills and ~/.agents/skills. Name and description come
// from the SKILL.md front matter; a folder without SKILL.md is not a skill.
public static class AgentSkills
{
  public static IReadOnlyList<string> Roots(IEnumerable<string> projectFolders, string? home = null)
  {
    home ??= Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var roots = new List<string>();
    foreach (var folder in projectFolders.Where(f => !string.IsNullOrWhiteSpace(f)))
    {
      roots.Add(Path.Combine(folder, ".claude", "skills")); roots.Add(Path.Combine(folder, ".agents", "skills"));
    }
    if (!string.IsNullOrWhiteSpace(home))
      foreach (var tool in new[] { ".claude", ".codex", ".agents" }) roots.Add(Path.Combine(home, tool, "skills"));
    return roots;
  }
  public static IReadOnlyList<InstalledSkill> Find(IEnumerable<string> roots, int limit = 400)
  {
    var found = new Dictionary<string, InstalledSkill>(StringComparer.OrdinalIgnoreCase);
    foreach (var root in roots)
    {
      DirectoryInfo dir;
      try { dir = new DirectoryInfo(root); if (!dir.Exists) continue; } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { continue; }
      IEnumerable<DirectoryInfo> children;
      try { children = dir.EnumerateDirectories().ToArray(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
      foreach (var child in children.OrderBy(c => c.Name, StringComparer.OrdinalIgnoreCase))
      {
        if (found.Count >= limit) return found.Values.ToArray();
        var file = Path.Combine(child.FullName, "SKILL.md");
        try
        {
          if (!File.Exists(file) || new FileInfo(file).Length > 512 * 1024) continue;
          var (name, description) = FrontMatter(File.ReadLines(file).Take(60));
          name = string.IsNullOrWhiteSpace(name) ? child.Name : name.Trim();
          if (name.Length > 200 || found.ContainsKey(name)) continue;
          found[name] = new(name, description.Trim(), child.FullName, Where(root));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
      }
    }
    return found.Values.OrderBy(s => s.Name, StringComparer.OrdinalIgnoreCase).ToArray();
  }
  private static string Where(string root)
  {
    var parent = Path.GetFileName(Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(root)) ?? "");
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var personal = home.Length > 0 && root.StartsWith(home, StringComparison.OrdinalIgnoreCase) && Path.GetDirectoryName(Path.GetDirectoryName(root)) is { } owner && string.Equals(Path.TrimEndingDirectorySeparator(owner), Path.TrimEndingDirectorySeparator(home), StringComparison.OrdinalIgnoreCase);
    return (personal ? "Yours · " : "This project · ") + parent;
  }
  public static (string Name, string Description) FrontMatter(IEnumerable<string> lines)
  {
    string name = "", description = ""; var inside = false; var first = true;
    foreach (var raw in lines)
    {
      var line = raw.TrimEnd();
      if (first) { first = false; if (line == "---") { inside = true; continue; } return (name, description); }
      if (!inside) break;
      if (line == "---") break;
      static string Value(string l) => l[(l.IndexOf(':') + 1)..].Trim().Trim('"', '\'');
      if (line.StartsWith("name:", StringComparison.OrdinalIgnoreCase)) name = Value(line);
      else if (line.StartsWith("description:", StringComparison.OrdinalIgnoreCase)) description = Value(line);
    }
    return (name, description.Length > 300 ? description[..300] + "…" : description);
  }
}
