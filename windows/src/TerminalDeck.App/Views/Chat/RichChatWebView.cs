using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

// The parent page is our renderer. Untrusted visual/App code lives only in an
// opaque-origin sandboxed iframe, with no host objects or app credentials.
internal sealed class RichChatWebView : Grid
{
  private const string AssetsOrigin = "https://rich-chat.deck.invalid";
  private string html;
  private readonly Action<string> copy;
  private readonly Action<string> error;
  private readonly string dataDirectory;
  private readonly ChatMcpAppContent? app;
  private readonly Func<JsonElement, Task<JsonElement>>? rpc;
  private readonly Dictionary<string, int> frames = [];
  private readonly string token = Guid.NewGuid().ToString("N");
  private WebView2? web;
  private bool starting;
  private int generation;
  private readonly TextBlock pending = new() { Text = "Drawing message…", Opacity = 0.6, FontSize = 12 };
  internal RichChatWebView(string html, Action<string> copy, Action<string> error, string? dataDirectory = null,
    ChatMcpAppContent? app = null, Func<JsonElement, Task<JsonElement>>? rpc = null)
  {
    this.html = html; this.copy = copy; this.error = error; this.app = app; this.rpc = rpc;
    this.dataDirectory = dataDirectory ?? Path.Combine(Path.GetTempPath(), "deck-chat-preview");
    MinHeight = 40; HorizontalAlignment = HorizontalAlignment.Stretch;
    Children.Add(pending);
    EffectiveViewportChanged += async (_, args) => { if (args.EffectiveViewport.Width > 0 && args.EffectiveViewport.Height > 0) await StartAsync(); };
    Unloaded += (_, _) => { generation++; web?.Close(); web = null; starting = false; Children.Clear(); Children.Add(pending); };
    ActualThemeChanged += (_, _) => { ColorScheme(web?.CoreWebView2); Post(new { type = "theme", theme = Theme() }); };
  }
  // prefers-color-scheme inside messages and drawings follows the app's theme, not Windows' own setting.
  private void ColorScheme(CoreWebView2? core)
  {
    if (core is not null) core.Profile.PreferredColorScheme = ActualTheme == ElementTheme.Dark ? CoreWebView2PreferredColorScheme.Dark : CoreWebView2PreferredColorScheme.Light;
  }
  private Dictionary<string, string> StyleVariables()
  {
    string Color(string key)
    {
      var color = ((SolidColorBrush)ShellTheme.Resource(this, key)).Color;
      return FormattableString.Invariant($"rgba({color.R},{color.G},{color.B},{color.A / 255d})");
    }
    return new() { ["--color-background-primary"] = Color("DeckCanvasBrush"), ["--color-text-primary"] = Color("DeckInkBrush"), ["--color-text-secondary"] = Color("DeckSecondaryInkBrush"), ["--color-background-secondary"] = Color("DeckHoverBrush"), ["--color-text-link"] = Color("DeckProjectBlueBrush"), ["--font-sans"] = "Inter, Segoe UI, sans-serif" };
  }
  internal void UpdateHtml(string value)
  {
    if (html == value) return;
    html = value; Post(new { type = "content", html });
  }
  private object Theme()
  {
    string Color(string name)
    {
      var color = ((SolidColorBrush)ShellTheme.Resource(this, name)).Color;
      return FormattableString.Invariant($"rgba({color.R},{color.G},{color.B},{color.A / 255d})");
    }
    return new { dark = ActualTheme == ElementTheme.Dark, variables = StyleVariables(), colors = new Dictionary<string, string>
      { ["ink"] = Color("DeckInkBrush"), ["background"] = Color("DeckCanvasBrush"), ["tint"] = Color("DeckHoverBrush"), ["accent"] = Color("DeckProjectBlueBrush"), ["muted"] = Color("DeckSecondaryInkBrush") } };
  }
  private void Post(object value)
  {
    if (web?.CoreWebView2 is { } core) core.PostWebMessageAsJson(JsonSerializer.Serialize(value));
  }
  private async Task StartAsync()
  {
    if (starting || web is not null) return;
    starting = true; var ownGeneration = generation;
    var view = new WebView2 { DefaultBackgroundColor = Microsoft.UI.Colors.Transparent, MinHeight = 40, HorizontalAlignment = HorizontalAlignment.Stretch };
    web = view; Children.Add(view);
    try
    {
      var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, Path.Combine(dataDirectory, "rich-chat-webview"), null);
      var controller = environment.CreateCoreWebView2ControllerOptions();
      controller.ProfileName = "RichChat"; controller.IsInPrivateModeEnabled = true;
      await view.EnsureCoreWebView2Async(environment, controller);
      if (generation != ownGeneration) { view.Close(); return; }
      var core = view.CoreWebView2;
      core.Settings.AreHostObjectsAllowed = false;
      core.Settings.AreDevToolsEnabled = false;
      core.Settings.AreDefaultContextMenusEnabled = false;
      core.Settings.IsStatusBarEnabled = false;
      core.Settings.IsPasswordAutosaveEnabled = false;
      core.Settings.IsGeneralAutofillEnabled = false;
      core.Settings.IsWebMessageEnabled = true;
      ColorScheme(core);
      core.SetVirtualHostNameToFolderMapping("rich-chat.deck.invalid", Path.Combine(AppContext.BaseDirectory, "Assets", "chat"), CoreWebView2HostResourceAccessKind.Allow);
      core.NavigationCompleted += (_, args) => { if (args.IsSuccess && app is null) Post(new { type = "content", html }); };
      core.NavigationStarting += (_, args) => args.Cancel = args.Uri != "about:blank";
      core.FrameNavigationStarting += (_, args) => args.Cancel = args.Uri is not ("about:srcdoc" or "about:blank");
      core.NewWindowRequested += (_, args) => args.Handled = true;
      core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
      core.DownloadStarting += (_, args) => args.Cancel = true;
      core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
      core.WebResourceRequested += (_, args) =>
      {
        var allowed = Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var uri) &&
          (uri.Scheme is "data" or "blob" or "about" || uri.Scheme == "https" && uri.Host == "rich-chat.deck.invalid" ||
           uri.Scheme == "https" && uri.Host is "cdnjs.cloudflare.com" or "cdn.jsdelivr.net" && args.ResourceContext is CoreWebView2WebResourceContext.Script or CoreWebView2WebResourceContext.Stylesheet ||
           app is null && uri.Scheme is "https" or "http" && args.ResourceContext == CoreWebView2WebResourceContext.Image);
        if (!allowed) args.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "Content-Type: text/plain");
        args.Request.Headers.RemoveHeader("Cookie"); args.Request.Headers.RemoveHeader("Authorization");
      };
      core.WebMessageReceived += async (_, args) =>
      {
        if (generation != ownGeneration || args.Source != "about:blank") return;
        try
        {
          using var document = JsonDocument.Parse(args.WebMessageAsJson);
          var message = document.RootElement;
          if (ChatLineProtocol.S(message, "token") != token) return;
          switch (ChatLineProtocol.S(message, "type"))
          {
            case "size":
              if (message.TryGetProperty("height", out var size) && size.TryGetDouble(out var height) && double.IsFinite(height)) view.Height = Math.Clamp(height + 2, 40, 30000);
              pending.Visibility = Visibility.Collapsed; break;
            case "copy": copy(ChatLineProtocol.S(message, "text")); break;
            case "link": await OpenLinkAsync(ChatLineProtocol.S(message, "url"), false); break;
            case "app-frame" when app is not null: frames[ChatLineProtocol.S(message, "frame")] = 0; break;
            case "app-rpc" when app is not null:
              var frame = ChatLineProtocol.S(message, "frame");
              if (frames.ContainsKey(frame)) await AppRequestAsync(frame, ChatLineProtocol.P(message, "request"));
              break;
          }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { error("This message action could not finish. " + ex.Message); }
      };
      var payload = JsonSerializer.Serialize(new { html, app, token, theme = Theme(), maxVisualHeight = Math.Max(160, (XamlRoot?.Size.Height ?? 680) * 0.7) }, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
      var csp = "default-src 'none'; script-src 'unsafe-inline' " + AssetsOrigin + " https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; style-src 'unsafe-inline' " + AssetsOrigin + " https://cdnjs.cloudflare.com https://cdn.jsdelivr.net; img-src https: http: data: blob:; font-src data: " + AssetsOrigin + "; frame-src about: blob:; connect-src 'none'; base-uri 'none'; object-src 'none'; form-action 'none'";
      view.NavigateToString("<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"" + csp + "\"><meta name=\"referrer\" content=\"no-referrer\"><link rel=\"stylesheet\" href=\"" + AssetsOrigin + "/chat.css\"><link rel=\"stylesheet\" href=\"" + AssetsOrigin + "/katex/dist/katex.min.css\"><link id=\"code-theme\" rel=\"stylesheet\" href=\"" + AssetsOrigin + "/cdn-assets/styles/github.min.css\"><script id=\"payload\" type=\"application/json\">" + payload + "</script><main id=\"body\"></main>" +
        string.Join("", new[] { "dompurify/dist/purify.min.js", "cdn-assets/highlight.min.js", "katex/dist/katex.min.js", "mermaid/dist/mermaid.min.js", "chat.js" }.Select(file => "<script src=\"" + AssetsOrigin + "/" + file + "\"></script>")));
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { pending.Text = "This message could not be drawn. Use Copy to read its source."; error("The chat renderer could not start. " + ex.Message); }
    finally { starting = false; }
  }
  private async Task<bool> OpenLinkAsync(string target, bool confirm)
  {
    if (!ChatMarkdown.CanOpenLink(target)) return false;
    if (confirm)
    {
      var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Open this link?", Content = target, PrimaryButtonText = "Open", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
      if (await dialog.ShowAsync() != ContentDialogResult.Primary) return false;
    }
    return await Windows.System.Launcher.LaunchUriAsync(new Uri(target));
  }
  private async Task AppRequestAsync(string frame, JsonElement request)
  {
    var id = ChatLineProtocol.P(request, "id"); var method = ChatLineProtocol.S(request, "method");
    var parameters = ChatLineProtocol.P(request, "params");
    object result;
    try
    {
      if (method == "ui/initialize" && frames[frame] == 0)
      {
        frames[frame] = 1;
        result = new { protocolVersion = "2026-01-26", hostInfo = new { name = TerminalDeck.Core.Brand.Name, version = "1" }, hostCapabilities = new { serverTools = new { }, openLinks = new { } }, hostContext = new { theme = ActualTheme == ElementTheme.Dark ? "dark" : "light", displayMode = "inline", platform = "desktop", availableDisplayModes = new[] { "inline" }, containerDimensions = new { width = Math.Max(1, ActualWidth), maxHeight = Math.Max(160, (XamlRoot?.Size.Height ?? 680) * 0.7) }, styles = new { variables = StyleVariables() } } };
      }
      else if (method == "ui/notifications/initialized" && frames[frame] == 1)
      {
        frames[frame] = 2;
        Post(new { type = "rpc", frame, reply = new { jsonrpc = "2.0", method = "ui/notifications/tool-input", @params = new { arguments = app!.Input } } });
        Post(new { type = "rpc", frame, reply = new { jsonrpc = "2.0", method = "ui/notifications/tool-result", @params = app!.Result } }); return;
      }
      else if (method == "ui/notifications/size-changed") return;
      else if (frames[frame] != 2) throw new InvalidOperationException("Initialize this MCP App first.");
      else if (method == "tools/call" && rpc is not null) result = await rpc(parameters);
      else if (method == "ui/open-link") result = new { isError = !await OpenLinkAsync(ChatLineProtocol.S(parameters, "url"), true) };
      else if (method == "ping") result = new { };
      else throw new InvalidOperationException("This MCP App request is not supported.");
      if (id.ValueKind is JsonValueKind.String or JsonValueKind.Number) Post(new { type = "rpc", frame, reply = new { jsonrpc = "2.0", id, result } });
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    { if (id.ValueKind is JsonValueKind.String or JsonValueKind.Number) Post(new { type = "rpc", frame, reply = new { jsonrpc = "2.0", id, error = new { code = -32000, message = ex.Message } } }); }
  }
}
