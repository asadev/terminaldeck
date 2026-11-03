using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Proof;

internal static class Program
{
  [STAThread]
  private static void Main(string[] args)
  {
    ApplicationConfiguration.Initialize();
    if (args.Length != 4 || !Path.IsPathFullyQualified(args[0]) || !Path.IsPathFullyQualified(args[1])) return;
    Application.Run(new ProofWindow(AppDataRoot.Explicit(args[0]), args[1], args[2], args[3]));
  }
}
internal sealed class ProofWindow : Form, INativeBrowserHost, INativeBrowserActions
{
  private readonly AppDataRoot root;
  private readonly string evidence;
  private readonly string executable;
  private readonly string phase;
  private readonly Panel browserPanel = new() { Dock = DockStyle.Fill };
  private readonly TextBox terminalView = new() { Dock = DockStyle.Bottom, Height = 130, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical };
  private readonly Label status = new() { Dock = DockStyle.Top, Height = 44, Text = "Starting the Windows adapter checks…", Padding = new Padding(12) };
  private BrowserModel? model;
  private readonly CancellationTokenSource lifetime = new(TimeSpan.FromMinutes(5));
  public IntPtr ParentWindow => browserPanel.Handle;
  Rectangle INativeBrowserHost.Bounds => browserPanel.ClientRectangle;
  public ProofWindow(AppDataRoot root, string evidence, string executable, string phase)
  {
    this.root = root; this.evidence = evidence; this.executable = executable; this.phase = phase;
    Text = "Windows adapter proof — scratch data"; Width = 960; Height = 760;
    StartPosition = FormStartPosition.CenterScreen;
    Controls.Add(browserPanel); Controls.Add(terminalView); Controls.Add(status);
    Shown += async (_, _) =>
    {
      try { await RunAsync(); }
      catch (Exception ex) { File.WriteAllText(Path.Combine(evidence, phase + "-failed.json"), JsonSerializer.Serialize(new { error = ex.GetType().Name, message = ex.Message })); status.Text = "A check failed. See the evidence folder."; }
    };
    FormClosed += (_, _) => lifetime.Cancel();
  }
  public void Failed(string tabId, string message) => status.Text = message;
  public ValueTask<JsonElement> PerformAsync(CoreWebView2 page, BrowserPageAction action, JsonElement arguments, CancellationToken ct) => throw new InvalidOperationException("This proof does not enable browser toolbar actions.");
  private async Task RunAsync()
  {
    var ct = lifetime.Token;
    var client = await KeeperConnection.AttachAsync(root, executable, ct);
    var sessions = (await client.ListAsync(ct)).Sessions!;
    if (phase == "cleanup")
    {
      foreach (var session in sessions.Where(s => s.LeaseIdentity is not null)) await client.StopAsync(session.Definition.Id, ct);
      File.WriteAllText(Path.Combine(evidence, "cleanup.json"), "{\"sessionsStopped\":true}"); Close(); return;
    }
    var row = sessions.SingleOrDefault();
    if (row is null) row = (await client.CreateAsync(new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "App survival proof"), ct)).Session!;
    if (phase == "first") await client.WriteAsync(row.Definition.Id, Encoding.UTF8.GetBytes("echo W3_APP_SURVIVAL_MARKER\r"), ct);
    await using (var attachment = await client.AttachAsync(row.Definition.Id, ct))
    {
      var replay = new SessionReplay(); replay.Restore(attachment.Snapshot);
      if (!replay.Text.Contains("W3_APP_SURVIVAL_MARKER"))
        await foreach (var change in attachment.Events(ct)) { replay.Receive(change); if (replay.Text.Contains("W3_APP_SURVIVAL_MARKER")) break; }
      terminalView.Text = Strip(replay.Text);
      if (!replay.Text.Contains("W3_APP_SURVIVAL_MARKER")) throw new IOException("The marker is missing from scrollback.");
    }
    status.Text = "Terminal marker is still in scrollback. The worker stayed alive.";
    File.WriteAllText(Path.Combine(evidence, phase + "-ready.json"), JsonSerializer.Serialize(new { pid = Environment.ProcessId, hwnd = Handle.ToInt64(), sessionId = row.Definition.Id, lease = row.LeaseIdentity, markerSeen = true }));
    if (phase != "third") return;
    using var fixture = new Fixture();
    var storage = new WindowsBrowserProfileStorage(root);
    var factory = new NativeWebView2SurfaceFactory(this, storage, this, u => u.Host == "127.0.0.1" || u.AbsoluteUri == "about:blank",
      async (id, url, title) => { if (model is not null) await model.ObserveNavigationAsync(id, url, title, ct); });
    var tracking = new TrackingFactory(factory);
    model = new(new JsonStateStore<BrowserState>(root, "proof-browser"), tracking, storage);
    var one = await model.OpenAsync(fixture.Address + "one", cancellationToken: ct); await factory.PresentAsync(one.Id, ct);
    var original = await ReadyAsync(tracking.Pages[one.Id], ct);
    await EvaluateAsync(tracking.Pages[one.Id], "window.w3State='preserved'", ct);
    var two = await model.OpenAsync(fixture.Address + "two", cancellationToken: ct); await factory.PresentAsync(two.Id, ct);
    await ReadyAsync(tracking.Pages[two.Id], ct);
    await Task.Delay(1600, ct);
    var background = await EvaluateAsync(tracking.Pages[one.Id], "({loadId:window.loadId,ticks:window.ticks,state:window.w3State})", ct);
    await model.SelectAsync(one.Id, ct); await model.AttachAsync(one.Id, row.Definition.Id, ct); await model.AttachAsync(one.Id, null, ct); await model.AttachAsync(one.Id, row.Definition.Id, ct);
    using var alternate = new Panel { Width = 500, Height = 300 }; Controls.Add(alternate); _ = alternate.Handle;
    await factory.ReparentAsync(one.Id, alternate.Handle, alternate.ClientRectangle, ct);
    await factory.ReparentAsync(one.Id, browserPanel.Handle, browserPanel.ClientRectangle, ct); Controls.Remove(alternate);
    await factory.PresentAsync(one.Id, ct);
    var restored = await EvaluateAsync(tracking.Pages[one.Id], "({loadId:window.loadId,ticks:window.ticks,state:window.w3State})", ct);
    if (original.GetProperty("loadId").GetString() != background.GetProperty("loadId").GetString() || original.GetProperty("loadId").GetString() != restored.GetProperty("loadId").GetString() || restored.GetProperty("state").GetString() != "preserved" || background.GetProperty("ticks").GetInt32() < 1 || tracking.Pages.Count != 2)
      throw new IOException("A browser page reloaded or stopped in the background.");
    var screenshot = await tracking.Pages[one.Id].DevToolsAsync("Page.captureScreenshot", JsonSerializer.SerializeToElement(new { format = "png" }), ct);
    File.WriteAllBytes(Path.Combine(evidence, "browser-page.png"), Convert.FromBase64String(screenshot.GetProperty("data").GetString()!));
    status.Text = "Passed: app crash, keeper crash, two live browser pages, reattach without reload.";
    await Task.Delay(300, ct); CaptureWindow(Path.Combine(evidence, "proof-window.png"));
    File.WriteAllText(Path.Combine(evidence, "browser-proof.json"), JsonSerializer.Serialize(new { surfaces = 2, backgroundKeptAlive = true, sameDocumentAfterReattach = true, sameDocumentAfterReparent = true, statePreserved = true, fixtureRequests = fixture.Requests, source = "BrowserModel + native WebView2 adapter", phase }));
  }
  private static string Strip(string value) => System.Text.RegularExpressions.Regex.Replace(value, "\\x1B\\[[0-?]*[ -/]*[@-~]", "").Replace("\n", Environment.NewLine);
  private static async Task<JsonElement> ReadyAsync(IBrowserPage page, CancellationToken ct)
  {
    while (true)
    {
      var value = await EvaluateAsync(page, "({loadId:window.loadId,ticks:window.ticks})", ct);
      if (value.TryGetProperty("loadId", out var id) && id.ValueKind == JsonValueKind.String) return value;
      await Task.Delay(50, ct);
    }
  }
  private static async Task<JsonElement> EvaluateAsync(IBrowserPage page, string expression, CancellationToken ct)
  {
    var result = await page.DevToolsAsync("Runtime.evaluate", JsonSerializer.SerializeToElement(new { expression, returnByValue = true }), ct);
    return result.GetProperty("result").TryGetProperty("value", out var value) ? value.Clone() : JsonSerializer.SerializeToElement(new { });
  }
  private void CaptureWindow(string path)
  {
    using var bitmap = new Bitmap(Width, Height); using var graphics = Graphics.FromImage(bitmap); var dc = graphics.GetHdc();
    try { if (!PrintWindow(Handle, dc, 2)) throw new IOException("The proof window could not be captured."); }
    finally { graphics.ReleaseHdc(dc); }
    bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
  }
  [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
  private sealed class TrackingFactory(IBrowserSurfaceFactory factory) : IBrowserSurfaceFactory
  {
    public Dictionary<string, IBrowserPage> Pages { get; } = [];
    public async ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken ct)
    { var page = await factory.CreateAsync(options, ct); Pages.Add(options.TabId, page); return page; }
  }
  private sealed class Fixture : IDisposable
  {
    private readonly TcpListener listener = new(IPAddress.Loopback, 0); private readonly CancellationTokenSource closed = new();
    public string Address { get; }
    public int Requests;
    public Fixture()
    {
      listener.Start(); var port = ((IPEndPoint)listener.LocalEndpoint).Port;
      Address = $"http://127.0.0.1:{port}/";
      _ = Task.Run(async () =>
      {
        try
        {
          while (!closed.IsCancellationRequested)
          {
            using var client = await listener.AcceptTcpClientAsync(closed.Token); using var stream = client.GetStream();
            var header = new byte[8192]; var used = 0;
            while (used < header.Length)
            {
              var count = await stream.ReadAsync(header.AsMemory(used), closed.Token); if (count == 0) break; used += count;
              if (Encoding.ASCII.GetString(header, 0, used).Contains("\r\n\r\n")) break;
            }
            Interlocked.Increment(ref Requests);
            var html = "<!doctype html><meta charset=utf-8><title>Windows browser lifetime proof</title><style>body{font:22px system-ui;background:#f6f3ee;color:#222;padding:48px}h1{font-size:32px}.card{padding:24px;background:white;border-radius:20px}</style><h1>Browser stays alive</h1><div class=card>Same document after background, session reattach and window reparent.<p id=ticks>Starting timer…</p></div><script>window.loadId=crypto.randomUUID();window.ticks=0;setInterval(()=>document.querySelector('#ticks').textContent='Live timer: '+(++window.ticks),250)</script>";
            var bytes = Encoding.UTF8.GetBytes(html);
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n"), closed.Token);
            await stream.WriteAsync(bytes, closed.Token);
          }
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException or ObjectDisposedException or IOException) { }
      });
    }
    public void Dispose() { closed.Cancel(); listener.Stop(); closed.Dispose(); }
  }
}
