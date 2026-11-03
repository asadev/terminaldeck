using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.Core.Mcp;

public sealed class McpHttpRequest
{
  public required string Method { get; init; }
  public required string Path { get; init; }
  public required string Host { get; init; }
  public string? Origin { get; init; }
  public required string Authorization { get; init; }
  public required ReadOnlyMemory<byte> Body { get; init; }
  public override string ToString() => "<MCP HTTP request>";
}
public sealed record McpHttpReply(int Status, byte[] Body, string ContentType = "application/json");

// A transport-independent HTTP endpoint; no listener starts from its constructor.
public sealed class McpHttpEndpoint
{
  public static readonly string[] Versions = ["2024-11-05", "2025-03-26", "2025-06-18"];
  private readonly McpDoor door;
  private readonly string host;
  private readonly string version;
  private readonly ConcurrentDictionary<Guid, string> initialized = [];
  private readonly ConcurrentDictionary<(Guid Caller, string Request), CancellationTokenSource> active = [];
  private readonly Dictionary<Guid, Queue<DateTimeOffset>> rates = [];
  private readonly object rateGate = new();
  private readonly SemaphoreSlim slots = new(8);
  private readonly TimeProvider clock;
  public McpHttpEndpoint(McpDoor door, Uri address, string appVersion, TimeProvider? clock = null)
  {
    if (address.Scheme != "http" || !new[] { "127.0.0.1", "localhost", "[::1]", "::1" }.Contains(address.Host) || address.Port is < 1 or > 65535 || address.AbsolutePath != "/mcp" || address.Query.Length != 0 || address.Fragment.Length != 0 || address.UserInfo.Length != 0)
      throw new ArgumentException("The MCP door needs a loopback HTTP /mcp address.");
    this.door = door; host = address.Authority; version = appVersion; this.clock = clock ?? TimeProvider.System;
  }
  public async ValueTask<McpHttpReply> HandleAsync(McpHttpRequest request, CancellationToken cancellationToken = default)
  {
    if (request.Method != "POST") return Empty(405);
    if (request.Path != "/mcp") return Empty(404);
    if (request.Origin is not null || !request.Host.Equals(host, StringComparison.OrdinalIgnoreCase)) return Empty(403);
    if (request.Body.Length > 65536) return Empty(413);
    Guid caller;
    try { caller = door.Authenticate(request.Authorization.StartsWith("Bearer ", StringComparison.Ordinal) ? request.Authorization[7..] : ""); }
    catch (McpRefusal) { return Empty(401); }
    if (!TakeRate(caller)) return Empty(429);
    JsonElement root;
    try
    {
      using var document = JsonDocument.Parse(request.Body, new JsonDocumentOptions { MaxDepth = 32 }); root = document.RootElement.Clone();
      if (root.ValueKind != JsonValueKind.Object || root.GetProperty("jsonrpc").GetString() != "2.0" || root.EnumerateObject().Select(p => p.Name).Distinct().Count() != root.EnumerateObject().Count()) return Error(null, -32600, "This JSON-RPC request is unusable.");
    }
    catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException) { return Error(null, -32700, "The request could not be read."); }
    var id = root.TryGetProperty("id", out var requestId) ? requestId : (JsonElement?)null;
    if (id is not null && id.Value.ValueKind is not (JsonValueKind.String or JsonValueKind.Number)) return Error(null, -32600, "Choose a text or numeric request id.");
    var method = root.TryGetProperty("method", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() : null;
    var args = root.TryGetProperty("params", out var p) ? p : JsonSerializer.SerializeToElement(new { });
    if (method == "notifications/cancelled")
    {
      if (args.ValueKind == JsonValueKind.Object && args.TryGetProperty("requestId", out var cancelled) && active.TryGetValue((caller, cancelled.GetRawText()), out var pending)) pending.Cancel();
      return Empty(204);
    }
    if (method == "notifications/initialized") return Empty(204);
    if (id is null) return Empty(204);
    if (!await slots.WaitAsync(0, cancellationToken)) return Empty(429);
    using var source = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, door.Lifetime(caller)); source.CancelAfter(TimeSpan.FromSeconds(150));
    var key = (caller, id.Value.GetRawText());
    if (!active.TryAdd(key, source)) { slots.Release(); return Error(id, -32600, "This request id is already running."); }
    try
    {
      object result;
      switch (method)
      {
        case "initialize":
          var requested = args.GetProperty("protocolVersion").GetString()!;
          var negotiated = Versions.Contains(requested) ? requested : Versions[^1];
          initialized[caller] = negotiated;
          result = new { protocolVersion = negotiated, capabilities = new { tools = new { listChanged = false } }, serverInfo = new { name = "deck-control", version } };
          break;
        case "ping": result = new { }; break;
        case "tools/list":
          RequireInitialized(caller);
          result = new { tools = door.List(caller).Select(t => new { name = t.Wire, description = t.Id, inputSchema = t.InputSchema, annotations = new { readOnlyHint = t.Tier == McpTier.Read, destructiveHint = t.Tier == McpTier.Alter, openWorldHint = true } }) };
          break;
        case "tools/call":
          RequireInitialized(caller);
          var name = args.GetProperty("name").GetString()!;
          var input = args.TryGetProperty("arguments", out var supplied) ? supplied : JsonSerializer.SerializeToElement(new { });
          try
          {
            var output = await door.CallAsync(caller, name, input, source.Token).AsTask().WaitAsync(source.Token);
            result = Content(output);
          }
          catch (SignInRequiredException ex) { result = ToolContent(JsonSerializer.Serialize(new { message = ex.Message, action = ex.ActionLabel, accountId = ex.AccountId }), true); }
          catch (TerminalDeck.Core.Platform.ProviderUnavailableException ex) { result = ToolContent(ex.Message, true); }
          catch (McpRefusal ex) { result = ToolContent(ex.Message, true); }
          catch (OperationCanceledException) { throw; }
          catch (Exception ex) { result = ToolContent(Failure(ex), true); }
          break;
        default: return Error(id, -32601, "This MCP method is not available.");
      }
      return Json(new { jsonrpc = "2.0", id, result });
    }
    catch (OperationCanceledException) { return Error(id, -32800, "This request was cancelled."); }
    catch (Exception ex) when (ex is KeyNotFoundException or InvalidOperationException or ArgumentException) { return Error(id, -32602, "The request arguments are unusable."); }
    finally { active.TryRemove(key, out _); slots.Release(); }
  }
  private bool TakeRate(Guid caller)
  {
    lock (rateGate)
    {
      var now = clock.GetUtcNow();
      if (!rates.TryGetValue(caller, out var queue)) rates[caller] = queue = new();
      while (queue.TryPeek(out var time) && time <= now.AddMinutes(-1)) queue.Dequeue();
      if (queue.Count >= 120) return false;
      queue.Enqueue(now); return true;
    }
  }
  private void RequireInitialized(Guid caller) { if (!initialized.ContainsKey(caller)) throw new McpRefusal("Initialize this MCP connection first."); }
  // Argument and state refusals are written for people (CAPTEST rerun: S6/S10
  // showed only "could not be completed"). Other failures can carry provider or
  // file text, so they name only their kind.
  public static string Failure(Exception ex)
  {
    if (ex is ArgumentException or InvalidOperationException or KeyNotFoundException or FormatException or TimeoutException or NotSupportedException)
    {
      var text = new string(ex.Message.Where(c => !char.IsControl(c)).Take(400).ToArray()).Trim();
      if (text.Length > 0) return text;
    }
    return "This action could not be completed (" + ex.GetType().Name + "). Try again.";
  }
  // A page picture goes back as an MCP image block so the AI can see it (CAPTEST
  // rerun S2: base64 inside text left Claude unable to "make out the details").
  public static object Content(JsonElement output)
  {
    if (output.ValueKind == JsonValueKind.Object && output.TryGetProperty("mimeType", out var type) && type.ValueKind == JsonValueKind.String && type.GetString()!.StartsWith("image/", StringComparison.Ordinal)
      && output.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.String)
    {
      var rest = new Dictionary<string, JsonElement>();
      foreach (var property in output.EnumerateObject()) if (property.Name != "data") rest[property.Name] = property.Value.Clone();
      return new { content = new object[] { new { type = "image", data = data.GetString(), mimeType = type.GetString() }, new { type = "text", text = JsonSerializer.Serialize(rest) } }, isError = false };
    }
    return ToolContent(output.GetRawText(), false);
  }
  private static object ToolContent(string text, bool error) => new { content = new[] { new { type = "text", text } }, isError = error };
  private static McpHttpReply Empty(int status) => new(status, []);
  private static McpHttpReply Json(object value) => new(200, JsonSerializer.SerializeToUtf8Bytes(value));
  private static McpHttpReply Error(JsonElement? id, int code, string message) => Json(new { jsonrpc = "2.0", id, error = new { code, message } });
}
