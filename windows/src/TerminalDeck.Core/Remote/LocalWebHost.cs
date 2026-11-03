using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Remote;

public sealed class LocalWebOffers(TimeProvider? clock = null)
{
  private readonly TimeProvider time = clock ?? TimeProvider.System;
  private readonly object gate = new();
  private readonly List<(byte[] Hash, DateTimeOffset Until)> offers = [];
  public string Create()
  {
    lock (gate)
    {
      offers.RemoveAll(o => o.Until <= time.GetUtcNow());
      while (offers.Count >= 16) offers.RemoveAt(0);
      var token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
      offers.Add((SHA256.HashData(Encoding.UTF8.GetBytes(token)), time.GetUtcNow().AddSeconds(60))); return token;
    }
  }
  public bool Consume(string token)
  {
    lock (gate)
    {
      offers.RemoveAll(o => o.Until <= time.GetUtcNow());
      if (token.Length != 43) return false;
      var digest = SHA256.HashData(Encoding.UTF8.GetBytes(token));
      var index = offers.FindIndex(o => CryptographicOperations.FixedTimeEquals(o.Hash, digest));
      if (index < 0) return false; offers.RemoveAt(index); return true;
    }
  }
  public void Cancel() { lock (gate) offers.Clear(); }
}

// HTTP/WebSocket on loopback only, with exact Host/Origin checks. A short-lived
// owner-issued fragment enrolls a browser; ordinary saved credentials reconnect.
public sealed class LocalWebHost : IAsyncDisposable
{
  private sealed class Peer(WebSocket socket, CancellationToken life)
  {
    public readonly WebSocket Socket = socket;
    public readonly SemaphoreSlim Writer = new(1, 1);
    public readonly CancellationToken Life = life;
    public int QueuedBytes;
  }
  private readonly string webRoot;
  private readonly DeviceTrust trust;
  private readonly PhoneTransportHub application;
  private readonly Action<string>? enrolled;
  private TcpListener listener;
  private readonly object startGate = new();
  private readonly CancellationTokenSource stop = new();
  private readonly ConcurrentDictionary<string, Peer> peers = [];
  private readonly ConcurrentDictionary<int, Task> clients = [];
  private readonly LocalWebOffers offers;
  private Task? running;
  private int nextClient;
  public int Port { get; private set; }
  public string Address => "http://localhost:" + Port + "/";
  public LocalWebHost(string root, DeviceTrust trust, PhoneTransportHub application, Action<string>? enrolled = null, TimeProvider? clock = null, int preferredPort = 0)
  { listener = new(IPAddress.Loopback, preferredPort); webRoot = Path.GetFullPath(root); this.trust = trust; this.application = application; this.enrolled = enrolled; offers = new(clock); }
  public static bool CompatibleBundle(string root)
  {
    try
    {
      var marker = Path.Combine(root, "build.json");
      if (!File.Exists(Path.Combine(root, "index.html")) || new FileInfo(marker).Length > 4096) return false;
      using var doc = JsonDocument.Parse(File.ReadAllBytes(marker));
      return doc.RootElement.GetProperty("client").GetString() == "terminaldeck-web" && doc.RootElement.GetProperty("bootstrap").GetInt32() == 1;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or KeyNotFoundException) { return false; }
  }
  public void Start()
  {
    lock (startGate)
    {
      if (running is not null) return;
      if (!CompatibleBundle(webRoot)) throw new InvalidOperationException("A compatible web version is not bundled in this copy.");
      try { listener.Start(32); }
      catch (SocketException) { listener = new(IPAddress.Loopback, 0); listener.Start(32); }
      Port = ((IPEndPoint)listener.LocalEndpoint).Port;
      application.SetLocalPublisher(PublishAsync); running = AcceptAsync();
    }
  }

