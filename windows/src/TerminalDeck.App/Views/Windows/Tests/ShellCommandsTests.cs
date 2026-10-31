using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class ShellCommandsTests
{
  [Fact] public void PaletteAndShortcutReferenceUseOneUniqueCommandCatalogue()
  {
    Assert.Equal(ShellCommands.All.Length, ShellCommands.All.DistinctBy(c => c.Id).Count());
    var chords = ShellCommands.All.Where(c => c.Shortcut.Length > 0).ToArray();
    Assert.Equal(chords.Length, chords.DistinctBy(c => c.Shortcut).Count());
    Assert.Contains(ShellCommands.Matching("ctrl+shift"), c => c.Id == "new-chat");
  }
  [Fact] public void FilesSourceControlAndGitHubAreInMoreWithPinsAndShortcuts()
  {
    Assert.Equal("Ctrl+Shift+E", ShellCommands.All.Single(c => c.Id == "files").Shortcut);
    Assert.Equal("Ctrl+Shift+G", ShellCommands.All.Single(c => c.Id == "source-control").Shortcut);
    Assert.Contains(ShellCommands.All, c => c.Id == "github");
    foreach (var id in new[] { "Files", "SourceControl", "GitHub" })
    {
      Assert.Contains(SidebarState.Catalogue, p => p.Id == id);
      Assert.True(Enum.TryParse<TerminalDeck.App.ViewModels.ShellPage>(id, out _));
      var state = new SidebarState(null, false); state.Pin(id, true); Assert.True(state.Pinned(id)); state.Pin(id, false); Assert.False(state.Pinned(id));
    }
    Assert.Equal("Source control", new TerminalDeck.App.ViewModels.ShellViewModel { Page = TerminalDeck.App.ViewModels.ShellPage.SourceControl }.Title);
  }
  [Fact] public void QuickOpenSeesNewFilesAndNeverFollowsDirectoryLinks()
  {
    var folder = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "td-w12-" + Guid.NewGuid().ToString("N"));
    try
    {
      Directory.CreateDirectory(folder); File.WriteAllText(System.IO.Path.Combine(folder, "one.txt"), "first");
      Assert.Single(WorkspaceFiles.Find(folder, ".txt"));
      File.WriteAllText(System.IO.Path.Combine(folder, "two.txt"), "second");
      Directory.CreateSymbolicLink(System.IO.Path.Combine(folder, "loop"), folder);
      Assert.Equal(2, WorkspaceFiles.Find(folder, ".txt").Count);
      Directory.CreateDirectory(System.IO.Path.Combine(folder, "node_modules")); File.WriteAllText(System.IO.Path.Combine(folder, "node_modules", "ignore.txt"), "dependency");
      Assert.Empty(WorkspaceFiles.Find(folder, "ignore"));
    }
    finally { Directory.Delete(folder, true); }
  }
  [Fact] public void FolderLinksResolveToTheActualGrantTargetIncludingAncestorLinks()
  {
    var root = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "td-w12-link-" + Guid.NewGuid().ToString("N"));
    try
    {
      var actual = System.IO.Path.Combine(root, "actual"); Directory.CreateDirectory(System.IO.Path.Combine(actual, "child"));
      var link = System.IO.Path.Combine(root, "link"); Directory.CreateSymbolicLink(link, actual);
      Assert.Equal(WorkspaceFiles.ResolveFolder(System.IO.Path.Combine(actual, "child")), WorkspaceFiles.ResolveFolder(System.IO.Path.Combine(link, "child")));
    }
    finally { Directory.Delete(root, true); }
  }

}
