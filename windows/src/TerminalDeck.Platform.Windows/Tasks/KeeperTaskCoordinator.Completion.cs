using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Platform.Windows.Tasks;

public sealed partial class KeeperTaskCoordinator
{
  private TaskCompletion CreateTaskCompletion(TaskService tasks) => new(tasks, async (run, ct) =>
  {
    if (run.SessionId is not { } id) return new(false);
    string? conversation;
    if (run.Mode == "chat")
    {
      var chat = chats.List().FirstOrDefault(c => c.Definition.Id == id);
      if (chat is null || chat.Busy || chat.Stopping || chat.AccountRevision != 0 || chat.Definition.AccountId != run.AccountId
        || !SameBudgetFolder(chat.Definition.Cwd, run.ExecutionFolder ?? run.Folder)) return new(false);
      conversation = chat.ConversationId;
      if (!await chats.TryEndIdleAsync(chat, ct)) return new(false);
    }
    else
    {
      var session = sessions.List().FirstOrDefault(s => s.Definition.Id == id);
      if (session is null || session.AccountRevision != 0 || session.Definition.AccountId != run.AccountId
        || !SameBudgetFolder(session.Definition.Cwd, run.ExecutionFolder ?? run.Folder)) return new(false);
      conversation = session.Definition.ConversationId;
      if (!await sessions.TryStopIdleAsync(session, ct)) return new(false);
    }
    return new(true, run.Efficiency?.Completion == "park" ? conversation : null);
  });
  private static bool SameBudgetFolder(string first, string second) => Path.GetFullPath(first).Equals(Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase);
  private async Task ObserveCompletionAsync(TaskCompletion completion, string id, TaskSessionSignal signal, CancellationToken ct)
  {
    try { await completion.ObserveAsync(id, signal, ct); }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception error) when (error is not OutOfMemoryException) { Failed?.Invoke("This task could not finish closing its session. Its work and completion request were kept."); }
  }
  private async Task ObserveUsageAndCompletionAsync(TerminalDeck.Core.Tasks.TaskBudgetObserver budget, TaskCompletion completion, string id, CancellationToken ct)
  {
    await ObserveBudgetAsync(budget, id, ct);
    await CheckCurrentCompletionAsync(completion, id, ct);
  }
  private async Task FinishPendingTasksAsync(TaskService tasks, TaskCompletion completion, CancellationToken ct)
  {
    try
    {
      foreach (var run in tasks.Runs().Where(r => r.SessionId is not null && r.State != TaskRunState.Ended))
        if (TaskExtras.Of(tasks.Get(run.TaskId)).CompletionRequested) await CheckCurrentCompletionAsync(completion, run.SessionId!, ct);
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception error) when (error is not OutOfMemoryException) { Failed?.Invoke("The requested task completion is waiting for its saved state."); }
  }
  private async Task CheckCurrentCompletionAsync(TaskCompletion completion, string id, CancellationToken ct)
  {
    try
    {
      TaskSessionSignal signal;
      if (chats.List().FirstOrDefault(c => c.Definition.Id == id) is { } chat) signal = TerminalDeck.Core.Integration.W9TaskRunner.ChatSignal(chat);
      else if (sessions.List().FirstOrDefault(s => s.Definition.Id == id) is { } terminal)
        signal = terminal.State == SessionState.Exited ? TaskSessionSignal.Ended : await sessions.IsIdleAsync(id, ct) ? TaskSessionSignal.Idle : TaskSessionSignal.Working;
      else return;
      await ObserveCompletionAsync(completion, id, signal, ct);
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    catch (Exception error) when (error is not OutOfMemoryException) { Failed?.Invoke("This task's completion is waiting for its session state."); }
  }

}
