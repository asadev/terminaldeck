using System.Text.Json;
using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.Core.Tests.Settings;

public sealed class SettingsWindowPlacementTests
{
  [Fact]
  public void FirstOpeningIsLargeAndStartsAfterTheMainChrome()
  {
    var result = SettingsWindowPlacement.Initial(new(20, 30, 1920, 1080), 240, 40);
    Assert.Equal(new(268, 78, 1304, 1000), result);
  }
  [Fact]
  public void SavedPositionCanBeEntirelyOutsideTheMainWindowOnANegativeMonitor()
  {
    var saved = new SettingsWindowPlacement(-1500, 120, 1000, 760);
    var restored = JsonSerializer.Deserialize<SettingsWindowPlacement>(JsonSerializer.Serialize(saved))!;
    Assert.Equal(saved, restored.Fit(new(-1920, 0, 1920, 1040), 1));
  }
  [Fact]
  public void MissingMonitorClampsTheEntireWindowOntoTheRemainingWorkArea()
  {
    Assert.Equal(new(0, 140, 1000, 760), new SettingsWindowPlacement(-1500, 1200, 1000, 760).Fit(new(0, 0, 1600, 900), 1));
  }
  [Fact]
  public void RestoringAtDifferentDpiKeepsTheLogicalSize()
  {
    Assert.Equal(new(100, 100, 1200, 900, 1.5), new SettingsWindowPlacement(100, 100, 800, 600).Fit(new(0, 0, 2560, 1440), 1.5));
  }
  [Fact]
  public void MinimumSizeAndTinyDisplaysStayUsable()
  {
    Assert.Equal(new(0, 0, 680, 440), new SettingsWindowPlacement(0, 0, 10, 10).Fit(new(0, 0, 1920, 1080), 1));
    Assert.Equal(new(0, 0, 600, 400), new SettingsWindowPlacement(0, 0, 900, 800).Fit(new(0, 0, 600, 400), 1));
    Assert.Throws<ArgumentException>(() => new SettingsWindowPlacement(0, 0, 900, 800, double.NaN).Fit(new(0, 0, 1600, 900), 1));
  }
}
