using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// Byte streams terminate ONLY on loopback listeners. Port policy is supplied by
// the desktop composition, and is rechecked before every incoming/outgoing chunk.
public sealed class PhoneLocalhostFeatures(Func<ApprovedDevice, int, bool> permitted, Func<IReadOnlyList<int>>? reserved = null) : IPhoneHostWorkspace, IDisposable
{
  private sealed class StreamState(TcpClient socket, string tunnel, int port)
  {
    public readonly TcpClient Socket = socket;
    public readonly string Tunnel = tunnel;
    public readonly int Port = port;
    public readonly CancellationTokenSource Stop = new();
    public readonly SemaphoreSlim Writer = new(1, 1);
    public readonly object Gate = new();
    public int Unacked;
    public TaskCompletionSource? Credit;
  }
  private sealed class Connection(string deviceId)
  {
    public readonly string DeviceId = deviceId;
    public readonly object Gate = new();
    public readonly Dictionary<string, int> Tunnels = [];
    public readonly Dictionary<string, StreamState> Streams = [];
  }
  private readonly ConcurrentDictionary<string, Connection> connections = [];
  private Func<string, JsonObject, CancellationToken, ValueTask>? publish;
  private Func<string, ApprovedDevice?>? current;
  private volatile bool disposed;
  private int activeStreams;
  public IReadOnlyList<string> Capabilities => ["localhost"];
  public bool Handles(string type) => type is "ports" or "tunnel.open" or "tunnel.close" or "net.open" or "net.data" or "net.ack" or "net.close";
  public bool Permits(PhoneAccess access, string type) => access is PhoneAccess.Work or PhoneAccess.Full;
  public void Bind(Func<string, JsonObject, CancellationToken, ValueTask> publisher, Func<string, ApprovedDevice?> device) { publish = publisher; current = device; }
  private bool Allowed(ApprovedDevice device, int port) => (device.Access is PhoneAccess.Work or PhoneAccess.Full) && port is >= 1 and <= 65535 && !(reserved?.Invoke().Contains(port) ?? false) && permitted(device, port);
  private static IPEndPoint[] Listeners() => IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Where(p => IPAddress.IsLoopback(p.Address) || p.Address.Equals(IPAddress.Any) || p.Address.Equals(IPAddress.IPv6Any)).ToArray();
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    ObjectDisposedException.ThrowIf(disposed, this); ct.ThrowIfCancellationRequested();
    if (!Permits(device.Access, type)) { await DisconnectedAsync(channel); throw new PhoneRefusal("unauthorized", "Localhost connections need a granted Work session or Full control."); }
    if (type == "ports")
    {
      var rows = new JsonArray(Listeners().Select(p => p.Port).Distinct().Where(p => Allowed(device, p)).Order().Take(256)
        .Select(port => (JsonNode)new JsonObject { ["port"] = port, ["process"] = "Unknown process", ["guessed"] = true }).ToArray());
      return [new JsonObject { ["t"] = "ports", ["ports"] = rows }];
    }
    if (publish is null || current is null) throw new PhoneRefusal("unavailable", "Localhost streams are not connected to this device yet.");
    if (connections.Count >= 32 && !connections.ContainsKey(channel)) throw new PhoneRefusal("unavailable", "This PC has too many localhost connections.");
    var state = connections.GetOrAdd(channel, _ => new Connection(device.Id));
    if (state.DeviceId != device.Id) throw new PhoneRefusal("unauthorized", "This stream belongs to another device.");
    if (type == "tunnel.open")
    {
      var id = Id(message, "id"); var port = Whole(message, "port", 1, 65535);
      if (!Allowed(device, port) || !Listeners().Any(p => p.Port == port)) return [Closed(id, "That port is not offered by this PC.")];
      lock (state.Gate)
      {
        if (state.Tunnels.Count >= 4 || state.Tunnels.ContainsKey(id)) return [Closed(id, "Close an existing tunnel before opening another.")];
        state.Tunnels.Add(id, port);
      }
      return [new JsonObject { ["t"] = "tunnel.opened", ["id"] = id, ["port"] = port }];
    }
    if (type == "tunnel.close")
    {
      var id = Id(message, "id");
      lock (state.Gate) { state.Tunnels.Remove(id); foreach (var pair in state.Streams.Where(s => s.Value.Tunnel == id).ToArray()) Drop(state, pair.Key); }
      return [Closed(id, "Closed on the device.")];
    }
    var ch = Id(message, "ch");
    if (type == "net.open")
    {
      var tunnel = Id(message, "tunnel"); int port;
      lock (state.Gate)
      {
        if (!state.Tunnels.TryGetValue(tunnel, out port) || state.Streams.Count >= 16 || state.Streams.ContainsKey(ch)) return [NetClosed(ch)];
      }
      if (!Allowed(device, port)) return [NetClosed(ch)];
      TcpClient? socket = null;
      foreach (var address in new[] { IPAddress.Loopback, IPAddress.IPv6Loopback })
      {
        if (!Listeners().Any(p => p.Port == port && p.AddressFamily == address.AddressFamily)) continue;
        var candidate = new TcpClient(address.AddressFamily);
        try { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(5)); await candidate.ConnectAsync(address, port, timeout.Token); socket = candidate; break; }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException) { candidate.Dispose(); }
      }
      if (socket is null) return [NetClosed(ch)];
      if (Interlocked.Increment(ref activeStreams) > 64) { Interlocked.Decrement(ref activeStreams); socket.Dispose(); return [NetClosed(ch)]; }
      var stream = new StreamState(socket, tunnel, port);
      lock (state.Gate)
      {
        if (disposed || !state.Tunnels.ContainsKey(tunnel) || state.Streams.Count >= 16 || state.Streams.ContainsKey(ch) || current(channel)?.Id != device.Id || !Allowed(device, port))
        { Interlocked.Decrement(ref activeStreams); socket.Dispose(); stream.Stop.Dispose(); stream.Writer.Dispose(); return [NetClosed(ch)]; }
        state.Streams.Add(ch, stream);
      }
      _ = ReadAsync(channel, ch, state, stream);
      return [];
    }
    StreamState? target; lock (state.Gate) state.Streams.TryGetValue(ch, out target);
    if (target is null) return type == "net.close" ? [] : [NetClosed(ch)];
    if (type == "net.close") { lock (state.Gate) Drop(state, ch); return []; }
    if (!Allowed(device, target.Port)) { lock (state.Gate) Drop(state, ch); return [NetClosed(ch)]; }
    if (type == "net.ack")
    {
      var bytes = Whole(message, "bytes", 1, 262144);
      bool invalid;
      lock (target.Gate)
      {
        invalid = bytes > target.Unacked;
        if (!invalid) { target.Unacked -= bytes; target.Credit?.TrySetResult(); target.Credit = null; }
      }
      if (invalid) { lock (state.Gate) Drop(state, ch); return [NetClosed(ch)]; }
      return [];
    }
    if (type != "net.data") throw new PhoneRefusal("bad-message", "Unknown localhost action.");
    try
    {
      var encoded = Text(message, "data", 32768, empty: true);
      if (encoded.Length % 4 != 0 || encoded.Any(char.IsWhiteSpace)) throw new FormatException();
      var bytes = Convert.FromBase64String(encoded); if (bytes.Length > 24576) throw new FormatException();
      if (bytes.Length == 0) return [];
      await target.Writer.WaitAsync(ct);
      try { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct, target.Stop.Token); timeout.CancelAfter(TimeSpan.FromSeconds(30)); await target.Socket.GetStream().WriteAsync(bytes, timeout.Token); }
      finally { target.Writer.Release(); }
      return [new JsonObject { ["t"] = "net.ack", ["ch"] = ch, ["bytes"] = bytes.Length }];
    }
    catch (Exception ex) when (ex is FormatException or IOException or SocketException or OperationCanceledException or ObjectDisposedException)
    { lock (state.Gate) Drop(state, ch); return [NetClosed(ch)]; }
  }
  private async Task ReadAsync(string channel, string ch, Connection connection, StreamState stream)
  {
    try
    {
      var buffer = new byte[24576];
      while (!stream.Stop.IsCancellationRequested)
      {
        var device = current?.Invoke(channel);
        if (device is null || device.Id != connection.DeviceId || !Allowed(device, stream.Port)) break;
        Task? wait = null; int amount;
        lock (stream.Gate)
        {
          amount = Math.Min(buffer.Length, 262144 - stream.Unacked);
          if (amount <= 0) wait = (stream.Credit ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).Task;
        }
        if (wait is not null) { await wait.WaitAsync(TimeSpan.FromSeconds(60), stream.Stop.Token); continue; }
        var count = await stream.Socket.GetStream().ReadAsync(buffer.AsMemory(0, amount), stream.Stop.Token);
        if (count == 0) break;
        device = current?.Invoke(channel);
        if (device is null || device.Id != connection.DeviceId || !Allowed(device, stream.Port)) break;
        lock (stream.Gate) stream.Unacked += count;
        await publish!(channel, new JsonObject { ["t"] = "net.data", ["ch"] = ch, ["data"] = Convert.ToBase64String(buffer, 0, count) }, stream.Stop.Token);
      }
    }
    catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException or ObjectDisposedException or TimeoutException or PhoneRefusal) { }
    finally
    {
      lock (connection.Gate) Drop(connection, ch);
      try { if (publish is { } send) await send(channel, NetClosed(ch), CancellationToken.None); }
      catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException or System.Net.WebSockets.WebSocketException) { }
    }
  }
  private void Drop(Connection connection, string ch)
  {
    if (!connection.Streams.Remove(ch, out var stream)) return;
    Interlocked.Decrement(ref activeStreams); stream.Stop.Cancel(); stream.Socket.Dispose();
    lock (stream.Gate) { stream.Credit?.TrySetCanceled(); stream.Credit = null; }
    // A writer/read loop may still own these synchronization objects. GC releases
    // them after cancellation; disposing them here races an in-flight Release.
  }
  public ValueTask DisconnectedAsync(string channel)
  {
    if (connections.TryRemove(channel, out var connection)) lock (connection.Gate) { foreach (var ch in connection.Streams.Keys.ToArray()) Drop(connection, ch); connection.Tunnels.Clear(); }
    return ValueTask.CompletedTask;
  }
  public void Dispose() { disposed = true; foreach (var channel in connections.Keys) DisconnectedAsync(channel).GetAwaiter().GetResult(); }
  private static JsonObject NetClosed(string ch) => new() { ["t"] = "net.close", ["ch"] = ch };
  private static JsonObject Closed(string id, string message) => new() { ["t"] = "tunnel.closed", ["id"] = id, ["message"] = message };
  private static string Text(JsonElement message, string field, int maximum, bool empty = false) => message.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { } text && text.Length <= maximum && (empty || text.Length > 0) && !text.Any(char.IsControl) ? text : throw new PhoneRefusal("bad-message", "Invalid " + field + ".");
  private static string Id(JsonElement message, string field) => Text(message, field, 128);
  private static int Whole(JsonElement message, string field, int minimum, int maximum) => message.TryGetProperty(field, out var value) && value.TryGetInt32(out var number) && number >= minimum && number <= maximum ? number : throw new PhoneRefusal("bad-message", "Invalid " + field + ".");
}
