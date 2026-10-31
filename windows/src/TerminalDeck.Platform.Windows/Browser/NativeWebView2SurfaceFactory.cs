using System.Drawing;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.Platform.Windows;

public interface INativeBrowserHost
{
  IntPtr ParentWindow { get; }
  Rectangle Bounds { get; }
  void Failed(string tabId, string message);
}
public interface INativeBrowserActions
{
  ValueTask<JsonElement> PerformAsync(CoreWebView2 page, BrowserPageAction action, JsonElement arguments, CancellationToken ct);
}

// HWND-based WebView2 adapter: usable by WinUI without owning a WinUI control.
// The UI thread and each live controller are retained while tabs are in the background.
public sealed class NativeWebView2SurfaceFactory : IBrowserSurfaceFactory
{
  private readonly SynchronizationContext ui;
  private readonly INativeBrowserHost host;
  private readonly WindowsBrowserProfileStorage storage;
  private readonly INativeBrowserActions actions;
  private readonly Func<Uri, bool> allowed;
  private readonly Func<string, string, string, ValueTask> metadata;
  private readonly Dictionary<string, CoreWebView2Environment> environments = [];
  private readonly Dictionary<string, Page> pages = [];
  public NativeWebView2SurfaceFactory(INativeBrowserHost host, WindowsBrowserProfileStorage storage, INativeBrowserActions actions,
    Func<Uri, bool> allowed, Func<string, string, string, ValueTask> metadata)
  {
    ui = SynchronizationContext.Current ?? throw new InvalidOperationException("Create browser surfaces on the window thread.");
    this.host = host; this.storage = storage; this.actions = actions; this.allowed = allowed; this.metadata = metadata;
  }
  public ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken ct) => new(OnUiAsync<IBrowserPage>(async () =>
  {
    ct.ThrowIfCancellationRequested();
    var key = options.PrivateStoreId ?? options.ProfileId;
    if (!environments.TryGetValue(key, out var environment))
    {
      environment = await CoreWebView2Environment.CreateAsync(null, storage.PathFor(options)); environments.Add(key, environment);
    }
    var preferences = environment.CreateCoreWebView2ControllerOptions(); preferences.ProfileName = "Deck"; preferences.IsInPrivateModeEnabled = options.Isolated;
    var controller = await environment.CreateCoreWebView2ControllerAsync(host.ParentWindow, preferences);
    try
    {
      ct.ThrowIfCancellationRequested(); controller.Bounds = host.Bounds;
      var web = controller.CoreWebView2;
      if (web.Profile.IsInPrivateModeEnabled != options.Isolated) throw new IOException("The requested browser store is not available.");
      web.Settings.IsWebMessageEnabled = false; web.Settings.AreHostObjectsAllowed = false;
      web.Settings.IsPasswordAutosaveEnabled = false; web.Settings.IsGeneralAutofillEnabled = false;
      var page = new Page(this, options, controller); pages.Add(options.TabId, page); page.Subscribe(); return page;
    }
    catch { controller.Close(); throw; }
  }));
  public Task PresentAsync(string? selectedTab, CancellationToken ct = default) => OnUiAsync(async () =>
  {
    ct.ThrowIfCancellationRequested();
    foreach (var (id, page) in pages) { page.Controller.Bounds = host.Bounds; page.Controller.IsVisible = id == selectedTab; }
    await Task.CompletedTask; return true;
  });
  public Task ReparentAsync(string tabId, IntPtr parent, Rectangle bounds, CancellationToken ct = default) => OnUiAsync(async () =>
  {
    ct.ThrowIfCancellationRequested(); var page = pages[tabId]; page.Controller.ParentWindow = parent; page.Controller.Bounds = bounds;
    await Task.CompletedTask; return true;
  });
  private Task<T> OnUiAsync<T>(Func<Task<T>> action)
  {
    if (SynchronizationContext.Current == ui) return action();
    var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
    ui.Post(async _ => { try { done.TrySetResult(await action()); } catch (Exception ex) { done.TrySetException(ex); } }, null); return done.Task;
  }
  private sealed class Page(NativeWebView2SurfaceFactory owner, BrowserSurfaceOptions options, CoreWebView2Controller controller) : IBrowserPage
  {
    public CoreWebView2Controller Controller { get; } = controller;
    private CoreWebView2 Web => Controller.CoreWebView2;
    private bool closed;
    public string TabId => options.TabId;
    public void Subscribe()
    {
      Web.NavigationStarting += NavigationStarting; Web.NavigationCompleted += NavigationCompleted;
      Web.DocumentTitleChanged += TitleChanged; Web.PermissionRequested += Permission; Web.NewWindowRequested += NewWindow;
      Web.DownloadStarting += Download; Web.ProcessFailed += Failed;
    }
    private void NavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
      try { if (!owner.allowed(BrowserModel.Address(e.Uri))) e.Cancel = true; }
      catch (ArgumentException) { e.Cancel = true; }
    }
    private async void NavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
      if (!e.IsSuccess) { owner.host.Failed(TabId, "The page could not load."); return; } await ObserveAsync();
    }
    private async void TitleChanged(object? sender, object e) => await ObserveAsync();
    private async Task ObserveAsync()
    {
      try { if (!closed) await owner.metadata(TabId, Web.Source, Web.DocumentTitle); }
      catch { owner.host.Failed(TabId, "The page details could not be saved."); }
    }
    private static void Permission(object? sender, CoreWebView2PermissionRequestedEventArgs e) => e.State = CoreWebView2PermissionState.Deny;
    private static void NewWindow(object? sender, CoreWebView2NewWindowRequestedEventArgs e) => e.Handled = true;
    private static void Download(object? sender, CoreWebView2DownloadStartingEventArgs e) => e.Cancel = true;
    private void Failed(object? sender, CoreWebView2ProcessFailedEventArgs e) => owner.host.Failed(TabId, "The page stopped. Reload to try again.");
    public Task NavigateAsync(Uri address, CancellationToken cancellationToken = default) => owner.OnUiAsync(async () =>
    {
      Require(cancellationToken); _ = BrowserModel.Address(address.AbsoluteUri);
      if (!owner.allowed(address)) throw new IOException("This page is outside the browser's permission.");
      Web.Navigate(address.AbsoluteUri); await Task.CompletedTask; return true;
    });
    public ValueTask ReloadAsync(bool bypassCache, CancellationToken ct) => new(owner.OnUiAsync(async () =>
    {
      Require(ct); if (bypassCache) await Web.CallDevToolsProtocolMethodAsync("Page.reload", "{\"ignoreCache\":true}"); else Web.Reload(); return true;
    }));
    public Task<JsonElement> DevToolsAsync(string method, JsonElement arguments, CancellationToken cancellationToken = default) => owner.OnUiAsync(async () =>
    {
      Require(cancellationToken); using var document = JsonDocument.Parse(await Web.CallDevToolsProtocolMethodAsync(method, arguments.GetRawText())); return document.RootElement.Clone();
    });
    public ValueTask<JsonElement> PerformAsync(BrowserPageAction action, JsonElement arguments, CancellationToken ct) => new(owner.OnUiAsync(async () =>
    { Require(ct); return await owner.actions.PerformAsync(Web, action, arguments, ct); }));
    public ValueTask DisposeAsync() => new(owner.OnUiAsync(async () =>
    {
      if (closed) return true; closed = true;
      Web.NavigationStarting -= NavigationStarting; Web.NavigationCompleted -= NavigationCompleted; Web.DocumentTitleChanged -= TitleChanged;
      Web.PermissionRequested -= Permission; Web.NewWindowRequested -= NewWindow; Web.DownloadStarting -= Download; Web.ProcessFailed -= Failed;
      Controller.Close(); owner.pages.Remove(TabId); if (options.PrivateStoreId is { } key) owner.environments.Remove(key);
      await Task.CompletedTask; return true;
    }));
    private void Require(CancellationToken ct) { ct.ThrowIfCancellationRequested(); ObjectDisposedException.ThrowIf(closed, this); }
  }
}
