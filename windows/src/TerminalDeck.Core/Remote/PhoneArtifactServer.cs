using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Remote;

public sealed record PhoneArtifactHandle(int Port, string Secret, string Token, long Bytes, string Path, string Kind);

// The token names one indexed output, never a directory. Every HTTP read checks
// the requesting device again. The phone tunnels only this loopback listener.
public sealed class PhoneArtifactServer(IReceiverArtifacts artifacts, Func<string, string, bool> stillAllowed) : IDisposable
{
  private sealed record Entry(string Device, string Cwd, string Relative, string Secret, string Token, DateTimeOffset Until);
  private readonly object gate = new();
  private readonly Dictionary<string, Entry> entries = [];
  private readonly TcpListener listener = new(IPAddress.Loopback, 0);
  private readonly CancellationTokenSource lifetime = new();
  private readonly SemaphoreSlim requests = new(8, 8);
  private bool started;
  public int? Port { get { lock (gate) return started ? ((IPEndPoint)listener.LocalEndpoint).Port : null; } }
  public PhoneArtifactHandle Serve(string device, string cwd, string relative)
  {
    if (!stillAllowed(device, cwd)) throw new PhoneRefusal("unauthorized", "This output is no longer shared.");
    var preview = artifacts.Preview(cwd, relative);
    var path = preview.FilePath ?? preview.ImagePath ?? ReceiverArtifacts.SafePath(cwd, relative);
    var info = new FileInfo(path);
    var token = "#" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(relative))).ToLowerInvariant()[..16];
    lock (gate)
    {
      foreach (var key in entries.Where(e => e.Value.Until < DateTimeOffset.UtcNow).Select(e => e.Key).ToArray()) entries.Remove(key);
      if (entries.Count >= 128) throw new PhoneRefusal("unavailable", "Too many output previews are open. Close one first.");
      if (!started) { listener.Start(8); started = true; _ = AcceptAsync(); }
      var secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
      entries[secret + "/" + token] = new(device, cwd, relative, secret, token, DateTimeOffset.UtcNow.AddMinutes(15));
      return new(((IPEndPoint)listener.LocalEndpoint).Port, secret, token, info.Length, path, Kind(path));
    }
  }
  public void Forget(string device) { lock (gate) foreach (var key in entries.Where(e => e.Value.Device == device).Select(e => e.Key).ToArray()) entries.Remove(key); }
  private async Task AcceptAsync()
  {
    try
    {
      while (!lifetime.IsCancellationRequested)
      {
        var client = await listener.AcceptTcpClientAsync(lifetime.Token);
        if (!await requests.WaitAsync(0, lifetime.Token)) { client.Dispose(); continue; }
        _ = RespondAsync(client);
      }
    }
    catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException) { }
  }
  private async Task RespondAsync(TcpClient client)
  {
    using (client)
    using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token))
    {
      timeout.CancelAfter(TimeSpan.FromSeconds(30)); var ct = timeout.Token;
      try
      {
        var stream = client.GetStream(); var header = new List<byte>(); var one = new byte[1];
        while (header.Count < 8192 && await stream.ReadAsync(one, ct) == 1)
        { header.Add(one[0]); if (header.Count >= 4 && header[^4] == 13 && header[^3] == 10 && header[^2] == 13 && header[^1] == 10) break; }
        var lines = Encoding.ASCII.GetString(header.ToArray()).Split("\r\n"); var request = lines[0].Split(' ');
        if (request.Length != 3 || request[0] is not ("GET" or "HEAD") || !request[1].StartsWith('/')) { await Error(stream, 400, ct); return; }
        // Fragment-style artifact tokens are sent by the phones as URL path components.
        var parts = Uri.UnescapeDataString(request[1].Split('?')[0]).Trim('/').Split('/');
        Entry? entry; lock (gate) entries.TryGetValue(parts.Length >= 3 && parts[1] == "~" ? parts[0] + "/" + parts[2] : string.Join('/', parts.Take(2)), out entry);
        if (entry is null || entry.Until < DateTimeOffset.UtcNow || !stillAllowed(entry.Device, entry.Cwd)) { await Error(stream, 404, ct); return; }
        var preview = artifacts.Preview(entry.Cwd, entry.Relative);
        var path = preview.FilePath ?? preview.ImagePath ?? ReceiverArtifacts.SafePath(entry.Cwd, entry.Relative);
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
        long start = 0, end = file.Length - 1; var partial = false;
        var range = lines.FirstOrDefault(l => l.StartsWith("Range:", StringComparison.OrdinalIgnoreCase));
        if (range is not null)
        {
          var value = range[6..].Trim();
          if (!value.StartsWith("bytes=", StringComparison.Ordinal) || value.Contains(',')) { await Error(stream, 416, ct); return; }
          var bounds = value[6..].Split('-');
          if (bounds.Length != 2 || !long.TryParse(bounds[0], out start) || start < 0 || start >= file.Length ||
              bounds[1].Length > 0 && (!long.TryParse(bounds[1], out end) || end < start)) { await Error(stream, 416, ct); return; }
          end = Math.Min(end, file.Length - 1); partial = true;
        }
        var count = file.Length == 0 ? 0 : end - start + 1;
        var response = $"HTTP/1.1 {(partial ? "206 Partial Content" : "200 OK")}\r\nContent-Type: {Media(path)}\r\nContent-Length: {count}\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: sandbox allow-scripts; default-src 'self' data: blob:; connect-src 'none'\r\nConnection: close\r\n" + (partial ? $"Content-Range: bytes {start}-{end}/{file.Length}\r\n" : "") + "\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(response), ct);
        if (request[0] == "HEAD") return;
        file.Position = start; var buffer = new byte[65536];
        while (count > 0)
        {
          if (!stillAllowed(entry.Device, entry.Cwd)) return;
          var read = await file.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, count)), ct); if (read == 0) break;
          await stream.WriteAsync(buffer.AsMemory(0, read), ct); count -= read;
        }
      }
      catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or UnauthorizedAccessException or ArgumentException) { }
      finally { requests.Release(); }
    }
  }
  private static ValueTask Error(Stream stream, int code, CancellationToken ct) => stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {code} Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), ct);
  public static string Kind(string path) => Path.GetExtension(path).ToLowerInvariant() switch { ".html" or ".htm" or ".pdf" => "page", ".png" or ".jpg" or ".jpeg" or ".gif" or ".webp" or ".bmp" or ".svg" => "image", _ => "media" };
  public static string Media(string path) => Path.GetExtension(path).ToLowerInvariant() switch { ".html" or ".htm" => "text/html", ".pdf" => "application/pdf", ".png" => "image/png", ".jpg" or ".jpeg" => "image/jpeg", ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml", ".mp4" => "video/mp4", ".webm" => "video/webm", ".mp3" => "audio/mpeg", ".wav" => "audio/wav", _ => "application/octet-stream" };
  public void Dispose() { lifetime.Cancel(); listener.Stop(); lock (gate) entries.Clear(); lifetime.Dispose(); }
}
