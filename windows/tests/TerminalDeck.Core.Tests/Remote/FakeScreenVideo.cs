using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

// Contract §11.7: a screen is watched only as H.264 on a direct link. A stand-in encoder for the screen tests: a
// keyframe once, then nothing (the screen never changes).
internal sealed class FakeScreenVideo : IScreenVideoHost
{
  public int Opened;
  public IScreenVideoSource? Open(string displayId, int maxSide, int fps, bool drawCursor, out string? problem)
  { problem = null; Interlocked.Increment(ref Opened); return new Source(); }

  private sealed class Source : IScreenVideoSource
  {
    private bool sent;
    public string Encoder => "test: none";
    public IReadOnlyList<ScreenVideoFrame>? Next(bool key, bool still, out string? problem)
    {
      problem = null;
      if (sent && !key && !still) return null;
      sent = true;
      return [new ScreenVideoFrame([0, 0, 0, 1, 0x65], true, [0x67], [0x68], 16, 16, 0, still)];
    }
    public void Dispose() { }
  }
}
