using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

// Login/install terminals are short lived and owned by their sheet. They never
// enter the session ledger or send a model prompt.
internal sealed class CliTerminalView : Grid, IAsyncDisposable
{
  private readonly WebView2 web = new() { DefaultBackgroundColor = Microsoft.UI.Colors.Transparent };
  private readonly CancellationTokenSource stop = new();
  private ITerminalProcess? process;
  private TerminalSize size = new(100, 26);
  private readonly TaskCompletionSource<int> finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public Task<int> Exited => finished.Task;
  public event Action? OutputChanged;
  internal bool OAuthReady { get; private set; }
  private string recent = "";
  private bool loaded;
  public CliTerminalView(ProcessLaunch launch, AppDataRoot root)
  {
    Children.Add(web);
    ActualThemeChanged += (_, _) => PostTheme();
    Loaded += async (_, _) =>
    {
      if (loaded) return;
      loaded = true;
      try
      {
        var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, Path.Combine(root.DirectoryPath, "login-webview"), null);
        await web.EnsureCoreWebView2Async(environment);
        stop.Token.ThrowIfCancellationRequested();
        var core = web.CoreWebView2;
        core.Settings.AreDevToolsEnabled = false; core.Settings.AreHostObjectsAllowed = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        core.SetVirtualHostNameToFolderMapping("login.deck.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "terminal"), CoreWebView2HostResourceAccessKind.DenyCors);
        core.NavigationStarting += (_, args) => args.Cancel = args.Uri != "https://login.deck.invalid/index.html";
        core.NewWindowRequested += (_, args) => args.Handled = true;
        core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
        core.DownloadStarting += (_, args) => args.Cancel = true;
        core.WebMessageReceived += async (sender, args) =>
        {
          if (args.Source != "https://login.deck.invalid/index.html" || stop.IsCancellationRequested) return;
          try
          {
            using var doc = JsonDocument.Parse(args.WebMessageAsJson); var message = doc.RootElement;
            switch (message.GetProperty("type").GetString())
            {
              case "ready":
                PostTheme();
                web.Focus(FocusState.Programmatic); Post(new { type = "focus" });
                process = await new ConPtyTerminalFactory().StartAsync(launch, size, stop.Token);
                _ = PumpAsync(); break;
              case "input" when process is not null:
                var text = message.GetProperty("data").GetString() ?? "";
                if (Encoding.UTF8.GetByteCount(text) <= 65536) await process.WriteAsync(Encoding.UTF8.GetBytes(text), stop.Token); break;
              case "resize":
                size = new(Math.Clamp(message.GetProperty("cols").GetInt32(), 20, 500), Math.Clamp(message.GetProperty("rows").GetInt32(), 5, 200));
                if (process is not null) await process.ResizeAsync(size, stop.Token); break;
              case "link":
                if (Uri.TryCreate(message.GetProperty("uri").GetString(), UriKind.Absolute, out var uri) && uri.Scheme == "https") await Windows.System.Launcher.LaunchUriAsync(uri); break;
              case "copy":
                var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(message.GetProperty("text").GetString() ?? ""); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); break;
              case "pasteRequest":
                var clipboard = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
                if (clipboard.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) Post(new { type = "paste", text = await clipboard.GetTextAsync() }); break;
            }
          }
          catch (Exception ex) when (ex is not OutOfMemoryException) { finished.TrySetException(new IOException("The AI’s terminal could not start. Try again.", ex)); }
        };
        core.NavigationCompleted += (_, args) => { if (!args.IsSuccess) finished.TrySetException(new IOException("The sign-in terminal could not load. Try again.")); };
        core.Navigate("https://login.deck.invalid/index.html");
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { finished.TrySetException(new IOException("The sign-in terminal could not open. Try again.", ex)); }
    };
  }
  private void PostTheme()
  {
    string Color(string key)
    {
      var brush = (Microsoft.UI.Xaml.Media.SolidColorBrush)ShellTheme.Resource(this, key);
      return $"#{brush.Color.R:X2}{brush.Color.G:X2}{brush.Color.B:X2}";
    }
    Post(new { type = "theme", theme = ActualTheme == ElementTheme.Dark ? "dark" : "light", background = Color("DeckCanvasBrush"), foreground = Color("DeckInkBrush") });
  }
  private void Post(object message) { if (!stop.IsCancellationRequested) web.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(message)); }
  private async Task PumpAsync()
  {
    try
    {
      var exit = process!.WaitForExitAsync(stop.Token);
      var finish = FinishAsync();
      async Task FinishAsync()
      {
        try
        {
          var code = await exit;
          // Login state follows the CLI, not a browser child that may stay open.
          finished.TrySetResult(code);
          if (process is ConPtyProcess console) await console.FinishAsync(stop.Token);
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
      }
      var decoder = Encoding.UTF8.GetDecoder();
      await foreach (var bytes in process!.ReadOutputAsync(stop.Token))
      {
        var chars = new char[Encoding.UTF8.GetMaxCharCount(bytes.Length)];
        var count = decoder.GetChars(bytes.Span, chars, false);
        var text = new string(chars, 0, count);
        recent = (recent + text); if (recent.Length > 32768) recent = recent[^32768..];
        OAuthReady |= recent.Contains("/oauth/authorize", StringComparison.OrdinalIgnoreCase) || recent.Contains("auth.openai.com", StringComparison.OrdinalIgnoreCase) || recent.Contains("accounts.google.com/o/oauth", StringComparison.OrdinalIgnoreCase);
        Post(new { type = "data", data = text }); OutputChanged?.Invoke();
      }
      await finish; finished.TrySetResult(await exit);
    }
    catch (OperationCanceledException) { finished.TrySetCanceled(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { finished.TrySetException(new IOException("The AI’s terminal ended. Try again.", ex)); }
  }
  public async ValueTask DisposeAsync()
  {
    stop.Cancel(); recent = "";
    if (process is not null) { await process.QuitAsync(); await process.DisposeAsync(); }
    web.Close();
  }
}
