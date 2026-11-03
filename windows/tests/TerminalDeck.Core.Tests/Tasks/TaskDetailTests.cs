using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskDetailTests
{
  [Theory]
  [InlineData("To-Do", "Working on it")]
  [InlineData("Working on it", "In Progress")]
  [InlineData("Stuck", "In Progress")]
  [InlineData("In Progress", "Done")]
  [InlineData("Done", null)]
  public void NextStatusFollowsTheMacWorkflowAndStopsAtDone(string status, string? next) => Assert.Equal(next, TaskStatuses.Next(status));
  [Fact] public void DetailEditsSurviveReopenAndPreserveOtherFields()
  {
    var f = new TaskFixture(); var task = f.Create();
    f.Tasks.Detail(task.Id, "field", null, "Customer", TaskActor.Owner);
    var field = Assert.Single(TaskExtras.Of(f.Open().Get(task.Id)).Fields);
    f.Tasks = f.Open();
    f.Tasks.Detail(task.Id, "field-value", field.Id, "Acme", TaskActor.Owner);
    f.Tasks.Detail(task.Id, "star", null, null, TaskActor.Owner);
    var saved = f.Open().Get(task.Id); Assert.True(TaskExtras.Of(saved).Starred);
    Assert.Equal("Acme", Assert.Single(TaskExtras.Of(saved).Fields).Value); Assert.NotEmpty(saved.Activity);
  }
  [Fact] public void ChecklistCanToggleAndTimerCanStopAfterReopen()
  {
    var f = new TaskFixture(); var task = f.Create();
    f.Tasks.Detail(task.Id, "timer", null, null, TaskActor.Owner);
    f.Tasks.Detail(task.Id, "checklist", null, "Verify light theme", TaskActor.Owner);
    var item = Assert.Single(TaskExtras.Of(f.Open().Get(task.Id)).Checklist);
    f.Open().Detail(task.Id, "check", item.Id, null, TaskActor.Owner);
    var saved = f.Open().Detail(task.Id, "timer", null, null, TaskActor.Owner);
    Assert.Null(TaskExtras.Of(saved).TimerStarted); Assert.True(TaskExtras.Of(saved).TrackedSeconds >= 0);
    Assert.True(Assert.Single(TaskExtras.Of(saved).Checklist).Done);
    Assert.Equal("time", saved.Activity[^1].Kind); Assert.Contains(saved.Activity, a => a.Kind == "checklists");
  }
  [Fact] public void RelationCannotCrossProjectsOrPointToItselfAndFailedSaveIsAtomic()
  {
    var f = new TaskFixture(); var task = f.Create(); var other = f.Tasks.Create(new("Other", ProjectId: "other"), TaskActor.Owner);
    Assert.Throws<ArgumentException>(() => f.Tasks.Detail(task.Id, "relate", null, other.Id, TaskActor.Owner));
    Assert.Throws<ArgumentException>(() => f.Tasks.Detail(task.Id, "relate", null, task.Id, TaskActor.Owner));
    f.Persistence.Fail = true;
    Assert.Throws<IOException>(() => f.Tasks.Detail(task.Id, "field", null, "Lost", TaskActor.Owner));
    Assert.Empty(TaskExtras.Of(f.Tasks.Get(task.Id)).Fields);
  }
}
