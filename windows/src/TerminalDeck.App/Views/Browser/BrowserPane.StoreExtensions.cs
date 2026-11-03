using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Browser;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

public sealed class BrowserStoreExtensions(BrowserPane browser, Func<Func<Task>, Task> dispatch) : IStoreBrowserExtensions
{
  public async ValueTask<string> InstallAsync(string directory, CancellationToken ct)
  {
    string? id = null;
    await dispatch(async () => { ct.ThrowIfCancellationRequested(); id = await browser.InstallStoreExtensionAsync(directory, ct); });
    return id ?? throw new IOException("The browser could not install this extension.");
  }
  public async ValueTask RemoveAsync(string extensionId, CancellationToken ct) =>
    await dispatch(async () => { ct.ThrowIfCancellationRequested(); await browser.RemoveStoreExtensionAsync(extensionId, ct); });
}

public sealed partial class BrowserPane
{
  private async Task<T> WithStoreProfileAsync<T>(Func<CoreWebView2Profile, Task<T>> action, CancellationToken ct)
  {
    var current = tabs.FirstOrDefault(t => t.Profile.Id == BrowserModel.DefaultProfileId && !t.Isolated);
    if (current is not null) return await action(current.View.CoreWebView2.Profile);
    var options = new BrowserSurfaceOptions(Guid.NewGuid().ToString("N"), BrowserModel.DefaultProfileId, false, null);
    var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, storage.PathFor(options), new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = true });
    var view = new WebView2 { Width = 1, Height = 1, Opacity = 0, IsHitTestVisible = false, IsTabStop = false };
    SurfaceHost.Children.Add(view);
    try
    {
      var controller = environment.CreateCoreWebView2ControllerOptions(); controller.ProfileName = "Deck";
      await view.EnsureCoreWebView2Async(environment, controller); ct.ThrowIfCancellationRequested();
      return await action(view.CoreWebView2.Profile);
    }
    finally { SurfaceHost.Children.Remove(view); view.Close(); }
  }
  public Task<string> InstallStoreExtensionAsync(string directory, CancellationToken ct) => WithStoreProfileAsync(async profile =>
  {
    if (!File.Exists(Path.Combine(directory, "manifest.json"))) throw new IOException("This extension has no manifest.");
    var extension = await profile.AddBrowserExtensionAsync(Path.GetFullPath(directory)); ct.ThrowIfCancellationRequested(); return extension.Id;
  }, ct);
  public async Task RemoveStoreExtensionAsync(string id, CancellationToken ct) => await WithStoreProfileAsync(async profile =>
  {
    var extensions = await profile.GetBrowserExtensionsAsync(); ct.ThrowIfCancellationRequested();
    var extension = extensions.FirstOrDefault(e => e.Id == id);
    if (extension is not null) await extension.RemoveAsync(); return true;
  }, ct);
}