  public string OpenUrl()
  {
    Start(); var token = offers.Create();
    return Address + "#pair=" + Uri.EscapeDataString(token) + "&endpoint=" + Uri.EscapeDataString("ws://localhost:" + Port + "/ws");
  }
  public bool AllowsHost(string value) => value == "localhost:" + Port || value == "127.0.0.1:" + Port;
  public bool AllowsOrigin(string? origin, string host) => origin is null || origin == "https://terminaldeck.app" || origin == "http://" + host;
  private bool LocalBootstrap(string? origin, string host) => host == "localhost:" + Port && origin == "http://" + host;
  private string Policy => "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; font-src 'self'; connect-src 'self' ws://localhost:" + Port + " ws://127.0.0.1:" + Port + " wss://relay.terminaldeck.dev; worker-src 'self' blob:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\n";
  private async Task AcceptAsync()
  {
    try
    {
      while (!stop.IsCancellationRequested)
      {
        var client = await listener.AcceptTcpClientAsync(stop.Token);
        if (clients.Count >= 64) { client.Dispose(); continue; }
        var id = Interlocked.Increment(ref nextClient);
        var task = ServeAsync(client); clients[id] = task;
        _ = task.ContinueWith(_ => clients.TryRemove(id, out var ignored), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
      }
    }
    catch (Exception ex) when (stop.IsCancellationRequested && ex is OperationCanceledException or SocketException or ObjectDisposedException) { }
  }
  private async Task ServeAsync(TcpClient client)
  {
    using (client)
    using (var life = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
    {
      string? channel = null; WebSocket? socket = null; var refusalCode = "unauthorized";
      try
      {
        var stream = client.GetStream(); using var headerDeadline = CancellationTokenSource.CreateLinkedTokenSource(life.Token); headerDeadline.CancelAfter(TimeSpan.FromSeconds(10));
        var request = await ReadHeadersAsync(stream, headerDeadline.Token);
        var first = request[0].Split(' '); var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in request.Skip(1).Where(l => l.Length > 0))
        {
          var colon = line.IndexOf(':'); if (colon < 1 || !headers.TryAdd(line[..colon].Trim(), line[(colon + 1)..].Trim())) throw new ProtocolException("Invalid HTTP headers.");
        }
        var host = headers.GetValueOrDefault("Host", "").ToLowerInvariant(); var origin = headers.GetValueOrDefault("Origin");
        if (first.Length != 3 || first[0] != "GET" || first[2] != "HTTP/1.1" || !AllowsHost(host) || !AllowsOrigin(origin, host)) { await HttpAsync(stream, 403, "text/plain", [], life.Token); return; }
        if (first[1] != "/ws") { await StaticAsync(stream, first[1], life.Token); return; }
        if (!headers.TryGetValue("Sec-WebSocket-Key", out var key) || Convert.FromBase64String(key).Length != 16 || headers.GetValueOrDefault("Sec-WebSocket-Version") != "13" ||
          !string.Equals(headers.GetValueOrDefault("Upgrade"), "websocket", StringComparison.OrdinalIgnoreCase) || !headers.GetValueOrDefault("Connection", "").Split(',').Any(s => s.Trim().Equals("upgrade", StringComparison.OrdinalIgnoreCase)))
          throw new ProtocolException("A valid WebSocket upgrade is required.");
        var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"), life.Token);
        socket = WebSocket.CreateFromStream(stream, true, null, TimeSpan.FromSeconds(30));
        channel = "local-web:" + Guid.NewGuid().ToString("N"); var peer = new Peer(socket, life.Token); peers[channel] = peer;
        byte[]? binding = null;
        while (!life.IsCancellationRequested && socket.State == WebSocketState.Open)
        {
          using var helloDeadline = CancellationTokenSource.CreateLinkedTokenSource(life.Token);
          if (binding is null) helloDeadline.CancelAfter(TimeSpan.FromSeconds(15));
          var bytes = await ReadMessageAsync(socket, helloDeadline.Token);
          if (bytes is null) break;
          using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 }); var message = document.RootElement;
          if (binding is null)
          {
            if (message.GetProperty("t").GetString() != "hello" || message.GetProperty("protocol").GetInt32() != 1 || message.GetProperty("device").GetProperty("platform").GetString() != "web") throw new ProtocolException("A browser hello is required.");
            var token = message.GetProperty("token").GetString() ?? "";
            if (!token.Contains('.'))
            {
              if (!LocalBootstrap(origin, host) || !offers.Consume(token)) throw new ProtocolException("The browser link expired or was already used. Open the web version again on this computer.");
              var receipt = trust.EnrollLocalWeb(message.GetProperty("device").GetProperty("name").GetString() ?? "Web browser");
              try { enrolled?.Invoke(receipt.DeviceId); } catch { trust.Revoke(receipt.DeviceId); throw; }
              await PublishAsync(channel, PhoneWire.PendingWelcome(receipt.DeviceId, receipt.DeviceName, receipt.Credential), life.Token);
              await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Paired. Reconnect with the browser's saved credential.", life.Token); break;
            }
            refusalCode = "unauthenticated";
            binding = trust.LocalWebBinding(token);
            refusalCode = "unauthorized";
          }
          var reply = await application.ReceiveAsync(channel, binding, bytes, life.Token);
          foreach (var raw in reply.Messages) await PublishAsync(channel, raw, life.Token);
          if (reply.Close) break;
        }
      }
      catch (Exception ex) when (ex is IOException or SocketException or WebSocketException or OperationCanceledException or ObjectDisposedException or ProtocolException or JsonException or FormatException or InvalidOperationException or KeyNotFoundException)
      {
        if (channel is not null && !life.IsCancellationRequested)
          try { await PublishAsync(channel, JsonSerializer.SerializeToUtf8Bytes(new { t = "error", code = refusalCode, message = ex is ProtocolException ? ex.Message : "This browser connection closed. Open the web version again." }), life.Token); } catch (Exception) { }
      }
      finally
      {
        if (socket is { State: WebSocketState.Open })
          try { using var closing = new CancellationTokenSource(TimeSpan.FromSeconds(2)); await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Connection closed.", closing.Token); } catch (Exception) { }
        socket?.Dispose(); life.Cancel();
        if (channel is not null) { peers.TryRemove(channel, out _); await application.DisconnectedAsync(channel); }
      }
    }
  }
  private async ValueTask PublishAsync(string channel, byte[] bytes, CancellationToken ct)
  {
    if (!peers.TryGetValue(channel, out var peer)) return;
    if (Interlocked.Add(ref peer.QueuedBytes, bytes.Length) > 2_000_000) { Interlocked.Add(ref peer.QueuedBytes, -bytes.Length); peer.Socket.Abort(); throw new IOException("Browser output queue full."); }
    try
    {
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct, peer.Life); deadline.CancelAfter(TimeSpan.FromSeconds(15));
      await peer.Writer.WaitAsync(deadline.Token);
      try { await peer.Socket.SendAsync(bytes, WebSocketMessageType.Text, true, deadline.Token); }
      finally { peer.Writer.Release(); }
    }
    finally { Interlocked.Add(ref peer.QueuedBytes, -bytes.Length); }
  }
  private async Task StaticAsync(NetworkStream stream, string requested, CancellationToken ct)
  {
    var path = Uri.UnescapeDataString(requested.Split('?')[0]);
    if (!path.StartsWith('/') || path.Contains('\\') || path.Contains('\0') || path.Split('/').Any(p => p is ".." or ".")) { await HttpAsync(stream, 403, "text/plain", [], ct); return; }
    var file = Path.GetFullPath(Path.Combine(webRoot, path.TrimStart('/')));
    if (!file.StartsWith(webRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && file != webRoot) { await HttpAsync(stream, 403, "text/plain", [], ct); return; }
    if (Directory.Exists(file)) file = Path.Combine(file, "index.html");
    if (!File.Exists(file) && !Path.HasExtension(path)) file = Path.Combine(webRoot, "index.html");
    if (!File.Exists(file) || new FileInfo(file).Length > 16_000_000) { await HttpAsync(stream, 404, "text/plain", [], ct); return; }
    // Bundles are app-owned, nevertheless reject links rather than serve outside the root.
    var current = new FileInfo(file) as FileSystemInfo;
    while (current is not null && current.FullName.Length >= webRoot.Length)
    { if ((current.Attributes & FileAttributes.ReparsePoint) != 0) { await HttpAsync(stream, 403, "text/plain", [], ct); return; } current = current is FileInfo f ? f.Directory : ((DirectoryInfo)current).Parent; }
    var type = Path.GetExtension(file).ToLowerInvariant() switch { ".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8", ".json" => "application/json", ".svg" => "image/svg+xml", ".png" => "image/png", ".woff2" => "font/woff2", ".ico" => "image/x-icon", _ => "application/octet-stream" };
    await HttpAsync(stream, 200, type, await File.ReadAllBytesAsync(file, ct), ct);
  }
  private async Task HttpAsync(NetworkStream stream, int code, string type, byte[] body, CancellationToken ct)
  {
    var header = Encoding.ASCII.GetBytes("HTTP/1.1 " + code + " " + (code == 200 ? "OK" : code == 404 ? "Not Found" : "Forbidden") + "\r\nContent-Type: " + type + "\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n" + Policy + "\r\n");
    await stream.WriteAsync(header, ct); await stream.WriteAsync(body, ct);
  }
  private static async Task<string[]> ReadHeadersAsync(NetworkStream stream, CancellationToken ct)
  {
    var bytes = new List<byte>(); var single = new byte[1];
    while (bytes.Count < 16_384)
    {
      if (await stream.ReadAsync(single, ct) != 1) throw new IOException("HTTP request ended."); bytes.Add(single[0]);
      var n = bytes.Count;
      if (n >= 4 && bytes[n-4] == 13 && bytes[n-3] == 10 && bytes[n-2] == 13 && bytes[n-1] == 10) return Encoding.ASCII.GetString(bytes.ToArray()).Split("\r\n");
    }
    throw new ProtocolException("HTTP headers too large.");
  }
  private static async Task<byte[]?> ReadMessageAsync(WebSocket socket, CancellationToken ct)
  {
    using var message = new MemoryStream(); var buffer = new byte[8192];
    do
    {
      var part = await socket.ReceiveAsync(buffer.AsMemory(), ct);
      if (part.MessageType == WebSocketMessageType.Close) return null;
      if (part.MessageType != WebSocketMessageType.Text || message.Length + part.Count > 65_536) throw new ProtocolException("Browser message too large or not text.");
      message.Write(buffer, 0, part.Count); if (part.EndOfMessage) return message.ToArray();
    } while (true);
  }
  public async ValueTask DisposeAsync()
  {
    offers.Cancel(); stop.Cancel(); listener.Stop(); foreach (var peer in peers.Values) peer.Socket.Abort();
    if (running is not null) await running;
    await Task.WhenAll(clients.Values); application.SetLocalPublisher(null); stop.Dispose();
  }
}
