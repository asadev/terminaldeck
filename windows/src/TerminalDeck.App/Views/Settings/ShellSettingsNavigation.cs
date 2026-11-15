using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.App.Views;

public interface ISettingsPageNavigation
{
  Task OpenSettingsAsync(string section);
}

public sealed partial class ShellWindow : ISettingsPageNavigation
{
  private Window? browserSettingsWindow;

  public async Task OpenSettingsAsync(string section)
  {
    // The Browser's settings left the Settings list (Mac, 15 Nov): they open as their own small window.
    if (SettingsNavigation.IsBrowser(section)) { ShowBrowserSettingsWindow(); return; }
    ShowSettingsPanel();
    await settingsPanel!.SelectAsync(section);
  }

  // The Browser's own settings window: the same page content the Settings list used to show, nothing else.
  private void ShowBrowserSettingsWindow()
  {
    if (browserSettingsWindow is { } existing)
    {
      if (existing.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
      ShowSettingsOwnedWindow(existing);
      return;
    }
    var window = new Window { Title = "Browser settings — " + TerminalDeck.Core.Brand.Name };
    var root = new Microsoft.UI.Xaml.Controls.Grid { RequestedTheme = Root.RequestedTheme };
    root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    var drag = new Microsoft.UI.Xaml.Controls.Grid { Height = 40, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) };
    drag.Children.Add(new Microsoft.UI.Xaml.Controls.TextBlock { Text = "Browser settings", FontSize = 13, Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
    var host = new Microsoft.UI.Xaml.Controls.Grid();
    Microsoft.UI.Xaml.Controls.Grid.SetRow(host, 1);
    root.Children.Add(drag); root.Children.Add(host);
    void Fill()
    {
      host.Children.Clear();
      if (settings.DirectionPage("browser", _ => { }) is { } page) host.Children.Add(page);
    }
    Action<string> refresh = id => { if (id == "browser") DispatcherQueue.TryEnqueueHandled(Fill); };
    settings.DirectionRefreshRequested += refresh;
    Fill();
    window.Content = root;
    WindowMaterials.Attach(window, root, kind: Microsoft.UI.Composition.SystemBackdrops.MicaKind.Base);
    browserSettingsWindow = window;
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
    Windows.Foundation.TypedEventHandler<FrameworkElement, object> followTheme = (_, _) => root.RequestedTheme = Root.RequestedTheme;
    Root.ActualThemeChanged += followTheme;
    root.ActualThemeChanged += (_, _) => UpdateCaption();
    root.Loaded += (_, _) => UpdateCaption();
    var scale = WindowScale(this);
    window.AppWindow.Resize(new Windows.Graphics.SizeInt32((int)Math.Round(600 * scale), (int)Math.Round(680 * scale)));
    window.Closed += (_, _) =>
    {
      settings.DirectionRefreshRequested -= refresh; Root.ActualThemeChanged -= followTheme;
      root.Children.Clear(); window.Content = null; browserSettingsWindow = null;
    };
    UpdateCaption(); ShowSettingsOwnedWindow(window);
  }
}

public sealed partial class BrowserPane
{
  public Func<Task>? OpenSettingsRequested { get; set; }
  private Task OpenProfileSettingsAsync() => OpenSettingsRequested?.Invoke() ?? Task.FromException(new InvalidOperationException("Open Browser settings from the main window."));
}
