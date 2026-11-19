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
  // 19 Nov free plan: a row read live from another computer (no Cloud copy); its connection, else null.
  private readonly string? liveConnection;
  private CancellationTokenSource life = new();
  private RemoteSessionPane? live;
  private bool opening, disposed;
  internal CloudSessionRoute(SidebarCloudRow row, AppRuntime runtime)
  {
    this.row = row; this.runtime = runtime; liveConnection = SidebarCloudRows.LiveConnection(row);
    Children.Add(First());
    Loaded += async (_, _) =>
    {
      if (disposed)
      {
        life.Dispose(); life = new(); disposed = false; opening = false; live = null;
        Children.Clear(); Children.Add(First());
      }
      runtime.ReachChanged += Changed; runtime.OtherComputers.Changed += Changed; await TryLiveAsync();
    };
    Unloaded += async (_, _) =>
    {
      disposed = true; life.Cancel(); runtime.ReachChanged -= Changed; runtime.OtherComputers.Changed -= Changed;
      var previous = live; if (previous is not null) await previous.DisposeAsync();
    };
  }
  private void Changed() => DispatcherQueue.TryEnqueue(async () => await TryLiveAsync());
  private bool Allowed() => liveConnection is null ? runtime.CloudServicesAllowed : runtime.RemoteSessionsAllowed;
  // The readable Cloud copy; a live row has none, so it says it is opening until the live session replaces it.
  private FrameworkElement First()
  {
    if (liveConnection is null) return new CloudAccessSurface(new CloudChatPage(row, () => runtime.CloudChatsDoor()), () => runtime.CloudServicesAllowed, h => runtime.Changed += h, h => runtime.Changed -= h);
    var opening = new TextBlock { Text = "Opening " + row.Name + " on " + row.MachineName + "\u2026", FontSize = 13, Margin = new(24), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    opening.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    return new CloudAccessSurface(opening, Allowed, h => runtime.Changed += h, h => runtime.Changed -= h);
  }
  private async Task TryLiveAsync()
  {
    if (!Allowed() || disposed || opening || live is not null || row.SessionId is not { Length: > 0 } session) return;
    opening = true;
    var epoch = life;
    try
    {
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(epoch.Token); deadline.CancelAfter(TimeSpan.FromSeconds(20));
      var computer = liveConnection is { } connection ? await OpenLiveAsync(connection, session, deadline.Token)
        : await runtime.OtherComputers.OpenCloudSessionAsync(session, row.MachineName, deadline.Token);
      if (computer is null || disposed || epoch.IsCancellationRequested || !ReferenceEquals(epoch, life)) return;
      var actual = runtime.OtherComputers.Services(computer).Sessions.FirstOrDefault(s => OtherComputersService.Text(s, "id", "") == session);
      if (OtherComputersService.Text(actual, "status", "") is "exited" or "ended" || TerminalDeck.Core.Computers.RemoteSessionReading.Field(actual, "exitCode").ValueKind == System.Text.Json.JsonValueKind.Number) return;
      live = new RemoteSessionPane(runtime.OtherComputers, computer, session) { RequestedTheme = ActualTheme };
      Children.Clear(); Children.Add(new CloudAccessSurface(live, Allowed, h => runtime.Changed += h, h => runtime.Changed -= h));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      // Keep the readable copy, including its title and rows, on failed reach.
      ToolTipService.SetToolTip(this, ex is OperationCanceledException ? "The live computer is not answering yet. This is its saved conversation." : ex.Message);
    }
    finally { if (ReferenceEquals(epoch, life)) opening = false; }
  }
  // A live row's own connection: connected again when it dropped, then the session must still be listed there.
  private async Task<string?> OpenLiveAsync(string connection, string session, CancellationToken ct)
  {
    var computers = runtime.OtherComputers;
    if (!computers.List().Any(c => c.Id == connection && c.State == "Online")) await computers.ConnectAsync(connection, ct);
    return computers.Services(connection).Sessions.Any(s => OtherComputersService.Text(s, "id", "") == session) ? connection : null;
  }
}
