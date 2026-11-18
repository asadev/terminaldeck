namespace TerminalDeck.Core.Tasks;

public sealed record TaskFinishReceipt(bool Finished, string? ConversationId = null);

public sealed class TaskCompletion(TaskService tasks, Func<TaskRun, CancellationToken, ValueTask<TaskFinishReceipt>> finish)
{
  private readonly SemaphoreSlim gate = new(1, 1);
  public async Task ObserveAsync(string sessionId, TaskSessionSignal signal, CancellationToken ct)
  {
    if (signal is not (TaskSessionSignal.Idle or TaskSessionSignal.Ended)) return;
    await gate.WaitAsync(ct);
    try
    {
      var run = tasks.Runs().FirstOrDefault(r => r.SessionId == sessionId && r.State != TaskRunState.Ended);
      if (run is null || run.Efficiency?.Completion is not ("park" or "stop")) return;
      var task = tasks.Get(run.TaskId);
      if (task.CurrentRunId != run.Id || TaskExtras.Of(task).CompletionRequested != true) return;
      var receipt = await finish(run, ct);
      if (receipt.Finished) tasks.FinishRequested(run.Id, receipt);
    }
    finally { gate.Release(); }
  }
}

public sealed partial class TaskService
{
  public void FinishRequested(string runId, TaskFinishReceipt receipt)
  {
    if (!receipt.Finished) return;
    var changed = store.Change(state =>
    {
      var run = state.Runs.FirstOrDefault(r => r.Id == runId);
      var task = run is null ? null : state.Tasks.FirstOrDefault(t => t.Id == run.TaskId);
      if (run is null || task is null || task.CurrentRunId != run.Id || TaskExtras.Of(task).CompletionRequested != true) return (state, false);
      var parked = run.Efficiency?.Completion == "park" && receipt.ConversationId is { Length: > 0 };
      var updated = Stamp(task with { Status = "Done", NeedsYou = false, Extras = TaskExtras.Of(task) with { CompletionRequested = false } }, parked ? "Finished. Its conversation is parked for compatible work." : "Finished. Its session ended.", TaskActor.App, task);
      return (state with { Tasks = state.Tasks.Replace(task, updated), Runs = state.Runs.Replace(run, run with { State = TaskRunState.Ended, Parked = parked, ConversationId = parked ? receipt.ConversationId : null, CompletedAt = clock.GetUtcNow(), Problem = null }) }, true);
    });
    if (changed) Changed?.Invoke();
  }
}
