using TerminalDeck.App.Diagnostics;
using Xunit;

namespace TerminalDeck.Recovery.Tests;

public sealed class RecoveryTests
{
  private sealed class QueueContext : SynchronizationContext
  {
    internal readonly Queue<Action> Pending = new();
    public override void Post(SendOrPostCallback callback, object? state) => Pending.Enqueue(() => callback(state));
    internal void Drain() { while (Pending.TryDequeue(out var callback)) callback(); }
  }
  [Fact]
  public void QueuedFailureIsReportedAndNextCallbackStillRuns()
  {
    var queue = new QueueContext(); var errors = new List<Exception>();
    var context = new RecoveryContext(queue, errors.Add); var reached = false;
    context.Post(_ => throw new InvalidOperationException("queued failure"), null);
    context.Post(_ => reached = true, null); queue.Drain();
    Assert.Equal("queued failure", Assert.Single(errors).Message); Assert.True(reached);
  }
  [Fact]
  public void AsyncVoidFailureAfterAwaitIsReported()
  {
    var queue = new QueueContext(); var errors = new List<Exception>();
    var context = new RecoveryContext(queue, errors.Add);
    context.Post(async _ => { await Task.Yield(); throw new InvalidOperationException("after await"); }, null);
    queue.Drain(); Assert.Equal("after await", Assert.Single(errors).Message);
  }
  [Fact]
  public void CallbackRestoresPreviousContext()
  {
    var previous = SynchronizationContext.Current;
    var context = new RecoveryContext(new QueueContext(), _ => { });
    context.Run(_ => Assert.Same(context, SynchronizationContext.Current), null);
    Assert.Same(previous, SynchronizationContext.Current);
  }
  [Fact]
  public void ErrorLogKeepsOriginalStackAndInnerExceptionInChosenRoot()
  {
    var root = Path.Combine(Path.GetTempPath(), "td-recovery-" + Guid.NewGuid());
    try
    {
      var log = new AppErrorLog(root);
      try { throw new InvalidOperationException("outer", new IOException("inner")); }
      catch (Exception error) { log.Write("XAML", error); }
      var text = File.ReadAllText(log.PathName);
      Assert.Contains("[XAML] HRESULT=0x", text); Assert.Contains("outer", text);
      Assert.Contains("inner", text); Assert.Contains(nameof(ErrorLogKeepsOriginalStackAndInnerExceptionInChosenRoot), text);
    }
    finally { Directory.Delete(root, true); }
  }
  [Fact]
  public void UnwritableLogDoesNotThrowFromErrorHandler()
  {
    var file = Path.GetTempFileName();
    try { new AppErrorLog(file).Write("failure", new InvalidOperationException("original")); }
    finally { File.Delete(file); }
  }
}
