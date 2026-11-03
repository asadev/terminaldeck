using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  private readonly ConcurrentDictionary<string, (string Transfer, CancellationTokenSource Stop)> uploads = new();
  public async Task<JsonElement> UploadAsync(string computer, string path, string? folder, CancellationToken ct)
  {
    RequireCapability(computer, "upload");
    path = Path.GetFullPath(path);
    var parts = path.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
    if (parts.Any(p => p.Equals(".ssh", StringComparison.OrdinalIgnoreCase) || p.Equals(".aws", StringComparison.OrdinalIgnoreCase) || p.Equals(".gnupg", StringComparison.OrdinalIgnoreCase) || p.Equals(".azure", StringComparison.OrdinalIgnoreCase) || p.Equals(".kube", StringComparison.OrdinalIgnoreCase) || p.Equals(".codex", StringComparison.OrdinalIgnoreCase) || p.Equals(".claude", StringComparison.OrdinalIgnoreCase) || p.Equals(".gemini", StringComparison.OrdinalIgnoreCase)) || Path.GetFileName(path).StartsWith(".env", StringComparison.OrdinalIgnoreCase)) throw new UnauthorizedAccessException("Credential files cannot be sent.");
    for (var ancestor = new FileInfo(path).Directory; ancestor is not null; ancestor = ancestor.Parent)
      if (ancestor.LinkTarget is not null || (ancestor.Attributes & FileAttributes.ReparsePoint) != 0) throw new UnauthorizedAccessException("Choose a file under a real folder, without a link or junction.");
    if (new[] { ".pem", ".p12", ".pfx", ".key", ".kdbx" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase)) throw new UnauthorizedAccessException("Credential files cannot be sent.");
    var fileInfo = new FileInfo(path);
    if (fileInfo.LinkTarget is not null || fileInfo.Length is < 1 or > 536870912) throw new ArgumentException("Choose a regular file between 1 byte and 512 MB.");
    using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct, lifetime.Token);
    var transfer = Guid.NewGuid().ToString("N");
    if (!uploads.TryAdd(computer, (transfer, stop))) throw new InvalidOperationException("Finish or cancel this computer's current upload first.");
    try
    {
      await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 24576, FileOptions.Asynchronous | FileOptions.SequentialScan);
      var size = file.Length;
      var begin = new JsonObject { ["name"] = Path.GetFileName(path), ["size"] = size };
      if (!string.IsNullOrEmpty(folder)) begin["dir"] = folder;
      await RequestAsync(computer, "upload", "upload.begin", begin, ["upload.ready"], stop.Token, "id", transfer);
      using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
      var buffer = new byte[24576]; long sent = 0;
      while (sent < size)
      {
        var amount = await file.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, size - sent)), stop.Token);
        if (amount == 0) throw new IOException("The file changed before it could be sent.");
        hash.AppendData(buffer, 0, amount);
        var ack = await RequestAsync(computer, "upload", "upload.data", new() { ["data"] = Convert.ToBase64String(buffer, 0, amount) }, ["upload.ack"], stop.Token, "id", transfer);
        if (!ack.TryGetProperty("bytes", out var bytes) || bytes.GetInt32() != amount) throw new IOException("The receiver acknowledged the wrong number of bytes.");
        sent += amount;
      }
      var digest = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
      var receipt = await RequestAsync(computer, "upload", "upload.end", new() { ["sha256"] = digest }, ["upload.done"], stop.Token, "id", transfer);
      if (receipt.GetProperty("bytes").GetInt64() != size || !string.Equals(Text(receipt, "sha256", ""), digest, StringComparison.OrdinalIgnoreCase)) throw new IOException("The upload receipt did not match the sent file.");
      return receipt;
    }
    catch
    {
      try { await SendAsync(computer, new { t = "upload.cancel", id = transfer }); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
      throw;
    }
    finally { uploads.TryRemove(computer, out _); }
  }
  public void CancelUpload(string computer) { if (uploads.TryGetValue(computer, out var upload)) upload.Stop.Cancel(); }

  private sealed class Reach(string computer, string id, int remote, TcpListener listener, CancellationTokenSource stop)
  {
    public readonly string Computer = computer, Id = id;
    public readonly int Remote = remote;
    public readonly TcpListener Listener = listener;
    public readonly CancellationTokenSource Stop = stop;
  }
  private sealed class ReachStream(TcpClient socket, Reach reach)
  {
    public readonly TcpClient Socket = socket;
    public readonly Reach Reach = reach;
    public readonly SemaphoreSlim Credit = new(0, 1);
    public readonly SemaphoreSlim Writes = new(1, 1);
    public int Unacked;
  }
  private readonly ConcurrentDictionary<(string Computer, int Port), Reach> reaches = new();
  private readonly ConcurrentDictionary<(string Computer, string Channel), ReachStream> streams = new();
  public async Task<string> OpenPortAsync(string computer, int port, CancellationToken ct)
  {
    RequireCapability(computer, "localhost");
    if (port is < 1 or > 65535 || reaches.Count >= 16) throw new ArgumentException("Choose a valid port; at most 16 tunnels can be open.");
    if (reaches.TryGetValue((computer, port), out var existing)) return "http://127.0.0.1:" + ((IPEndPoint)existing.Listener.LocalEndpoint).Port + "/";
    var id = Guid.NewGuid().ToString("N");
    var reply = await RequestAsync(computer, "localhost", "tunnel.open", new() { ["port"] = port }, ["tunnel.opened"], ct, "id", id);
    if (reply.GetProperty("port").GetInt32() != port) throw new IOException("The computer opened a different port.");
    var listener = new TcpListener(IPAddress.Loopback, 0);
    try
    {
      listener.Start(16);
      var reach = new Reach(computer, id, port, listener, CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token));
      if (!reaches.TryAdd((computer, port), reach)) { listener.Stop(); await SendAsync(computer, new { t = "tunnel.close", id }, ct); return await OpenPortAsync(computer, port, ct); }
      _ = AcceptPortAsync(reach);
      return "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
    }
    catch { listener.Stop(); try { await SendAsync(computer, new { t = "tunnel.close", id }); } catch (Exception ex) when (ex is not OutOfMemoryException) { } throw; }
  }
  public async Task ClosePortAsync(string computer, int port)
  {
    if (!reaches.TryRemove((computer, port), out var reach)) return;
    reach.Stop.Cancel(); reach.Listener.Stop();
    foreach (var pair in streams.Where(s => ReferenceEquals(s.Value.Reach, reach))) DropStream(pair.Key);
    try { await SendAsync(computer, new { t = "tunnel.close", id = reach.Id }); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
  private void DropStream((string Computer, string Channel) key)
  {
    if (streams.TryRemove(key, out var stream)) { stream.Socket.Dispose(); try { stream.Credit.Release(); } catch (SemaphoreFullException) { } }
  }
  private async Task AcceptPortAsync(Reach reach)
  {
    try
    {
      while (!reach.Stop.IsCancellationRequested)
      {
        var socket = await reach.Listener.AcceptTcpClientAsync(reach.Stop.Token);
        if (streams.Count >= 64) { socket.Dispose(); continue; }
        var ch = Guid.NewGuid().ToString("N"); var stream = new ReachStream(socket, reach);
        streams[(reach.Computer, ch)] = stream;
        _ = PumpPortAsync(ch, stream);
      }
    }
    catch (Exception ex) when (ex is SocketException or OperationCanceledException or ObjectDisposedException) { }
  }
  private async Task PumpPortAsync(string ch, ReachStream stream)
  {
    var reach = stream.Reach;
    try
    {
      await SendAsync(reach.Computer, new { t = "net.open", ch, tunnel = reach.Id }, reach.Stop.Token);
      var buffer = new byte[24576];
      while (streams.ContainsKey((reach.Computer, ch)))
      {
        while (Volatile.Read(ref stream.Unacked) + buffer.Length > 262144) await stream.Credit.WaitAsync(TimeSpan.FromSeconds(60), reach.Stop.Token);
        var count = await stream.Socket.GetStream().ReadAsync(buffer, reach.Stop.Token);
        if (count == 0) break;
        Interlocked.Add(ref stream.Unacked, count);
        await SendAsync(reach.Computer, new { t = "net.data", ch, data = Convert.ToBase64String(buffer, 0, count) }, reach.Stop.Token);
      }
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { DropStream((reach.Computer, ch)); try { await SendAsync(reach.Computer, new { t = "net.close", ch }); } catch (Exception ex) when (ex is not OutOfMemoryException) { } }
  }
  private async Task HandlePortAsync(string computer, JsonElement frame)
  {
    var tag = Text(frame, "t", "");
    if (tag == "tunnel.closed") { foreach (var reach in reaches.Values.Where(r => r.Computer == computer && r.Id == Text(frame, "id", ""))) await ClosePortAsync(computer, reach.Remote); return; }
    var ch = Text(frame, "ch", ""); var key = (computer, ch);
    if (!streams.TryGetValue(key, out var stream)) return;
    try
    {
      if (tag == "net.close") { DropStream(key); return; }
      if (tag == "net.ack")
      {
        var amount = frame.GetProperty("bytes").GetInt32();
        if (amount <= 0 || amount > Volatile.Read(ref stream.Unacked)) { DropStream(key); return; }
        Interlocked.Add(ref stream.Unacked, -amount); try { stream.Credit.Release(); } catch (SemaphoreFullException) { } return;
      }
      if (tag != "net.data") return;
      var encoded = Text(frame, "data", ""); if (encoded.Length > 32768) { DropStream(key); return; }
      var bytes = Convert.FromBase64String(encoded); if (bytes.Length > 24576) { DropStream(key); return; }
      await stream.Writes.WaitAsync(stream.Reach.Stop.Token);
      try { await stream.Socket.GetStream().WriteAsync(bytes, stream.Reach.Stop.Token); }
      finally { stream.Writes.Release(); }
      if (bytes.Length > 0) await SendAsync(computer, new { t = "net.ack", ch, bytes = bytes.Length }, stream.Reach.Stop.Token);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { DropStream(key); }
  }
}
