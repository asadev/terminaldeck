using System.Collections.Immutable;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Tests.Tasks;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W9TaskRunnerTests
{
  private static ChatRecord Chat(bool busy = false, bool ended = false, string? problem = null, ChatEvent[]? events = null) =>
    new(1, new(Guid.NewGuid().ToString(), "codex", "C:/Scratch", "Task chat", "account", "home", new()), "worker", events ?? [], [], Busy: busy, Ended: ended, Problem: problem);
  [Fact] public void NotificationIdentityReusesOnlyTheSameSessionAndMessage()
  {
    var id = W9TaskRunner.NotificationClientId("a", "Comment one");
    Assert.True(Guid.TryParse(id, out _)); Assert.Equal(id, W9TaskRunner.NotificationClientId("a", "Comment one"));
    Assert.NotEqual(id, W9TaskRunner.NotificationClientId("b", "Comment one"));
    Assert.NotEqual(id, W9TaskRunner.NotificationClientId("a", "Comment two"));
  }
  [Fact] public void ChatWorkingIdleAndEndedComeFromSavedState()
  {
    Assert.Equal(TaskSessionSignal.Working, W9TaskRunner.ChatSignal(Chat(busy: true)));
    Assert.Equal(TaskSessionSignal.Idle, W9TaskRunner.ChatSignal(Chat()));
    Assert.Equal(TaskSessionSignal.Ended, W9TaskRunner.ChatSignal(Chat(busy: true, ended: true, problem: "Stopped")));
  }
  [Fact] public void OnlyUnansweredApprovalNeedsThePerson()
  {
    var chat = Chat(busy: true, events: [new(1, "approval", "request", "Allow?")]);
    Assert.Equal(TaskSessionSignal.NeedsYou, W9TaskRunner.ChatSignal(chat));
    Assert.Equal(TaskSessionSignal.Working, W9TaskRunner.ChatSignal(chat with { Events = [.. chat.Events, new(2, "approvalResolved", "request", "Allowed")] }));
    Assert.Equal(TaskSessionSignal.NeedsYou, W9TaskRunner.ChatSignal(Chat(problem: "Reconnect")));
  }
  [Theory]
  [InlineData("reset")]
  [InlineData("status")]
  [InlineData("exit")]
  public async Task TerminalStateChangesReleaseOnlyAConfirmedExitedSession(string kind)
  {
    var fixture = new TaskFixture(); var task = fixture.Create();
    await fixture.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner, "terminal");
    var row = new SessionRecord(new("session-1", "codex", task.Folder, "Task session"), "worker", SessionState.Held);
    Assert.True(W9TaskRunner.TerminalStatusEvent(kind));
    Assert.Null(W9TaskRunner.TerminalSignal(row));
    Assert.Equal(TaskRunState.Working, Assert.Single(fixture.Tasks.Runs()).State);
    var signal = W9TaskRunner.TerminalSignal(row with { State = SessionState.Exited });
    Assert.Equal(TaskSessionSignal.Ended, signal);
    using var hooks = new TaskRunnerHooks(fixture.Tasks); hooks.Observe("session-1", signal!.Value);
    Assert.Equal(TaskRunState.Ended, Assert.Single(fixture.Tasks.Runs()).State);
    Assert.NotEqual("Done", fixture.Tasks.Get(task.Id).Status);
    Assert.False(W9TaskRunner.TerminalStatusEvent("data"));
  }
  [Fact] public async Task AgentRunsKeepTheirExistingSessionAndRunner()
  {
    var fixture = new TaskFixture(); var hoot = new TestHoot("C:/Work/Sample");
    var runner = new W9TaskRunner(fixture.Runner, hoot, CancellationToken.None);
    var result = await runner.StartAsync(new(fixture.Create(), "run", "reviewer", "chat", "Brief"), (_, _) => ValueTask.CompletedTask, default);
    Assert.Equal("session-1", result); Assert.Equal(1, fixture.Runner.Starts); Assert.Empty(hoot.Read().Turns);
  }
  [Fact] public async Task HootResultsGoToTheirTaskOnceAndNeverClaimDone()
  {
    var (tasks, hoot, runner) = HootTasks(); var task = tasks.Create(new("Check files", ProjectId: "sample"), TaskActor.Owner);
    await tasks.AssignAsync(task.Id, "hoot", TaskActor.Owner);
    var run = Assert.Single(tasks.Runs()); Assert.Equal("hoot-task:" + run.Id, run.SessionId);
    hoot.Finish(HootTurnState.Finished, "Checked files; literal @unknown stays prose.");
    await runner.ReconcileAsync(tasks, default); await runner.ReconcileAsync(tasks, default);
    var saved = tasks.Get(task.Id); Assert.Equal("Stuck", saved.Status); Assert.True(saved.NeedsYou);
    var comment = Assert.Single(saved.Comments); Assert.Equal("hoot", comment.Author.Kind); Assert.Empty(comment.Mentions);
    Assert.Equal(TaskRunState.Ended, Assert.Single(tasks.Runs()).State);
  }
  [Fact] public async Task AnUncertainHootTurnKeepsItsFolderUntilARealFinish()
  {
    var (tasks, hoot, runner) = HootTasks(); var task = tasks.Create(new("Check files", ProjectId: "sample"), TaskActor.Owner);
    await tasks.AssignAsync(task.Id, "hoot", TaskActor.Owner);
    hoot.Finish(HootTurnState.Uncertain, ""); await runner.ReconcileAsync(tasks, default);
    Assert.Equal(TaskRunState.NeedsYou, Assert.Single(tasks.Runs()).State);
    var other = tasks.Create(new("Check more files", ProjectId: "sample"), TaskActor.Owner);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await tasks.AssignAsync(other.Id, "hoot", TaskActor.Owner));
    hoot.Finish(HootTurnState.Finished, "Finished after reconnect."); await runner.ReconcileAsync(tasks, default);
    Assert.Equal(TaskRunState.Ended, Assert.Single(tasks.Runs()).State);
  }
  [Fact] public async Task HootCannotExecuteInADifferentFolderThanTheTaskGrant()
  {
    var fixture = new TaskFixture(); var runner = new W9TaskRunner(fixture.Runner, new TestHoot("C:/Other"), default);
    var prepared = false;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await runner.StartAsync(new(fixture.Create(), Guid.NewGuid().ToString("N"), "hoot", "chat", "Brief"),
      (_, _) => { prepared = true; return ValueTask.CompletedTask; }, default));
    Assert.False(prepared);
  }
  [Fact] public async Task LostHootEnqueueReplyNeverReleasesAKnownRunningTurn()
  {
    var (tasks, hoot, runner) = HootTasks(); hoot.LoseReply = true;
    var task = tasks.Create(new("Check files", ProjectId: "sample"), TaskActor.Owner);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await tasks.AssignAsync(task.Id, "hoot", TaskActor.Owner));
    Assert.Equal(HootTurnState.Running, Assert.Single(hoot.Read().Turns).State);
    await runner.ReconcileAsync(tasks, default);
    Assert.Equal(TaskRunState.Uncertain, Assert.Single(tasks.Runs()).State);
    var other = tasks.Create(new("Check more files", ProjectId: "sample"), TaskActor.Owner);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await tasks.AssignAsync(other.Id, "hoot", TaskActor.Owner));
    Assert.Empty(tasks.Get(task.Id).Comments);
    hoot.Finish(HootTurnState.Finished, "Confirmed result after reconnect."); await runner.ReconcileAsync(tasks, default);
    Assert.Equal(TaskRunState.Ended, Assert.Single(tasks.Runs()).State);
    Assert.Contains("Confirmed result", Assert.Single(tasks.Get(task.Id).Comments).Text);
  }
  [Fact] public async Task FastHootFinishOverridesAnEarlierLostReplyPlaceholder()
  {
    var (tasks, hoot, runner) = HootTasks(); hoot.LoseReply = true;
    var task = tasks.Create(new("Check files", ProjectId: "sample"), TaskActor.Owner);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await tasks.AssignAsync(task.Id, "hoot", TaskActor.Owner));
    hoot.Finish(HootTurnState.Finished, "The actual saved answer.");
    await runner.ReconcileAsync(tasks, default);
    Assert.Contains("The actual saved answer.", Assert.Single(tasks.Get(task.Id).Comments).Text);
    Assert.Equal(TaskRunState.Ended, Assert.Single(tasks.Runs()).State);
  }
  private static (TaskService, TestHoot, W9TaskRunner) HootTasks()
  {
    var fixture = new TaskFixture(); var hoot = new TestHoot(fixture.Projects.Get("sample").HomeFolder!);
    var runner = new W9TaskRunner(fixture.Runner, hoot, default);
    var tasks = new TaskService(new TaskStore(fixture.Persistence), fixture.Projects,
      id => id == "hoot" ? new("hoot", "Hoot", "hoot", null) : null, runner, fixture.Files);
    return (tasks, hoot, runner);
  }
  private sealed class TestHoot(string folder) : IHoot
  {
    private HootState state = HootState.Empty with { Settings = new("codex", "account-one", folder, new()) };
    public bool LoseReply;
    public event Action<HootState>? Changed;
    public HootState Read() => state;
    public ValueTask<string> BackgroundTurnAsync(string clientId, string reason, string sourceId, string title, string text, string? compactLine = null, CancellationToken cancellationToken = default)
    {
      state = state with { Turns = [new(clientId, text, new(reason, sourceId, title), HootTurnState.Running, DateTimeOffset.UtcNow)] };
      if (LoseReply) return ValueTask.FromException<string>(new IOException("Synthetic lost enqueue reply."));
      Changed?.Invoke(state); return ValueTask.FromResult(clientId);
    }
    public void Finish(HootTurnState value, string answer)
    { state = state with { Turns = state.Turns.Select(t => t with { State = value, Answer = answer }).ToImmutableArray() }; Changed?.Invoke(state); }
    public ValueTask StartAsync(CancellationToken cancellationToken = default) => ValueTask.CompletedTask;
    public ValueTask ConfigureAsync(HootSettings settings, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask SayAsync(string clientId, string text, HootSource? source = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask CancelBackgroundAsync(string id, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask StopAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask AnswerAsync(string requestId, bool allow, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask RefreshAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask KeepUnconfirmedAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask ContinueAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask SaveMemoryAsync(string card, string playbook, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask SaveBoardAsync(HootBoardRow row, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<HootHandoff> HandoffAsync(string clientId, string sessionId, string text, CancellationToken cancellationToken = default) => throw new NotSupportedException();
  }
}
