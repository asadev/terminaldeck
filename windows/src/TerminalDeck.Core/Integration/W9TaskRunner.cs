using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Integration;

// Hoot turns have their own ledger identity. They are never terminal sessions.
public sealed class W9TaskRunner(ITaskRunner agents, IHoot hoot, CancellationToken lifetime, bool coordinateResults = true) : ITaskRunner
{
  private readonly ConcurrentDictionary<string, HootTaskResult> finished = new();
  private readonly SemaphoreSlim completionGate = new(1);
  public event Action? Changed;
  public event Action<string>? Failed;
  public static bool IsHootRun(string id) => id.StartsWith("hoot-task:", StringComparison.Ordinal);
  public static string NotificationClientId(string sessionId, string text) =>
    new Guid(SHA256.HashData(Encoding.UTF8.GetBytes(sessionId + "\0" + text)).AsSpan(0, 16)).ToString();
  public static TaskSessionSignal ChatSignal(ChatRecord chat) => chat.Ended ? TaskSessionSignal.Ended
    : ChatProjection.Rows(chat).Any(r => r.Kind == "approval" && r.Waiting) || chat.Problem is not null ? TaskSessionSignal.NeedsYou
    : chat.Busy ? TaskSessionSignal.Working : TaskSessionSignal.Idle;
  public static TaskSessionSignal? TerminalSignal(SessionRecord session) => session.State switch
  {
    SessionState.Exited => TaskSessionSignal.Ended,
    SessionState.Running => TaskSessionSignal.Working,
    _ => null
  };
  public static bool TerminalStatusEvent(string kind) => kind is "reset" or "status" or "exit";
  public bool CanStart(string mode) => agents.CanStart(mode);
  public async ValueTask<string> StartAsync(TaskLaunch launch, Func<TaskPreparedSession, CancellationToken, ValueTask> prepared, CancellationToken ct)
  {
    if (launch.AgentId != "hoot") return await agents.StartAsync(launch, prepared, ct);
    if (TaskExtras.Of(launch.Task).OwnWorkspace) throw new InvalidOperationException("Hoot uses its configured workspace. Assign a saved agent to use an own workspace.");
    if (launch.Mode != "chat") throw new InvalidOperationException("Hoot works through its chat. Choose chat mode for this task.");
    var settings = hoot.Read().Settings ?? throw new InvalidOperationException("Choose Hoot's coding AI, account and folder first.");
    if (!ProjectPaths.Equal(settings.Folder, launch.Task.Folder))
      throw new InvalidOperationException("Choose Hoot's configured folder for this task, or assign an agent that can work in the task's folder.");
    var identity = "hoot-task:" + launch.RunId;
    await prepared(new(identity, launch.Task.ProjectId, launch.Task.Folder, settings.AccountId, "hoot"), ct);
    ct.ThrowIfCancellationRequested();
    if (hoot.Read().Settings != settings) throw new InvalidOperationException("Hoot's settings changed. Read the task and assign it again.");
    var accepted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    _ = RunHootAsync(launch, accepted);
    // This confirms the durable Hoot turn, not the result of the task.
    await accepted.Task.WaitAsync(ct);
    return identity;
  }
  private async Task RunHootAsync(TaskLaunch launch, TaskCompletionSource accepted)
  {
    try
    {
      var result = await HootTaskTurns.RunAsync(hoot, launch.RunId, launch.Task.Id,
        launch.Task.Title[..Math.Min(200, launch.Task.Title.Length)], launch.Brief,
        _ => accepted.TrySetResult(), CancellationToken.None, launch.AssignedBy);
      if (coordinateResults && !lifetime.IsCancellationRequested) finished[launch.RunId] = result;
      accepted.TrySetResult(); if (coordinateResults && !lifetime.IsCancellationRequested) Changed?.Invoke();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      accepted.TrySetException(new InvalidOperationException("Hoot's task turn could not be confirmed. Check Hoot before trying again."));
      if (coordinateResults && !lifetime.IsCancellationRequested)
      {
        finished[launch.RunId] = new(launch.RunId, "", false, "Hoot's task turn could not be confirmed. Check Hoot before trying again.");
        Changed?.Invoke();
      }
    }
  }
  public async ValueTask ReconcileAsync(TaskService tasks, CancellationToken ct)
  {
    await completionGate.WaitAsync(ct);
    try
    {
      foreach (var run in tasks.Runs().Where(r => r.SessionId is { } id && IsHootRun(id) && r.State is TaskRunState.Working or TaskRunState.Uncertain or TaskRunState.NeedsYou))
        if (hoot.Read().Turns.FirstOrDefault(t => t.Id == run.Id) is { } turn && turn.State is HootTurnState.Finished or HootTurnState.Failed or HootTurnState.Stopped or HootTurnState.Uncertain)
          finished.TryAdd(run.Id, new(turn.Id, turn.Answer, turn.State == HootTurnState.Finished, turn.Problem));
      foreach (var pair in finished.ToArray())
      {
        var run = tasks.Runs().FirstOrDefault(r => r.Id == pair.Key);
        if (run is null || run.State is TaskRunState.Ended or TaskRunState.Yielded) { finished.TryRemove(pair.Key, out _); continue; }
        // TaskService stamps Working only after its runner has returned.
        if (run.State is not (TaskRunState.Working or TaskRunState.Uncertain or TaskRunState.NeedsYou)) continue;
        var currentTurn = hoot.Read().Turns.FirstOrDefault(t => t.Id == run.Id);
        var turnState = currentTurn?.State ?? HootTurnState.Uncertain;
        // A failed enqueue reply can arrive after the keeper accepted the turn.
        // A live or queued turn is positive evidence that work is still held.
        if (turnState is HootTurnState.Queued or HootTurnState.Dispatching or HootTurnState.Running)
        {
          finished.TryRemove(pair.Key, out _);
          continue;
        }
        // The keeper's final turn can race an earlier lost-reply placeholder.
        var result = currentTurn is null ? pair.Value : new HootTaskResult(currentTurn.Id, currentTurn.Answer,
          currentTurn.State == HootTurnState.Finished, currentTurn.Problem);
        var marker = "Hoot task turn " + run.Id + " · " + turnState;
        var text = result.Answer.Length > 0 ? result.Answer : result.Problem ?? "Hoot's turn ended. Review it before closing the task.";
        // Provider prose is a result, not permission to send new agent mentions.
        text = text.Replace("@", "@\u200b", StringComparison.Ordinal);
        if (text.Length > 39000) text = text[..39000] + "\n\nThe rest of this answer is kept in Hoot's turn history.";
        text = marker + "\n\n" + text;
        try
        {
          // Persist the answer before releasing this task's folder.
          if (!tasks.Get(run.TaskId).Comments.Any(c => c.Author.Id == "hoot" && c.Text.StartsWith(marker + "\n", StringComparison.Ordinal)))
            await tasks.CommentAsync(run.TaskId, text, new("hoot", "Hoot", "hoot"), cancellationToken: ct);
          if (turnState == HootTurnState.Uncertain && run.State == TaskRunState.NeedsYou) { finished.TryRemove(pair.Key, out _); continue; }
          tasks.ObserveSession(run.SessionId!, turnState != HootTurnState.Uncertain, turnState == HootTurnState.Uncertain, result.Finished
            ? "Hoot finished its turn. Review its task comment before closing the task."
            : "Hoot's turn stopped or needs attention. Review its task comment and Hoot.");
          finished.TryRemove(pair.Key, out _);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException && ex is not OperationCanceledException)
        { Failed?.Invoke("Hoot's task answer could not be saved. Check Hoot and the task before continuing."); }
      }
    }
    finally { completionGate.Release(); }
  }
  public ValueTask NotifyAsync(string sessionId, string text, CancellationToken ct) => agents.NotifyAsync(sessionId, text, ct);
  public async ValueTask FinishPendingWritesAsync()
  {
    await completionGate.WaitAsync(); completionGate.Release();
  }
}
