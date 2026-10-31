using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.App.Services;

public sealed class WebViewBrowserSurface(WebView2 view, string id) : IBrowserSurface
{
  public string TabId { get; } = id;
  public Task NavigateAsync(Uri address, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    if (address.Scheme is not ("http" or "https") || !string.IsNullOrEmpty(address.UserInfo)) throw new ArgumentException("Only http and https pages can open here.");
    view.CoreWebView2.Navigate(address.AbsoluteUri);
    return Task.CompletedTask;
  }
  public async Task<JsonElement> DevToolsAsync(string method, JsonElement arguments, CancellationToken cancellationToken = default)
  {
    cancellationToken.ThrowIfCancellationRequested();
    var result = await view.CoreWebView2.CallDevToolsProtocolMethodAsync(method, arguments.GetRawText());
    using var document = JsonDocument.Parse(result);
    return document.RootElement.Clone();
  }
  public ValueTask DisposeAsync() { view.Close(); return ValueTask.CompletedTask; }
}
