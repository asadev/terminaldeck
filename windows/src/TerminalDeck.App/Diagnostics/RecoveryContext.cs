namespace TerminalDeck.App.Diagnostics;

// DispatcherQueue has no UnhandledException event. Async-void exceptions are
// posted to the captured context, so guard that boundary as well as callbacks.
internal sealed class RecoveryContext(SynchronizationContext inner, Action<Exception> report) : SynchronizationContext
{
  public override void Post(SendOrPostCallback callback, object? state) => inner.Post(_ => Run(callback, state), null);
  public override void Send(SendOrPostCallback callback, object? state) => inner.Send(_ => Run(callback, state), null);
  public override SynchronizationContext CreateCopy() => new RecoveryContext(inner.CreateCopy(), report);
  internal static bool Recoverable(Exception error) => error is not (OutOfMemoryException or AccessViolationException);
  internal void Run(SendOrPostCallback callback, object? state)
  {
    var previous = Current;
    SetSynchronizationContext(this);
    try { callback(state); }
    catch (Exception error) when (Recoverable(error)) { report(error); }
    finally { SetSynchronizationContext(previous); }
  }
}
