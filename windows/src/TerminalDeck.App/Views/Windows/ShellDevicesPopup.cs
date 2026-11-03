using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private Window? devicesWindow;
  private SettingsPane? devicesPopupPane;
  private bool routingDevices;
  private bool devicesPopupOpen;
  private SettingsWindowPlacement? devicesBounds;
  private Microsoft.UI.Xaml.Controls.Grid? devicesWindowRoot;

  private void Devices_Click(object sender, RoutedEventArgs args) => ShowDevicesPopup();
  // Devices is its own owned window, built exactly like the Settings window.
  private void ShowDevicesPopup()
  {
    morePagesFlyout?.Hide();
    if (devicesWindow is { } existing)
    {
      if (existing.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
      ShowSettingsOwnedWindow(existing);
      return;
    }
    var store = new JsonStateStore<SettingsWindowPlacement>(dataRoot, "devices-window-placement");
    try { devicesBounds = store.Load(); if (devicesBounds is { } b && (!double.IsFinite(b.Scale) || b.Scale <= 0 || b.Width <= 0 || b.Height <= 0)) devicesBounds = null; }
    catch (Exception ex) when (ex is System.Text.Json.JsonException or IOException or UnauthorizedAccessException) { devicesBounds = null; }
    var pane = new SettingsPane(Model, Runtime, initialSection: 2, popupPresentation: true);
    pane.Children[0].Visibility = Visibility.Collapsed;
    pane.ColumnDefinitions[0].Width = new(0);
    pane.ColumnSpacing = 0;
    pane.SelectSection(2);
    devicesPopupPane = pane;
    var window = new Window { Title = "Devices — " + TerminalDeck.Core.Brand.Name };
    var root = new Microsoft.UI.Xaml.Controls.Grid { RequestedTheme = Root.RequestedTheme };
    var drag = new Microsoft.UI.Xaml.Controls.Grid { Height = 40, VerticalAlignment = VerticalAlignment.Top, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    pane.Margin = new(0, 40, 0, 0);
    root.Children.Add(pane); root.Children.Add(drag);
    window.Content = root;
    WindowMaterials.Attach(window, root, kind: Microsoft.UI.Composition.SystemBackdrops.MicaKind.Base);
    devicesWindow = window; devicesWindowRoot = root;
    var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
    System.Runtime.InteropServices.Marshal.SetLastPInvokeError(0);
    SetSettingsOwner(handle, -8, WinRT.Interop.WindowNative.GetWindowHandle(this));
    if (window.AppWindow.Presenter is OverlappedPresenter native) { native.IsResizable = true; native.IsMinimizable = true; native.IsMaximizable = false; }
    window.ExtendsContentIntoTitleBar = true;
    window.SetTitleBar(drag);
    void UpdateCaption()
    {
      var bar = window.AppWindow.TitleBar;
      bar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
      bar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
      bar.ButtonForegroundColor = ((Microsoft.UI.Xaml.Media.SolidColorBrush)ShellTheme.Resource(root, "DeckInkBrush")).Color;
      bar.ButtonInactiveForegroundColor = bar.ButtonForegroundColor;
      bar.ButtonHoverBackgroundColor = ((Microsoft.UI.Xaml.Media.SolidColorBrush)ShellTheme.Resource(root, "DeckHoverBrush")).Color;
    }
    root.ActualThemeChanged += (_, _) => UpdateCaption();
    root.Loaded += (_, _) => UpdateCaption();
    void Save()
    {
      if (window.AppWindow.Presenter is OverlappedPresenter { State: not OverlappedPresenterState.Restored } || window.AppWindow.Position.X < -10000) return;
      devicesBounds = new(window.AppWindow.Position.X, window.AppWindow.Position.Y, window.AppWindow.Size.Width, window.AppWindow.Size.Height, WindowScale(window));
      try { store.Save(devicesBounds); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
    var scale = WindowScale(this);
    var requested = devicesBounds ?? new SettingsWindowPlacement(AppWindow.Position.X + (int)Math.Round((SidebarColumn.ActualWidth + 8) * scale), AppWindow.Position.Y + (int)Math.Round((TitleBarRow.ActualHeight + 8) * scale), (int)Math.Round(560 * scale), (int)Math.Round(520 * scale), scale);
    var area = DisplayArea.GetFromRect(new(requested.X, requested.Y, Math.Max(1, requested.Width), Math.Max(1, requested.Height)), DisplayAreaFallback.Nearest).WorkArea;
    var fitted = requested.Fit(new(area.X, area.Y, area.Width, area.Height), requested.Scale, 520, 440);
    window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    fitted = requested.Fit(new(area.X, area.Y, area.Width, area.Height), WindowScale(window), 520, 440);
    window.AppWindow.MoveAndResize(new(fitted.X, fitted.Y, fitted.Width, fitted.Height));
    UpdateSettingsMinimum(window, 520, 440);
    window.AppWindow.Changed += (_, a) => { if (a.DidPositionChange || a.DidSizeChange) Save(); UpdateSettingsMinimum(window, 520, 440); };
    window.AppWindow.Closing += (_, _) => Save();
    window.Closed += (_, _) => { root.Children.Clear(); window.Content = null; devicesWindow = null; devicesWindowRoot = null; devicesPopupPane = null; devicesPopupOpen = false; };
    devicesPopupOpen = true;
    UpdateCaption(); ShowSettingsOwnedWindow(window);
  }

  private bool RouteDevicesPopup()
  {
    if (Model.Page != ShellPage.Devices || routingDevices) return false;
    routingDevices = true;
    try
    {
      Model.Page = renderedPage is { } prior && prior is not (ShellPage.Settings or ShellPage.Devices) ? prior : ShellPage.Sessions;
      ShowDevicesPopup();
    }
    finally { routingDevices = false; }
    return true;
  }
}
