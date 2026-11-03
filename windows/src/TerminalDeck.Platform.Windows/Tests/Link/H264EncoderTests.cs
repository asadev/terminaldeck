using System.Diagnostics;
using TerminalDeck.Platform.Windows.Phone;
using Xunit.Abstractions;

namespace TerminalDeck.Windows.Tests.Link;

// The screen encoder on its own: Media Foundation (the GPU's encoder, then the software one) makes decodable H.264
// with a keyframe first, keyframes on demand and the parameter sets on them.
[Collection("webrtc")]
public sealed class H264EncoderTests(ITestOutputHelper output)
{
  private sealed class StepListener : TraceListener
  {
    public override void Write(string? message) => WriteLine(message);
    private static readonly object Gate = new();
    public override void WriteLine(string? message)
    {
      // The encoder's event thread traces too: one writer at a time.
      if (Environment.GetEnvironmentVariable("TD_MEASURE_FILE") is { Length: > 0 } file)
        lock (Gate) File.AppendAllText(Path.Combine(Path.GetDirectoryName(file)!, "steps.txt"), DateTimeOffset.Now.ToString("HH:mm:ss.fff") + " " + message + Environment.NewLine);
    }
  }

  private static byte[] Page(int width, int height, int offset)
  {
    var bgra = new byte[width * height * 4];
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++)
      {
        var i = (y * width + x) * 4;
        var on = ((x / 9 + (y + offset) / 18) % 7) == 0;
        bgra[i] = bgra[i + 1] = bgra[i + 2] = on ? (byte)40 : (byte)250;
      }
    return bgra;
  }

  [Fact]
  public void Nv12IsBt709LimitedRange()
  {
    // 64×2 pixels: white, black, red, then a gradient (the SIMD and the scalar tail must agree).
    const int width = 64, height = 2;
    var bgra = new byte[width * height * 4];
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++)
      {
        var i = (y * width + x) * 4;
        (byte b, byte g, byte r) = x < 2 ? ((byte)255, (byte)255, (byte)255) : x < 4 ? ((byte)0, (byte)0, (byte)0) : x < 6 ? ((byte)0, (byte)0, (byte)255) : ((byte)(x * 4), (byte)(x * 3), (byte)(x * 2));
        bgra[i] = b; bgra[i + 1] = g; bgra[i + 2] = r; bgra[i + 3] = 255;
      }
    var nv12 = Nv12.FromBgra(bgra, width, height);
    Assert.Equal(235, nv12[0]); Assert.Equal(16, nv12[2]); Assert.InRange(nv12[4], (byte)60, (byte)66);
    Assert.InRange(nv12[width * height + 0], (byte)127, (byte)129); Assert.InRange(nv12[width * height + 1], (byte)127, (byte)129); // white: no colour
    Assert.InRange(nv12[width * height + 5], (byte)236, (byte)242); // red: high Cr
    for (var x = 6; x < width; x++)
    {
      int r = x * 2, g = x * 3, b = x * 4;
      Assert.Equal((byte)(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16), nv12[x]);
    }
  }

  [Theory]
  [InlineData(true)]
  [InlineData(false)]
  public void MakesDecodableH264(bool hardware)
  {
    var listener = new StepListener();
    Trace.Listeners.Add(listener);
    try
    {
      const int width = 1280, height = 800;
      listener.WriteLine("encoder test: hardware=" + hardware);
      using var encoder = WindowsH264Encoder.Create(width, height, 30, 4_000_000, preferHardware: hardware);
      listener.WriteLine("encoder: " + encoder.Name);
      using var decoder = new TestH264Decoder();
      var frames = new List<H264Frame>();
      var started = Stopwatch.GetTimestamp();
      for (var n = 0; n < 30; n++)
      {
        var nv12 = Nv12.FromBgra(Page(width, height, n * 6), width, height);
        frames.AddRange(encoder.Encode(nv12, key: n == 0 || n == 20));
      }
      var ms = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
      listener.WriteLine($"encoded {frames.Count} of 30 in {ms:0} ms; keys at " + string.Join(",", frames.Select((f, i) => f.Key ? i : -1).Where(i => i >= 0)));
      output.WriteLine($"MEASURE win-h264 encoder=\"{encoder.Name}\" frames={frames.Count} ms-per-frame={ms / 30:0.0} kb-per-frame={frames.Sum(f => f.Avcc.Length) / 1000.0 / Math.Max(1, frames.Count):0.0}");
      if (Environment.GetEnvironmentVariable("TD_MEASURE_FILE") is { Length: > 0 } file)
        File.AppendAllText(file, $"MEASURE win-h264 encoder=\"{encoder.Name}\" 1280x800 frames={frames.Count}/30 ms-per-frame={ms / 30:0.0} kb-per-frame={frames.Sum(f => f.Avcc.Length) / 1000.0 / Math.Max(1, frames.Count):0.0}" + Environment.NewLine);
      Assert.True(frames.Count >= 25, "frames out: " + frames.Count);
      Assert.True(frames[0].Key && frames[0].Sps is not null && frames[0].Pps is not null, "a keyframe with its parameter sets first");
      Assert.Contains(frames.Skip(1), f => f.Key);
      var decoded = frames.Sum(f => decoder.Decode(TestH264Decoder.AnnexB(f.Avcc, f.Sps, f.Pps))) + decoder.Drain();
      listener.WriteLine("decoded " + decoded);
      Assert.True(decoded >= frames.Count - 2, $"decoded {decoded} of {frames.Count}");
    }
    finally { Trace.Listeners.Remove(listener); }
  }

  // M4 (review 25): the GPU-stall fallback on the real GPU encoder. The software encoder takes over at once (a keyframe
  // first), the stalled one is shut down on a background thread while its event thread still runs, a second Dispose
  // races it, nothing throws on any thread (an escape there ends the test process), and the GPU encoder is let go
  // exactly once. A driver that holds its event thread past the 1 s join: Core.Tests' EncoderEventThreadTests.
  [Fact]
  public void AStalledGpuEncoderIsReplacedAndLetGoOnce()
  {
    const int width = 1280, height = 800;
    var encoder = WindowsH264Encoder.Create(width, height, 30, 4_000_000, preferHardware: true);
    var gpu = encoder;
    try
    {
      if (!gpu.Hardware) { output.WriteLine("no GPU encoder on this PC: nothing to stall"); return; }
      for (var n = 0; n < 5; n++) encoder.Encode(Nv12.FromBgra(Page(width, height, n * 6), width, height), key: n == 0);
      gpu.StallForTest();
      var frames = WindowsH264Encoder.Encode(ref encoder, Nv12.FromBgra(Page(width, height, 40), width, height), key: false);
      Assert.NotSame(gpu, encoder);
      Assert.False(encoder.Hardware);
      gpu.Dispose(); // races the fallback's background Dispose: whichever is second does nothing
      Assert.True(SpinWait.SpinUntil(() => gpu.Releases == 1 && gpu.EventsEnded, 5000), "the GPU encoder was let go and its event thread left");
      Assert.Throws<ObjectDisposedException>(() => gpu.Encode(Nv12.FromBgra(Page(width, height, 0), width, height), key: false));
      for (var n = 0; n < 5; n++) frames.AddRange(encoder.Encode(Nv12.FromBgra(Page(width, height, 50 + n * 6), width, height), key: false));
      Assert.True(frames.Count > 0 && frames[0].Key && frames[0].Sps is not null, "the software encoder starts with a keyframe");
      Thread.Sleep(300);
      Assert.Equal(1, gpu.Releases);
    }
    finally { encoder.Dispose(); }
  }
}
