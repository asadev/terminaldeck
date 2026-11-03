using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using Xunit;

namespace TerminalDeck.App.Shell;

public sealed class W14UpgradeTests
{
  [Fact] public void ScratchUpgradeOfW11ProjectRegistryKeepsEveryProjectAndBindingAcrossRestart()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "w14-upgrade-" + Guid.NewGuid()));
    try
    {
      var sessions = Enumerable.Range(1, 5).Select(_ => Guid.NewGuid().ToString()).ToArray();
      // W11's v1 JSON shape, including defaults omitted by older writers.
      var state = new { Version = 1, Projects = new object[] {
        new { Id = "windows-review", Name = "Windows review", Folders = new[] { @"C:\TD\review\Sample project" }, IsOpen = true },
        new { Id = "independent", Name = "Independent", Folders = Array.Empty<string>(), IsOpen = true }
      }, ActiveProjectId = "windows-review", Sessions = sessions.Select(id => new { SessionId = id, ProjectId = "windows-review" }) };
      Directory.CreateDirectory(Path.Combine(root.DirectoryPath, "state"));
      var file = Path.Combine(root.DirectoryPath, "state", "projects.json"); File.WriteAllText(file, JsonSerializer.Serialize(state)); var original = File.ReadAllBytes(file);
      Assert.Null(new JsonStateStore<SidebarSaved>(root, "sidebar").Load());
      var sidebar = new SidebarState(null, true, new JsonStateStore<SidebarSaved>(root, "sidebar").Save);
      Assert.True(sidebar.Pinned("Projects"));
      var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new NeverTouchFolders());
      Assert.Equal(new[] { "Windows review", "Independent" }, projects.List().Select(p => p.Name));
      var group = Assert.Single(projects.GroupSessions(sessions.Select(id => new ProjectSession(id, "Review", "shell", @"C:\Other", "running"))));
      Assert.Equal("windows-review", group.ProjectId); Assert.Equal(5, group.Sessions.Length);
      Assert.Equal(original, File.ReadAllBytes(file));
      sidebar.Pin("Projects", false);
      var restored = new SidebarState(new JsonStateStore<SidebarSaved>(root, "sidebar").Load(), true);
      Assert.False(restored.Pinned("Projects")); Assert.Equal(original, File.ReadAllBytes(file));
      Assert.Equal(2, new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new NeverTouchFolders()).List().Count);
    }
    finally { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  private sealed class NeverTouchFolders : IProjectFolders
  {
    public string RequireFolder(string path) => throw new InvalidOperationException("Upgrading must not touch project folders.");
    public IReadOnlyList<ProjectFolder> Browse(string path, bool showHidden) => throw new InvalidOperationException("Upgrading must not browse project folders.");
  }
}
