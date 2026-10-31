using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskGoalsTests
{
  [Fact] public void ProjectRemovalCannotOrphanItsGoals()
  {
    var f = new TaskFixture(); var goal = f.Tasks.SaveGoal(new("Outcome", "", "sample"), TaskActor.Owner);
    Assert.Throws<InvalidOperationException>(() => f.Projects.Remove("sample")); Assert.Equal(goal.Id, Assert.Single(f.Tasks.Goals()).Id);
    f.Tasks.DeleteGoal(goal.Id, TaskActor.Owner); f.Projects.Remove("sample"); Assert.DoesNotContain(f.Projects.List(), p => p.Id == "sample");
  }
  [Fact] public void RemovingAGoalReparentsTasksAndSubgoalsInOneDurableChange()
  {
    var f = new TaskFixture(); var root = f.Tasks.SaveGoal(new("Release", "", "sample"), TaskActor.Owner);
    var middle = f.Tasks.SaveGoal(new("Review", "", "sample", ParentId: root.Id), TaskActor.Owner);
    var child = f.Tasks.SaveGoal(new("Checks", "", "sample", ParentId: middle.Id), TaskActor.Owner);
    var task = f.Tasks.Create(new("Review task", ProjectId: "sample", GoalId: middle.Id), TaskActor.Owner);
    Assert.Equal(task.Id, Assert.Single(f.Tasks.List(new(Status: "all", GoalId: root.Id))).Id);
    f.Tasks.RememberFilter("pc", new(GoalId: middle.Id)); f.Tasks.SaveView("pc", null, "Review", new(GoalId: middle.Id));
    f.Tasks.DeleteGoal(middle.Id, TaskActor.Owner); var loaded = f.Open();
    Assert.Equal(root.Id, loaded.Get(task.Id).GoalId); Assert.Equal(root.Id, loaded.Goals().Single(g => g.Id == child.Id).ParentId);
    Assert.Equal(root.Id, loaded.Filter("pc").GoalId); Assert.Equal(root.Id, Assert.Single(loaded.Views("pc")).State.GoalId);
    Assert.Equal(4, f.Persistence.State!.Version);
  }
  [Fact] public void CyclesForeignGoalsAndStaleEditsAreRejectedWithoutLoss()
  {
    var f = new TaskFixture(); var root = f.Tasks.SaveGoal(new("Release", "", "sample"), TaskActor.Owner);
    var child = f.Tasks.SaveGoal(new("Review", "", "sample", ParentId: root.Id), TaskActor.Owner);
    Assert.Throws<ArgumentException>(() => f.Tasks.SaveGoal(new("Release", "", "sample", ParentId: child.Id), TaskActor.Owner, root.Id));
    Assert.Throws<ArgumentException>(() => f.Tasks.Create(new("Wrong goal", ProjectId: "other", GoalId: root.Id), TaskActor.Owner));
    var updated = f.Tasks.SaveGoal(new("Release updated", "", "sample", "achieved"), TaskActor.Owner, root.Id, root.Revision);
    Assert.Throws<InvalidOperationException>(() => f.Tasks.SaveGoal(new("Stale", "", "sample"), TaskActor.Owner, root.Id, root.Revision));
    Assert.Equal(updated.Title, f.Tasks.Goals().Single(g => g.Id == root.Id).Title);
  }
  [Fact] public void FailedGoalRemovalLeavesEveryLinkedObjectUntouched()
  {
    var f = new TaskFixture(); var goal = f.Tasks.SaveGoal(new("Release", "", "sample"), TaskActor.Owner);
    var task = f.Tasks.Create(new("Work", ProjectId: "sample", GoalId: goal.Id), TaskActor.Owner); f.Persistence.Fail = true;
    Assert.Throws<IOException>(() => f.Tasks.DeleteGoal(goal.Id, TaskActor.Owner));
    Assert.Equal(goal.Id, Assert.Single(f.Tasks.Goals()).Id); Assert.Equal(goal.Id, f.Tasks.Get(task.Id).GoalId);
  }
  [Fact] public void LegacyTaskLedgerMigratesWithoutLosingTasks()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Persistence.State = f.Persistence.State! with { Version = 1, Goals = default, Views = default };
    var reopened = f.Open(); Assert.Equal(task.Id, Assert.Single(reopened.List()).Id);
    reopened.SaveGoal(new("Outcome", "", "sample"), TaskActor.Owner);
    Assert.Equal(4, f.Persistence.State!.Version); Assert.Equal(task.Id, f.Open().Get(task.Id).Id);
  }
}
