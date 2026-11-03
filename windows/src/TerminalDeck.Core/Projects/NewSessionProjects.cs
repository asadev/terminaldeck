namespace TerminalDeck.Core.Projects;

// A project organizes work; neither a saved project nor a search match is a
// prerequisite for starting a session outside one.
public static class NewSessionProjects
{
  public const string CreateId = ":new-project";
  public static IReadOnlyList<Project> Choices(IEnumerable<Project> projects, string query = "")
  {
    var rows = projects.ToArray();
    var independent = rows.FirstOrDefault(p => p.Id == ProjectIdentity.IndependentId) ?? ProjectIdentity.Independent;
    return new[] { independent }.Concat(rows.Where(p => p.Id != ProjectIdentity.IndependentId && p.IsOpen &&
      (p.Name + " " + p.HomeFolder).Contains(query.Trim(), StringComparison.OrdinalIgnoreCase))).ToArray();
  }
  public static string Selection(IEnumerable<Project> choices, string? preferred)
    => choices.Any(p => p.Id == preferred) ? preferred! : ProjectIdentity.IndependentId;
  public static string Folder(Project project, string homeFolder) => project.HomeFolder ?? homeFolder;
}

public enum FolderChoiceKind { Project, Recent, Home }
public sealed record FolderChoice(string Path, string Label, FolderChoiceKind Kind, string? ProjectId = null);

// The New session folder dropdown (Mac: Project menu + recent list + Browse):
// open projects' folders first, then folders recently used by sessions, then the
// home folder for an Independent session. Typed paths and Choose folder… add to it.
public static class NewSessionFolders
{
  public const int RecentLimit = 12;
  // "C:/TD/x", "C:\TD\x" and "C:\TD\x\" are one folder: compare with one separator, no trailing one.
  public static string Key(string path) => path.Trim().Replace('/', '\\').TrimEnd('\\');
  // Folders inside the app's own data (account homes, Hoot's folder) are never offered.
  public static bool Internal(string path, string? dataRoot) => dataRoot is { Length: > 0 } &&
    (Key(path) + "\\").StartsWith(Key(dataRoot) + "\\", StringComparison.OrdinalIgnoreCase);
  public static IReadOnlyList<FolderChoice> Choices(IEnumerable<Project> projects, IEnumerable<string> recentFolders, string homeFolder, string query = "", string? dataRoot = null)
  {
    var rows = new List<FolderChoice>(); var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    bool Add(FolderChoice choice)
    {
      var key = Key(choice.Path);
      if (string.IsNullOrWhiteSpace(key) || !seen.Add(key)) return false;
      if (query.Trim().Length > 0 && !(choice.Label + " " + choice.Path).Contains(query.Trim(), StringComparison.OrdinalIgnoreCase)) { seen.Remove(key); return false; }
      rows.Add(choice); return true;
    }
    foreach (var project in projects.Where(p => p.IsOpen && p.Id != ProjectIdentity.IndependentId).OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase))
      foreach (var folder in project.Folders)
        Add(new(folder, project.Folders.Length > 1 ? project.Name + " · " + Path.GetFileName(Path.TrimEndingDirectorySeparator(folder)) : project.Name, FolderChoiceKind.Project, project.Id));
    var recent = 0;
    foreach (var folder in recentFolders)
    {
      if (recent >= RecentLimit) break;
      if (Internal(folder, dataRoot)) continue;
      if (Add(new(folder, Path.GetFileName(Path.TrimEndingDirectorySeparator(folder)) is { Length: > 0 } name ? name : folder, FolderChoiceKind.Recent))) recent++;
    }
    Add(new(homeFolder, "Independent · home folder", FolderChoiceKind.Home, ProjectIdentity.IndependentId));
    return rows;
  }
}
