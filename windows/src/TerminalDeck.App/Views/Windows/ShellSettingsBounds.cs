using Microsoft.UI.Windowing;
using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // The workspace tool keeps its DIP contract; coordinates now address the desktop.
  private SettingsPanelBounds? ReadNativeSettingsBounds()
  {
    if (settingsWindow is not { } window) return null;
    var scale = WindowScale(window);
    return new(window.AppWindow.Position.X / scale, window.AppWindow.Position.Y / scale, window.AppWindow.Size.Width / scale, window.AppWindow.Size.Height / scale);
  }
  private void ApplyNativeSettingsBounds(SettingsPanelBounds requested)
  {
    ShowSettingsPanel();
    var window = settingsWindow!; var scale = WindowScale(window);
    var desired = new SettingsWindowPlacement((int)Math.Clamp(Math.Round(requested.X * scale), int.MinValue, int.MaxValue), (int)Math.Clamp(Math.Round(requested.Y * scale), int.MinValue, int.MaxValue),
      (int)Math.Clamp(Math.Round(requested.Width * scale), 1, int.MaxValue), (int)Math.Clamp(Math.Round(requested.Height * scale), 1, int.MaxValue), scale);
    var area = DisplayArea.GetFromRect(new(desired.X, desired.Y, desired.Width, desired.Height), DisplayAreaFallback.Nearest).WorkArea;
    var fitted = desired.Fit(new(area.X, area.Y, area.Width, area.Height), scale);
    window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    SaveSettingsWindowBounds(window);
  }
}
