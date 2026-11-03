using System.Text.Json;

namespace TerminalDeck.Core.Computers;

/// One decoded picture: top-down BGRA, opaque.
public sealed record ComputerVideoPicture(byte[] Bgra, int Width, int Height);

/// The platform's H.264 decoder for "Other computers" (Windows: Media Foundation).
public interface IComputerVideoDecoder : IDisposable
{
  /// The pictures that came out for this frame (none while the decoder still holds it).
  IReadOnlyList<ComputerVideoPicture> Decode(ComputerVideoFrame frame);
}

// "Other computers" viewer, from `sims.video` to pictures, off the UI thread (contract §6, §11.7). A software decoder is
// slower than a fast host, so the queue is bounded (review #27 item 5, Security S2): when it fills, the decoder fell
// behind; everything waiting is dropped, the viewer rules and the decoder start afresh, and one keyframe is asked for,
// so the picture catches up instead of lagging further and growing memory. The watch asks 15 fps, what the software
// decoder keeps up with at 2560 wide.
public sealed class ComputerVideoPipeline
{
  public const int MostQueued = 16;
  public const int Fps = 15;
  private readonly string display;
  private readonly Func<IComputerVideoDecoder> newDecoder;
  private readonly Func<object, Task> send;
  private readonly Action<ComputerVideoPicture, int> show;
  private readonly Func<int> currentEpoch;
  private readonly ComputerScreenVideo video;
  private readonly System.Threading.Channels.Channel<(JsonElement Frame, int Epoch)> queue = System.Threading.Channels.Channel.CreateBounded<(JsonElement, int)>(
    new System.Threading.Channels.BoundedChannelOptions(MostQueued) { SingleReader = true, FullMode = System.Threading.Channels.BoundedChannelFullMode.Wait });
  private IComputerVideoDecoder? decoder;
  private int behind;

  /// `send` takes protocol messages for the other computer (acks, keyframe asks); `show` gets the newest picture of a
  /// screen epoch; `currentEpoch` is the viewer's (frames of an older epoch are skipped).
  public ComputerVideoPipeline(string display, Func<IComputerVideoDecoder> newDecoder, Func<object, Task> send, Action<ComputerVideoPicture, int> show, Func<int> currentEpoch)
  {
    this.display = display; this.newDecoder = newDecoder; this.send = send; this.show = show; this.currentEpoch = currentEpoch;
    video = new(display);
  }

  /// Decoders made so far (for tests).
  public int DecoderStarts { get; private set; }

  /// The watch to send: H.264 on the link, 15 fps.
  public static object Watch(string display, string rid, bool cursor) =>
    new { t = "sims.watch", id = display, rid, maxWidth = 2560, fps = Fps, cursor, video = new[] { "h264" } };

  /// One `sims.video` for this display; false when the queue was full (the loop then catches up).
  public bool Offer(JsonElement frame, int epoch)
  {
    if (queue.Writer.TryWrite((frame, epoch))) return true;
    Volatile.Write(ref behind, 1);
    return false;
  }

  public void Complete() => queue.Writer.TryComplete();

  private void Restart()
  {
    decoder?.Dispose();
    decoder = null; // a decoder that cannot be made (Windows N without the Media Feature Pack) leaves none, never a disposed one
    decoder = newDecoder();
    DecoderStarts++;
  }

  public async Task RunAsync()
  {
    var epochSeen = -1;
    try
    {
      await foreach (var (frame, epoch) in queue.Reader.ReadAllAsync().ConfigureAwait(false))
      {
        if (Interlocked.Exchange(ref behind, 0) != 0)
        {
          // The decoder fell behind: drop what waits, start afresh, ask for one keyframe.
          while (queue.Reader.TryRead(out _)) { }
          try { video.Reset(); Restart(); }
          catch (Exception ex) when (ex is not OutOfMemoryException)
          {
            // Same as a frame that fails: log, mark broken, keep the loop (Reviewer S-C2 nit: the catch-up branch was outside the try).
            System.Diagnostics.Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " Other computers screen: " + ex.GetType().Name);
            video.Broken();
          }
          await Quiet(new { t = "sims.key", id = display }).ConfigureAwait(false);
          continue;
        }
        if (epoch != currentEpoch()) continue;
        try
        {
          if (epoch != epochSeen || decoder is null) { epochSeen = epoch; video.Reset(); Restart(); }
          var step = video.Accept(frame, Environment.TickCount64);
          if (step.AskKey) await Quiet(new { t = "sims.key", id = display }).ConfigureAwait(false);
          ComputerVideoPicture? newest = null;
          if (step.Decode is { } next)
          {
            try { foreach (var picture in decoder!.Decode(next)) newest = picture; }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
              video.Broken(); Restart();
              await Quiet(new { t = "sims.key", id = display }).ConfigureAwait(false);
            }
          }
          if (step.Ack is { } seq) await Quiet(new { t = "sims.ack", id = display, seq }).ConfigureAwait(false);
          if (newest is { } shown) show(shown, epoch);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
          System.Diagnostics.Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " Other computers screen: " + ex.GetType().Name);
          video.Broken();
        }
      }
    }
    finally { decoder?.Dispose(); decoder = null; }
  }

  private async Task Quiet(object message)
  {
    try { await send(message).ConfigureAwait(false); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
