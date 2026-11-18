using TerminalDeck.Core.Agents;

namespace TerminalDeck.Core.Tasks;

// Runs on the keeper's existing session/transcript events. It warns in the task, without interrupting a running turn.
public sealed class TaskBudgetObserver(TaskService tasks, AgentBudgetRuntime budgets, AgentBudgetLedger ledger,
  Func<IReadOnlyList<AgentRun>> agents, TimeProvider? time = null)
{
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  private readonly object gate = new();
  private readonly Dictionary<string, Task> reading = new(StringComparer.Ordinal);
  private readonly HashSet<string> again = new(StringComparer.Ordinal);
  public bool Watches(string sessionId) => agents().Any(r => r.SessionId == sessionId && (r.Efficiency?.HasBudget == true || r.Efficiency?.Completion is "park" or "stop"));
  public Task ObserveAsync(string sessionId, CancellationToken ct)
  {
    lock (gate)
    {
      if (reading.TryGetValue(sessionId, out var current)) { again.Add(sessionId); return current; }
      var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
      reading[sessionId] = done.Task;
      _ = ReadUntilSettledAsync(sessionId, ct, done);
      return done.Task;
    }
  }
  private async Task ReadUntilSettledAsync(string id, CancellationToken ct, TaskCompletionSource done)
  {
    try
    {
      while (true)
      {
        await ObserveOnceAsync(id, ct);
        lock (gate) { if (again.Remove(id)) continue; reading.Remove(id); break; }
      }
      done.TrySetResult();
    }
    catch (Exception error)
    {
      lock (gate) { reading.Remove(id); again.Remove(id); }
      done.TrySetException(error);
    }
  }
  private async Task ObserveOnceAsync(string sessionId, CancellationToken ct)
  {
      var run = agents().LastOrDefault(r => r.SessionId == sessionId);
      if (run?.Efficiency is not { HasBudget: true } policy || run.AgentId is not { } id || run.TaskRunId is not { } taskRun) return;
      var task = tasks.Runs().FirstOrDefault(r => r.Id == taskRun && r.SessionId == sessionId);
      if (task is null || task.State is TaskRunState.Ended or TaskRunState.Yielded) return;
      var totals = await budgets.ReadAsync(id, run.Api, ct);
      var monthly = AgentBudgetPolicy.Monthly(run.Efficiency, totals, run.Api);
      if (monthly.Warning is { } warning)
        tasks.BudgetNotice(taskRun, "monthly:" + clock.GetUtcNow().ToLocalTime().ToString("yyyy-MM") + (totals.UnknownSessions > 0 ? ":unknown" : ":warning"), warning);
      if (policy.TaskTokens is > 0 and var limit)
      {
        var used = await ledger.TaskTokensAsync(taskRun, ct);
        if (used is null) tasks.BudgetNotice(taskRun, "task:" + taskRun + ":unknown", "Token usage for this task is not known yet. Its token warning budget cannot be checked.");
        else if ((decimal)used * 100 >= (decimal)limit * policy.WarnAt) tasks.BudgetNotice(taskRun, "task:" + taskRun, $"This task has used {used:N0} of its {limit:N0}-token warning budget.");
      }
  }
}

public sealed partial class TaskService
{
  public void BudgetNotice(string runId, string key, string words)
  {
    var changed = store.Change(state =>
    {
      var run = state.Runs.FirstOrDefault(r => r.Id == runId);
      var task = run is null ? null : state.Tasks.FirstOrDefault(t => t.Id == run.TaskId);
      if (task is null || task.Activity.Any(a => a.Kind == "budget:" + key)) return (state, false);
      var next = task with { Revision = task.Revision + 1, UpdatedAt = clock.GetUtcNow(), Activity = task.Activity.Add(new(Guid.NewGuid().ToString("N"), words, TaskActor.App, clock.GetUtcNow(), "budget:" + key)) };
      return (state with { Tasks = state.Tasks.Replace(task, next) }, true);
    });
    if (changed) Changed?.Invoke();
  }
}
