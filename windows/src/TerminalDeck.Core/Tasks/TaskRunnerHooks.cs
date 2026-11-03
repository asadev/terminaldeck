namespace TerminalDeck.Core.Tasks;

public enum TaskSessionSignal { Working, Idle, NeedsYou, Ended }

// The existing session/chat owner sends real status events here. No process
// polling, terminal scraping, timers per screen or stopping an owner's session.
public sealed class TaskRunnerHooks(TaskService tasks, TimeProvider? time = null) : IDisposable
{
  private readonly object gate = new();
  private readonly Dictionary<string, ITimer> idle = [];
  private readonly TimeProvider clock = time ?? TimeProvider.System;
  private bool disposed;
  public event Action<string>? Failed;
  public void Observe(string sessionId, TaskSessionSignal signal)
  {
    lock (gate)
    {
      if (disposed || !tasks.Runs().Any(r => r.SessionId == sessionId && r.State is not (TaskRunState.Ended or TaskRunState.Yielded))) return;
      if (signal == TaskSessionSignal.Idle)
      {
        if (!idle.ContainsKey(sessionId)) idle[sessionId] = clock.CreateTimer(_ => Release(sessionId), null, TimeSpan.FromMinutes(5), Timeout.InfiniteTimeSpan);
        return;
      }
      if (idle.Remove(sessionId, out var timer)) timer.Dispose();
      try
      {
        if (signal == TaskSessionSignal.NeedsYou) tasks.YieldSession(sessionId, "The agent needs you. Its folder is available for another task; the session stays open.");
        else tasks.ObserveSession(sessionId, signal == TaskSessionSignal.Ended, false);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Failed?.Invoke("The task's session status could not be saved. Check the task before starting another run."); }
    }
  }
  private void Release(string sessionId)
  {
    lock (gate)
    {
      if (disposed || !idle.Remove(sessionId, out var timer)) return;
      timer.Dispose();
      try { tasks.YieldSession(sessionId, "The agent was idle for five minutes. Its folder is available for another task; the session stays open."); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Failed?.Invoke("The idle task's folder could not be released. Check it before starting another run."); }
    }
  }
  public void Dispose() { lock (gate) { disposed = true; foreach (var timer in idle.Values) timer.Dispose(); idle.Clear(); } }
}
