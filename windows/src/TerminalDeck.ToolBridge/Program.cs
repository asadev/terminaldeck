using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Integration;

// Private stdio-to-HTTP adapter. Its argv contains identities and paths only.
// It lives as long as the AI process: the app may restart or be replaced while
// the chat keeps running, so a missing app is an error reply, never an exit
// (an exited stdio server stays "Connection closed" for the rest of the chat).
if (args.Length != 4 || args[0] != "--root" || args[2] != "--chat") return 2;
AppDataRoot root;
try { root = AppDataRoot.Explicit(args[1]); }
catch (ArgumentException) { return 2; }
var chat = args[3];
using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(140) };
http.DefaultRequestHeaders.Accept.ParseAdd("application/json");
string? initialize = null, keyInUse = null;

async Task<ChatToolConnection?> ConnectionAsync(bool renew)
{
  ChatToolConnection? Read()
  {
    try { return HootToolConnection.Read(root, chat); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException or System.Security.Cryptography.CryptographicException) { return null; }
  }
  var saved = renew ? null : Read();
  if (saved is not null) return saved;
  // The open window provisions (or hands back) this chat's key from its live seat and permission.
  try { await new HootToolConnection(root, TerminalDeck.Platform.Windows.KeeperCredentials.GetOrCreate(root)).PrepareAsync(chat, CancellationToken.None); }
  catch (Exception ex) when (ex is IOException or TimeoutException or OperationCanceledException or UnauthorizedAccessException or InvalidOperationException) { }
  return Read();
}
// A request "reached" the app unless the connection itself was refused. One that
// reached it is never sent again (CAPTEST rerun: a timed-out screenshot was resent
// under the same id and answered "This request id is already running").
async Task<(HttpResponseMessage? Response, bool Reached)> PostAsync(ChatToolConnection connection, string body)
{
  using var request = new HttpRequestMessage(HttpMethod.Post, connection.Url) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
  request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", connection.Token);
  try { return (await http.SendAsync(request), true); }
  catch (HttpRequestException ex) when (ex.InnerException is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.ConnectionRefused }) { return (null, false); }
  catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException) { return (null, true); }
}
// The app's door keys MCP sessions by caller. A renewed key is a new caller,
// so repeat the AI's own handshake for it before forwarding the next request.
var handshakeGate = new SemaphoreSlim(1);
async Task<bool> ReadyAsync(ChatToolConnection connection, string? method)
{
  if (connection.Token == keyInUse || method == "initialize" || initialize is null) return true;
  await handshakeGate.WaitAsync();
  try
  {
    if (connection.Token == keyInUse) return true;
    var (handshake, _) = await PostAsync(connection, initialize);
    using (handshake) if (handshake is null || !handshake.IsSuccessStatusCode) return false;
    var (notified, _) = await PostAsync(connection, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    notified?.Dispose(); keyInUse = connection.Token; return true;
  }
  finally { handshakeGate.Release(); }
}
var output = new SemaphoreSlim(1);
async Task WriteAsync(string text)
{
  await output.WaitAsync();
  try { await Console.Out.WriteLineAsync(text); await Console.Out.FlushAsync(); }
  finally { output.Release(); }
}
string Error(JsonElement id, string message) => JsonSerializer.Serialize(new { jsonrpc = "2.0", id, error = new { code = -32000, message } });
async Task ForwardAsync(string line, JsonElement? id, string? method)
{
  ChatToolConnection? last = null;
  for (var attempt = 0; attempt < 2; attempt++)
  {
    var connection = await ConnectionAsync(renew: attempt > 0);
    if (connection is null || !await ReadyAsync(connection, method)) continue;
    last = connection;
    var (response, reached) = await PostAsync(connection, line);
    if (response is null)
    {
      if (!reached) continue;
      if (id is { } lost)
      {
        // Stop the app's copy of this call too; the AI gets one clear answer.
        var (cancel, _) = await PostAsync(connection, JsonSerializer.Serialize(new { jsonrpc = "2.0", method = "notifications/cancelled", @params = new { requestId = lost, reason = "timeout" } }));
        cancel?.Dispose();
        await WriteAsync(Error(lost, "Terminal Deck did not finish this tool call within 140 seconds, so it was stopped. Try once more; a page action needs its browser window to be open."));
      }
      return;
    }
    using (response)
    {
      if (response.StatusCode == HttpStatusCode.Unauthorized) continue; // refused before it ran: safe to renew and retry
      if (method == "initialize" && response.IsSuccessStatusCode) keyInUse = connection.Token;
      var text = await response.Content.ReadAsStringAsync();
      if (id is null) return;
      if (response.IsSuccessStatusCode && text.Length > 0)
      {
        try { using var reply = JsonDocument.Parse(text); await WriteAsync(reply.RootElement.GetRawText()); return; }
        catch (JsonException) { }
      }
      await WriteAsync(Error(id.Value, "Terminal Deck answered this tool call with an unreadable reply (HTTP " + (int)response.StatusCode + "). Try again."));
      return;
    }
  }
  if (id is { } unanswered) await WriteAsync(Error(unanswered, last is null
    ? "Terminal Deck's app tools are not reachable right now. Open Terminal Deck, then try this tool again; this chat reconnects by itself."
    : "Terminal Deck refused this chat's tool key twice. Reopen the chat or Terminal Deck, then try again."));
}

// Calls run side by side (an AI may ask for several at once, and a cancel must
// reach the app while a long call is still running); replies are written whole.
var calls = new List<Task>();
while (await Console.In.ReadLineAsync() is { } line)
{
  if (line.Length > 65536) return 2;
  JsonElement? id = null; string? method = null;
  try
  {
    using var parsed = JsonDocument.Parse(line);
    if (parsed.RootElement.TryGetProperty("id", out var requestId)) id = requestId.Clone();
    if (parsed.RootElement.TryGetProperty("method", out var m) && m.ValueKind == JsonValueKind.String) method = m.GetString();
  }
  catch (JsonException) { continue; }
  if (method == "initialize") { initialize = line; await ForwardAsync(line, id, method); continue; }
  calls.RemoveAll(t => t.IsCompleted);
  if (method is "tools/call") calls.Add(Task.Run(() => ForwardAsync(line, id, method)));
  else await ForwardAsync(line, id, method);
}
await Task.WhenAll(calls);
return 0;
