using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Hoot;

public sealed record HootRoutineRun(string Id, DateTimeOffset At, string State, string Cause, string? Problem = null, string? SessionId = null);
public sealed record HootRoutine(string Id, string Name, string Purpose, string Folder, int EveryMinutes, string Text, bool Enabled = false,
  DateTimeOffset? NextAt = null, DateTimeOffset? LastAt = null, string? LastOutcome = null, string? Problem = null)
{
  public string[] Triggers { get; init; } = [];
  public string AgentId { get; init; } = "@hoot";
  public string Overlap { get; init; } = "queue";
  public string CatchUp { get; init; } = "once";
  public int MaxPending { get; init; } = 10;
  public int MaxCatchUp { get; init; } = 5;
  public int MaxRunsPerHour { get; init; } = 6;
  public int MaxRunsPerDay { get; init; } = 24;
  public int QuietSeconds { get; init; } = 30;
  public int? ExpectEverySeconds { get; init; }
  public DateTimeOffset? EnabledAt { get; init; }
  public HootRoutineRun[] Runs { get; init; } = [];
  public bool RecoveryHold { get; init; }
  // Supplied to the owning dispatcher, never accepted from a remote request.
  public string? ExecutionId { get; init; }
}
public sealed record HootRoutineState(HootRoutine[] Routines);

