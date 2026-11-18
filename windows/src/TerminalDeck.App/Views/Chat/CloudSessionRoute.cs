using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.App.Views.Computers;

namespace TerminalDeck.App.Views.Chat;

// Paint the readable copy immediately. Replace it only after a live host
// actually lists the same session id; the Cloud's presence flag is not proof.
internal sealed class CloudSessionRoute : Grid
{
  private readonly SidebarCloudRow row;
  private readonly AppRuntime runtime;
  private readonly CancellationTokenSource life = new();
  private RemoteSessionPane? live;
  private bool opening, disposed;
  internal CloudSessionRoute(SidebarCloudRow row, AppRuntime runtime)
  {
    this.row = row; this.runtime = runtime;
    Children.Add(new CloudAccessSurface(new CloudChatPage(row, () => runtime.CloudChatsDoor()), () => runtime.CloudServicesAllowed, h => runtime.Changed += h, h => runtime.Changed -= h));
    Loaded += async (_, _) =>
    {
      runtime.ReachChanged += Changed; runtime.OtherComputers.Changed += Changed; await TryLiveAsync();
    };
    Unloaded += async (_, _) =>
    {
      disposed = true; life.Cancel(); runtime.ReachChanged -= Changed; runtime.OtherComputers.Changed -= Changed;
      if (live is not null) await live.DisposeAsync();
    };
  }
  private void Changed() => DispatcherQueue.TryEnqueue(async () => await TryLiveAsync());
  private async Task TryLiveAsync()
  {
    if (!runtime.CloudServicesAllowed || disposed || opening || live is not null || row.SessionId is not { Length: > 0 } session) return;
    opening = true;
    try
    {
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(life.Token); deadline.CancelAfter(TimeSpan.FromSeconds(20));
      var computer = await runtime.OtherComputers.OpenCloudSessionAsync(session, row.MachineName, deadline.Token);
      if (computer is null || disposed) return;
      var actual = runtime.OtherComputers.Services(computer).Sessions.FirstOrDefault(s => OtherComputersService.Text(s, "id", "") == session);
      if (OtherComputersService.Text(actual, "status", "") is "exited" or "ended" || TerminalDeck.Core.Computers.RemoteSessionReading.Field(actual, "exitCode").ValueKind == System.Text.Json.JsonValueKind.Number) return;
      live = new RemoteSessionPane(runtime.OtherComputers, computer, session) { RequestedTheme = ActualTheme };
      Children.Clear(); Children.Add(new CloudAccessSurface(live, () => runtime.CloudServicesAllowed, h => runtime.Changed += h, h => runtime.Changed -= h));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      // Keep the readable copy, including its title and rows, on failed reach.
      ToolTipService.SetToolTip(this, ex is OperationCanceledException ? "The live computer is not answering yet. This is its saved conversation." : ex.Message);
    }
    finally { opening = false; }
  }
}
