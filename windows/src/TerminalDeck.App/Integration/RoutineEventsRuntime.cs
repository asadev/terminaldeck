using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.App.Integration;
public sealed partial class AppRuntime
{
  private readonly Dictionary<string, (bool Busy, bool Waiting)> routineChatStates = [];
  private readonly Dictionary<string, string> routineTaskStates = [];
  private bool routineTaskBaseline;
  private readonly HashSet<string> completedRoutineTurns = [];
  private readonly object routineCompletionGate = new();
  private int routineDirty;
  private int routineRefreshing;
  private bool routineEventsInitialized;
  private volatile bool routineEventsDisposed;
  private void InitializeRoutineEvents()
  {
    if (routineEventsInitialized) return; routineEventsInitialized = true; routineEventsDisposed = false;
    _ = Routines; Changed += RoutineSessionsChanged; Hoot.Changed += RoutineHootStateChanged; RoutineSessionsChanged();
  }
  private void RoutineHootStateChanged(HootState state)
  {
    if (routineEventsDisposed) return;
    var completed = new List<HootTurn>();
    lock (routineCompletionGate)
      foreach (var turn in state.Turns.Where(t => t.Source.Kind == "background" && t.Source.Id.Length > 0 && t.State is HootTurnState.Finished or HootTurnState.Failed or HootTurnState.Stopped))
        if (completedRoutineTurns.Add(turn.Id)) completed.Add(turn);
    foreach (var turn in completed)
      if (!routineEventsDisposed && Routines.List().Any(r => r.Id == turn.Source.Id)) Routines.Complete(turn.Source.Id, turn.State == HootTurnState.Finished, turn.Problem);
  }
  private void DisposeRoutineEvents()
  {
    routineEventsDisposed = true;
    if (!routineEventsInitialized) return; routineEventsInitialized = false;
    Changed -= RoutineSessionsChanged; Hoot.Changed -= RoutineHootStateChanged;
  }
  private void RoutineSessionsChanged()
  {
    if (routineEventsDisposed) return;
    Interlocked.Exchange(ref routineDirty, 1);
    if (Interlocked.CompareExchange(ref routineRefreshing, 1, 0) != 0) return;
    try
    {
      do { Interlocked.Exchange(ref routineDirty, 0); if (!routineEventsDisposed) RefreshRoutineSessions(); }
      while (!routineEventsDisposed && Volatile.Read(ref routineDirty) != 0);
    }
    finally
    {
      Volatile.Write(ref routineRefreshing, 0);
      if (!routineEventsDisposed && Volatile.Read(ref routineDirty) != 0) RoutineSessionsChanged();
    }
  }
  private void RefreshRoutineSessions()
  {
    var owned = Routines.List().SelectMany(r => r.Runs).Where(r => r.SessionId is not null).Select(r => r.SessionId).ToHashSet();
    foreach (var chat in Chats.List().Where(c => c.Definition.Id != Hoot.Read().ChatId && !owned.Contains(c.Definition.Id)))
    {
      var waiting = chat.Problem is not null || ChatProjection.Rows(chat).Any(r => r.Kind == "approval" && r.Waiting);
      Routines.ObserveSession(chat.Definition.Id, chat.Definition.Cwd, chat.Busy, chat.Ended);
      if (routineChatStates.TryGetValue(chat.Definition.Id, out var before) && before.Busy && !chat.Busy && !chat.Ended)
        _ = TriggerRoutineEventAsync(waiting ? "session-failed" : "session-finished", chat.Definition.Cwd);
      routineChatStates[chat.Definition.Id] = (chat.Busy, waiting);
    }
    foreach (var task in Tasks.List(new TaskFilter(Status: "all")))
    {
      if (!routineTaskStates.TryGetValue(task.Id, out var before)) { if (routineTaskBaseline) _ = TriggerRoutineEventAsync("task-created", task.Folder); }
      else if (before != "Done" && task.Status == "Done") _ = TriggerRoutineEventAsync("task-finished", task.Folder);
      routineTaskStates[task.Id] = task.Status;
    }
    routineTaskBaseline = true;
  }
  private async Task TriggerRoutineEventAsync(string kind, string? folder, string? argument = null)
  {
    try { await Routines.TriggerAsync(kind, folder, argument); }
    catch (Exception e) when (e is IOException or InvalidOperationException or ArgumentException or OperationCanceledException) { }
  }
}
