using System.Diagnostics;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Platform.Windows.Phone;

// stream step 2: This PC's monitors as H.264 (GDI capture → NV12 → Media Foundation, the GPU's encoder when present).
public sealed class WindowsScreenVideo(WindowsScreenHost screens) : IScreenVideoHost
{
  public IScreenVideoSource? Open(string displayId, int maxSide, int fps, bool drawCursor, out string? problem)
  {
    var first = screens.Grab(displayId, maxSide, drawCursor, out problem);
    if (first is null) return null;
    try { return new Source(screens, displayId, maxSide, fps, drawCursor, WindowsH264Encoder.Create(first.Value.Width, first.Value.Height, fps, Bitrate(first.Value.Width, first.Value.Height, fps))); }
    catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidCastException or ArgumentException or TypeLoadException)
    {
      problem = "This PC could not start its video encoder (" + ex.Message + ").";
      return null;
    }
  }

  /// Bits a second for moving pictures: about 0.07 bits a pixel a frame, 1.5 to 8 Mbit/s.
  public static int Bitrate(int width, int height, int fps) => (int)Math.Clamp(width * (double)height * fps * 0.07, 1_500_000, 8_000_000);

  private sealed class Source(WindowsScreenHost screens, string displayId, int maxSide, int fps, bool drawCursor, WindowsH264Encoder first) : IScreenVideoSource
  {
    private WindowsH264Encoder encoder = first;
    private ulong lastHash;
    private bool sent;
    private byte[]? nv12;
    // One BGRA picture reused for the whole watch (review 25: a new 16 MB array a frame at 2560×1600×30 ≈ 490 MB/s of
    // large-object garbage); it never leaves Next.
    private byte[]? bgra;
    public string Encoder => encoder.Name + " " + encoder.Width + "×" + encoder.Height;

    public IReadOnlyList<ScreenVideoFrame>? Next(bool key, bool still, out string? problem)
    {
      var grabbed = screens.Grab(displayId, maxSide, drawCursor, out problem, bgra);
      if (grabbed is not { } frame) return null;
      bgra = frame.Bgra;
      var captured = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
      if (sent && frame.Hash == lastHash && !key && !still) return null;
      if (frame.Width != encoder.Width || frame.Height != encoder.Height)
      {
        // The monitor changed size: a new encoder, starting with a keyframe. A failed close never ends the watch (X4).
        try { encoder.Dispose(); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: encoder close failed (" + ex.GetType().Name + ")"); }
        encoder = WindowsH264Encoder.Create(frame.Width, frame.Height, fps, Bitrate(frame.Width, frame.Height, fps));
        key = true;
      }
      lastHash = frame.Hash;
      nv12 = Nv12.FromBgra(frame.Bgra, frame.Width, frame.Height, nv12);
      var moving = encoder.Bitrate;
      // A still is a keyframe with room to be sharp (four times the moving rate for this one picture).
      if (still) encoder.Bitrate = Math.Min(moving * 4, 24_000_000);
      List<H264Frame> encoded;
      try { encoded = WindowsH264Encoder.Encode(ref encoder, nv12, key || still || !sent); }
      finally { if (still) encoder.Bitrate = moving; }
      if (encoded.Count > 0) sent = true;
      return encoded.Select(e => new ScreenVideoFrame(e.Avcc, e.Key, e.Sps, e.Pps, frame.Width, frame.Height, captured, still)).ToArray();
    }

    public void Dispose()
    {
      try { encoder.Dispose(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " video: encoder close failed (" + ex.GetType().Name + ")"); }
    }
  }
}
