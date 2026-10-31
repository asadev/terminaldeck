using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class TaskRunnerHooksTests
{
  private sealed class Clock : TimeProvider
  {
    public List<Timer> Timers = [];
    public sealed class Timer(TimerCallback callback, object? state) : ITimer
    {
      public bool Disposed;
      public bool Change(TimeSpan dueTime, TimeSpan period) => !Disposed;
      public void Dispose() => Disposed = true;
      public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
      public void Fire() { if (!Disposed) callback(state); }
    }
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    { Assert.Equal(TimeSpan.FromMinutes(5), dueTime); var timer = new Timer(callback, state); Timers.Add(timer); return timer; }
  }
  [Fact] public async Task IdleTaskYieldsItsFolderOnceWithoutStoppingTheOpenSession()
  {
    var f = new TaskFixture(); var a = f.Create(); var b = f.Create("Another task");
    await f.Tasks.AssignAsync(a.Id, "reviewer", TaskActor.Owner);
    var clock = new Clock(); using var hooks = new TaskRunnerHooks(f.Tasks, clock);
    hooks.Observe("owner-session", TaskSessionSignal.Idle); Assert.Empty(clock.Timers);
    hooks.Observe("session-1", TaskSessionSignal.Idle); hooks.Observe("session-1", TaskSessionSignal.Idle);
    var timer = Assert.Single(clock.Timers); timer.Fire(); timer.Fire();
    var run = Assert.Single(f.Tasks.Runs()); Assert.Equal(TaskRunState.Yielded, run.State); Assert.Equal("session-1", run.SessionId);
    Assert.Equal("Stuck", f.Tasks.Get(a.Id).Status); Assert.Single(f.Tasks.Get(a.Id).Activity, e => e.Text.StartsWith("The agent was idle", StringComparison.Ordinal));
    await f.Tasks.AssignAsync(b.Id, "reviewer", TaskActor.Owner); Assert.Equal(2, f.Runner.Starts);
  }
  [Fact] public async Task WorkingEventCancelsIdleReleaseAndEndedEventDoesNotClaimSuccess()
  {
    var f = new TaskFixture(); var task = f.Create(); await f.Tasks.AssignAsync(task.Id, "reviewer", TaskActor.Owner);
    var clock = new Clock(); using var hooks = new TaskRunnerHooks(f.Tasks, clock);
    hooks.Observe("session-1", TaskSessionSignal.Idle); hooks.Observe("session-1", TaskSessionSignal.Working); clock.Timers[0].Fire();
    Assert.Equal(TaskRunState.Working, Assert.Single(f.Tasks.Runs()).State);
    hooks.Observe("session-1", TaskSessionSignal.Ended); Assert.Equal("Stuck", f.Tasks.Get(task.Id).Status);
    Assert.True(f.Tasks.Get(task.Id).NeedsYou);
  }
}
