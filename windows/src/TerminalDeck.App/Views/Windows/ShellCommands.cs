namespace TerminalDeck.App.Shell;

public sealed record ShellCommand(string Id, string Title, string Shortcut = "");
public static class ShellCommands
{
  public static readonly ShellCommand[] All = [
    new("new-session", "New session…", "Ctrl+T"), new("new-chat", "New chat…", "Ctrl+Shift+T"),
    new("split", "Split the Window", "Ctrl+D"), new("one-pane", "One pane / Restore split"),
    new("swarm", "Swarm View", "Ctrl+\\"), new("palette", "Command Palette", "Ctrl+K"),
    new("quick-open", "Quick Open", "Ctrl+P"), new("search-sessions", "Search Sessions", "Ctrl+Shift+F"),
    new("inspector", "Session Inspector", "Ctrl+Shift+I"), new("actual-size", "Actual Size", "Ctrl+0"),
    new("zoom-in", "Zoom In", "Ctrl+="), new("zoom-out", "Zoom Out", "Ctrl+-"),
    new("settings", "Settings…", "Ctrl+,"), new("rename-session", "Rename session…", "F2"),
    new("session-delete-confirmation", "Ask before deleting sessions…"), new("shortcuts", "Keyboard Shortcuts", "Ctrl+/"),
    new("help", "Help"), new("diagnostics", "Setup & Diagnostics"), new("retry-connection", "Retry connection"), new("show-log", "Show log"), new("report", "Report an Issue"), new("about", "About"),
    new("resume", "Resume last session here", "Ctrl+Shift+R"), new("open-project", "Open a project…", "Ctrl+O"),
    new("project-overview", "Project dashboard", "Ctrl+Shift+D"), new("artifacts", "Artifacts", "Ctrl+Shift+A"),
    new("files", "Files", "Ctrl+Shift+E"), new("source-control", "Source control", "Ctrl+Shift+G"), new("github", "GitHub"),
    new("sidebar", "Show / Hide Sidebar", "Ctrl+Shift+S"), new("return-windows", "Bring session windows back"),
    new("exit", "Exit"), new("stop-exit", "Stop all and exit…")
  ];
  public static IEnumerable<ShellCommand> Matching(string query) => All.Where(c => c.Title.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase) || c.Shortcut.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase));
}

public sealed record QuickFile(string Path, string RelativePath);
public static class WorkspaceFiles
{
  public static string ResolveFolder(string folder) => ResolveFolder(folder, 0);
  private static string ResolveFolder(string folder, int links)
  {
    if (links > 40) throw new IOException("This folder has too many links.");
    var full = System.IO.Path.GetFullPath(folder); var root = System.IO.Path.GetPathRoot(full)!; var current = root;
    foreach (var part in full[root.Length..].Split([System.IO.Path.DirectorySeparatorChar, System.IO.Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
    {
      var entry = new DirectoryInfo(System.IO.Path.Combine(current, part));
      current = entry.LinkTarget is null ? entry.FullName : ResolveFolder((entry.ResolveLinkTarget(true) ?? throw new IOException("This folder link is unavailable.")).FullName, links + 1);
    }
    return current;
  }
  public static IReadOnlyList<QuickFile> Find(string folder, string query, CancellationToken ct = default)
  {
    folder = ResolveFolder(folder);
    if (!Directory.Exists(folder)) throw new DirectoryNotFoundException("The selected project folder is unavailable.");
    var options = new EnumerationOptions { RecurseSubdirectories = false, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.System };
    var pending = new Stack<string>(); pending.Push(folder); var found = new List<QuickFile>(); var visited = 0;
    while (pending.TryPop(out var directory) && visited < 20000)
    {
      ct.ThrowIfCancellationRequested();
      foreach (var path in Directory.EnumerateFiles(directory, "*", options))
      {
        ct.ThrowIfCancellationRequested(); visited++;
        var relative = System.IO.Path.GetRelativePath(folder, path);
        if (relative.Contains(query, StringComparison.OrdinalIgnoreCase)) found.Add(new(path, relative));
        if (visited >= 20000 || found.Count >= 100) return found;
      }
      foreach (var child in Directory.EnumerateDirectories(directory, "*", options))
        if (System.IO.Path.GetFileName(child) is not (".git" or "node_modules" or "bin" or "obj" or ".vs"))
        { if (++visited >= 20000) return found; pending.Push(child); }
    }
    return found;
  }
}
