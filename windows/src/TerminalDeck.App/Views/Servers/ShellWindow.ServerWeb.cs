using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Servers;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  async Task IServerPageHost.OpenWebsiteAsync(string url)
  {
    if (!Uri.TryCreate(url, UriKind.Absolute, out var address) || address.Scheme is not ("http" or "https") || address.UserInfo.Length > 0)
      throw new ServerRefusal("Only this server's current HTTP or HTTPS website can open here.");
    Model.Page = ShellPage.Browser;
    await browser.PrepareShellAsync();
    var page = await browser.Core.OpenAsync(url);
    browser.ObserveShellPages(); SyncWindows(); windowState.Select(page.Id); RenderWindows();
  }
}
