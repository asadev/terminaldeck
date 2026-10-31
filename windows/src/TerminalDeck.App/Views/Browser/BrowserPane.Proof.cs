using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Browser;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private string? proofDownloads;
  private ContentDialog? BrowserDialogForProof;
  private async Task RunBrowserProofIfRequestedAsync()
  {
    if (Environment.GetEnvironmentVariable("TD_W12_BROWSER_PROOF") != "1") return;
    var directory = root.DirectoryPath;
    if (!directory.StartsWith(@"C:\TD\scratch\w12-browser-", StringComparison.OrdinalIgnoreCase) ||
      !File.Exists(Path.Combine(directory, ".w12-browser-proof"))) throw new IOException("Browser proof requires its explicitly marked scratch data folder.");
    var output = Path.Combine(directory, "proof"); Directory.CreateDirectory(output);
    proofDownloads = Path.Combine(directory, "downloads"); Directory.CreateDirectory(proofDownloads);
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool value) { (value ? passed : failed).Add(name); }
    void Stage(string name) => File.WriteAllText(Path.Combine(output, "stage.txt"), name);
    async Task Wait(Func<bool> condition)
    {
      var until = DateTimeOffset.UtcNow.AddSeconds(15);
      while (!condition()) { if (DateTimeOffset.UtcNow > until) throw new TimeoutException("Fixture event did not arrive."); await Task.Delay(50); }
    }
    try
    {
      await Task.Delay(1000);
      var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
      appWindow.MoveAndResize(new Windows.Graphics.RectInt32(-16000, -16000, 1240, 900));
      if (appWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) presenter.Restore(false);
      appWindow.Show(false);
      await using var server = new BrowserProofServer();
      var tab = selected!; ShellSelected?.Invoke(tab.Id);
      Stage("navigate-fixture"); await ExecuteTabAsync(tab, "navigate", server.Url); await Task.Delay(350);
      Check("real local fixture loaded", tab.Title == "W12 browser fixture");
      var panel = (Grid)ShellView(tab.Id); var frame = (FrameworkElement)RootFor(tab).Content;
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        frame.RequestedTheme = theme; await Task.Delay(250);
        await ProofFrameAsync(frame, tab, Path.Combine(output, "browser-" + theme.ToString().ToLowerInvariant() + ".png"));
      }
      Stage("inspect"); await InspectAsync(tab, true);
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "document.getElementById('target').click()" });
      await Wait(() => tab.Annotations.Count == 1);
      Check("Inspect captures a selector instead of opening DevTools", tab.Annotations[0].Selector == "#target");
      await ProofFrameAsync(frame, tab, Path.Combine(output, "annotations-dark.png"));
      await InspectAsync(tab, false);
      Stage("redaction");
      await using var foreign = new BrowserProofServer();
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "new Promise(resolve=>{const f=document.createElement('iframe');f.id='foreign';f.onload=()=>resolve(true);f.src=" + JsonSerializer.Serialize(foreign.Url + "frame") + ";document.body.append(f)})", awaitPromise = true, returnByValue = true });
      var mask = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = BrowserAutomation.HidePrivate, returnByValue = true });
      var visibility = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "({ordinary:getComputedStyle(document.getElementById('ordinary')).visibility,password:getComputedStyle(document.getElementById('password')).visibility,otp:getComputedStyle(document.getElementById('otp')).visibility,card:getComputedStyle(document.getElementById('card')).visibility,private:getComputedStyle(document.getElementById('private')).visibility,foreign:getComputedStyle(document.getElementById('foreign')).visibility,frameOrdinary:getComputedStyle(document.querySelector('iframe').contentDocument.getElementById('frameordinary')).visibility,framePassword:getComputedStyle(document.querySelector('iframe').contentDocument.getElementById('framepassword')).visibility})", returnByValue = true });
      var values = visibility.GetProperty("result").GetProperty("value");
      Check("ordinary form and readable-frame content stay visible", values.GetProperty("ordinary").GetString() == "visible" && values.GetProperty("frameOrdinary").GetString() == "visible");
      Check("password/card/OTP/private and readable-frame password are masked", new[] { "password", "otp", "card", "private", "foreign", "framePassword" }.All(k => values.GetProperty(k).GetString() == "hidden"));
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = BrowserAutomation.RestorePrivate });
      var capture = await CaptureAsync(tab); await File.WriteAllBytesAsync(Path.Combine(output, "redacted-page.png"), capture);
      Check("screenshot returns a real PNG", capture.Length > 1000 && capture[0] == 137 && capture[1] == 80);
      Stage("history"); await ExecuteTabAsync(tab, "navigate", server.Url + "next"); await Wait(() => Core.History(tab.Profile.Id).Any(v => v.Url.EndsWith("/next", StringComparison.Ordinal)));
      Check("profile history keeps exact visited URLs", Core.History(tab.Profile.Id).Any(v => v.Url == server.Url + "next"));
      await ExecuteTabAsync(tab, "back"); await Wait(() => tab.Address == server.Url);
      Check("Back returns to the previous real visit", tab.View.CoreWebView2.CanGoForward);
      Stage("size");
      foreach (var preset in BrowserViewport.Presets.Skip(1))
      {
        tab.Viewport = preset; await ApplyViewportAsync(tab);
        var viewport = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "({width:innerWidth,height:innerHeight})", returnByValue = true });
        var actual = viewport.GetProperty("result").GetProperty("value");
        Check(preset.Name + " dimensions", actual.GetProperty("width").GetInt32() == preset.Width && actual.GetProperty("height").GetInt32() == preset.Height);
      }
      tab.Viewport = BrowserViewport.Presets[2]; await ApplyViewportAsync(tab);
      await ProofFrameAsync(frame, tab, Path.Combine(output, "phone-dark.png"));
      tab.Viewport = BrowserViewport.Presets[0]; await ApplyViewportAsync(tab);
      Stage("find"); tab.FindText = "Fixture target"; await FindAsync(tab); Check("Find sees page text", tab.FindResult == "");
      tab.FindText = "no-such-w12-fixture-word"; await FindAsync(tab); Check("Find reports Not found", tab.FindResult == "Not found");
      Stage("record"); await ExecuteTabAsync(tab, "record"); await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "document.getElementById('target').click()" }); await Wait(() => tab.Steps.Count > 0); await ExecuteTabAsync(tab, "record");
      Check("Record keeps a semantic click and selector", tab.Steps.Any(s => s.Contains("click:", StringComparison.Ordinal)));
      await ProofFrameAsync(frame, tab, Path.Combine(output, "recorded-flow-dark.png"));
      Stage("download");
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "document.getElementById('download').click()" });
      await Wait(() => downloads.Any(d => d.Operation.State == CoreWebView2DownloadState.Completed));
      var downloaded = downloads.Single(d => d.Operation.State == CoreWebView2DownloadState.Completed);
      Check("download saves actual fixture bytes inside scratch", downloaded.Path.StartsWith(proofDownloads, StringComparison.OrdinalIgnoreCase) && await File.ReadAllTextAsync(downloaded.Path) == "w12-browser-download");
      Stage("downloads-panel");
      var downloadsPanel = ShowDownloadsAsync(tab); await Task.Delay(300);
      await ProofDialogFrameAsync(Path.Combine(output, "downloads-dark.png")); BrowserDialogForProof!.Hide(); await downloadsPanel;
      Stage("history-panel");
      var historyPanel = ShowHistoryAsync(tab); await Task.Delay(300);
      await ProofDialogFrameAsync(Path.Combine(output, "history-dark.png")); BrowserDialogForProof!.Hide(); await historyPanel;
      Stage("drawing-panel");
      tab.Drawing.Add(new(BrowserDrawTool.Box, [new(0.1, 0.1), new(0.7, 0.4)]));
      tab.Drawing.Add(new(BrowserDrawTool.Arrow, [new(0.2, 0.8), new(0.6, 0.3)]));
      tab.Drawing.Add(new(BrowserDrawTool.Text, [new(0.2, 0.5)], "Move this"));
      var drawingPanel = DrawAsync(tab); await Task.Delay(300); await ProofDialogFrameAsync(Path.Combine(output, "drawing-dark.png"));
      tab.Drawing.Clear(); BrowserDialogForProof!.Hide(); await drawingPanel;
      Stage("private-history"); var prior = Core.Read().History.Length;
      var privateTab = await Core.OpenAsync(server.Url + "private", true); await Task.Delay(200);
      Check("private navigation leaves no history", Core.Read().History.Length == prior && Core.History("default").All(v => !v.Url.EndsWith("/private", StringComparison.Ordinal)));
      await Core.CloseAsync(privateTab.Id); await Core.SelectAsync(tab.Id); Present(tab);
      Stage("failed-page");
      await ExecuteTabAsync(tab, "navigate", "http://127.0.0.1:1/");
      Check("failed navigation keeps a recoverable tab", tab.Failed && Core.Read().Tabs.Any(t => t.Id == tab.Id));
      await ProofFrameAsync(frame, tab, Path.Combine(output, "error-page-dark.png"));
      await ExecuteTabAsync(tab, "navigate", server.Url); Check("failed page can recover to a working URL", !tab.Failed);
      Stage("store-switch");
      var profile = await Core.CreateProfileAsync("Fixture Work"); var retained = ShellView(tab.Id);
      await SwitchStoreAsync(tab, profile.Id, false); var replacement = tabs.Single(t => t.Id == tab.Id);
      Check("profile switch retains one logical window and shell view", replacement.Profile.Id == profile.Id && ReferenceEquals(retained, ShellView(tab.Id)));
      Stage("self-close");
      var closing = await Core.OpenAsync(server.Url + "close"); var closingTab = tabs.Single(t => t.Id == closing.Id);
      await GuardAsync(async () => { await closingTab.Model.CommandAsync("Page.close", new { }); }, closingTab); await Wait(() => !Core.Read().Tabs.Any(t => t.Id == closing.Id));
      Check("page self-close removes its tab", !tabs.Any(t => t.Id == closing.Id));
      Stage("complete");
    }
    catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(error.ToString()); }
    finally
    {
      var result = new { at = DateTimeOffset.UtcNow, commit = Environment.GetEnvironmentVariable("TD_W12_BROWSER_COMMIT"), passed, failed, passCount = passed.Count, failCount = failed.Count, output, scratch = directory };
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
      Application.Current.Exit();
    }
  }
  private async Task ProofDialogFrameAsync(string path)
  {
    var dialog = BrowserDialogForProof ?? throw new InvalidOperationException("The scratch dialog did not open.");
    dialog.UpdateLayout(); var content = (FrameworkElement)dialog.Content;
    await File.WriteAllBytesAsync(path, await RenderPngAsync(content, (int)content.ActualWidth, (int)content.ActualHeight));
  }
  private static async Task ProofFrameAsync(FrameworkElement frame, BrowserTab tab, string path)
  {
    frame.UpdateLayout();
    if (tab.View.Parent is not Panel parent) throw new InvalidOperationException("The fixture WebView has no panel parent.");
    using var stream = new InMemoryRandomAccessStream(); await tab.View.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, stream); stream.Seek(0);
    var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream);
    var image = new Image { Visibility = tab.View.Visibility, Source = bitmap, Stretch = Stretch.Fill, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
    var index = parent.Children.IndexOf(tab.View); parent.Children.RemoveAt(index); parent.Children.Insert(index, image);
    try { frame.UpdateLayout(); await File.WriteAllBytesAsync(path, await RenderPngAsync(frame, (int)frame.ActualWidth, (int)frame.ActualHeight)); }
    finally { parent.Children.Remove(image); parent.Children.Insert(index, tab.View); }
  }
}

