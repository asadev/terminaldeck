using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Mcp;

// The factory owns only its child and sockets. Protected values never enter a
// diagnostic, and HTTP redirects cannot forward an authorization header.
public sealed class ManagedMcpFactory : IMcpConnectionFactory
{
  public async ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken ct)
  {
    Connection connection;
    if (config.Transport == "stdio")
    {
      var start = new ProcessStartInfo(config.Executable ?? throw new IOException("Choose a server command."))
      { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
      foreach (var key in start.Environment.Keys.Where(k => k.EndsWith("_KEY", StringComparison.OrdinalIgnoreCase) || k.EndsWith("_TOKEN", StringComparison.OrdinalIgnoreCase) || k.Contains("SECRET", StringComparison.OrdinalIgnoreCase)).ToArray()) start.Environment.Remove(key);
      foreach (var argument in config.Arguments) start.ArgumentList.Add(argument);
      foreach (var (key, reference) in config.EnvironmentReferences) start.Environment[key] = await ReadSecretAsync(secrets, reference, ct);
      if (config.Folder is not null) start.WorkingDirectory = config.Folder;
      connection = new Stdio(Process.Start(start) ?? throw new IOException("The MCP server could not start."));
    }
    else if (config.Transport is "http" or "sse")
    {
      var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false }) { Timeout = Timeout.InfiniteTimeSpan };
      try
      {
        foreach (var (key, reference) in config.HeaderReferences) client.DefaultRequestHeaders.Add(key, await ReadSecretAsync(secrets, reference, ct));
        var address = new Uri(config.Url!);
        connection = new Http(client, address, config.Transport == "sse");
      }
      catch { client.Dispose(); throw; }
    }
    else throw new IOException("Choose stdio, HTTP or SSE for this MCP server.");
    try { await connection.InitializeAsync(ct); return connection; }
    catch (HttpRequestException) { await connection.DisposeAsync(); throw new IOException("The MCP HTTP server could not complete the connection."); }
    catch { await connection.DisposeAsync(); throw; }
  }
  private static async Task<string> ReadSecretAsync(ISecretStore secrets, string reference, CancellationToken ct)
  {
    var bytes = await secrets.ReadAsync(reference, ct) ?? throw new IOException("A saved MCP credential is missing.");
    try { return Encoding.UTF8.GetString(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  private abstract class Connection : IManagedMcpConnection
  {
    private readonly SemaphoreSlim gate = new(1);
    private long sequence;
    protected const int Limit = 4 * 1024 * 1024;
    protected abstract Task<JsonElement> ExchangeAsync(byte[] body, long? id, CancellationToken ct);
    private async Task<JsonElement> RpcAsync(string method, object args, CancellationToken ct)
    {
      await gate.WaitAsync(ct);
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(45));
      try
      {
        var id = Interlocked.Increment(ref sequence);
        var body = JsonSerializer.SerializeToUtf8Bytes(new { jsonrpc = "2.0", id, method, @params = args });
        if (body.Length > Limit) throw new IOException("The MCP request is too large.");
        return await ExchangeAsync(body, id, deadline.Token);
      }
      finally { gate.Release(); }
    }
    public async Task InitializeAsync(CancellationToken ct)
    {
      await RpcAsync("initialize", new { protocolVersion = "2025-06-18", capabilities = new { }, clientInfo = new { name = "deck-control", version = "0.1.0" } }, ct);
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(45));
      await ExchangeAsync(Encoding.UTF8.GetBytes("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"), null, deadline.Token);
    }
    public async ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(CancellationToken ct)
    {
      var tools = new List<McpRemoteTool>(); string? cursor = null;
      var seen = new HashSet<string>();
      do
      {
        var result = await RpcAsync("tools/list", cursor is null ? new { } : (object)new { cursor }, ct);
        tools.AddRange(result.GetProperty("tools").EnumerateArray().Select(t => new McpRemoteTool(t.GetProperty("name").GetString()!, t.GetProperty("inputSchema").Clone(), t.TryGetProperty("title", out var title) ? title.GetString() : null, t.TryGetProperty("description", out var description) ? description.GetString() : null)));
        cursor = result.TryGetProperty("nextCursor", out var next) ? next.GetString() : null;
        if (tools.Count > 4096 || cursor is not null && (!seen.Add(cursor) || seen.Count > 64)) throw new IOException("The MCP tool list is too large or repeats itself.");
      } while (cursor is not null);
      return tools;
    }
    public async ValueTask<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken ct) => await RpcAsync("tools/call", new { name = tool, arguments }, ct);
    protected static JsonElement? Reply(string text, long id)
    {
      if (Encoding.UTF8.GetByteCount(text) > Limit) throw new IOException("The MCP reply is too large.");
      using var document = JsonDocument.Parse(text);
      var root = document.RootElement;
      if (!root.TryGetProperty("id", out var responseId) || !responseId.TryGetInt64(out var number) || number != id) return null;
      if (root.TryGetProperty("error", out _)) throw new IOException("The MCP server refused this request.");
      return root.GetProperty("result").Clone();
    }
    // ReadLineAsync allocates before a size check. Bound each event while reading.
    protected static async Task<string?> LineAsync(StreamReader reader, CancellationToken ct)
    {
      var line = new StringBuilder(); var buffer = new char[1];
      while (await reader.ReadAsync(buffer.AsMemory(), ct) != 0)
      {
        if (buffer[0] == '\n') return line.ToString().TrimEnd('\r');
        line.Append(buffer[0]); if (line.Length > Limit) throw new IOException("The MCP event is too large.");
      }
      return line.Length == 0 ? null : line.ToString();
    }
    public abstract ValueTask DisposeAsync();
  }
  private sealed class Stdio : Connection
  {
    private readonly Process child;
    private readonly CancellationTokenSource stop = new();
    private readonly Task stderr;
    public Stdio(Process child)
    {
      this.child = child;
      stderr = Task.Run(async () =>
      {
        var buffer = new char[4096];
        try { while (await child.StandardError.ReadAsync(buffer.AsMemory(), stop.Token) != 0) { } }
        catch (OperationCanceledException) { }
        catch (IOException) { }
      });
    }
    protected override async Task<JsonElement> ExchangeAsync(byte[] body, long? id, CancellationToken ct)
    {
      await child.StandardInput.WriteLineAsync(Encoding.UTF8.GetString(body).AsMemory(), ct); await child.StandardInput.FlushAsync(ct);
      if (id is null) return default;
      for (var count = 0; count < 4096; count++)
      {
        var line = await LineAsync(child.StandardOutput, ct) ?? throw new IOException("The MCP server ended without a reply.");
        if (line.Length == 0) continue;
        if (Reply(line, id.Value) is { } reply) return reply;
      }
      throw new IOException("The MCP server sent too many unrelated messages.");
    }
    public override async ValueTask DisposeAsync()
    {
      stop.Cancel(); child.StandardInput.Close();
      try { if (!child.HasExited) child.Kill(entireProcessTree: true); await child.WaitForExitAsync(); await stderr; }
      finally { child.Dispose(); stop.Dispose(); }
    }
  }
  private sealed class Http(HttpClient client, Uri address, bool legacy) : Connection
  {
    private string? session;
    private Uri? postAddress;
    private HttpResponseMessage? eventsResponse;
    private StreamReader? events;
    private static bool SameOrigin(Uri a, Uri b) => a.Scheme == b.Scheme && a.IdnHost == b.IdnHost && a.Port == b.Port && b.UserInfo.Length == 0 && b.Fragment.Length == 0;
    private async Task<(string Event, string Data)> EventAsync(StreamReader reader, CancellationToken ct)
    {
      var type = "message"; var data = new StringBuilder(); var bytes = 0;
      while (true)
      {
        var line = await LineAsync(reader, ct) ?? throw new IOException("The MCP event stream ended without a reply.");
        bytes += line.Length; if (bytes > Limit) throw new IOException("The MCP event is too large.");
        if (line.Length == 0) { if (data.Length > 0) return (type, data.ToString().TrimEnd('\n')); bytes = 0; type = "message"; continue; }
        if (line.StartsWith("event:", StringComparison.Ordinal)) type = line[6..].TrimStart(' ');
        if (line.StartsWith("data:", StringComparison.Ordinal)) data.Append(line[5..].TrimStart(' ')).Append('\n');
      }
    }
    protected override async Task<JsonElement> ExchangeAsync(byte[] body, long? id, CancellationToken ct)
    {
      if (legacy && events is null)
      {
        using var get = new HttpRequestMessage(HttpMethod.Get, address); get.Headers.Accept.Add(new("text/event-stream"));
        eventsResponse = await client.SendAsync(get, HttpCompletionOption.ResponseHeadersRead, ct); eventsResponse.EnsureSuccessStatusCode();
        if (eventsResponse.Content.Headers.ContentType?.MediaType != "text/event-stream") throw new IOException("The MCP server did not open an event stream.");
        events = new(await eventsResponse.Content.ReadAsStreamAsync(ct));
        var endpoint = await EventAsync(events, ct);
        if (endpoint.Event != "endpoint" || !Uri.TryCreate(address, endpoint.Data, out var wanted) || !SameOrigin(address, wanted)) throw new IOException("The MCP server offered an unsafe reply address.");
        postAddress = wanted;
      }
      using var request = new HttpRequestMessage(HttpMethod.Post, postAddress ?? address);
      request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json")); request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
      request.Headers.Add("MCP-Protocol-Version", "2025-06-18"); if (session is not null) request.Headers.Add("Mcp-Session-Id", session);
      request.Content = new ByteArrayContent(body); request.Content.Headers.ContentType = new("application/json");
      using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
      if (response.Headers.TryGetValues("Mcp-Session-Id", out var values)) session = values.Single();
      if (id is null) return default;
      if (legacy || response.Content.Headers.ContentType?.MediaType == "text/event-stream")
      {
        using var ownReader = legacy ? null : new StreamReader(await response.Content.ReadAsStreamAsync(ct));
        var reader = events ?? ownReader!;
        for (var count = 0; count < 4096; count++)
        {
          var message = await EventAsync(reader, ct);
          if (message.Event == "message" && Reply(message.Data, id.Value) is { } reply) return reply;
        }
      }
      else
      {
        await using var stream = await response.Content.ReadAsStreamAsync(ct); using var output = new MemoryStream();
        var buffer = new byte[8192]; int count;
        while ((count = await stream.ReadAsync(buffer, ct)) > 0) { if (output.Length + count > Limit) throw new IOException("The MCP reply is too large."); await output.WriteAsync(buffer.AsMemory(0, count), ct); }
        if (Reply(Encoding.UTF8.GetString(output.ToArray()), id.Value) is { } reply) return reply;
      }
      throw new IOException("The MCP server did not return the requested reply.");
    }
    public override ValueTask DisposeAsync() { events?.Dispose(); eventsResponse?.Dispose(); client.Dispose(); return ValueTask.CompletedTask; }
  }
}
