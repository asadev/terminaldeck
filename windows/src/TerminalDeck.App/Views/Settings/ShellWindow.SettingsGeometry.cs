using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private JsonStateStore<SettingsWindowPlacement>? settingsGeometryStore;
  private SettingsWindowPlacement? settingsBounds;
  private void InitializeSettingsGeometry()
  {
    // Deliberately separate from the old panel's coordinates inside the workspace.
    settingsGeometryStore = new(dataRoot, "settings-window-placement");
    try
    {
      settingsBounds = settingsGeometryStore.Load();
      if (settingsBounds is { } saved && (!double.IsFinite(saved.Scale) || saved.Scale <= 0 || saved.Width <= 0 || saved.Height <= 0))
      { settingsBounds = null; throw new ArgumentException("Invalid Settings placement."); }
    }
    catch (Exception ex) when (ex is System.Text.Json.JsonException or IOException or ArgumentException or UnauthorizedAccessException)
    { Model.Notice = "Settings will open beside the sidebar. Its previous position could not be read."; }
  }
  private void RestoreSettingsWindowBounds(Window window)
  {
    var scale = WindowScale(this);
    var initial = SettingsWindowPlacement.Initial(new(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height, scale), SidebarColumn.ActualWidth, TitleBarRow.ActualHeight);
    var requested = settingsBounds ?? initial;
    var area = DisplayArea.GetFromRect(new(requested.X, requested.Y, Math.Max(1, requested.Width), Math.Max(1, requested.Height)), DisplayAreaFallback.Nearest).WorkArea;
    var fitted = requested.Fit(new(area.X, area.Y, area.Width, area.Height), requested.Scale);
    window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    fitted = requested.Fit(new(area.X, area.Y, area.Width, area.Height), WindowScale(window));
    window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    UpdateSettingsMinimum(window);
    window.AppWindow.Changed += (_, args) =>
    {
      if (args.DidPositionChange || args.DidSizeChange) SaveSettingsWindowBounds(window);
      UpdateSettingsMinimum(window);
    };
  }
  private static void UpdateSettingsMinimum(Window window)
  {
    if (window.AppWindow.Presenter is not OverlappedPresenter presenter) return;
    var work = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
    var minWidth = Math.Min(work.Width, (int)Math.Round(680 * WindowScale(window)));
    var minHeight = Math.Min(work.Height, (int)Math.Round(440 * WindowScale(window)));
    if (presenter.PreferredMinimumWidth != minWidth) presenter.PreferredMinimumWidth = minWidth;
    if (presenter.PreferredMinimumHeight != minHeight) presenter.PreferredMinimumHeight = minHeight;
  }
  private void SaveSettingsWindowBounds(Window window)
  {
    if (window.AppWindow.Presenter is OverlappedPresenter { State: not OverlappedPresenterState.Restored } || window.AppWindow.Position.X < -10000) return;
    settingsBounds = new(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height, WindowScale(window));
    try { settingsGeometryStore?.Save(settingsBounds); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Model.Notice = "Settings moved, but its position could not be saved."; }
  }
}
