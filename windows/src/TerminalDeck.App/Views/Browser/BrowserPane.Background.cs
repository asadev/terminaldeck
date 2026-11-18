using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
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
  private readonly Dictionary<string, BrowserParking> retainedPages = [];
  private sealed class BrowserParking
  {
    private readonly Panel owner;
    private readonly Canvas layer = new();
    private Matrix transform;
    public XamlRoot Root { get; }
    public Grid Host { get; } = new() { Width = 1280, Height = 800, Opacity = 0, IsHitTestVisible = false };
    public BrowserParking(XamlRoot xamlRoot, WebView2 view)
    {
      Root = xamlRoot;
      owner = xamlRoot.Content as Panel ?? throw new InvalidOperationException("This browser window has no retained page host.");
      // This is the WebView's only parent, attached before initialization. A
      // workspace placeholder supplies its geometry; the live control never unloads.
      Grid.SetRowSpan(layer, int.MaxValue); Grid.SetColumnSpan(layer, int.MaxValue);
      Host.Children.Add(view); layer.Children.Add(Host); owner.Children.Add(layer);
    }
    public void Place(Grid slot, bool visible, double width, double height)
    {
      if (Host.Width != width || Host.Height != height)
      {
        Host.Width = width; Host.Height = height;
        Host.Clip = new RectangleGeometry { Rect = new Rect(0, 0, width, height) };
      }
      if (visible)
      {
        if (!ReferenceEquals(slot.XamlRoot, Root)) throw new InvalidOperationException("This browser page cannot move to another window without losing its live document.");
        var coordinates = slot.TransformToVisual(Root.Content);
        var origin = coordinates.TransformPoint(new(0, 0)); var x = coordinates.TransformPoint(new(1, 0)); var y = coordinates.TransformPoint(new(0, 1));
        var next = new Matrix { M11 = x.X - origin.X, M12 = x.Y - origin.Y, M21 = y.X - origin.X, M22 = y.Y - origin.Y, OffsetX = origin.X, OffsetY = origin.Y };
        if (!next.Equals(transform)) { transform = next; Host.RenderTransform = new MatrixTransform { Matrix = next }; }
      }
      Host.Opacity = visible ? 1 : 0; Host.IsHitTestVisible = visible;
    }
    public void Close() { owner.Children.Remove(layer); layer.Children.Clear(); }
  }
  private BrowserParking RetainBrowserPage(string id, WebView2 view)
  {
    var retained = new BrowserParking(XamlRoot ?? throw new InvalidOperationException("The browser has no window root."), view);
    retainedPages.Add(id, retained); return retained;
  }
  private void ReleaseRetainedPage(string id)
  {
    if (retainedPages.Remove(id, out var retained)) retained.Close();
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
      if (!retainedPages.TryGetValue(tab.Id, out var retained)) return;
      if (shown) parkedPages.Remove(tab.Id); else parkedPages[tab.Id] = retained;
      retained.Place(slot, shown && !tab.Failed && (tab.Address.Length > 0 || tab.NativePopup), width, height);
      tab.View.IsTabStop = shown;
    }
    finally { parkingChanging = false; }
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
    parkedPages.Remove(tab.Id); ReleaseRetainedPage(tab.Id); pageSlots.Remove(tab.Id);
  }
}
