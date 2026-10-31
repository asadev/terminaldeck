using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

internal sealed record BrowserShellIdentity(string? Favicon, bool Loading, string Status, string Binding, string Address);

public sealed partial class BrowserPane
{
  private readonly HashSet<string> identityObserved = [];
  internal BrowserShellIdentity? ShellIdentity(string id)
  {
    var tab = tabs.FirstOrDefault(t => t.Id == id); if (tab is null) return null;
    if (identityObserved.Add(id) && tab.View.CoreWebView2 is { } core)
    {
      core.FaviconChanged += (_, _) => ShellChanged?.Invoke();
      core.NavigationStarting += (_, _) => DispatcherQueue.TryEnqueueHandled(() => ShellChanged?.Invoke());
    }
    var saved = Core.Read().Tabs.FirstOrDefault(t => t.Id == id);
    var favicon = tab.View.CoreWebView2?.FaviconUri;
    if (!Uri.TryCreate(favicon, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http")) favicon = null;
    return new(favicon, tab.Loading, tab.Status, saved?.SessionSlot ?? saved?.Window ?? "", tab.Address);
  }
}
