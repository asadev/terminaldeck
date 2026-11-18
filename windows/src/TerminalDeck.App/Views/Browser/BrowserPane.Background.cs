using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

// A page keeps its original WebView/controller and cookie store. A finite host
// on that same XamlRoot retains its drawing size while its workspace pane is
// hidden. WinUI WebView2 cannot move into another window's XamlRoot.
public sealed partial class BrowserPane
{
  private static Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions BrowserEnvironmentOptions() => new() { AreBrowserExtensionsEnabled = true, AdditionalBrowserArguments = "--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows" };
  private void BrowserActivityChanged() { RefreshBackgroundPages(); RefreshShellViews(); }
  private readonly Dictionary<string, BrowserParking> parkedPages = [];
  private readonly Dictionary<string, Grid> pageSlots = [];
  private readonly HashSet<XamlRoot> browserRoots = [];
  private sealed class BrowserParking
  {
    private readonly Panel owner;
    private readonly Canvas layer = new() { Width = 1, Height = 1, Opacity = 0, IsHitTestVisible = false, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    public Grid Host { get; } = new();
    public BrowserParking(XamlRoot xamlRoot, ElementTheme theme)
    {
      owner = xamlRoot.Content as Panel ?? throw new InvalidOperationException("This browser window has no retained page host.");
      Host.RequestedTheme = theme;
      // A transparent, noninteractive layer stays loaded on the original root.
      // Its child has finite bounds; it never covers or captures input from the person.
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetAccessibilityView(layer, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
      Grid.SetRowSpan(layer, int.MaxValue); Grid.SetColumnSpan(layer, int.MaxValue);
      layer.Children.Add(Host); owner.Children.Add(layer);
    }
    public void Close() { layer.Children.Clear(); owner.Children.Remove(layer); }
  }
  private static bool IsDrawn(FrameworkElement element)
  {
    if (element.XamlRoot is not { IsHostVisible: true } xamlRoot) return false;
    var host = AppWindow.GetFromWindowId(xamlRoot.ContentIslandEnvironment.AppWindowId);
    if (!host.IsVisible || host.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }) return false;
    // A retained pane can keep its XamlRoot and last measured size after its
    // workspace tab is removed. Only a chain reaching this root is on screen.
    for (DependencyObject? node = element; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
    {
      if (node is FrameworkElement { Visibility: Visibility.Collapsed }) return false;
      if (ReferenceEquals(node, xamlRoot.Content)) return element.ActualWidth > 0 && element.ActualHeight > 0;
    }
    return false;
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
      parked.Host.Children.Remove(tab.View); slot.Children.Add(tab.View); tab.View.Visibility = Visibility.Visible; parked.Close();
    }
    else if (!shown && !parkedPages.ContainsKey(tab.Id))
    {
      var parking = new BrowserParking(tab.View.XamlRoot ?? slot.XamlRoot ?? throw new InvalidOperationException("The browser page has no window root."), tab.View.ActualTheme);
      ResizeParking(parking, width, height);
      parking.Host.Loaded += (_, _) => ResizeParking(parking, parking.Host.Width, parking.Host.Height);
      var previous = tab.View.Parent as Panel; previous?.Children.Remove(tab.View);
      try { parking.Host.Children.Add(tab.View); }
      catch { previous?.Children.Add(tab.View); parking.Close(); throw; }
      tab.View.Visibility = Visibility.Visible; parkedPages[tab.Id] = parking;
    }
    else if (!shown && parkedPages.TryGetValue(tab.Id, out var retained)) ResizeParking(retained, width, height);
    }
    finally { parkingChanging = false; }
  }
  private static void ResizeParking(BrowserParking parking, double width, double height)
  {
    if (parking.Host.Width == width && parking.Host.Height == height) return;
    parking.Host.Width = width; parking.Host.Height = height;
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
    if (parkedPages.Remove(tab.Id, out var parked)) { parked.Host.Children.Remove(tab.View); parked.Close(); }
    pageSlots.Remove(tab.Id);
  }
}
