using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class WorkspaceWindowBoundsTests
{
  [Fact] public void RemovedMonitorAndSmallDisplaysKeepTheWholeWindowVisible()
  {
    var area = new WorkspaceWindowBounds(0, 0, 800, 600);
    Assert.Equal(new(0, 0, 800, 600), new WorkspaceWindowBounds(3000, -800, 1600, 1000).Fit(area));
    Assert.Equal(new(-1280, 0, 800, 600), new WorkspaceWindowBounds(-3000, -800, 800, 600).Fit(new(-1280, 0, 1280, 720)));
    Assert.Equal(0, new WorkspaceWindowBounds(3000, 0, 800, 600).Intersection(area));
    Assert.Equal(480000, area.Intersection(area));
  }
  [Fact] public void DisplayScaleChangesPreserveTheRememberedLogicalSize()
  {
    var saved = new WorkspaceWindowBounds(50, 50, 1200, 900, 1.5);
    Assert.Equal(new(50, 50, 800, 600), saved.AtScale(1));
    Assert.Equal(saved, saved.AtScale(1).AtScale(1.5));
    Assert.Throws<ArgumentException>(() => saved.AtScale(double.NaN));
  }

}
