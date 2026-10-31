global using TerminalDeck.App.Diagnostics;
using Microsoft.UI.Dispatching;

namespace TerminalDeck.App.Diagnostics;

internal static class UiRecovery
{
  private static AppErrorLog? log;
  private static Action<string>? show;
  private static int reporting;
  internal static void Initialize(string directory, Action<string> showError)
  {
    log = new(directory); show = showError;
    if (SynchronizationContext.Current is { } current && current is not RecoveryContext)
      SynchronizationContext.SetSynchronizationContext(new RecoveryContext(current, error => Report("DispatcherQueue async", error)));
  }
  internal static void Log(string source, Exception error) => log?.Write(source, error);
  internal static void Report(string source, Exception error)
  {
    Log(source, error);
    if (Interlocked.Exchange(ref reporting, 1) != 0) return;
    try { show?.Invoke("Something went wrong in this view. You can choose another page. Details were saved to logs/errors.log in this preview’s data folder."); }
    catch (Exception failure) when (RecoveryContext.Recoverable(failure)) { Log("Error row", failure); }
    finally { Volatile.Write(ref reporting, 0); }
  }
  internal static bool TryEnqueueHandled(this DispatcherQueue queue, DispatcherQueueHandler callback) => queue.TryEnqueueHandled(DispatcherQueuePriority.Normal, callback);
  internal static bool TryEnqueueHandled(this DispatcherQueue queue, DispatcherQueuePriority priority, DispatcherQueueHandler callback) => queue.TryEnqueue(priority, () =>
  {
    var current = SynchronizationContext.Current ?? new DispatcherQueueSynchronizationContext(queue);
    var guarded = current as RecoveryContext ?? new RecoveryContext(current, error => Report("DispatcherQueue async", error));
    guarded.Run(_ => callback(), null);
  });
}
