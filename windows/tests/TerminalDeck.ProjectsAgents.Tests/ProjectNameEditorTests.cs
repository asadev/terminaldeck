using TerminalDeck.Core.Projects;

namespace TerminalDeck.ProjectsAgents.Tests;

public sealed class ProjectNameEditorTests
{
  [Fact] public async Task RapidEditsPersistOnlyTheLastDraftAndPreserveOtherProjectFields()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Original", [f.Home])); var saves = 0;
    using var editor = new ProjectNameEditor((name, expected) => { saves++; return f.Projects.Rename("sample", name, expected).Name; }, "Original");
    editor.Edit("First"); editor.Edit("Second"); editor.Edit("Last"); Assert.True(await editor.FlushAsync());
    Assert.Equal("Last", f.Projects.Get("sample").Name); Assert.Equal(1, saves); Assert.Equal(f.Home, f.Projects.Get("sample").HomeFolder);
  }
  [Fact] public async Task OutsideRenameKeepsTheDraftUntilAnExplicitChoice()
  {
    using var f = new Fixture(); f.Projects.Save(new("sample", "Original", [f.Home]));
    using var editor = new ProjectNameEditor((name, expected) => f.Projects.Rename("sample", name, expected).Name, "Original");
    editor.Edit("My draft"); f.Projects.Rename("sample", "Outside", "Original"); editor.Observe("Outside");
    Assert.True(editor.Conflict); Assert.False(await editor.FlushAsync()); Assert.Equal("My draft", editor.Draft); Assert.Equal("Outside", f.Projects.Get("sample").Name);
    editor.KeepMine(); Assert.True(await editor.FlushAsync()); Assert.Equal("My draft", f.Projects.Get("sample").Name);
    editor.Edit("Another draft"); f.Projects.Rename("sample", "Latest", "My draft"); editor.Observe("Latest"); editor.UseSaved(); Assert.False(editor.Dirty); Assert.Equal("Latest", editor.Draft);
  }
  [Fact] public async Task InvalidNameDoesNotEraseTheSavedNameOrDraft()
  {
    using var editor = new ProjectNameEditor((name, _) => string.IsNullOrWhiteSpace(name) ? throw new ArgumentException("Give the project a name.") : name, "Original");
    editor.Edit(""); Assert.False(await editor.FlushAsync()); Assert.Equal("Original", editor.Saved); Assert.Equal("", editor.Draft); Assert.NotEmpty(editor.Error);
  }
  [Fact] public void ConcurrentProjectSaveCannotRollBackANewerName()
  {
    using var f = new Fixture(); var before = f.Projects.Save(new("sample", "Original", [f.Home])); f.Projects.Rename("sample", "New name", "Original");
    Assert.Throws<InvalidOperationException>(() => f.Projects.Save(new("sample", "Old form", [f.Home]), before)); Assert.Equal("New name", f.Projects.Get("sample").Name);
  }
}
