using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Storage;
using TerminalDeck.App.Integration;
using System.Text;
using System.Text.Json;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class SessionPane : Grid
{
  private readonly SessionDraft draft;
  private readonly AppRuntime? runtime;
  private readonly CancellationTokenSource stop = new();
  private readonly AppDataRoot root;
  private readonly Action<string> notice;
  private WebView2? terminal;
  private bool disposed;
  private bool initialized;
  private bool replayReady;
  private (int Cols, int Rows)? lastSize;
  private readonly TaskCompletionSource ready = new();
  public Task Ready => ready.Task;
  public SessionDraft Draft => draft;
  internal FrameworkElement HeaderElement { get; private set; } = null!;

  public SessionPane(SessionDraft session, AppDataRoot dataRoot, Action<string> showNotice, Action close, AppRuntime? services = null)
  {
    draft = session; root = dataRoot; notice = ShowSessionNotice; runtime = services;
    RowSpacing = 0;
    RowDefinitions.Add(new() { Height = GridLength.Auto });
    RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    var header = new Grid { ColumnSpacing = 8, MinHeight = 48, Padding = new Thickness(16, 6, 16, 6) };
    HeaderElement = header;
    var surface = session.Presentation == SessionPresentation.Terminal ? WorkspacePaper.Terminal : WorkspacePaper.Page;
    this.SetResourceReference(BackgroundProperty, surface); header.SetResourceReference(BackgroundProperty, surface);
    if (surface == WorkspacePaper.Terminal) WorkspacePaper.ApplyInk(header);
    header.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var identity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    identity.Children.Add(new TextBlock { Text = session.Title, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
    header.Children.Add(identity);
    // The workspace supplies its own header; standalone panes keep the folder in info too.
    var info = new Button { Content = new DeckIcon { Glyph = "\uE946", FontSize = 14 }, Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"] };
    info.Flyout = new Flyout { Content = new StackPanel { Spacing = 8, MaxWidth = 400, Children = {
      new TextBlock { Text = "Project folder", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
      new TextBlock { Text = session.Folder, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
    } } };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(info, "Session info");
    ToolTipService.SetToolTip(info, "Session info");
    header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    SetColumn(info, 1); header.Children.Add(info);
    var closeButton = new Button { Content = session.IsLive ? "Stop session" : "Close draft", VerticalAlignment = VerticalAlignment.Center, MinHeight = 26, Height = 26, FontSize = 11, Padding = new Thickness(8, 2, 8, 2) };
    closeButton.Click += (_, _) => close();
    SetColumn(closeButton, 2); header.Children.Add(closeButton); Children.Add(header);
    var area = new Grid { Margin = new Thickness(0), CornerRadius = new CornerRadius(0), Style = (Style)Application.Current.Resources["SurfaceGridStyle"] };
    area.SetResourceReference(BackgroundProperty, surface);
    SetRow(area, 1); Children.Add(area);
    if (session.Presentation == SessionPresentation.Terminal) TerminalAppearanceBridge.Changed += TerminalAppearanceChanged;
    if (session.Presentation == SessionPresentation.Chat) { BuildChat(area); InitializeSessionNotices(area); }
    else
    {
      ActualThemeChanged += async (_, _) => await ApplyTerminalThemeAsync();
      terminal = new WebView2 { DefaultBackgroundColor = Microsoft.UI.Colors.Transparent }; BuildTerminalActions(area); area.Children.Add(terminal); InitializeSessionNotices(area);
      if (session.IsLive) { session.PropertyChanged += DraftStateChanged; ShowEnded(IsEnded); }
      Loaded += async (_, _) =>
      {
        if (initialized || disposed) return;
        initialized = true;
        try
        {
          var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, Path.Combine(root.DirectoryPath, "terminal-webview"), null);
          await terminal.EnsureCoreWebView2Async(environment);
          if (disposed) { terminal.Close(); return; }
          terminal.CoreWebView2.Settings.IsWebMessageEnabled = true;
          terminal.CoreWebView2.Settings.AreDevToolsEnabled = false;
          terminal.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
          terminal.CoreWebView2.SetVirtualHostNameToFolderMapping("terminal.deck.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "terminal"), CoreWebView2HostResourceAccessKind.DenyCors);
          terminal.CoreWebView2.NavigationStarting += (_, args) => args.Cancel = args.Uri != "https://terminal.deck.invalid/index.html";
          terminal.CoreWebView2.NewWindowRequested += (_, args) => args.Handled = true;
          terminal.CoreWebView2.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
          terminal.CoreWebView2.DownloadStarting += (_, args) => args.Cancel = true;
          terminal.CoreWebView2.Settings.AreHostObjectsAllowed = false;
          terminal.CoreWebView2.WebMessageReceived += async (sender, message) =>
          {
            if (message.Source != "https://terminal.deck.invalid/index.html" || disposed) return;
            try
            {
              using var doc = JsonDocument.Parse(message.WebMessageAsJson);
              var body = doc.RootElement;
              switch (body.GetProperty("type").GetString())
              {
                case "copy": CopyTerminalSelection(body.GetProperty("text").GetString() ?? ""); break;
                case "pasteRequest": await PasteClipboardAsync(); break;
                case "findRequest": OpenTerminalFind(); break;
                case "findNext": FindTerminal(body.TryGetProperty("previous", out var previous) && previous.GetBoolean()); break;
                case "findResult": TerminalFindResult(body); break;
                case "contextMenu": ShowTerminalMenu(); break;
                case "ready":
                  PostTerminalTheme();
                  ApplyCopyOnSelect();
                  // Focused while the page was still loading (a new tab): put the cursor in it now.
                  if (terminal is { FocusState: not FocusState.Unfocused }) Post(new { type = "focus" });
                  if (runtime is not null && draft.IsLive) _ = FollowAsync();
                  else ready.TrySetResult();
                  break;
                case "input" when runtime is not null && draft.IsLive:
                  if (ended || IsEnded) { ShowEnded(true); break; }
                  var text = body.GetProperty("data").GetString()!;
                  if (Encoding.UTF8.GetByteCount(text) <= 65536) await runtime.SendAsync(draft.Id, text);
                  break;
                case "resize" when runtime is not null && draft.IsLive:
                  var cols = Math.Clamp(body.GetProperty("cols").GetInt32(), 20, 500);
                  var rows = Math.Clamp(body.GetProperty("rows").GetInt32(), 5, 200);
                  lastSize = (cols, rows);
                  if (replayReady) await runtime.Keeper.ResizeAsync(draft.Id, new(cols, rows)); break;
                case "replayed" when runtime is not null && draft.IsLive:
                  replayReady = true;
                  await ApplyReplaySizeAsync(Math.Clamp(body.GetProperty("cols").GetInt32(), 20, 500), Math.Clamp(body.GetProperty("rows").GetInt32(), 5, 200)); break;
              }
            }
            catch (Exception ex) when (ex is not OutOfMemoryException) { TerminalActionFailed(ex); }
          };
          terminal.CoreWebView2.NavigationCompleted += (_, args) =>
          {
            if (!args.IsSuccess) ready.TrySetException(new IOException("The packaged terminal page could not load."));
          };
          await ApplyTerminalThemeAsync();
          terminal.CoreWebView2.Navigate("https://terminal.deck.invalid/index.html");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowSessionNotice("The terminal preview could not open. Close this draft and try again."); ready.TrySetException(new IOException("The terminal view could not start.")); }
      };
    }
  }

  private void BuildChat(Grid area)
  {
    area.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    area.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var intro = new StackPanel { Spacing = 12, Margin = new Thickness(32), VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 460 };
    intro.Children.Add(new TextBlock { Text = "What are we working on?", FontSize = 28, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
    intro.Children.Add(new TextBlock { Text = "Keep your first message here. Sending and streamed replies will be available when the chat service is connected.", TextWrapping = TextWrapping.Wrap, Opacity = 0.65 });
    area.Children.Add(intro);
    var compose = new StackPanel { Spacing = 12, Margin = new Thickness(24) };
    var input = new TextBox { PlaceholderText = "Write a message…", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 240 };
    input.SetBinding(TextBox.TextProperty, new Microsoft.UI.Xaml.Data.Binding { Source = draft, Path = new PropertyPath(nameof(SessionDraft.Message)), Mode = Microsoft.UI.Xaml.Data.BindingMode.TwoWay, UpdateSourceTrigger = Microsoft.UI.Xaml.Data.UpdateSourceTrigger.PropertyChanged });
    compose.Children.Add(input);
    var save = new Button { Content = "Keep draft", HorizontalAlignment = HorizontalAlignment.Right };
    save.Click += (_, _) => ShowSessionNotice("Message kept in this window. It has not been sent. The chat service is not connected yet.");
    compose.Children.Add(save); SetRow(compose, 1); area.Children.Add(compose);
  }
  internal async Task SetSurfaceThemeAsync(ElementTheme theme)
  {
    RequestedTheme = theme;
    if (terminal is not null) terminal.RequestedTheme = theme;
    await ApplyTerminalThemeAsync();
  }
  private async Task ApplyTerminalThemeAsync()
  {
    if (terminal?.CoreWebView2 is not { } core || disposed) return;
    var dark = ActualTheme == ElementTheme.Dark;
    try
    {
      PostTerminalTheme();
      terminal!.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
      core.Profile.PreferredColorScheme = dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
      await core.CallDevToolsProtocolMethodAsync("Emulation.setEmulatedMedia", System.Text.Json.JsonSerializer.Serialize(new { features = new[] { new { name = "prefers-color-scheme", value = dark ? "dark" : "light" } } }));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { ShowSessionNotice("The terminal theme could not update. Your draft is still available."); }
  }
  private void TerminalAppearanceChanged() => DispatcherQueue.TryEnqueue(PostTerminalTheme);
  private void PostTerminalTheme()
  {
    var configured = TerminalAppearanceBridge.Read(ActualTheme == ElementTheme.Dark);
    if (configured.ValueKind == JsonValueKind.Object) { Post(new { type = "appearance", appearance = configured }); return; }
    // Use the host's theme tokens for the web surface too; ANSI data keeps its palette.
    var background = (Microsoft.UI.Xaml.Media.SolidColorBrush)TerminalDeck.App.Shell.ShellTheme.Resource(this, WorkspacePaper.Terminal);
    var foreground = (Microsoft.UI.Xaml.Media.SolidColorBrush)TerminalDeck.App.Shell.ShellTheme.Resource(this, "DeckInkBrush");
    Post(new { type = "theme", theme = ActualTheme == ElementTheme.Dark ? "dark" : "light",
      background = $"#{background.Color.R:X2}{background.Color.G:X2}{background.Color.B:X2}",
      foreground = $"#{foreground.Color.R:X2}{foreground.Color.G:X2}{foreground.Color.B:X2}" });
  }
  private void Post(object message) => terminal?.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(message));
  private async Task FollowAsync()
  {
    while (!stop.IsCancellationRequested)
    {
      var generation = runtime!.KeeperGeneration;
      try
      {
        await using var attachment = await runtime!.Keeper.AttachAsync(draft.Id, stop.Token);
        replayReady = false;
        Post(new { type = "replay", data = attachment.Snapshot.Replay, cols = attachment.Snapshot.Session.ReplaySize?.Columns, rows = attachment.Snapshot.Session.ReplaySize?.Rows });
        ready.TrySetResult();
        ShowSessionNotice(""); ShowEnded(attachment.Snapshot.Session.State == TerminalDeck.Core.Sessions.SessionState.Exited);
        await foreach (var change in attachment.Events(stop.Token))
        {
          if (change.Kind == "data") Post(new { type = "data", data = change.Text });
          if (change.Kind == "reset") { replayReady = false; Post(new { type = "replay", data = change.Text ?? "", cols = change.ReplaySize?.Columns, rows = change.ReplaySize?.Rows }); }
          if (change.Kind is "exit" or "status" or "reset") await runtime.RefreshSessionsAsync();
        }
      }
      catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
      catch (Exception ex) when (ex is IOException or TimeoutException or InvalidOperationException)
      {
        UiRecovery.Log("Terminal attachment", ex);
        ShowSessionNotice("Reconnecting to this terminal…");
        try { await Task.Delay(1000, stop.Token); await runtime!.ReconnectAsync(generation); await runtime.RefreshSessionsAsync(); }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
        catch (Exception retry) when (retry is IOException or TimeoutException) { }
      }
    }
  }
  // Rebuild at the source's recorded grid, then apply only the viewport's
  // actual fitted grid. No temporary shrink/restore can scramble a prompt.
  private async Task ApplyReplaySizeAsync(int cols, int rows)
  {
    var (finalCols, finalRows) = lastSize ?? (cols, rows);
    if (!stop.IsCancellationRequested) await runtime!.Keeper.ResizeAsync(draft.Id, new(finalCols, finalRows));
  }
  internal async Task<string> ScreenForProofAsync()
  {
    if (terminal?.CoreWebView2 is not { } core) throw new IOException();
    return await core.ExecuteScriptAsync("document.body.innerText");
  }
  internal async Task InputForProofAsync(string value)
  {
    var core = terminal!.CoreWebView2;
    await core.ExecuteScriptAsync("document.querySelector('.xterm-helper-textarea').focus()");
    await core.CallDevToolsProtocolMethodAsync("Input.insertText", JsonSerializer.Serialize(new { text = value }));
    await core.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", "{\"type\":\"keyDown\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13}");
    await core.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", "{\"type\":\"keyUp\",\"key\":\"Enter\",\"code\":\"Enter\",\"windowsVirtualKeyCode\":13}");
  }
  public void DisposeView() { TerminalAppearanceBridge.Changed -= TerminalAppearanceChanged; if (runtime is not null) runtime.General.Changed -= ApplyCopyOnSelect; draft.PropertyChanged -= DraftStateChanged; disposed = true; stop.Cancel(); terminal?.Close(); }

}