// One persisted state machine backs every trigger and management surface. A
// crash leaves an in-flight paid turn uncertain; it is never replayed as a new
// send. Catch-up concerns only scheduled occurrences which were never sent.
public sealed partial class HootRoutines : IDisposable
{
  private readonly IStateStore<HootRoutineState> store;
  private readonly Func<HootRoutine, CancellationToken, ValueTask> dispatch;
  private readonly TimeProvider clock;
  private readonly object gate = new();
  private readonly CancellationTokenSource lifetime = new();
  private readonly ITimer timer;
  private HootRoutineState state;
  private readonly Dictionary<string, CancellationTokenSource> active = [];
  private bool ticking;
  public event Action? Changed;
  public HootRoutines(IStateStore<HootRoutineState> store, Func<HootRoutine, CancellationToken, ValueTask> dispatch, TimeProvider? clock = null)
  {
    this.store = store; this.dispatch = dispatch; this.clock = clock ?? TimeProvider.System;
    var saved = store.Load() ?? new([]);
    saved = new(saved.Routines.Select(DocumentOptions).Select(r => r with { EnabledAt = r.Enabled ? r.EnabledAt ?? this.clock.GetUtcNow() : null,
      NextAt = !r.Enabled || r.Triggers.Length > 0 && !r.Triggers.Any(t => t.StartsWith("schedule ", StringComparison.Ordinal)) ? null : r.NextAt ?? NextDue(r, this.clock.GetUtcNow()) }).ToArray());
    foreach (var routine in saved.Routines) Validate(routine);
    state = new(saved.Routines.Select(r => r with
    {
      RecoveryHold = r.RecoveryHold || r.Runs.Any(run => run.State == "running"),
      Runs = r.Runs.Select(run => run.State == "running" ? run with { State = "uncertain", Problem = "Delivery was interrupted. It was not sent again." } : run).ToArray()
    }).ToArray());
    if (state.Routines.Any(r => r.RecoveryHold)) store.Save(state);
    timer = this.clock.CreateTimer(_ => _ = TickAsync(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    RebuildWatchers(); Schedule();
  }
  public IReadOnlyList<HootRoutine> List() { lock (gate) return state.Routines.ToArray(); }
  public void Save(HootRoutine value)
  {
    value = DocumentOptions(value); Validate(value);
    lock (gate)
    {
      var prior = state.Routines.FirstOrDefault(r => r.Id == value.Id);
      var next = value with { ExecutionId = null, NextAt = value.Enabled ? prior?.NextAt ?? NextDue(value, clock.GetUtcNow()) : null,
        Runs = prior?.Runs ?? value.Runs, RecoveryHold = prior?.RecoveryHold ?? value.RecoveryHold, EnabledAt = value.Enabled ? prior?.EnabledAt ?? clock.GetUtcNow() : null };
      if (!next.Enabled)
      {
        if (active.TryGetValue(next.Id, out var running)) running.Cancel();
        next = next with { Runs = next.Runs.Select(r => r.State == "queued" ? r with { State = "stopped", Problem = "Routine disabled." } : r).ToArray() };
      }
      Commit(new(state.Routines.Where(r => r.Id != value.Id).Append(next).ToArray())); RebuildWatchers(); Schedule();
    }
  }
  public void BindSession(string routineId, string executionId, string sessionId)
  { lock (gate) if (state.Routines.Any(r => r.Id == routineId)) Update(routineId, r => r with { Runs = r.Runs.Select(run => run.Id == executionId ? run with { SessionId = sessionId } : run).ToArray() }); }
  public void Remove(string id)
  {
    lock (gate) { if (active.TryGetValue(id, out var running)) running.Cancel(); Commit(new(state.Routines.Where(r => r.Id != id).ToArray())); RebuildWatchers(); Schedule(); }
  }
  private static void Validate(HootRoutine r)
  {
    if (!Guid.TryParse(r.Id, out _) || string.IsNullOrWhiteSpace(r.Name) || r.Name.Length > 120 || r.Text.Length is < 1 or > 24000 ||
      r.EveryMinutes is < 1 or > 525600 || r.MaxRunsPerHour is < 1 or > 1000 || r.MaxRunsPerDay is < 1 or > 10000 || r.QuietSeconds is < 0 or > 86400 || !Path.IsPathFullyQualified(r.Folder) ||
      r.MaxPending is < 1 or > 100 || r.MaxCatchUp is < 1 or > 50 || r.Overlap is not ("queue" or "merge" or "queue-all" or "skip" or "cancel") || r.CatchUp is not ("skip" or "once" or "replay") ||
      r.AgentId != "@hoot" && !System.Text.RegularExpressions.Regex.IsMatch(r.AgentId, "^[a-z][a-z0-9-]{0,39}$")) throw new ArgumentException("Choose a routine name, owner, folder, policy and instruction.");
    foreach (var trigger in r.Triggers.Length == 0 ? DocumentTriggers(r.Text) : r.Triggers) ValidateTrigger(trigger);
  }
  private void Commit(HootRoutineState next) { store.Save(next); state = next; Changed?.Invoke(); }
  private void Update(string id, Func<HootRoutine, HootRoutine> update) => Commit(new(state.Routines.Select(r => r.Id == id ? update(r) : r).ToArray()));
  private void Schedule()
  {
    if (lifetime.IsCancellationRequested) return;
    var now = clock.GetUtcNow();
    var next = state.Routines.Where(r => r.Enabled && !r.RecoveryHold && r.NextAt is not null).MinBy(r => r.NextAt)?.NextAt;
    var idle = IdleNext(); if (idle is not null && (next is null || idle < next)) next = idle;
    foreach (var routine in state.Routines.Where(r => r.Enabled && r.ExpectEverySeconds is not null && r.Problem is null))
      if ((routine.LastAt ?? routine.EnabledAt) is { } observed)
      { var expected = observed.AddSeconds(routine.ExpectEverySeconds!.Value); if (next is null || expected < next) next = expected; }
    foreach (var routine in state.Routines.Where(r => r.Enabled && !r.RecoveryHold && !active.ContainsKey(r.Id)))
      if (routine.Runs.FirstOrDefault(run => run.State == "queued") is { } queued)
      { var ready = ReadyAt(routine, queued); if (next is null || ready < next) next = ready; }
    timer.Change(next is { } at ? TimeSpan.FromMilliseconds(Math.Max(1, (at - now).TotalMilliseconds)) : Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
  }
  private DateTimeOffset ReadyAt(HootRoutine routine, HootRoutineRun run)
  {
    var due = run.Cause == "manual" ? run.At : run.At.AddSeconds(routine.QuietSeconds);
    var history = routine.Runs.Where(r => r.State is "running" or "finished" or "failed" or "stopped" or "uncertain").OrderBy(r => r.At).ToArray();
    var hour = history.Where(r => clock.GetUtcNow() - r.At < TimeSpan.FromHours(1)).ToArray();
    var day = history.Where(r => clock.GetUtcNow() - r.At < TimeSpan.FromDays(1)).ToArray();
    if (hour.Length >= routine.MaxRunsPerHour && hour[^routine.MaxRunsPerHour].At.AddHours(1) > due) due = hour[^routine.MaxRunsPerHour].At.AddHours(1);
    if (day.Length >= routine.MaxRunsPerDay && day[^routine.MaxRunsPerDay].At.AddDays(1) > due) due = day[^routine.MaxRunsPerDay].At.AddDays(1);
    return due;
  }
  public ValueTask CheckDueAsync(CancellationToken ct = default) { ct.ThrowIfCancellationRequested(); return new(TickAsync()); }
  private async Task TickAsync()
  {
    lock (gate) { if (ticking || lifetime.IsCancellationRequested) return; ticking = true; }
    var storageFailed = false;
    try
    {
      lock (gate)
      {
        var now = clock.GetUtcNow();
        foreach (var routine in state.Routines.Where(r => r.Enabled && r.ExpectEverySeconds is not null && r.Problem is null).ToArray())
          if ((routine.LastAt ?? routine.EnabledAt) is { } observed && observed.AddSeconds(routine.ExpectEverySeconds!.Value) <= now)
            Update(routine.Id, r => r with { Problem = "The expected routine run is overdue." });
        foreach (var routine in state.Routines.Where(r => r.Enabled && !r.RecoveryHold && r.NextAt <= now).ToArray())
        {
          var due = routine.NextAt!.Value; var count = 0;
          while (due <= now && count < 10000)
          {
            if (routine.CatchUp != "skip" && (routine.CatchUp == "once" ? count == 0 : count < routine.MaxCatchUp)) QueueLocked(routine.Id, count == 0 && now - due < TimeSpan.FromSeconds(2) ? "schedule" : "catch-up", due);
            else if (now - due < TimeSpan.FromSeconds(2)) QueueLocked(routine.Id, "schedule", due);
            var next = NextDue(routine, due); if (next is null) break; due = next.Value; count++;
          }
          Update(routine.Id, r => r with { NextAt = due > now ? due : NextDue(r, now) });
        }
      }
      await DispatchIdleAsync(lifetime.Token);
      KickReady();
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ObjectDisposedException) { storageFailed = true; }
    finally { lock (gate) { ticking = false; if (!lifetime.IsCancellationRequested) { if (storageFailed) timer.Change(TimeSpan.FromMinutes(1), Timeout.InfiniteTimeSpan); else Schedule(); } } }
  }
  private void QueueLocked(string id, string cause, DateTimeOffset at)
  {
    var routine = state.Routines.Single(r => r.Id == id); var queued = routine.Runs.Where(r => r.State == "queued").ToArray(); var busy = active.ContainsKey(id) || queued.Length > 0;
    var replay = cause == "catch-up" && routine.CatchUp == "replay";
    if (!replay && busy && routine.Overlap == "skip") return;
    if (!replay && busy && routine.Overlap == "cancel")
    {
      if (active.TryGetValue(id, out var running)) running.Cancel();
      routine = routine with { Runs = routine.Runs.Select(r => r.State == "queued" ? r with { State = "stopped", Problem = "Replaced by a newer trigger." } : r).ToArray() }; queued = [];
    }
    if (!replay && queued.Length > 0 && (routine.Overlap is "queue" or "merge"))
    {
      if (routine.Overlap == "merge")
      {
        var keep = queued[0]; var merged = keep.Cause + " · " + cause;
        Update(id, r => r with { Runs = r.Runs.Select(run => run.Id == keep.Id ? run with { Cause = merged[..Math.Min(1000, merged.Length)] } : run).ToArray() });
      }
      return;
    }
    if (queued.Length >= routine.MaxPending) { Update(id, r => r with { Problem = "The pending trigger limit was reached." }); return; }
    var run = new HootRoutineRun(Guid.NewGuid().ToString(), at, "queued", cause);
    var retained = routine.Runs.Where(r => r.State is "queued" or "running" or "uncertain").Concat(routine.Runs.Where(r => r.State is not ("queued" or "running" or "uncertain")).TakeLast(200)).ToArray();
    Update(id, r => routine with { Runs = [.. retained, run], LastOutcome = null, Problem = "Waiting to run." });
  }
  private void KickReady()
  {
    List<(HootRoutine Routine, HootRoutineRun Run, CancellationTokenSource Stop)> starts = [];
    lock (gate)
      foreach (var routine in state.Routines.Where(r => r.Enabled && !r.RecoveryHold && !active.ContainsKey(r.Id)).ToArray())
        if (routine.Runs.FirstOrDefault(r => r.State == "queued") is { } run && ReadyAt(routine, run) <= clock.GetUtcNow())
        {
          var stop = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); active[routine.Id] = stop;
          Update(routine.Id, r => r with { LastAt = clock.GetUtcNow(), Problem = null, Runs = r.Runs.Select(saved => saved.Id == run.Id ? saved with { State = "running", At = clock.GetUtcNow() } : saved).ToArray() });
          starts.Add((routine with { ExecutionId = run.Id }, run, stop));
        }
    foreach (var start in starts) _ = ExecuteAsync(start.Routine, start.Run, start.Stop);
  }
  private async Task ExecuteAsync(HootRoutine routine, HootRoutineRun run, CancellationTokenSource stop)
  {
    string outcome = "finished"; string? error = null;
    try { await dispatch(routine, stop.Token); }
    catch (OperationCanceledException) when (stop.IsCancellationRequested) { outcome = "stopped"; error = "Routine cancelled."; }
    catch (Exception e) { outcome = "failed"; error = e.Message; }
    finally
    {
      lock (gate)
      {
        active.Remove(routine.Id); stop.Dispose();
        if (state.Routines.Any(r => r.Id == routine.Id)) Update(routine.Id, r => r with { LastOutcome = outcome == "finished" ? "ok" : "failed", Problem = error,
          Runs = r.Runs.Select(saved => saved.Id == run.Id ? saved with { State = outcome, Problem = error } : saved).ToArray() });
        Schedule();
      }
      if (!lifetime.IsCancellationRequested) KickReady();
    }
  }
  public void Dispose() { lifetime.Cancel(); timer.Dispose(); foreach (var watcher in watchers) watcher.Dispose(); foreach (var wait in fileDebounce.Values) wait.Cancel(); }
}
