using System.Collections.Immutable;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TasksTests
{
  [Fact] public void TasksFiltersCommentsAndTrashSurviveReopeningWithoutInventingCompletion()
  {
    var f = new TaskFixture(); var task = f.Create();
    f.Tasks.RememberFilter("mac-one", new("sample", Search: "Check", GroupBy: "status"));
    f.Tasks.RememberFilter("pc-two", new("other", Status: "Done"));
    f.Tasks.Status(task.Id, "Stuck", TaskActor.Owner);
    var open = f.Open(); Assert.True(open.Get(task.Id).NeedsYou); Assert.Equal("sample", open.Filter("mac-one").ProjectId);
    Assert.Equal("other", open.Filter("pc-two").ProjectId); Assert.Equal(new TaskFilter(), open.Filter("new-machine"));
    open.Delete(task.Id, TaskActor.Owner); Assert.Empty(open.List()); Assert.Single(open.List(new(Trash: true)));
    var restored = f.Open().Restore(task.Id, TaskActor.Owner); Assert.Null(restored.DeletedAt); Assert.Equal("Stuck", restored.Status);
  }
  [Fact] public void UpdatedFieldsProduceTheirOwnActivityCategories()
  {
    var f = new TaskFixture(); var task = f.Create();
    task = f.Tasks.Update(task.Id, TaskService.Draft(task) with { DueDate = "2026-11-01", Priority = "High", Title = "New title" }, TaskActor.Owner, task.Revision);
    Assert.Equal(new[] { "details", "dates", "priority" }, task.Activity.Skip(1).Select(TaskActivityKinds.Of));
    task = f.Tasks.Status(task.Id, "In Progress", TaskActor.Owner); Assert.Equal("status", TaskActivityKinds.Of(task.Activity.Last()));
    Assert.Equal("assignees", TaskActivityKinds.Of(new("old", "Given to Reviewer.", TaskActor.Owner, DateTimeOffset.UtcNow)));
  }
  [Fact] public async Task AutomaticRunStateChangesAppearInTheStatusActivityFilter()
  {
    var f = new TaskFixture(); var task = f.Create(); await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner);
    Assert.Contains(f.Tasks.Get(task.Id).Activity, a => TaskActivityKinds.Of(a) == "status" && a.Text.Contains("Working on it", StringComparison.Ordinal));
    f.Tasks.ObserveSession("session-1", false, true);
    Assert.Contains(f.Tasks.Get(task.Id).Activity, a => TaskActivityKinds.Of(a) == "status" && a.Text.Contains("Stuck", StringComparison.Ordinal));
  }
  [Fact] public void FailedPersistenceNeverChangesVisibleState()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Persistence.Fail = true;
    Assert.Throws<IOException>(() => f.Tasks.Status(task.Id, "Done", TaskActor.Owner));
    Assert.Equal(task, f.Tasks.Get(task.Id)); Assert.Equal(task, Assert.Single(f.Persistence.State!.Tasks));
  }
  [Theory]
  [InlineData("2026-02-29")]
  [InlineData("2026-13-01")]
  [InlineData("2026-1-01")]
  [InlineData("")]
  public void InvalidDatesAreRefusedBeforeSaving(string date)
  {
    var f = new TaskFixture(); Assert.Throws<ArgumentException>(() => f.Create(due: date)); Assert.Empty(f.Tasks.List());
  }
  [Fact] public void DatesFoldersStatusesAndRevisionsAreValidatedTogether()
  {
    var f = new TaskFixture(); var task = f.Create(due: "2026-10-30");
    Assert.Throws<ArgumentException>(() => f.Tasks.Create(new("Wrong folder", ProjectId: "sample", Folder: "C:/Work/Sample-other"), TaskActor.Owner));
    Assert.Throws<ArgumentException>(() => f.Tasks.Create(new("Wrong dates", StartDate: "2026-11-01", DueDate: "2026-10-01"), TaskActor.Owner));
    Assert.Throws<ArgumentException>(() => f.Tasks.Status(task.Id, "unknown", TaskActor.Owner));
    f.Tasks.Update(task.Id, TaskService.Draft(task) with { Details = "Changed" }, TaskActor.Owner, task.Revision);
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Update(task.Id, TaskService.Draft(task), TaskActor.Owner, task.Revision));
  }
  [Fact] public void FilterMatchesTasksRatherThanDisplayLabels()
  {
    var f = new TaskFixture(); var first = f.Create(); var second = f.Create("Second task");
    f.Tasks.Status(first.Id, "Stuck", TaskActor.Owner); f.Tasks.Status(second.Id, "Done", TaskActor.Owner);
    Assert.Equal(first.Id, Assert.Single(f.Tasks.List(new(Status: "needs-you"))).Id);
    Assert.Equal(second.Id, Assert.Single(f.Tasks.List(new(Status: "Done", Search: "second"))).Id);
    Assert.Equal(2, f.Tasks.List(new(Status: "all")).Count); Assert.Empty(f.Tasks.List(new(ProjectId: "other")));
  }
  [Fact] public async Task AnAgentGetsOneTaskSessionAndItsBriefIsInAFile()
  {
    var f = new TaskFixture(); var task = f.Create();
    task = f.Tasks.Update(task.Id, TaskService.Draft(task) with { Details = task.Details + new string('x', 1000) }, TaskActor.Owner);
    var result = await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner, "terminal");
    Assert.Equal("Working on it", result.Status); Assert.False(result.NeedsYou); Assert.Equal(1, f.Runner.Starts);
    var run = Assert.Single(f.Tasks.Runs()); Assert.Equal("terminal", run.Mode); Assert.Equal("session-1", run.SessionId);
    var launch = f.Runner.Launch!; Assert.True(launch.Brief.Length <= 600); Assert.Contains("Read the task brief at", launch.Brief);
    var brief = Assert.Single(f.Files.Text).Value;
    Assert.Equal(1, brief.Split("Task id:").Length - 1); Assert.Equal(1, brief.Split(task.Title).Length - 1);
    Assert.Contains("Project: Sample project", brief); Assert.Contains("> Read the supplied files", brief); Assert.Contains("task's comments", brief);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner));
    Assert.Equal(1, f.Runner.Starts);
  }
  [Fact] public async Task TwoTasksCannotReserveTheSameWindowsFolderDuringAnAwait()
  {
    var f = new TaskFixture(); var a = f.Create("First task"); var b = f.Create("Second task"); f.Runner.Hold = new();
    var start = f.Tasks.AssignAsync(a.Id, "reviewer", TaskActor.Owner).AsTask(); await f.Runner.Prepared.Task;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Tasks.AssignAsync(b.Id, "reviewer", TaskActor.Owner));
    Assert.Equal(1, f.Runner.Starts); f.Runner.Hold.SetResult(); await start;
    f.Tasks.ObserveSession("session-1", true, false); await f.Tasks.AssignAsync(b.Id, "reviewer", TaskActor.Owner);
    Assert.Equal(2, f.Runner.Starts);
  }
  [Fact] public async Task FailedStartReleasesReservationButUncertainStartHoldsItAcrossRestart()
  {
    var f = new TaskFixture(); var first = f.Create(); f.Runner.FailBefore = true;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Tasks.AssignAsync(first.Id, "reviewer", TaskActor.Owner));
    Assert.Equal(TaskRunState.Ended, Assert.Single(f.Tasks.Runs()).State); Assert.True(f.Tasks.Get(first.Id).NeedsYou);
    f.Runner.FailBefore = false; f.Runner.FailAfter = true;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Tasks.AssignAsync(first.Id, "reviewer", TaskActor.Owner));
    var open = f.Open(); Assert.Equal(TaskRunState.Uncertain, open.Runs().Last().State);
    var other = open.Create(new("Another task", ProjectId: "sample"), TaskActor.Owner);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await open.AssignAsync(other.Id, "reviewer", TaskActor.Owner));
    Assert.DoesNotContain("protected driver", open.Get(first.Id).Activity.Last().Text);
  }
  [Fact] public async Task LaunchRechecksPermissionBeforeAnySessionIsPrepared()
  {
    var f = new TaskFixture(); var task = f.Create(); var checks = 0;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner,
      authorizeStart: (_, _) => { checks++; throw new InvalidOperationException("Permission changed."); }));
    Assert.Equal(1, checks); Assert.Equal(TaskRunState.Ended, Assert.Single(f.Tasks.Runs()).State); Assert.Null(f.Tasks.Runs()[0].SessionId);
  }
  [Fact] public async Task RunningTaskCannotBeDeletedMovedReassignedOrSilentlyMarkedDone()
  {
    var f = new TaskFixture(); var task = f.Create(); await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner);
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Delete(task.Id, TaskActor.Owner));
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Archive(task.Id, true, TaskActor.Owner));
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Status(task.Id, "Done", TaskActor.Owner));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Tasks.AssignAsync(task.Id, "me", TaskActor.Owner));
    f.Tasks.ObserveSession("session-1", false, true); Assert.True(f.Tasks.Get(task.Id).NeedsYou);
    f.Tasks.ObserveSession("session-1", true, false); Assert.Equal("Stuck", f.Tasks.Get(task.Id).Status);
    f.Tasks.Status(task.Id, "Done", TaskActor.Owner); Assert.Equal("Done", f.Tasks.Get(task.Id).Status);
  }
  [Fact] public async Task CommentRepliesAndMentionsKeepRealAuthorsAndAnOutbox()
  {
    var f = new TaskFixture(); var task = f.Create(); f.Runner.FailNotify = true;
    var comment = await f.Tasks.CommentAsync(task.Id, "Please check @[reviewer] and @reviewer. Email x@example.com is just text.", TaskActor.Owner);
    Assert.Equal("me", comment.Author.Id); Assert.Equal("reviewer", Assert.Single(comment.Mentions));
    Assert.False(Assert.Single(f.Tasks.Mentions()).Delivered); Assert.Contains("could not be delivered", f.Tasks.Mentions()[0].Problem);
    f.Runner.FailNotify = false; await f.Tasks.DeliverMentionsAsync(task.Id); await f.Tasks.DeliverMentionsAsync(task.Id);
    Assert.True(Assert.Single(f.Tasks.Mentions()).Delivered); Assert.Equal("existing-session", Assert.Single(f.Runner.Notifications).Session);
    var reply = await f.Tasks.CommentAsync(task.Id, "Found the answer", new("reviewer", "Reviewer", "agent"), comment.Id);
    Assert.Equal(comment.Id, reply.ReplyTo); Assert.Equal("reviewer", reply.Author.Id);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Tasks.CommentAsync(task.Id, "reply", TaskActor.Owner, "not-on-this-task"));
  }
  [Fact] public async Task OfflineAndUnknownMentionsAreDifferentOutcomes()
  {
    var f = new TaskFixture(); var task = f.Create(); f.People["reviewer"] = f.People["reviewer"] with { SessionId = null };
    await f.Tasks.CommentAsync(task.Id, "@reviewer please read", TaskActor.Owner);
    Assert.Contains("Waiting", Assert.Single(f.Tasks.Mentions()).Problem); Assert.Empty(f.Runner.Notifications);
    await Assert.ThrowsAsync<ArgumentException>(async () => await f.Tasks.CommentAsync(task.Id, "@missing please read", TaskActor.Owner));
    Assert.Single(f.Tasks.Get(task.Id).Comments);
  }
  [Fact] public void BriefFilesStayInTheExplicitScratchRoot()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-tasks-" + Guid.NewGuid().ToString("N"));
    try
    {
      var root = AppDataRoot.Explicit(path); var files = new TaskBriefFiles(root);
      var saved = files.Save("../../escape", "../run", "Task details");
      Assert.StartsWith(path + Path.DirectorySeparatorChar, saved); Assert.Equal("Task details", File.ReadAllText(saved));
      var store = TaskStore.At(root); Assert.Empty(store.Read().Tasks);
    }
    finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
  }
  [Fact] public void ConnectedTaskLinkIsSavedAtomicallyAndDuplicateHandoffsDoNotLeaveExtraTasks()
  {
    var f = new TaskFixture(); var link = new ConnectedTaskLink("iloop", "remote-one");
    var task = f.Tasks.Create(new("Connected task", ProjectId: "sample"), TaskActor.Owner, link);
    Assert.Equal(link, task.Connected);
    Assert.Throws<InvalidOperationException>(() => f.Tasks.Create(new("Duplicate", ProjectId: "sample"), TaskActor.Owner, link));
    Assert.Single(f.Tasks.List());
  }
  [Fact] public void InvalidSavedVersionIsKeptAndNeverOverwritten()
  {
    var storage = new MemoryStore<TasksState> { State = new(88, [], [], [], ImmutableDictionary<string, TaskFilter>.Empty) };
    Assert.Throws<IOException>(() => new TaskStore(storage)); Assert.Equal(88, storage.State!.Version);
  }
}
