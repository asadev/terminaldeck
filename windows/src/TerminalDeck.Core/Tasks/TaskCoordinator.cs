using System.Threading.Channels;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;

namespace TerminalDeck.Core.Tasks;

public interface ITaskRunSessions
{
  // Watching only attaches to the saved identity. It must never create/resume
  // a task run or replay its brief when a connection or keeper is replaced.
  IAsyncEnumerable<TaskSessionSignal> WatchAsync(string sessionId, CancellationToken ct);
}

// One keeper-owned coordinator, independent of any window. Explicit task
// assignment remains in the attended UI/MCP path with its current authority.
public sealed class TaskCoordinator(TaskService tasks, ITaskRunSessions sessions, IHoot hoot, TimeProvider? clock = null)
{
  private readonly Channel<bool> wake = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
  { FullMode = BoundedChannelFullMode.DropWrite, SingleReader = true });
  private int running;
  public event Action<string>? Failed;
  public void Refresh() => wake.Writer.TryWrite(true);
  public async Task RunAsync(CancellationToken ct)
  {
    if (Interlocked.Exchange(ref running, 1) != 0) throw new InvalidOperationException("Task coordination is already running.");
    using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
    var watches = new Dictionary<string, Task>();
    using var hooks = new TaskRunnerHooks(tasks, clock);
    var results = new W9TaskRunner(new ObserverOnlyRunner(), hoot, lifetime.Token);
    hooks.Failed += Report; results.Failed += Report;
    void HootChanged(HootState _) => Refresh();
    tasks.Changed += Refresh; hoot.Changed += HootChanged;
    try
    {
      Refresh();
      await foreach (var _ in wake.Reader.ReadAllAsync(lifetime.Token))
      {
        foreach (var run in tasks.Runs().Where(r => r.SessionId is { } id && W9TaskRunner.IsHootRun(id) &&
          r.State is TaskRunState.Starting or TaskRunState.Uncertain))
          if (hoot.Read().Turns.Any(t => t.Id == run.Id && t.State is HootTurnState.Queued or HootTurnState.Dispatching or HootTurnState.Running))
            tasks.ObserveSession(run.SessionId!, false, false);
        await results.ReconcileAsync(tasks, lifetime.Token);
        foreach (var id in tasks.Runs().Where(r => r.State is not (TaskRunState.Ended or TaskRunState.Yielded))
          .Select(r => r.SessionId).OfType<string>().Where(id => !W9TaskRunner.IsHootRun(id)).Distinct())
          if (!watches.TryGetValue(id, out var previous) || previous.IsCompleted) watches[id] = FollowAsync(id, hooks, lifetime.Token);
        // A crash before a prepared session was saved has no positive proof of
        // non-start. Leave its folder held; never start a replacement here.
      }
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    finally
    {
      tasks.Changed -= Refresh; hoot.Changed -= HootChanged; lifetime.Cancel();
      await Task.WhenAll(watches.Values);
      await results.FinishPendingWritesAsync();
      hooks.Failed -= Report; results.Failed -= Report;
      Volatile.Write(ref running, 0);
    }
  }
  private void Report(string message) => Failed?.Invoke(message);
  private async Task FollowAsync(string id, TaskRunnerHooks hooks, CancellationToken ct)
  {
    try
    {
      TaskSessionSignal? last = null;
      await foreach (var signal in sessions.WatchAsync(id, ct))
      {
        if (last != signal) { last = signal; hooks.Observe(id, signal); }
        if (signal == TaskSessionSignal.Ended) return;
      }
      if (!ct.IsCancellationRequested)
      {
        tasks.SessionDisconnected(id);
        Report("A task's session disconnected. Its folder stays reserved until its state is known.");
      }
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      try { tasks.SessionDisconnected(id); }
      catch (Exception failure) when (failure is not OutOfMemoryException) { }
      Report("A task's session needs to reconnect. Check its saved session before starting another run.");
    }
  }
  private sealed class ObserverOnlyRunner : ITaskRunner
  {
    public bool CanStart(string mode) => false;
    public ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken ct) =>
      ValueTask.FromException<string>(new InvalidOperationException("Start tasks through their attended assignment action."));
    public ValueTask NotifyAsync(string id, string text, CancellationToken ct) =>
      ValueTask.FromException(new InvalidOperationException("Task mentions need their original live caller permission."));
  }
}
