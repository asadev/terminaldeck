using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Code;

// One folder the Files / Source control / GitHub pages show: a project's
// folder, or the folder of an Independent (no-project) session.
public sealed record CodeRoot(string Key, string? ProjectId, string Name, string Folder, bool Independent)
{
  public string FolderName => Path.GetFileName(Path.TrimEndingDirectorySeparator(Folder)) is { Length: > 0 } name ? name : Folder;
}
public sealed record CodeSessionFolder(string? ProjectId, string Folder);

public static class CodeWorkspace
{
  private static StringComparer Paths => OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
  private static string Normal(string folder) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));

  // Every open project (each of its folders), then the folders of sessions that
  // belong to no project. Nothing is locked to one project.
  public static IReadOnlyList<CodeRoot> Roots(IEnumerable<Project> projects, IEnumerable<CodeSessionFolder> sessions)
  {
    var roots = new List<CodeRoot>(); var seen = new HashSet<string>(Paths);
    foreach (var project in projects.Where(p => p.IsOpen && p.Id != ProjectIdentity.IndependentId))
    {
      var folders = project.Folders.IsDefaultOrEmpty ? [] : project.Folders.Where(f => !string.IsNullOrWhiteSpace(f)).Select(Normal).Distinct(Paths).ToArray();
      foreach (var folder in folders)
      {
        if (!seen.Add(folder)) continue;
        var name = folders.Length > 1 ? project.Name + " · " + (Path.GetFileName(folder) is { Length: > 0 } leaf ? leaf : folder) : project.Name;
        roots.Add(new("project:" + project.Id + ":" + folder, project.Id, name, folder, false));
      }
    }
    var known = projects.Where(p => p.Id != ProjectIdentity.IndependentId).Select(p => p.Id).ToHashSet();
    foreach (var session in sessions)
    {
      if (string.IsNullOrWhiteSpace(session.Folder)) continue;
      if (session.ProjectId is { } id && known.Contains(id) && projects.First(p => p.Id == id).IsOpen) continue;
      var folder = Normal(session.Folder);
      if (roots.Any(r => Within(r.Folder, folder)) || !seen.Add(folder)) continue;
      roots.Add(new("folder:" + folder, null, Path.GetFileName(folder) is { Length: > 0 } leaf ? leaf : folder, folder, true));
    }
    return roots;
  }
  public static bool Within(string root, string folder)
  {
    var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    root = Path.TrimEndingDirectorySeparator(root); folder = Path.TrimEndingDirectorySeparator(folder);
    return string.Equals(root, folder, comparison) || folder.StartsWith(root + Path.DirectorySeparatorChar, comparison);
  }
  // Follows the current session: its folder first, then its project, else the first root.
  public static CodeRoot? Current(IReadOnlyList<CodeRoot> roots, string? projectId, string? folder)
  {
    if (folder is { Length: > 0 })
    {
      var normal = Normal(folder);
      var match = roots.Where(r => Within(r.Folder, normal)).OrderByDescending(r => r.Folder.Length).FirstOrDefault();
      if (match is not null) return match;
    }
    return roots.FirstOrDefault(r => projectId is not null && r.ProjectId == projectId) ?? roots.FirstOrDefault();
  }
}
