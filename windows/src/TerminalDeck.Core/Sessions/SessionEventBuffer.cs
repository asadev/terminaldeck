using System.Text;
using System.Threading.Channels;

namespace TerminalDeck.Core.Sessions;

// A count alone allowed thousands of 32 KB PTY reads to pile up behind each
// paused viewer. Both worker and supervisor enforce the same byte ceiling.
public sealed class SessionEventBuffer
{
  public const int MaximumQueuedBytes = 4 * 1024 * 1024;
  private readonly Channel<SessionEvent> channel = Channel.CreateBounded<SessionEvent>(new BoundedChannelOptions(SessionAttachment.EventBuffer) { FullMode = BoundedChannelFullMode.Wait });
  private long queuedBytes;
  private int closed;
  public bool Closed => Volatile.Read(ref closed) != 0;
  public bool TryPublish(SessionEvent change)
  {
    if (Closed) return false;
    var bytes = Encoding.UTF8.GetByteCount(change.Text ?? "");
    if (Interlocked.Add(ref queuedBytes, bytes) <= MaximumQueuedBytes && channel.Writer.TryWrite(change)) return true;
    Interlocked.Add(ref queuedBytes, -bytes);
    Complete(new IOException("The viewer fell behind. Reattach for a fresh bounded snapshot.")); return false;
  }
  public async IAsyncEnumerable<SessionEvent> ReadAllAsync([System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
  {
    await foreach (var change in channel.Reader.ReadAllAsync(ct))
    {
      Interlocked.Add(ref queuedBytes, -Encoding.UTF8.GetByteCount(change.Text ?? "")); yield return change;
    }
  }
  public void Complete(Exception? error = null) { Interlocked.Exchange(ref closed, 1); channel.Writer.TryComplete(error); }
}
