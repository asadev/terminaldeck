using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Storage;
namespace TerminalDeck.Core.Tests;
public sealed class HootRoutinePoliciesTests
{
  private sealed class Store : IStateStore<HootRoutineState> { public HootRoutineState? State; public HootRoutineState? Load() => State; public void Save(HootRoutineState next) => State = next; }
  private sealed class Clock : TimeProvider
  {
    public DateTimeOffset Now = DateTimeOffset.Parse("2026-11-01T12:00:00Z"); public override DateTimeOffset GetUtcNow() => Now;
    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) => new Timer();
    private sealed class Timer : ITimer { public bool Change(TimeSpan dueTime, TimeSpan period) => true; public void Dispose() { } public ValueTask DisposeAsync() => ValueTask.CompletedTask; }
  }
  private static HootRoutine Routine(string policy) => new(Guid.NewGuid().ToString(), "Synthetic routine", "", Path.GetTempPath(), 60, "No paid AI is connected.", true)
    { Triggers = ["manual"], QuietSeconds = 0, Overlap = policy };
  [Theory] [InlineData("queue", 1)] [InlineData("merge", 1)] [InlineData("queue-all", 3)] [InlineData("skip", 0)]
  public async Task OverlapPoliciesPersistExactlyTheExpectedPendingRuns(string policy, int expected)
  {
    var calls = 0; var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var clock = new Clock(); var store = new Store();
    using var owner = new HootRoutines(store, async (_, ct) => { calls++; await finish.Task.WaitAsync(ct); }, clock);
    var routine = Routine(policy); owner.Save(routine); await owner.RunAsync(routine.Id); Assert.Equal(1, calls);
    for (var i = 0; i < 3; i++) await owner.RunAsync(routine.Id);
    Assert.Equal(expected, Assert.Single(owner.List()).Runs.Count(r => r.State == "queued"));
    Assert.Single(Assert.Single(owner.List()).Runs, r => r.State == "running");
    finish.TrySetResult();
  }
  [Fact] public async Task CancelPolicyCancelsOnlyPriorOwnedRunAndStartsTheReplacement()
  {
    var tokens = new List<CancellationToken>(); var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    using var owner = new HootRoutines(new Store(), async (_, ct) => { lock (tokens) { tokens.Add(ct); if (tokens.Count == 2) started.TrySetResult(); } await Task.Delay(Timeout.Infinite, ct); }, new Clock());
    var routine = Routine("cancel"); owner.Save(routine); await owner.RunAsync(routine.Id); await owner.RunAsync(routine.Id);
    await started.Task.WaitAsync(TimeSpan.FromSeconds(3)); Assert.True(tokens[0].IsCancellationRequested); Assert.False(tokens[1].IsCancellationRequested);
  }
  [Theory] [InlineData("skip", 0)] [InlineData("once", 1)] [InlineData("replay", 3)]
  public async Task CatchUpPoliciesUsePersistedUnsentOccurrencesAndDoNotReplayInflightWork(string policy, int expected)
  {
    var clock = new Clock(); var store = new Store(); var calls = 0; var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var routine = Routine("queue") with { Triggers = ["schedule every 5m"], CatchUp = policy, MaxCatchUp = 3, NextAt = clock.Now.AddMinutes(-26) };
    store.State = new([routine]);
    using var owner = new HootRoutines(store, async (_, ct) => { calls++; await gate.Task.WaitAsync(ct); }, clock);
    await owner.CheckDueAsync(); var saved = Assert.Single(owner.List()); Assert.True(saved.NextAt > clock.Now);
    Assert.Equal(expected, saved.Runs.Count(r => r.State is "queued" or "running")); Assert.Equal(expected == 0 ? 0 : 1, calls);
    gate.TrySetResult();
  }
  [Fact] public async Task RecoveryHoldsUncertainPaidRunUntilExplicitManualDecisionAndPreservesAgentAndPolicies()
  {
    var clock = new Clock(); var store = new Store(); var calls = 0;
    var routine = Routine("queue-all") with { Runs = [new(Guid.NewGuid().ToString(), clock.Now.AddMinutes(-1), "running", "manual")] };
    store.State = new([routine]);
    using var owner = new HootRoutines(store, (_, _) => { calls++; return ValueTask.CompletedTask; }, clock);
    Assert.True(Assert.Single(owner.List()).RecoveryHold); Assert.Equal("uncertain", Assert.Single(Assert.Single(owner.List()).Runs).State);
    await owner.CheckDueAsync(); Assert.Equal(0, calls); await owner.RunAsync(routine.Id); Assert.Equal(1, calls);
    var source = "# Agent check\nagent-id: critic\nwhen: manual\noverlap: merge\ncatch-up: replay\nmax-pending: 4\nmax-catch-up: 2\nquiet-for: 10s\n---\nInspect only the fake data.";
    owner.Save(new(Guid.NewGuid().ToString(), "Agent", "", Path.GetTempPath(), 60, source));
    var agent = owner.List().Single(r => r.Name == "Agent"); Assert.Equal("critic", agent.AgentId); Assert.Equal("merge", agent.Overlap); Assert.Equal("replay", agent.CatchUp); Assert.Equal(4, agent.MaxPending); Assert.False(agent.Enabled);
  }
}
