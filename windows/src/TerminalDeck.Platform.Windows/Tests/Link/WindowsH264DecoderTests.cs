using TerminalDeck.Platform.Windows.Phone;
using Xunit.Abstractions;

namespace TerminalDeck.Windows.Tests.Link;

// "Other computers" (contract §11.7): the production decoder turns the PC encoder's own H.264 back into the picture.
[Collection("webrtc")]
public sealed class WindowsH264DecoderTests(ITestOutputHelper output)
{
  [Fact]
  public void DecodesThePcEncodersPicturesBackToTheirColours()
  {
    const int width = 640, height = 360;
    // Left half red, right half white, as BGRA.
    var bgra = new byte[width * height * 4];
    for (var y = 0; y < height; y++)
      for (var x = 0; x < width; x++)
      {
        var i = (y * width + x) * 4;
        (bgra[i], bgra[i + 1], bgra[i + 2], bgra[i + 3]) = x < width / 2 ? ((byte)0, (byte)0, (byte)255, (byte)255) : ((byte)255, (byte)255, (byte)255, (byte)255);
      }
    using var encoder = WindowsH264Encoder.Create(width, height, 30, 2_000_000, preferHardware: false);
    using var decoder = new WindowsH264Decoder();
    var shown = new List<TerminalDeck.Core.Computers.ComputerVideoPicture>();
    for (var n = 0; n < 10; n++)
      foreach (var frame in encoder.Encode(Nv12.FromBgra(bgra, width, height), key: n == 0))
        shown.AddRange(decoder.Decode(WindowsH264Decoder.AnnexB(frame.Avcc, frame.Sps, frame.Pps), width, height));
    output.WriteLine($"MEASURE win-h264-decode pictures={shown.Count} of 10");
    Assert.True(shown.Count >= 8, "pictures out: " + shown.Count);
    var last = shown[^1];
    Assert.Equal(width, last.Width); Assert.Equal(height, last.Height);
    int At(int x, int y, int channel) => last.Bgra[(y * width + x) * 4 + channel];
    // Red stays red, white stays white (lossy, so within a margin).
    Assert.InRange(At(100, 180, 2), 200, 255); Assert.InRange(At(100, 180, 1), 0, 60); Assert.InRange(At(100, 180, 0), 0, 60);
    Assert.InRange(At(500, 180, 0), 220, 255); Assert.InRange(At(500, 180, 1), 220, 255); Assert.InRange(At(500, 180, 2), 220, 255);
    Assert.Equal(255, At(10, 10, 3));
  }
}
