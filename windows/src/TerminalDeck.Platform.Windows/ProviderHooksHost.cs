using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Hooks;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// This listener accepts only local, nonce-authenticated bounded observations.
// It cannot execute commands, update grants, or acknowledge provider approvals.
public sealed class ProviderHooksHost : IDisposable
{
  private readonly TcpListener listener = new(IPAddress.Loopback, 0);
  private readonly CancellationTokenSource stop = new();
  private readonly byte[] secret = RandomNumberGenerator.GetBytes(32);
  private readonly string endpointFile;
  private readonly string script;
  private readonly SemaphoreSlim slots = new(8, 8);
  public event Action<ProviderHookEvent>? Received;
  public int Port { get; }
  public ProviderHooksHost(AppDataRoot root)
  {
    var directory = Path.Combine(root.DirectoryPath, "hooks"); WindowsPrivateDirectory.Ensure(directory);
    endpointFile = Path.Combine(directory, "endpoint.json"); script = Path.Combine(directory, "send.ps1");
    listener.Start(8); Port = ((IPEndPoint)listener.LocalEndpoint).Port;
    File.WriteAllText(script, Script, new UTF8Encoding(false));
    File.WriteAllText(endpointFile, JsonSerializer.Serialize(new { port = Port, secret = Convert.ToBase64String(secret) }), new UTF8Encoding(false));
    _ = ListenAsync();
  }
  public ProviderHooks ForHomes(IReadOnlyDictionary<string, string> homes) => new(homes.ToDictionary(p => p.Key, p => p.Key == "gemini" ? Path.Combine(p.Value, ".gemini", "settings.json") : Path.Combine(p.Value, p.Key == "codex" ? "hooks.json" : "settings.json")),
    Path.Combine(Path.GetDirectoryName(script)!, "backups"), Command);
  public string Command(string provider, string eventName)
  {
    if (!ProviderHooks.Events.TryGetValue(provider, out var events) || !events.Contains(eventName)) throw new ArgumentException("Choose a known hook event.");
    static string Quote(string value) => "\"" + value.Replace("\"", "\"\"") + "\"";
    return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Endpoint " + Quote(endpointFile) +
      " -Provider " + provider + " -EventName " + eventName + " -DeckHook " + ProviderHooks.Marker;
  }
  private async Task ListenAsync()
  {
    try
    {
      while (!stop.IsCancellationRequested)
      {
        var client = await listener.AcceptTcpClientAsync(stop.Token);
        if (!await slots.WaitAsync(0, stop.Token)) { client.Dispose(); continue; }
        _ = ServeAsync(client);
      }
    }
    catch (Exception e) when (e is SocketException or OperationCanceledException or ObjectDisposedException) { }
  }
  private async Task ServeAsync(TcpClient client)
  {
    using (client)
    using (var limit = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
    {
      limit.CancelAfter(TimeSpan.FromSeconds(5)); var ct = limit.Token;
      try
      {
        var stream = client.GetStream(); var buffer = new byte[8192]; var count = 0; var end = -1;
        while (count < buffer.Length)
        {
          var read = await stream.ReadAsync(buffer.AsMemory(count, 1), ct); if (read == 0) return; count += read;
          if (count >= 4 && buffer[count - 4] == 13 && buffer[count - 3] == 10 && buffer[count - 2] == 13 && buffer[count - 1] == 10) { end = count; break; }
        }
        if (end < 0) return;
        var lines = Encoding.ASCII.GetString(buffer, 0, end).Split("\r\n"); var request = lines[0].Split(' ');
        if (request.Length != 3 || request[0] != "POST" || request[1] != "/hook" || lines.Any(l => l.StartsWith("Origin:", StringComparison.OrdinalIgnoreCase))) return;
        string? Header(string name) => lines.FirstOrDefault(l => l.StartsWith(name + ":", StringComparison.OrdinalIgnoreCase))?[(name.Length + 1)..].Trim();
        var presented = Header("X-Deck-Hook-Secret");
        byte[] received; try { received = Convert.FromBase64String(presented ?? ""); } catch (FormatException) { return; }
        if (!CryptographicOperations.FixedTimeEquals(received, secret) || !int.TryParse(Header("Content-Length"), out var length) || length is < 2 or > 65536) return;
        var payload = new byte[length]; await stream.ReadExactlyAsync(payload, ct);
        using var doc = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 24 }); var root = doc.RootElement;
        string? Text(string key) => root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: <= 4096 } s && !s.Any(char.IsControl) ? s : null;
        var provider = Text("provider"); var eventName = Text("event");
        if (provider is null || eventName is null || !ProviderHooks.Events.TryGetValue(provider, out var events) || !events.Contains(eventName)) return;
        var observation = new ProviderHookEvent(provider, eventName, Text("deckSession"), Text("conversation"), Text("folder"), DateTimeOffset.UtcNow);
        foreach (var callback in Received?.GetInvocationList() ?? []) try { ((Action<ProviderHookEvent>)callback)(observation); } catch (Exception) { }
        await stream.WriteAsync("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"u8.ToArray(), ct);
      }
      catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or JsonException or InvalidOperationException) { }
      finally { slots.Release(); }
    }
  }
  public void Dispose() { stop.Cancel(); listener.Stop(); CryptographicOperations.ZeroMemory(secret); stop.Dispose(); }
  private const string Script = """
param([string]$Endpoint,[string]$Provider,[string]$EventName,[string]$DeckHook)
$ErrorActionPreference='Stop'
try {
  $raw=[Console]::In.ReadToEnd()
  if($raw.Length -gt 60000){exit 0}
  $source=@{}
  if($raw.Trim().Length -gt 0){$source=$raw|ConvertFrom-Json}
  $destination=Get-Content -Raw -LiteralPath $Endpoint|ConvertFrom-Json
  $envelope=@{provider=$Provider;event=$EventName;deckSession=$env:DECK_SESSION_ID;conversation=$source.session_id;folder=$source.cwd}|ConvertTo-Json -Compress
  Invoke-WebRequest -UseBasicParsing -Method Post -Uri ('http://127.0.0.1:'+$destination.port+'/hook') -Headers @{'X-Deck-Hook-Secret'=$destination.secret} -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($envelope)) -TimeoutSec 3|Out-Null
}catch{}
exit 0
""";
}
