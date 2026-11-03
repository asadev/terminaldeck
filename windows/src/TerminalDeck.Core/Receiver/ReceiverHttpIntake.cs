using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Receiver;

// No URL reservation, wildcard binding, cookies, CORS or filesystem paths.
// A browser extension needs a person-provisioned bearer token, kept outside
// tool results. Ordinary web pages cannot preflight this endpoint.
public sealed class ReceiverHttpIntake : IAsyncDisposable
{
  private readonly TcpListener listener;
  private readonly byte[] digest;
  private readonly IReceiver receiver;
  private readonly string sourceId;
  private readonly CancellationTokenSource lifetime = new();
  private readonly Task loop;
  public int Port { get; }
  public ReceiverHttpIntake(IReceiver receiver, string sourceId, string token, int port = 0)
  {
    if (token.Length is < 32 or > 256) throw new ArgumentException("Use a strong intake token.");
    this.receiver = receiver; this.sourceId = sourceId; digest = SHA256.HashData(Encoding.UTF8.GetBytes(token));
    listener = new(IPAddress.Loopback, port); listener.Start(8); Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    loop = ListenAsync();
  }
  public override string ToString() => "<Receiver local intake>";
  private async Task ListenAsync()
  {
    try
    {
      while (!lifetime.IsCancellationRequested)
      {
        using var client = await listener.AcceptTcpClientAsync(lifetime.Token);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try { await HandleAsync(client.GetStream(), timeout.Token); }
        catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or JsonException or ArgumentException) { }
      }
    }
    catch (Exception ex) when (ex is SocketException or OperationCanceledException or ObjectDisposedException) { }
  }
  private async Task HandleAsync(NetworkStream stream, CancellationToken ct)
  {
    var bytes = new List<byte>(); var one = new byte[1];
    while (bytes.Count < 8192)
    {
      if (await stream.ReadAsync(one, ct) == 0) return; bytes.Add(one[0]);
      if (bytes.Count >= 4 && bytes.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
    }
    var header = Encoding.ASCII.GetString(bytes.ToArray());
    if (!header.EndsWith("\r\n\r\n", StringComparison.Ordinal)) { await Reply(stream, 413, "Request too large", ct); return; }
    var lines = header.Split("\r\n"); var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    foreach (var line in lines.Skip(1).Where(l => l.Length > 0))
    {
      var colon = line.IndexOf(':');
      if (colon < 1 || !headers.TryAdd(line[..colon], line[(colon + 1)..].Trim())) { await Reply(stream, 400, "Invalid headers", ct); return; }
    }
    if (lines[0] != "POST /receive HTTP/1.1" || headers.GetValueOrDefault("Host") != $"127.0.0.1:{Port}" || headers.ContainsKey("Transfer-Encoding") ||
      headers.TryGetValue("Origin", out var origin) && !origin.StartsWith("chrome-extension://", StringComparison.Ordinal) && !origin.StartsWith("moz-extension://", StringComparison.Ordinal))
    { await Reply(stream, 403, "Request refused", ct); return; }
    var auth = headers.GetValueOrDefault("Authorization") ?? "";
    if (!auth.StartsWith("Bearer ", StringComparison.Ordinal) || auth.Length > 263 || !CryptographicOperations.FixedTimeEquals(digest, SHA256.HashData(Encoding.UTF8.GetBytes(auth[7..]))))
    { await Reply(stream, 401, "Authorization required", ct); return; }
    if (!headers.GetValueOrDefault("Content-Type", "").StartsWith("application/json", StringComparison.OrdinalIgnoreCase) || !int.TryParse(headers.GetValueOrDefault("Content-Length"), out var size) || size is < 2 or > 65536)
    { await Reply(stream, 413, "Use a small JSON request", ct); return; }
    var body = new byte[size]; await stream.ReadExactlyAsync(body, ct);
    try
    {
      using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 8 }); var value = document.RootElement;
      if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Any(p => p.Name is not ("title" or "text" or "url" or "externalId")) ||
        value.EnumerateObject().Select(p => p.Name).Distinct().Count() != value.EnumerateObject().Count()) throw new ArgumentException();
      string? S(string key) => value.TryGetProperty(key, out var field) ? field.GetString() : null;
      var item = receiver.Receive(new(sourceId, S("title") ?? "Shared from browser", S("text") ?? "", S("url"), ExternalId: S("externalId")));
      await Reply(stream, 202, "Saved to inbox: " + item.Id, ct);
    }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or JsonException) { await Reply(stream, 400, "The shared item could not be accepted", ct); }
    catch (IOException) { await Reply(stream, 429, "The inbox is full or busy", ct); }
  }
  private static async Task Reply(Stream stream, int status, string message, CancellationToken ct)
  {
    var body = JsonSerializer.SerializeToUtf8Bytes(new { message });
    var header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Receiver\r\nContent-Type: application/json\r\nContent-Length: {body.Length}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n");
    await stream.WriteAsync(header, ct); await stream.WriteAsync(body, ct);
  }
  public async ValueTask DisposeAsync()
  {
    lifetime.Cancel(); listener.Stop(); await loop; lifetime.Dispose(); CryptographicOperations.ZeroMemory(digest);
  }
}
