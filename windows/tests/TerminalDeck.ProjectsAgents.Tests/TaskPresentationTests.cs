using TerminalDeck.App.ViewModels.Tasks;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.ProjectsAgents.Tests;

public sealed class TaskPresentationTests
{
  private sealed class EmptyStore : TerminalDeck.Core.Storage.IStateStore<TasksState>
  {
    public TasksState? Load() => null;
    public void Save(TasksState state) { }
  }
  private sealed class ProjectStore : TerminalDeck.Core.Storage.IStateStore<TerminalDeck.Core.Projects.ProjectState>
  {
    public TerminalDeck.Core.Projects.ProjectState? Load() => null;
    public void Save(TerminalDeck.Core.Projects.ProjectState state) { }
  }
  private sealed class Folders : TerminalDeck.Core.Projects.IProjectFolders
  {
    public string RequireFolder(string folder) => folder;
    public IReadOnlyList<TerminalDeck.Core.Projects.ProjectFolder> Browse(string folder, bool showHidden) => [];
  }
  private static DeckTask Row(string title, string? due = null, string? priority = null) =>
    new(title, title, "", "independent", "", "To-Do", "me", DateTimeOffset.UtcNow, DateTimeOffset.UtcNow, Priority: priority, DueDate: due);

  private static TasksViewModel Model()
  {
    var projects = new TerminalDeck.Core.Projects.ProjectService(new ProjectStore(), new Folders());
    return new(new TaskService(new TaskStore(new EmptyStore()), projects, _ => null), projects, "proof", () => []);
  }
  [Fact] public async Task RenameRejectsAStaleRevisionAndKeepsTheDraft()
  {
    using var model = Model(); var row = model.Tasks.Create(new("Original"), TaskActor.Owner);
    model.Select(row.Id); model.BeginRename(row); model.TitleDraft = "My new name";
    model.Tasks.Status(row.Id, "In Progress", TaskActor.Owner);
    Assert.False(await model.RenameAsync()); Assert.True(model.EditingTitle); Assert.Equal("My new name", model.TitleDraft);
    Assert.Equal("Original", model.Tasks.Get(row.Id).Title);
    model.CancelRename(); model.BeginRename(model.Tasks.Get(row.Id)); model.TitleDraft = "Current name";
    Assert.True(await model.RenameAsync()); Assert.False(model.EditingTitle); Assert.Equal("Current name", model.Tasks.Get(row.Id).Title);
    Assert.Equal("In Progress", model.Tasks.Get(row.Id).Status);
  }
  [Fact] public void TagGroupsDoNotLoseMultiTaggedTasksOrConfuseATagNamedDone()
  {
    using var model = Model(); model.Filters(new(GroupBy: "tags"));
    var rows = new[] { Row("One") with { Labels = ["review", "windows"] }, Row("Two") with { Labels = ["Done"] }, Row("Three") with { Labels = [], Status = "Done" } };
    var groups = model.Groups(rows);
    Assert.Equal("One", Assert.Single(groups.Single(g => g.Tag == "review").Rows).Id);
    Assert.Equal("One", Assert.Single(groups.Single(g => g.Tag == "windows").Rows).Id);
    Assert.NotEqual(groups.Single(g => g.Tag == "Done").Key, groups.Single(g => g.Key == "closed").Key);
    Assert.Equal("Three", Assert.Single(groups.Single(g => g.Key == "closed").Rows).Id);
  }
  [Fact] public void ColumnsMoveAndSavedViewDirtyStateCompareMeaning()
  {
    using var model = Model(); model.Column("created", true); model.MoveColumn("created", -1);
    var saved = model.Tasks.SaveView(model.Machine, null, "My view", model.Filter); model.SelectView(saved.Id);
    Assert.False(model.ViewChanged); Assert.True(model.Columns.Contains("created"));
    model.Descending = true; Assert.True(model.ViewChanged); model.SelectView(saved.Id); Assert.False(model.Descending); Assert.False(model.ViewChanged);
  }
  [Fact] public void SortDirectionAppliesToTheCombinedOpenAndClosedRows()
  {
    using var model = Model();
    DeckTask[] rows = [Row("Zulu", "2026-11-01"), Row("Alpha", "2026-10-29") with { Status = "Done" }, Row("Middle")];
    model.Sort = "name"; Assert.Equal(new[] { "Alpha", "Middle", "Zulu" }, model.Ordered(rows).Select(t => t.Title));
    model.Descending = true; Assert.Equal(new[] { "Zulu", "Middle", "Alpha" }, model.Ordered(rows).Select(t => t.Title));
    model.Sort = "due"; model.Descending = false; Assert.Equal(new[] { "Alpha", "Zulu", "Middle" }, model.Ordered(rows).Select(t => t.Title));
  }
}