internal sealed class BrowserProofServer : IAsyncDisposable
{
  private readonly TcpListener listener = new(IPAddress.Loopback, 0);
  private readonly CancellationTokenSource stopped = new();
  private readonly Task loop;
  public string Url { get; }
  public BrowserProofServer()
  {
    listener.Start(); Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/"; loop = ServeAsync();
  }
  private async Task ServeAsync()
  {
    try { while (!stopped.IsCancellationRequested) { var client = await listener.AcceptTcpClientAsync(stopped.Token); _ = ReplyAsync(client); } }
    catch (OperationCanceledException) { }
  }
  private async Task ReplyAsync(TcpClient client)
  {
    using (client)
    {
      try
      {
        await using var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
        var request = await reader.ReadLineAsync(stopped.Token); var path = request?.Split(' ').ElementAtOrDefault(1) ?? "/";
        while (!string.IsNullOrEmpty(await reader.ReadLineAsync(stopped.Token))) { }
        var download = path == "/download";
        var body = download ? "w12-browser-download" : path == "/frame" ? "<input id='frameordinary' value='frame ordinary'><input id='framepassword' type='password' value='synthetic'>" : path == "/next" ? "<title>Next fixture</title><h1>Next fixture</h1>" : """
<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>W12 browser fixture</title><style>body{font:16px system-ui;padding:32px;color-scheme:light dark;background:Canvas;color:CanvasText}input,textarea{display:block;margin:12px;padding:8px}button,a{margin:12px;padding:8px}iframe{display:block;width:400px;height:160px}</style></head><body><h1>Browser parity fixture</h1><button id="target">Fixture target</button><a id="next" href="/next">Next page</a><a id="download" href="/download">Download fixture</a><input id="ordinary" value="Ordinary form text stays visible"><textarea>Ordinary notes stay visible</textarea><input id="password" type="password" value="synthetic-password"><input id="otp" autocomplete="one-time-code" value="123456"><input id="card" autocomplete="cc-number" value="0000000000000000"><div id="private" data-private>Private synthetic text</div><iframe src="/frame"></iframe></body></html>
""";
        var bytes = Encoding.UTF8.GetBytes(body); var headers = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: " + (download ? "application/octet-stream\r\nContent-Disposition: attachment; filename=w12-browser.bin" : "text/html; charset=utf-8") + "\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(headers, stopped.Token); await stream.WriteAsync(bytes, stopped.Token);
      }
      catch (Exception error) when (error is IOException or OperationCanceledException) { }
    }
  }
  public async ValueTask DisposeAsync() { stopped.Cancel(); listener.Stop(); await loop; stopped.Dispose(); }
}
