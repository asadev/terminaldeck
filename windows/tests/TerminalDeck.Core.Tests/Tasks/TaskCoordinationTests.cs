using System.Collections.Immutable;
using System.Runtime.CompilerServices;
using System.Threading.Channels;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Keeper;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskCoordinationTests
{
  [Fact]
  public async Task SeparateStoresPreserveEditsAndRefuseADoubleStartWhileLaunchIsAwaiting()
  {
    var folder = Path.Combine(Path.GetTempPath(), "td-v3a-tasks-" + Guid.NewGuid().ToString("N"));
    var root = AppDataRoot.Explicit(folder); var f = new TaskFixture();
    TaskService Open() => new(TaskStore.At(root), f.Projects, id => f.People.GetValueOrDefault(id), f.Runner, f.Files, recoverStarts: false);
    try
    {
      var first = Open(); var second = Open();
      var a = first.Create(new("First shared task", ProjectId: "sample"), TaskActor.Owner);
      var b = second.Create(new("Second shared task", ProjectId: "sample"), TaskActor.Owner);
      Assert.Equal(2, first.List().Count); f.Runner.Hold = new();
      var launching = first.AssignAsync(a.Id, "reviewer", TaskActor.Owner).AsTask(); await f.Runner.Prepared.Task;
      await Assert.ThrowsAsync<InvalidOperationException>(async () => await second.AssignAsync(b.Id, "reviewer", TaskActor.Owner));
      await second.CommentAsync(a.Id, "An edit from the other window.", TaskActor.Owner);
      f.Runner.Hold.SetResult(); await launching;
      Assert.Equal(1, f.Runner.Starts); Assert.Single(first.Runs());
      Assert.Equal("An edit from the other window.", Assert.Single(first.Get(a.Id).Comments).Text);
      first.ObserveSession("session-1", true, false);
      Assert.Equal(TaskRunState.Ended, Assert.Single(second.Runs()).State);
    }
    finally { Directory.Delete(folder, true); }
  }

  [Fact(Timeout = 10000)]
  public async Task RestartAdoptsTheSameSavedRunAndPostsStatusWithoutStartingAgain()
  {
    var f = new TaskFixture(); var task = f.Create(); await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner);
    var original = Assert.Single(f.Tasks.Runs());
    var reopened = f.Open(); Assert.Equal(TaskRunState.Uncertain, Assert.Single(reopened.Runs()).State);
    var source = new Sessions(); var hoot = new Hoot();
    using var stop = new CancellationTokenSource(); var coordinator = new TaskCoordinator(reopened, source, hoot);
    var working = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var ended = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    reopened.Changed += () =>
    {
      if (reopened.Runs()[0].State == TaskRunState.Working) working.TrySetResult();
      if (reopened.Runs()[0].State == TaskRunState.Ended) ended.TrySetResult();
    };
    var run = coordinator.RunAsync(stop.Token); Assert.Equal(original.SessionId, await source.Opened.Task);
    await source.Events.Writer.WriteAsync(TaskSessionSignal.Working); await working.Task;
    await source.Events.Writer.WriteAsync(TaskSessionSignal.Ended); await ended.Task;
    stop.Cancel(); await run;
    Assert.Equal(original.Id, Assert.Single(reopened.Runs()).Id); Assert.Equal(1, f.Runner.Starts);
    Assert.True(reopened.Get(task.Id).NeedsYou); Assert.Single(reopened.Get(task.Id).Activity, a => a.Text.Contains("session ended", StringComparison.Ordinal));
  }

  [Fact(Timeout = 10000)]
  public async Task KeeperRestartPostsAFinishedHootAnswerOnlyOnceWithoutReplayingItsTurn()
  {
    var f = new TaskFixture(); var task = f.Create(); var hoot = new Hoot();
    var id = Guid.NewGuid().ToString("N");
    f.Persistence.State = f.Persistence.State! with
    {
      Tasks = [task with { CurrentRunId = id, Status = "Working on it" }],
      Runs = [new(id, task.Id, "hoot", task.Folder, "chat", TaskRunState.Working, DateTimeOffset.UtcNow, "hoot-task:" + id)]
    };
    hoot.State = hoot.State with { Turns = [new(id, "brief", new("task", task.Id), HootTurnState.Finished, DateTimeOffset.UtcNow, Answer: "Saved answer. @reviewer is quoted content.")] };
    async Task FollowOnce()
    {
      var tasks = f.Open(); using var stop = new CancellationTokenSource();
      var coordinator = new TaskCoordinator(tasks, new Sessions(), hoot);
      var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      tasks.Changed += () => { if (tasks.Runs()[0].State == TaskRunState.Ended) completed.TrySetResult(); };
      var run = coordinator.RunAsync(stop.Token);
      if (tasks.Runs()[0].State == TaskRunState.Ended) completed.TrySetResult();
      await completed.Task; stop.Cancel(); await run;
    }
    await FollowOnce(); await FollowOnce();
    var restored = f.Open(); var answer = Assert.Single(restored.Get(task.Id).Comments);
    Assert.Contains("Saved answer.", answer.Text); Assert.Empty(restored.Mentions());
    Assert.Equal(0, hoot.Starts); Assert.Equal(TaskRunState.Ended, Assert.Single(restored.Runs()).State);
  }

  [Fact]
  public async Task CrashBeforePreparedIdentityNeverReleasesTheFolderOrStartsAReplacement()
  {
    var f = new TaskFixture(); var task = f.Create(); var id = Guid.NewGuid().ToString("N");
    f.Persistence.State = f.Persistence.State! with
    {
      Tasks = [task with { CurrentRunId = id }],
      Runs = [new(id, task.Id, "reviewer", task.Folder, "chat", TaskRunState.Starting, DateTimeOffset.UtcNow)]
    };
    var reopened = f.Open(); var saved = Assert.Single(reopened.Runs());
    Assert.Equal(TaskRunState.Uncertain, saved.State); Assert.Null(saved.SessionId);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await reopened.AssignAsync(task.Id, "reviewer", TaskActor.Owner));
    Assert.Equal(0, f.Runner.Starts); Assert.Single(reopened.Runs());
  }

  [Fact]
  public void LeaseRefusesASecondOwnerAndAllowsASuccessorAfterRelease()
  {
    var folder = Path.Combine(Path.GetTempPath(), "td-v3a-owner-" + Guid.NewGuid().ToString("N")); var root = AppDataRoot.Explicit(folder);
    try
    {
      using (var first = new TaskCoordinatorLease(root)) Assert.Throws<IOException>(() => new TaskCoordinatorLease(root));
      using var successor = new TaskCoordinatorLease(root);
    }
    finally { Directory.Delete(folder, true); }
  }

  [Fact(Timeout = 15000)]
  public async Task V3aConcurrentLedgerReadsDoNotInterruptAtomicWrites()
  {
    var folder = Path.Combine(Path.GetTempPath(), "td-v3a-read-write-" + Guid.NewGuid().ToString("N"));
    var root = AppDataRoot.Explicit(folder); var f = new TaskFixture();
    TaskService Open() => new(TaskStore.At(root), f.Projects, _ => null, recoverStarts: false);
    try
    {
      var writer = Open(); var reader = Open();
      var task = writer.Create(new("Concurrent saved task", ProjectId: "sample"), TaskActor.Owner);
      await Task.WhenAll(Task.Run(async () =>
      {
        for (var i = 0; i < 30; i++) await writer.CommentAsync(task.Id, "Saved comment " + i, TaskActor.Owner);
      }), Task.Run(() =>
      {
        for (var i = 0; i < 100; i++) Assert.Equal(task.Id, Assert.Single(reader.List()).Id);
      }));
      Assert.Equal(30, reader.Get(task.Id).Comments.Length);
    }
    finally { Directory.Delete(folder, true); }
  }

  private sealed class Sessions : ITaskRunSessions
  {
    public Channel<TaskSessionSignal> Events = Channel.CreateUnbounded<TaskSessionSignal>();
    public TaskCompletionSource<string> Opened = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async IAsyncEnumerable<TaskSessionSignal> WatchAsync(string id, [EnumeratorCancellation] CancellationToken ct)
    {
      Opened.TrySetResult(id);
      await foreach (var signal in Events.Reader.ReadAllAsync(ct)) yield return signal;
    }
  }
  private sealed class Hoot : IHoot
  {
    public HootState State = HootState.Empty;
    public int Starts;
    public event Action<HootState>? Changed { add { } remove { } }
    public HootState Read() => State;
    public ValueTask<string> BackgroundTurnAsync(string clientId, string reason, string sourceId, string title, string text, string? compactLine = null, CancellationToken cancellationToken = default)
    { Starts++; throw new InvalidOperationException("Recovery must never enqueue work."); }
    public ValueTask StartAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
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
