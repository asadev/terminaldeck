using System.Text.Json;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskViewsTests
{
  [Fact] public async Task DuplicateTaskKeepsContentAndStartsAsFreshUnassignedWork()
  {
    var f = new TaskFixture(); var source = f.Create(); source = f.Tasks.Update(source.Id, TaskService.Draft(source) with { Details = new string('x', 4000), Labels = ["review"], Board = "Release", Type = "Milestone" }, TaskActor.Owner);
    await f.Tasks.CommentAsync(source.Id, "A prior comment", TaskActor.Owner); await f.Tasks.AssignAsync(source.Id, "reviewer", TaskActor.Owner);
    var copy = f.Tasks.Duplicate(source.Id, TaskActor.Owner); Assert.NotEqual(source.Id, copy.Id); Assert.Equal("none", copy.Assignee); Assert.Equal("To-Do", copy.Status);
    Assert.Equal(source.Details, copy.Details); Assert.Equal(source.Board, copy.Board); Assert.Equal("Milestone", copy.Type); Assert.Empty(copy.Comments); Assert.Null(copy.CurrentRunId); Assert.Single(f.Tasks.Runs());
  }
  [Fact] public async Task MultiFiltersCombineOrWithinEachGroupAndAndAcrossGroups()
  {
    var f = new TaskFixture(); var mine = f.Create("Mine"); var unassigned = f.Tasks.Create(new("Other project", ProjectId: "other", Status: "Stuck", Assignee: "none"), TaskActor.Owner);
    var delegated = f.Create("Delegated"); await f.Tasks.AssignAsync(delegated.Id, "reviewer", TaskActor.Owner);
    var filter = new TaskFilter(ProjectIds: ["sample", "other"], Statuses: ["To-Do", "Stuck"], Assignees: ["me", "none"]);
    Assert.Equal(new[] { mine.Id, unassigned.Id }.Order(), f.Tasks.List(filter).Select(t => t.Id).Order());
    Assert.Equal(unassigned.Id, Assert.Single(f.Tasks.List(filter with { NeedsYouOnly = true })).Id);
    Assert.Equal(delegated.Id, Assert.Single(f.Tasks.List(new(Assignees: ["others"]))).Id);
    f.Tasks.RememberFilter("pc", filter); var saved = f.Tasks.SaveView("pc", null, "Mixed", filter);
    f.Persistence.State = JsonSerializer.Deserialize<TasksState>(JsonSerializer.Serialize(f.Persistence.State));
    Assert.True(TaskPresentation.Same(filter, f.Open().Filter("pc"))); Assert.True(TaskPresentation.Same(filter, f.Open().Views("pc").Single(v => v.Id == saved.Id).State));
  }
  [Fact] public void SavedGroupingAliasesComeBackAsTheVisiblePickerValues()
  {
    var f = new TaskFixture(); f.Tasks.RememberFilter("pc", new(GroupBy: "none")); Assert.Equal("single", f.Tasks.Filter("pc").GroupBy);
    var view = f.Tasks.SaveView("pc", null, "Due", new(GroupBy: "due")); Assert.Equal("date", view.State.GroupBy);
  }
  [Fact] public void TrashContainsArchivedDeletedTasksAndRestoringKeepsTheirArchiveState()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Tasks.Status(task.Id, "Done", TaskActor.Owner); f.Tasks.Archive(task.Id, true, TaskActor.Owner); f.Tasks.Delete(task.Id, TaskActor.Owner);
    Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Status: "all", Trash: true))).Id);
    var restored = f.Tasks.Restore(task.Id, TaskActor.Owner); Assert.True(restored.Archived); Assert.Empty(f.Tasks.List(new(Status: "all", Trash: true))); Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Status: "all", Archived: true))).Id);
  }
  [Fact] public void DefaultColumnsSerializeSafelyAndExplicitNoColumnsStayEmpty()
  {
    var defaults = JsonSerializer.Deserialize<TaskFilter>(JsonSerializer.Serialize(new TaskFilter()))!;
    Assert.True(TaskPresentation.Same(new(), defaults));
    var hidden = JsonSerializer.Deserialize<TaskFilter>(JsonSerializer.Serialize(new TaskFilter(Columns: [])))!;
    Assert.Empty(TaskPresentation.Columns(hidden));
  }
  [Fact] public void SavedViewsKeepPresentationAndStayWithinTheirComputer()
  {
    var f = new TaskFixture(); var task = f.Create();
    var state = new TaskFilter("sample", GroupBy: "assignee", Due: "week", Sort: "name", Descending: true, View: "Board", Columns: ["created", "due"], ColumnOrder: [.. TaskPresentation.ColumnKeys.Reverse()]);
    var view = f.Tasks.SaveView("pc", null, "Review", state);
    f.Persistence.State = JsonSerializer.Deserialize<TasksState>(JsonSerializer.Serialize(f.Persistence.State));
    var reopened = f.Open(); var loaded = Assert.Single(reopened.Views("pc")); Assert.True(TaskPresentation.Same(state, loaded.State)); Assert.Empty(reopened.Views("other-pc"));
    var renamed = reopened.SaveView("pc", loaded.Id, "Review later", loaded.State); Assert.Equal(view.Id, renamed.Id);
    Assert.Throws<ArgumentException>(() => reopened.DeleteView("other-pc", view.Id));
    reopened.DeleteView("pc", view.Id); Assert.Empty(reopened.Views("pc")); Assert.Equal(task.Id, Assert.Single(reopened.List()).Id);
  }
  [Fact] public void DueFiltersUseCalendarBoundariesAndExcludeFinishedOverdueWork()
  {
    var f = new TaskFixture(); var today = DateOnly.FromDateTime(DateTime.Today);
    var overdue = f.Create("Overdue", today.AddDays(-1).ToString("yyyy-MM-dd"));
    var closed = f.Create("Closed", today.AddDays(-2).ToString("yyyy-MM-dd")); f.Tasks.Status(closed.Id, "Done", TaskActor.Owner);
    var dueToday = f.Create("Today", today.ToString("yyyy-MM-dd")); f.Create("Seventh day", today.AddDays(7).ToString("yyyy-MM-dd")); f.Create("Eighth day", today.AddDays(8).ToString("yyyy-MM-dd")); var undated = f.Create("No date");
    Assert.Equal(overdue.Id, Assert.Single(f.Tasks.List(new(Status: "all", Due: "overdue"))).Id);
    Assert.Equal(dueToday.Id, Assert.Single(f.Tasks.List(new(Due: "today"))).Id);
    Assert.Equal(2, f.Tasks.List(new(Due: "week")).Count); Assert.Equal(undated.Id, Assert.Single(f.Tasks.List(new(Due: "none"))).Id);
  }
  [Fact] public void InvalidPresentationNeverReplacesTheSavedFilter()
  {
    var f = new TaskFixture(); f.Tasks.RememberFilter("pc", new(GroupBy: "tags"));
    Assert.Throws<ArgumentException>(() => f.Tasks.RememberFilter("pc", new(Columns: ["due", "due"])));
    Assert.Throws<ArgumentException>(() => f.Tasks.RememberFilter("pc", new(ColumnOrder: ["due"])));
    Assert.Throws<ArgumentException>(() => f.Tasks.RememberFilter("pc", new(Due: "unknown")));
    Assert.Equal("tags", f.Tasks.Filter("pc").GroupBy);
  }
  [Fact] public void MilestoneTypeSurvivesCreationUpdateAndReload()
  {
    var f = new TaskFixture(); var task = f.Tasks.Create(new("Release", Type: "Milestone"), TaskActor.Owner);
    Assert.Equal("Milestone", f.Open().Get(task.Id).Type);
    task = f.Tasks.Update(task.Id, TaskService.Draft(task) with { Type = "Task" }, TaskActor.Owner, task.Revision);
    Assert.Equal("Task", task.Type); Assert.Equal("details", TaskActivityKinds.Of(task.Activity.Last()));
    Assert.Throws<ArgumentException>(() => f.Tasks.Update(task.Id, TaskService.Draft(task) with { Type = "unsupported" }, TaskActor.Owner));
  }
}
