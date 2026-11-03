using System.Diagnostics;

namespace TerminalDeck.Platform.Windows.Phone;

// M4 (review 25): who may touch a GPU encoder, and who lets it go. An asynchronous Media Foundation encoder is driven by
// its events on a thread of its own while Dispose runs on another, and a stalled driver can keep that thread inside its
// event wait past any timeout. So the encoder has two holders, the owner (until Dispose has shut it down) and the event
// thread (until it has left), and the last one out lets it go, exactly once. A thread that never comes back keeps it (a
// leak, never a crash); one that comes back late finds it closed and leaves without touching it. Any failure inside the
// loop is logged and ends the loop; the encoder then counts as stalled and the software one takes over.
// Plain .NET, no COM: Core.Tests links this file, so its tests run on the Mac too.
internal sealed class EncoderEventThread
{
  private readonly Thread? thread;
  private readonly Action release;
  private int holders, closed, ownerLeft, releases;
  private volatile bool ended, failed;

  /// wait: the next event (blocks inside the driver), null once the encoder has no more. handle: act on one event.
  /// Both null: no event thread (the software encoder), the owner alone holds it.
  public EncoderEventThread(string name, Func<EncoderEventThread, uint?>? wait, Action<uint>? handle, Action release)
  {
    this.release = release;
    if (wait is null || handle is null) { holders = 1; ended = true; return; }
    holders = 2;
    thread = new Thread(() => Run(wait, handle)) { IsBackground = true, Name = name };
  }

  public void Start() => thread?.Start();
  /// No event is acted on after Close.
  public bool Closed => Volatile.Read(ref closed) != 0;
  /// The event thread has left (shut down, or a failure ended it).
  public bool Ended => ended;
  /// Something other than Close ended the event thread: the encoder will not ask for input again.
  public bool Failed => failed;
  /// How often the encoder was let go: 0 while someone still holds it, then 1, never more.
  public int Releases => Volatile.Read(ref releases);

  /// True the first time only.
  public bool Close() => Interlocked.Exchange(ref closed, 1) == 0;

  /// The owner is done (after its own shut-down calls): waits up to `join` for the event thread, then gives up its
  /// share. True when the encoder was let go now; false when the event thread still holds it (it lets go when it
  /// returns, or never) or the owner had already left.
  public bool Leave(TimeSpan join)
  {
    Close();
    if (thread is { IsAlive: true } && thread != Thread.CurrentThread) thread.Join(join);
    return Interlocked.Exchange(ref ownerLeft, 1) == 0 && Drop();
  }

  private bool Drop()
  {
    if (Interlocked.Decrement(ref holders) != 0) return false;
    Interlocked.Increment(ref releases);
    try { release(); }
    catch (Exception ex) { Log("could not be let go (" + ex.GetType().Name + ": " + ex.Message + ")"); }
    return true;
  }

  private void Run(Func<EncoderEventThread, uint?> wait, Action<uint> handle)
  {
    try
    {
      while (!Closed)
      {
        if (wait(this) is not { } type) break;
        if (Closed) break; // shut down while it waited: never touch the encoder again
        handle(type);
      }
    }
    catch (Exception ex) { Log("event thread ended (" + ex.GetType().Name + ": " + ex.Message + ")"); }
    finally
    {
      failed = !Closed;
      ended = true;
      Drop();
    }
  }

  private static void Log(string text) => Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: encoder " + text);
}
