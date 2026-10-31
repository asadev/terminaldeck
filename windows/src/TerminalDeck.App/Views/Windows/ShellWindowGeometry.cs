using System.Text.Json;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
  private static double WindowScale(Window window)
  {
    var dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)); return dpi == 0 ? 1 : dpi / 96d;
  }
  private JsonStateStore<WorkspaceGeometry> windowGeometryStore = null!;
  private WorkspaceGeometry windowGeometry = new([]);
  private void InitializeWindowGeometry()
  {
    windowGeometryStore = new(dataRoot, "window-geometry");
    try
    {
      windowGeometry = windowGeometryStore.Load() ?? new([]);
      if (windowGeometry.Windows is null || windowGeometry.Windows.Values.Any(b => b.Width <= 0 || b.Height <= 0 || !double.IsFinite(b.Scale) || b.Scale <= 0)) throw new ArgumentException("Invalid saved window geometry.");
    }
    catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException or ArgumentException)
    { windowGeometry = new([]); Model.Notice = "Previous window positions could not be read. Windows will open on this display."; }
  }
  private static WorkspaceWindowBounds WindowWorkArea(WorkspaceWindowBounds desired)
  {
    var display = DisplayArea.GetFromRect(new(desired.X, desired.Y, Math.Max(1, desired.Width), Math.Max(1, desired.Height)), DisplayAreaFallback.Nearest);
    var area = display.WorkArea; return new(area.X, area.Y, area.Width, area.Height);
  }
  private void RememberWindow(Window window, string id, int width, int height)
  {
    if (Environment.GetEnvironmentVariable("TD_W13_PROOF") is not null)
    { window.AppWindow.MoveAndResize(new(-20000, -20000, width, height)); return; }
    var current = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
    var saved = windowGeometry.Windows.GetValueOrDefault(id) ?? new(current.X + (current.Width - width) / 2, current.Y + (current.Height - height) / 2, width, height);
    var area = WindowWorkArea(saved);
    var scale = WindowScale(window);
    var fitted = saved.AtScale(scale).Fit(area);
    window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    window.AppWindow.Changed += (_, args) =>
    {
      if ((!args.DidPositionChange && !args.DidSizeChange) || window.AppWindow.Position.X < -10000) return;
      if (window.AppWindow.Presenter is OverlappedPresenter presenter && presenter.State != OverlappedPresenterState.Restored) return;
      var bounds = new WorkspaceWindowBounds(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height, WindowScale(window));
      var next = new WorkspaceGeometry(new(windowGeometry.Windows) { [id] = bounds });
      try { windowGeometryStore.Save(next); windowGeometry = next; }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Model.Notice = "The window position could not be saved."; }
    };
  }
}
