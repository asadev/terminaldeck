using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using Windows.Graphics;

namespace TerminalDeck.App.Views;

// A page keeps its original WebView/controller and cookie store. A separate
// non-activating window gives Chromium a finite drawing surface while the
// session tab or the owning application window is hidden.
public sealed partial class BrowserPane
{
  private static Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions BrowserEnvironmentOptions() => new() { AreBrowserExtensionsEnabled = true, AdditionalBrowserArguments = "--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows" };
  private void BrowserActivityChanged() { RefreshBackgroundPages(); RefreshShellViews(); }
  private readonly Dictionary<string, BrowserParking> parkedPages = [];
  private readonly Dictionary<string, Grid> pageSlots = [];
  private readonly HashSet<XamlRoot> browserRoots = [];
  private sealed class BrowserParking
  {
    public Window Window { get; } = new();
    public Grid Host { get; } = new();
    public BrowserParking(ElementTheme theme)
    {
      Host.RequestedTheme = theme; Window.Content = Host;
      var app = Window.AppWindow; app.IsShownInSwitchers = false;
      var presenter = OverlappedPresenter.Create(); presenter.SetBorderAndTitleBar(false, false); presenter.IsResizable = false; presenter.IsMaximizable = false; presenter.IsMinimizable = false;
      app.SetPresenter(presenter); app.MoveAndResize(new RectInt32(-32000, -32000, 1280, 800));
      // Show(false) supplies an HWND without activating it or exposing a tab in Alt-Tab.
      app.Show(false);
    }
  }
  private static bool IsDrawn(FrameworkElement element)
  {
    if (element.XamlRoot is not { IsHostVisible: true } xamlRoot) return false;
    var host = AppWindow.GetFromWindowId(xamlRoot.ContentIslandEnvironment.AppWindowId);
    if (!host.IsVisible || host.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }) return false;
    for (DependencyObject? node = element; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
      if (node is FrameworkElement { Visibility: Visibility.Collapsed }) return false;
    return element.ActualWidth > 0 && element.ActualHeight > 0;
  }
  private void TrackBrowserRoot(FrameworkElement panel)
  {
    if (panel.XamlRoot is { } xamlRoot && browserRoots.Add(xamlRoot)) xamlRoot.Changed += (_, _) => RefreshBackgroundPages();
  }
  internal void RefreshBackgroundPages()
  {
    if (disposed) return;
    foreach (var tab in tabs.ToArray()) RefreshBackgroundPage(tab);
  }
  private bool parkingChanging;
  private void RefreshBackgroundPage(BrowserTab tab)
  {
    if (parkingChanging || disposed || !tabs.Contains(tab)) return;
    if (!pageSlots.TryGetValue(tab.Id, out var slot)) return;
    var shown = IsDrawn(slot);
    if (shown) { tab.RenderWidth = slot.ActualWidth; tab.RenderHeight = slot.ActualHeight; }
    var width = tab.Viewport.Width > 0 ? tab.Viewport.Width : tab.RenderWidth;
    var height = tab.Viewport.Height > 0 ? tab.Viewport.Height : tab.RenderHeight;
    var person = shown && WindowActivity.IsActive(slot.XamlRoot);
    tab.ParkedForTools = !shown;
    if (tab.PersonPresent != person)
    {
      tab.PersonPresent = person;
      _ = GuardAsync(async () => { await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.__tdPageParked=" + (!person ? "true" : "false") }); }, tab);
    }
    parkingChanging = true;
    try
    {
    if (shown && parkedPages.Remove(tab.Id, out var parked))
    {
      parked.Host.Children.Remove(tab.View); slot.Children.Add(tab.View); tab.View.Visibility = Visibility.Visible; parked.Window.Close();
    }
    else if (!shown && !parkedPages.ContainsKey(tab.Id))
    {
      var parking = new BrowserParking(tab.View.ActualTheme);
      ResizeParking(parking, width, height);
      parking.Host.Loaded += (_, _) => ResizeParking(parking, parking.Host.Width, parking.Host.Height);
      if (tab.View.Parent is Panel parent) parent.Children.Remove(tab.View);
      parking.Host.Children.Add(tab.View); tab.View.Visibility = Visibility.Visible;
      parkedPages[tab.Id] = parking;
    }
    else if (!shown && parkedPages.TryGetValue(tab.Id, out var retained)) ResizeParking(retained, width, height);
    }
    finally { parkingChanging = false; }
  }
  private static void ResizeParking(BrowserParking parking, double width, double height)
  {
    var scale = parking.Host.XamlRoot?.RasterizationScale ?? 1;
    if (parking.Host.Width == width && parking.Host.Height == height && parking.Window.AppWindow.Size.Width == (int)Math.Ceiling(width * scale) && parking.Window.AppWindow.Size.Height == (int)Math.Ceiling(height * scale)) return;
    parking.Host.Width = width; parking.Host.Height = height;
    parking.Window.AppWindow.Resize(new SizeInt32((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale)));
  }
  private async Task PrepareBackgroundPageAsync(BrowserTab tab)
  {
    if (!pageSlots.ContainsKey(tab.Id)) _ = ShellView(tab.Id);
    RefreshBackgroundPage(tab);
    // This is scoped to our page, never to another browser or the person's window.
    await tab.Model.CommandAsync("Page.setWebLifecycleState", new { state = "active" }).WaitAsync(TimeSpan.FromSeconds(5));
  }
  private void ReleasePageEnvironment(BrowserTab tab)
  {
    if (!pageEnvironments.Remove(tab.Id, out var environment) || !tab.Isolated || pageEnvironments.Values.Any(other => ReferenceEquals(other, environment))) return;
    foreach (var key in profileEnvironments.Where(pair => ReferenceEquals(pair.Value, environment)).Select(pair => pair.Key).ToArray()) profileEnvironments.Remove(key);
  }
  private void CloseBackgroundPage(BrowserTab tab)
  {
    if (parkedPages.Remove(tab.Id, out var parked)) { parked.Host.Children.Remove(tab.View); parked.Window.Close(); }
    pageSlots.Remove(tab.Id);
  }
}
