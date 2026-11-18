using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views.Computers;

// One live session, backed by the host's actual terminal or chat protocol.
// No duplicate local process or session-ledger row is created.
public sealed class RemoteSessionPane : Grid, IAsyncDisposable
{
  private readonly OtherComputersService service;
  private readonly string computer, session;
  private readonly WebView2 web = new() { DefaultBackgroundColor = Microsoft.UI.Colors.Transparent };
  private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
  private readonly CancellationTokenSource stop = new();
  private bool ready, started;
  private readonly RemoteChatPane? chatPane;
  private int cols = 120, rows = 30;
  public RemoteSessionPane(OtherComputersService service, string computer, string session)
  {
    this.service = service; this.computer = computer; this.session = session;
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    this.SetResourceReference(BackgroundProperty, "DeckCanvasBrush");
    var isChat = service.Services(computer).Sessions.Any(row => OtherComputersService.Text(row, "id", "") == session && row.TryGetProperty("chat", out var flag) && flag.ValueKind == JsonValueKind.True);
    Children.Add(new RemoteSessionHeader(service, computer, session, isChat, text => status.Text = text));
    status.FontSize = 12; status.Margin = new(16, 4, 16, 4); status.Visibility = Visibility.Collapsed;
    status.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) => status.Visibility = status.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed);
    Grid.SetRow(status, 1); Children.Add(status);
    if (isChat)
    {
      chatPane = new RemoteChatPane(service, computer, session, text => status.Text = text); Grid.SetRow(chatPane, 2); Children.Add(chatPane); return;
    }
    Grid.SetRow(web, 2); Children.Add(web);
    service.Frame += Received; service.Changed += Changed;
    Loaded += async (_, _) => { if (!started) { started = true; await StartAsync(); } };
    ActualThemeChanged += (_, _) => Post(new { type = "theme", theme = ActualTheme == ElementTheme.Dark ? "dark" : "light" });
  }
  private async Task StartAsync()
  {
    try
    {
      await web.EnsureCoreWebView2Async(); if (stop.IsCancellationRequested) return;
      var core = web.CoreWebView2;
      core.Settings.AreDevToolsEnabled = false; core.Settings.AreHostObjectsAllowed = false; core.Settings.AreDefaultContextMenusEnabled = false;
      core.SetVirtualHostNameToFolderMapping("remote-terminal.deck.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "terminal"), CoreWebView2HostResourceAccessKind.DenyCors);
      core.NavigationStarting += (_, e) => e.Cancel = e.Uri != "https://remote-terminal.deck.invalid/index.html";
      core.NewWindowRequested += (_, e) => e.Handled = true;
      core.DownloadStarting += (_, e) => e.Cancel = true;
      core.PermissionRequested += (_, e) => e.State = CoreWebView2PermissionState.Deny;
      core.WebMessageReceived += async (_, e) =>
      {
        if (e.Source != "https://remote-terminal.deck.invalid/index.html" || stop.IsCancellationRequested) return;
        try
        {
          using var doc = JsonDocument.Parse(e.WebMessageAsJson); var m = doc.RootElement;
          switch (m.GetProperty("type").GetString())
          {
            case "ready": ready = true; Post(new { type = "theme", theme = ActualTheme == ElementTheme.Dark ? "dark" : "light" }); await service.AttachAsync(computer, session, cols, rows, stop.Token); break;
            case "input":
              if (!service.List().Any(c => c.Id == computer && c.State == "Online")) { status.Text = "Reconnecting to that computer…"; break; }
              var text = m.GetProperty("data").GetString() ?? "";
              if (Encoding.UTF8.GetByteCount(text) > 65536) throw new ArgumentException("Paste at most 64 KB at once.");
              await service.SendAsync(computer, new { t = "input", id = session, data = text }, stop.Token); break;
            case "resize":
              cols = Math.Clamp(m.GetProperty("cols").GetInt32(), 20, 500); rows = Math.Clamp(m.GetProperty("rows").GetInt32(), 5, 200);
              if (ready) await service.SendAsync(computer, new { t = "resize", id = session, cols, rows }, stop.Token); break;
            case "copy": var package = new DataPackage(); package.SetText(m.GetProperty("text").GetString() ?? ""); Clipboard.SetContent(package); break;
            case "pasteRequest": var clip = Clipboard.GetContent(); if (clip.Contains(StandardDataFormats.Text)) Post(new { type = "paste", text = await clip.GetTextAsync() }); break;
            case "link": if (Uri.TryCreate(m.GetProperty("uri").GetString(), UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http") await Windows.System.Launcher.LaunchUriAsync(uri); break;
          }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = ex.Message; }
      };
      core.Navigate("https://remote-terminal.deck.invalid/index.html");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = "The remote terminal could not open: " + ex.Message; }
  }
  private void Changed() => DispatcherQueue.TryEnqueue(() => status.Text = service.List().FirstOrDefault(c => c.Id == computer)?.State == "Online" ? "" : "Reconnecting… Input resumes only after fresh access is granted.");
  private void Received(string id, JsonElement frame)
  {
    if (id != computer) return;
    if (OtherComputersService.Text(frame, "t", "") == "welcome")
    {
      DispatcherQueue.TryEnqueue(() => Post(new { type = "replay", data = "" }));
      return;
    }
    if (OtherComputersService.Text(frame, "id", "") != session) return;
    DispatcherQueue.TryEnqueue(() =>
    {
      if (stop.IsCancellationRequested) return;
      switch (OtherComputersService.Text(frame, "t", ""))
      {
        case "output": Post(new { type = "data", data = OtherComputersService.Text(frame, "data", "") }); break;
        case "exit": status.Text = "Session ended"; break;
        case "error": status.Text = OtherComputersService.Text(frame, "message", "The computer refused this action."); break;
      }
    });
  }
  private void Post(object value) { if (ready && !stop.IsCancellationRequested) web.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(value)); }
  public async ValueTask DisposeAsync()
  {
    stop.Cancel(); service.Frame -= Received; service.Changed -= Changed;
    if (chatPane is not null) { await chatPane.DisposeAsync(); return; }
    try { await service.DetachAsync(computer, session); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
    web.Close();
  }
}
