using System.Text.Json;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Browser;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Browser;

public interface IBrowserVisualHost
{
  // Keep background controls attached. Selection changes visibility, not lifetime.
  void Attach(string tabId, WebView2 view);
  void Detach(string tabId, WebView2 view);
  void Failed(string tabId, string message);
}
public interface IWebView2NamedActions
{
  // The complete toolbar adapter supplies exact named operations, privacy masks
  // and owned capture paths. Do not register browser.page until this is complete.
  ValueTask<JsonElement> PerformAsync(WebView2 view, BrowserPageAction action, JsonElement arguments, CancellationToken cancellationToken);
}

// WinUI glue only. No socket, global environment variable, OAuth token scraping,
// terminal bridge or script command from an untrusted page is installed here.
public sealed class WebView2SurfaceFactory(DispatcherQueue dispatcher, IBrowserVisualHost host,
  WindowsBrowserProfileStorage storage, IWebView2NamedActions actions, Func<Uri, bool> mayNavigate,
  Func<string, string, string, ValueTask> metadata) : IBrowserSurfaceFactory
{
  private readonly DispatcherQueue uiDispatcher = dispatcher;
  private readonly IBrowserVisualHost visualHost = host;
  private readonly WindowsBrowserProfileStorage profileStorage = storage;
  private readonly IWebView2NamedActions namedActions = actions;
  private readonly Func<Uri, bool> navigationPermission = mayNavigate;
  private readonly Func<string, string, string, ValueTask> recordMetadata = metadata;
  private readonly Dictionary<string, CoreWebView2Environment> environments = [];
  public ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken cancellationToken) => new(OnUiAsync<IBrowserPage>(async () =>
  {
    cancellationToken.ThrowIfCancellationRequested();
    var key = options.PrivateStoreId ?? options.ProfileId;
    if (!environments.TryGetValue(key, out var environment))
    {
      // Separate explicit UDFs, plus actual InPrivate controller mode. No global
      // WEBVIEW2_USER_DATA_FOLDER / browser flags and no debugging TCP port.
      environment = await CoreWebView2Environment.CreateAsync(null, profileStorage.PathFor(options), new CoreWebView2EnvironmentOptions());
      environments.Add(key, environment);
    }
    var view = new WebView2();
    try
    {
      var controller = environment.CreateCoreWebView2ControllerOptions(); controller.ProfileName = "Deck"; controller.IsInPrivateModeEnabled = options.Isolated;
      await view.EnsureCoreWebView2Async(environment, controller);
      cancellationToken.ThrowIfCancellationRequested();
      if (view.CoreWebView2.Profile.IsInPrivateModeEnabled != options.Isolated) throw new IOException("The browser could not provide the requested private store.");
      view.CoreWebView2.Settings.IsWebMessageEnabled = false;
      view.CoreWebView2.Settings.AreHostObjectsAllowed = false;
      view.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false;
      view.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
      var page = new Page(this, options, view);
      visualHost.Attach(options.TabId, view); page.Subscribe(); return page;
    }
    catch { view.Close(); if (options.Isolated) environments.Remove(key); throw; }
  }));
  private Task<T> OnUiAsync<T>(Func<Task<T>> work)
  {
    if (uiDispatcher.HasThreadAccess) return work();
    var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
    if (!uiDispatcher.TryEnqueueHandled(async () =>
    {
      try { done.TrySetResult(await work()); } catch (Exception ex) { done.TrySetException(ex); }
    })) done.TrySetException(new IOException("The browser window is closing."));
    return done.Task;
  }
  private sealed class Page(WebView2SurfaceFactory owner, BrowserSurfaceOptions options, WebView2 view) : IBrowserPage
  {
    private bool disposed;
    public string TabId => options.TabId;
    public void Subscribe()
    {
      view.CoreWebView2.NavigationStarting += NavigationStarting;
      view.CoreWebView2.NavigationCompleted += NavigationCompleted;
      view.CoreWebView2.DocumentTitleChanged += TitleChanged;
      view.CoreWebView2.PermissionRequested += PermissionRequested;
      view.CoreWebView2.NewWindowRequested += NewWindowRequested;
      view.CoreWebView2.DownloadStarting += DownloadStarting;
      view.CoreWebView2.ProcessFailed += ProcessFailed;
    }
    private void NavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
      try { var address = BrowserModel.Address(args.Uri); if (!owner.navigationPermission(address)) args.Cancel = true; }
      catch (ArgumentException) { args.Cancel = true; }
    }
    private async void NavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
      if (!args.IsSuccess) { owner.visualHost.Failed(TabId, "This page could not load. Use Reload to try again."); return; }
      await ObserveAsync(sender);
    }
    private async void TitleChanged(CoreWebView2 sender, object args) => await ObserveAsync(sender);
    private async Task ObserveAsync(CoreWebView2 sender)
    {
      try { if (!disposed) await owner.recordMetadata(TabId, sender.Source, sender.DocumentTitle); }
      catch { owner.visualHost.Failed(TabId, "The browser window's details could not be saved."); }
    }
    private static void PermissionRequested(CoreWebView2 sender, CoreWebView2PermissionRequestedEventArgs args) => args.State = CoreWebView2PermissionState.Deny;
    private static void NewWindowRequested(CoreWebView2 sender, CoreWebView2NewWindowRequestedEventArgs args) => args.Handled = true;
    private static void DownloadStarting(CoreWebView2 sender, CoreWebView2DownloadStartingEventArgs args) => args.Cancel = true;
    private void ProcessFailed(CoreWebView2 sender, CoreWebView2ProcessFailedEventArgs args) => owner.visualHost.Failed(TabId, "This browser page stopped. Use Reload to try again.");
    public Task NavigateAsync(Uri address, CancellationToken cancellationToken = default) => owner.OnUiAsync(async () =>
    {
      cancellationToken.ThrowIfCancellationRequested(); ObjectDisposedException.ThrowIf(disposed, this);
      _ = BrowserModel.Address(address.AbsoluteUri); if (!owner.navigationPermission(address)) throw new IOException("This page is outside the browser's permission.");
      view.CoreWebView2.Navigate(address.AbsoluteUri); await Task.CompletedTask; return true;
    });
    public ValueTask ReloadAsync(bool bypassCache, CancellationToken cancellationToken) => new(owner.OnUiAsync(async () =>
    {
      cancellationToken.ThrowIfCancellationRequested(); ObjectDisposedException.ThrowIf(disposed, this);
      if (bypassCache) await view.CoreWebView2.CallDevToolsProtocolMethodAsync("Page.reload", "{\"ignoreCache\":true}"); else view.CoreWebView2.Reload(); return true;
    }));
    public Task<JsonElement> DevToolsAsync(string method, JsonElement arguments, CancellationToken cancellationToken = default) => owner.OnUiAsync(async () =>
    {
      cancellationToken.ThrowIfCancellationRequested(); ObjectDisposedException.ThrowIf(disposed, this);
      var text = await view.CoreWebView2.CallDevToolsProtocolMethodAsync(method, arguments.GetRawText()); using var result = JsonDocument.Parse(text); return result.RootElement.Clone();
    });
    public ValueTask<JsonElement> PerformAsync(BrowserPageAction action, JsonElement arguments, CancellationToken cancellationToken) => new(owner.OnUiAsync(async () =>
    {
      cancellationToken.ThrowIfCancellationRequested(); ObjectDisposedException.ThrowIf(disposed, this); return await owner.namedActions.PerformAsync(view, action, arguments, cancellationToken);
    }));
    public ValueTask DisposeAsync() => new(owner.OnUiAsync(async () =>
    {
      if (disposed) return true; disposed = true;
      view.CoreWebView2.NavigationStarting -= NavigationStarting; view.CoreWebView2.NavigationCompleted -= NavigationCompleted; view.CoreWebView2.DocumentTitleChanged -= TitleChanged;
      view.CoreWebView2.PermissionRequested -= PermissionRequested; view.CoreWebView2.NewWindowRequested -= NewWindowRequested; view.CoreWebView2.DownloadStarting -= DownloadStarting; view.CoreWebView2.ProcessFailed -= ProcessFailed;
      owner.visualHost.Detach(TabId, view); view.Close();
      if (options.PrivateStoreId is { } key) owner.environments.Remove(key);
      // Locked files are reported by storage cleanup and retried at next start;
      // never kill a browser process shared by another window/profile.
      await Task.CompletedTask; return true;
    }));
  }
}
