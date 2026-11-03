using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class RemoteService
{
  private readonly WebLaunch webLaunch = new();
  // Installed by AppRuntime's existing workspace-grant owner before the host starts.
  public Action<string>? WebEnrolled { get; set; }
  public async Task<string?> OpenWebAsync(bool openBrowser = true)
  {
    await StartAsync();
    if (localWeb is null) throw new InvalidOperationException("A compatible web version is not bundled in this copy.");
    var url = localWeb.OpenUrl();
    if (!openBrowser) return url;
    try
    {
      // A local owner may consume an unopened URL; public tool replies and audits never include it.
      if (!await Windows.System.Launcher.LaunchUriAsync(new Uri(url)))
        throw new InvalidOperationException("Windows could not open your browser.");
      return null;
    }
    catch { webLaunch.Cancel(); throw; }
  }
}
