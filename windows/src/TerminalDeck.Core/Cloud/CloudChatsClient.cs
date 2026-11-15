using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

/// The session and chat routes of the service (`chats.ts`), signed exactly like the change feed's control calls
/// (CloudFeedClient: bearer token + the device proof over `TD-CLOUD-1\n{method}\n{/v1 path and query}\n{time}\n{request
/// id}\n{sha256 of body}`), but with their own size (8 MiB a call) and their own door: never the feed's back-off.
/// The Mac's CloudSyncTransport.chats(...). Only these routes and a plain query can be named.
public sealed class CloudChatsClient(CloudSyncEndpoint endpoint, ICloudSyncAuth auth, ICloudSyncHttp http, Func<long>? serviceNow = null)
{
  public const int MaximumBytes = 8_388_608;
  public static readonly IReadOnlyList<string> Routes = ["/chats/tick", "/chats/piece", "/chats/snap", "/chats/head", "/chats/raw", "/chats/read", "/chats/bin", "/sessions", "/sessions/move"];
  private readonly Func<long> now = serviceNow ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

  /// The session and chat routes, with a plain query only (letters, digits, `-_.=&%`): nothing that names another route,
  /// another host, a fragment or a parent folder.
  public static bool IsChatsPath(string path)
  {
    if (System.Text.Encoding.UTF8.GetByteCount(path) > 1_024 || path.Contains("..", StringComparison.Ordinal) || path.Contains("//", StringComparison.Ordinal)) return false;
    var parts = path.Split('?', 2);
    if (!Routes.Contains(parts[0])) return false;
    return parts.Length == 1 || parts[1].All(c => c is >= '0' and <= '9' or >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '-' or '_' or '.' or '=' or '&' or '%');
  }

  /// One call. Any refusal is answered as its status and body (the uploader reads the service's code); a network fault
  /// or a cancellation throws (a lost answer).
  public async Task<CloudChatsAnswer> SendAsync(string method, string path, byte[] body, CancellationToken ct = default)
  {
    if (method is not ("GET" or "POST") || !IsChatsPath(path) || method == "GET" && body.Length > 0 || body.Length > MaximumBytes) throw new CloudFailure("invalid_request");
    var credentials = await auth.CredentialsAsync(ct);
    var requestId = Guid.NewGuid().ToString("D");
    var proof = auth.Proof(method, "/v1" + path, body, now(), requestId);
    if (!proof.TryGetValue("X-TD-Device", out var device) || device != credentials.DeviceId) throw new CloudFailure("invalid_request");
    var headers = new Dictionary<string, string>(proof, StringComparer.OrdinalIgnoreCase)
    {
      ["Authorization"] = "Bearer " + credentials.AccessToken, ["Cache-Control"] = "no-store", ["Content-Type"] = "application/json"
    };
    var answer = await http.SendAsync(new(method, endpoint.Control(path), headers, body, MaximumBytes), ct);
    if (answer.Body.Length > MaximumBytes) throw new CloudFailure("invalid_request");
    return new(answer.Status, answer.Body);
  }

  /// The uploader's and readers' door.
  public CloudChatsSend Door(CancellationToken ct = default) => (method, path, body) => SendAsync(method, path, body, ct);
}

/// Reading the account's sessions (other machines, Earlier chats, a chat's readable copy): the phone routes, which this
/// PC reads too (contract §7: `self:false` rows are other machines'). The Mac's BackendCloudSessionsRead.
public static class CloudSessionsRead
{
  public sealed record Machine(string? Ref, string? Name, bool? On, bool? Listed);
  public sealed record Move(string Id, string? To, string? ToName, string? From, string? FromName, double? At);
  public sealed record Row(string Ref, string? SessionId = null, string? Name = null, double? LastUsedAt = null, CloudChats.Project? Project = null,
    string? Ai = null, string? Kind = null, string? Status = null, string? Machine = null, string? MachineName = null, bool? MachineOn = null,
    [property: System.Text.Json.Serialization.JsonPropertyName("self")] bool? Mine = null, bool? Readable = null, double? ClosedAt = null,
    string? Cwd = null, string? Login = null, string? ConversationId = null, double? StartedAt = null, long? CodeAt = null, [property: System.Text.Json.Serialization.JsonPropertyName("move")] Move? MoveOpen = null,
    string? MovedFrom = null, double? MovedAt = null);
  public sealed record Page(IReadOnlyList<Machine>? Machines, IReadOnlyList<Row>? Sessions, string? Next);
  /// One page of a readable copy: its events (raw, as the phones draw them), where it starts.
  public sealed record ChatPage(int Gen, int Total, int First, int Count, IReadOnlyList<JsonElement> Events);

  private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

  /// The account's sessions, every page (at most 10 pages of 500). `earlier`: the closed sessions whose chat is kept.
  public static async Task<(IReadOnlyList<Machine> Machines, IReadOnlyList<Row> Rows)?> ListAsync(CloudChatsSend send, bool earlier)
  {
    var machines = new List<Machine>(); var rows = new List<Row>(); string? after = null;
    for (var i = 0; i < 10; i++)
    {
      var path = "/sessions?limit=500" + (earlier ? "&earlier=1" : "") + (after is null ? "" : "&after=" + Uri.EscapeDataString(after));
      Page? page;
      try
      {
        var answer = await send("GET", path, []);
        page = answer.Status == 200 ? JsonSerializer.Deserialize<Page>(answer.Data, Json) : null;
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { page = null; }
      if (page is null) return rows.Count == 0 ? null : (machines, rows);
      if (machines.Count == 0) machines.AddRange(page.Machines ?? []);
      rows.AddRange(page.Sessions ?? []);
      if (string.IsNullOrEmpty(page.Next)) break;
      after = page.Next;
    }
    return (machines, rows);
  }

  /// One page of a session's readable copy: the newest (`before` null) or the one before event `before`; `after`: new
  /// events since (polling while it is open).
  public static async Task<ChatPage?> ChatAsync(CloudChatsSend send, string reference, int? before = null, int? after = null)
  {
    var path = "/chats/read?session=" + Uri.EscapeDataString(reference)
      + (before is { } b ? "&before=" + b.ToString(CultureInfo.InvariantCulture) + "&limit=200" : after is { } a ? "&after=" + a.ToString(CultureInfo.InvariantCulture) + "&limit=200" : "&last=200");
    try
    {
      var answer = await send("GET", path, []);
      if (answer.Status != 200 || answer.Data.Length > 4 * 1_048_576) return null;
      using var doc = JsonDocument.Parse(answer.Data);
      var root = doc.RootElement;
      if (root.ValueKind != JsonValueKind.Object) return null;
      var events = root.TryGetProperty("events", out var list) && list.ValueKind == JsonValueKind.Array
        ? list.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Object).Select(e => e.Clone()).ToArray() : [];
      int Number(string name, int fallback) => root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? (int)v.GetDouble() : fallback;
      return new(Number("gen", 1), Number("total", events.Length), Number("first", 0), Number("count", events.Length), events);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { return null; }
  }
}
