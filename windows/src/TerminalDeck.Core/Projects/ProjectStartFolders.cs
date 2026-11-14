using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Projects;

// Asad 30 Oct (Umer's /wrap, /catchup and team skills went missing): a team's
// skills, commands and hooks live in the .claude of the project's HOME folder,
// so every project/agent/seat session starts there, as the old Electron app did
// (one project = one folder = the session's cwd). A project with several folders
// gives the AI its other folders as extra access (Claude --add-dir) instead of
// starting in a code folder that has no team .claude. A task's own workspace
// (a git worktree) keeps its isolated folder and gets the others as extra access.
public sealed record ProjectStart(string Folder, IReadOnlyList<string> ExtraFolders, string? AskedFolder);

public static class ProjectStartFolders
{
  public const string TaskWorkspaceSegment = ".terminaldeck-workspaces";

  public static ProjectStart Choose(Project project, string requested)
  {
    if (project.Id == ProjectIdentity.IndependentId || project.HomeFolder is not { } home) return new(requested, [], null);
    if (ProjectPaths.Contains(home, requested) || IsTaskWorkspace(requested)) return new(requested, Others(project, requested), null);
    var start = ProjectPaths.Normalize(home);
    return new(start, Others(project, start), requested);
  }

  // The folders of the project that owns this working folder, other than the
  // one the session already sits in. Independent folders get none.
  public static IReadOnlyList<string> ExtraFolders(IEnumerable<Project> projects, string cwd)
  {
    try
    {
      var owner = projects.Where(p => p.Id != ProjectIdentity.IndependentId && !p.Folders.IsDefaultOrEmpty && p.Folders.Any(f => ProjectPaths.Contains(f, cwd)))
        .OrderByDescending(p => p.Folders.Where(f => ProjectPaths.Contains(f, cwd)).Max(f => ProjectPaths.Normalize(f).Length)).FirstOrDefault();
      return owner is null ? [] : Others(owner, cwd);
    }
    catch (ArgumentException) { return []; }
  }

  // Read-only look at the saved projects (the keeper and chat workers run the
  // launch without the project service). A missing or unreadable file gives none.
  public static IReadOnlyList<string> ExtraFolders(AppDataRoot root, string cwd)
  {
    try { return new JsonStateStore<ProjectState>(root, "projects").Load() is { Projects.IsDefault: false } state ? ExtraFolders(state.Projects, cwd) : []; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or NotSupportedException) { return []; }
  }

  public static string Note(string asked) =>
    "Work folder for this job: " + asked + ". This session starts in the project's home folder so the team's skills, commands and hooks load; the work folder is open to you as an extra folder.";

  private static IReadOnlyList<string> Others(Project project, string start) =>
    project.Folders.Where(f => !ProjectPaths.Contains(f, start)).Select(ProjectPaths.Normalize).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

  private static bool IsTaskWorkspace(string path) =>
    ProjectPaths.Normalize(path).Split('/').Contains(TaskWorkspaceSegment, StringComparer.OrdinalIgnoreCase);
}
