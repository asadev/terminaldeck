using TerminalDeck.Core.Computers;
namespace TerminalDeck.Core.Tests.Computers;

public sealed class ComputerViewportTests
{
  [Theory] [InlineData(0, 0, 0, 0)] [InlineData(1, 1, 1200, 600)]
  public void ActualSizeFollowClampsViewportWithoutChangingPictureCoordinates(double x, double y, double expectedX, double expectedY)
  {
    var offset = ComputerViewport.Follow(x, y, 2000, 1200, 800, 600, 300, 200);
    Assert.Equal(expectedX, offset.X); Assert.Equal(expectedY, offset.Y);
    var unchanged = ComputerViewport.Follow(0.4, 0.4, 2000, 1200, 800, 600, 500, 200);
    Assert.Equal((500d, 200d), unchanged);
  }
}
