using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Remote;

/// One device's TURN login from the Worker: its ICE servers, when it expires (Unix ms), and the Worker's id for it.
public sealed record TurnLogin(IReadOnlyList<LinkIceServer> Servers, long ExpiresAtMs, string? Login);

/// Cloudflare Realtime TURN logins from the relay's Worker, ONE PER PAIRED DEVICE (Security M2; contract "TURN per
/// device + revoke" in stream-anywhere-contract.md): `POST https://<relay host>/v1/turn {"device","ttl"}` with this PC's
/// own host secret, only while its relay socket is open; `POST /v1/turn/revoke {"device","login"?}` withdraws one (it
/// needs only the host secret, so it works while the relay is down). The logins go to their device only, inside the
/// sealed channel; the client never asks the Worker.
public sealed class RelayTurnLogins : IDisposable
{
  private static readonly Regex DeviceId = new("^[A-Za-z0-9_-]{1,64}$", RegexOptions.CultureInvariant);
  private static readonly Regex LoginId = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);
  private readonly Uri relay;
  private readonly byte[] hostSecret;
  private readonly Func<bool> relayOpen;
  private readonly HttpClient http;
  private readonly bool ownsHttp;
  private volatile bool disposed;

  public RelayTurnLogins(Uri relay, ReadOnlySpan<byte> hostSecret, Func<bool> relayOpen, HttpClient? http = null)
  {
    RelayEndpoint.Validate(relay);
    if (hostSecret.Length != 32) throw new ArgumentException("A host secret must be 32 bytes.");
    this.relay = relay;
    this.hostSecret = hostSecret.ToArray();
    this.relayOpen = relayOpen;
    ownsHttp = http is null;
    this.http = http ?? new HttpClient(new SocketsHttpHandler { UseCookies = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(8) };
  }

  /// wss://relay → https://relay/v1/turn (ws://localhost → http for a local relay).
  public static Uri Endpoint(Uri relay, string path = "/v1/turn") =>
    new UriBuilder(relay) { Scheme = relay.Scheme == "ws" ? "http" : "https", Port = relay.IsDefaultPort ? -1 : relay.Port, Path = path, Query = "", Fragment = "" }.Uri;

  public static bool ValidDevice(string device) => DeviceId.IsMatch(device);

  /// The device's own login, or null (relay socket closed, bad id, not deployed, not configured, refused, unusable).
  public async Task<TurnLogin?> FetchAsync(string device, int ttl, CancellationToken cancellationToken)
  {
    if (disposed || !ValidDevice(device) || !relayOpen()) return null;
    var answer = await PostAsync("/v1/turn", new JsonObject { ["device"] = device, ["ttl"] = Math.Clamp(ttl, 60, 3600) }, cancellationToken).ConfigureAwait(false);
    return answer is { Status: 200 } ? Parse(answer.Value.Body, device) : null;
  }

  /// Withdraws a device's login: with `login`, only that one and only while it is still current (its last link
  /// closed); without, whatever it holds (unpaired, access off). True when the Worker answered 200 (withdrawn or
  /// nothing held); false = try again later (502, 503, no answer).
  public async Task<bool> RevokeAsync(string device, string? login, CancellationToken cancellationToken)
  {
    if (disposed || !ValidDevice(device)) return false;
    var body = new JsonObject { ["device"] = device };
    if (login is not null && LoginId.IsMatch(login)) body["login"] = login;
    var answer = await PostAsync("/v1/turn/revoke", body, cancellationToken).ConfigureAwait(false);
    if (answer is not { Status: 200 }) return false;
    try
    {
      using var document = JsonDocument.Parse(answer.Value.Body);
      return document.RootElement.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True;
    }
    catch (JsonException) { return false; }
  }

  private async Task<(int Status, byte[] Body)?> PostAsync(string path, JsonObject body, CancellationToken cancellationToken)
  {
    try
    {
      using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(relay, path));
      request.Headers.Add("x-deck-host-secret", Convert.ToBase64String(hostSecret).TrimEnd('=').Replace('+', '-').Replace('/', '_'));
      request.Content = new StringContent(body.ToJsonString());
      request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
      deadline.CancelAfter(TimeSpan.FromSeconds(8));
      using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token).ConfigureAwait(false);
      if (response.Content.Headers.ContentLength > 16_384) return null;
      var bytes = await response.Content.ReadAsByteArrayAsync(deadline.Token).ConfigureAwait(false);
      return bytes.Length > 16_384 ? null : ((int)response.StatusCode, bytes);
    }
    catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or IOException or ObjectDisposedException) { return null; }
  }

  /// {ok:true, device, login, expiresAtMs, ttl, iceServers:[{urls, username?, credential?}]} for `device` → at most 8 servers.
  public static TurnLogin? Parse(ReadOnlySpan<byte> body, string device)
  {
    try
    {
      using var document = JsonDocument.Parse(body.ToArray());
      var root = document.RootElement;
      if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("ok", out var ok) || ok.ValueKind != JsonValueKind.True ||
        !root.TryGetProperty("device", out var named) || named.ValueKind != JsonValueKind.String || named.GetString() != device ||
        !root.TryGetProperty("iceServers", out var rows) || rows.ValueKind != JsonValueKind.Array) return null;
      var servers = ParseServers(rows);
      if (servers.Count == 0) return null;
      var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
      var expires = root.TryGetProperty("expiresAtMs", out var at) && at.TryGetInt64(out var ms) ? ms
        : now + (root.TryGetProperty("ttl", out var ttl) && ttl.TryGetInt32(out var seconds) ? seconds : 3600) * 1000L;
      var login = root.TryGetProperty("login", out var id) && id.ValueKind == JsonValueKind.String && LoginId.IsMatch(id.GetString()!) ? id.GetString() : null;
      return new TurnLogin(servers, expires, login);
    }
    catch (JsonException) { return null; }
  }

  internal static List<LinkIceServer> ParseServers(JsonElement rows)
  {
    var servers = new List<LinkIceServer>();
    foreach (var row in rows.EnumerateArray())
    {
      if (servers.Count == 8) break;
      if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("urls", out var given)) continue;
      JsonElement[] listed = given.ValueKind switch { JsonValueKind.String => [given], JsonValueKind.Array => given.EnumerateArray().ToArray(), _ => [] };
      var urls = listed.Where(u => u.ValueKind == JsonValueKind.String).Select(u => u.GetString()!)
        .Where(u => u.Length <= 512 && (u.StartsWith("stun:", StringComparison.Ordinal) || u.StartsWith("turn:", StringComparison.Ordinal) || u.StartsWith("turns:", StringComparison.Ordinal)))
        .Take(8).ToArray();
      if (urls.Length == 0) continue;
      servers.Add(new LinkIceServer(urls, Field(row, "username"), Field(row, "credential")));
    }
    return servers;
  }

  private static string? Field(JsonElement row, string name) =>
    row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && value.GetString()!.Length <= 1024 ? value.GetString() : null;

  public void Dispose()
  {
    disposed = true;
    CryptographicOperations.ZeroMemory(hostSecret);
    if (ownsHttp) http.Dispose();
  }
}

/// A device's ICE servers for a new link: ITS OWN TURN login (reused for that device's reconnects only while it has
/// more than 10 minutes left; asking again withdraws the old one at the Worker) plus Cloudflare's STUN, which is always
/// in the list; STUN alone when the Worker gives none. `ReleaseAsync` forgets a device's login and withdraws it, with
/// retries (5 s, 30 s, 2 min) that stop as soon as that device is given a new login (Security R1).
/// Debug builds only (Security S3 / W5): `TD_PEER_WORKER_TURN=0`, `TD_PEER_ICE_SERVERS` (a JSON list) and
/// `TD_PEER_POLICY` (all / nohost / relay) for measurements; a shipped build ignores the environment.
public sealed class LinkIceSource
{
  public static readonly TimeSpan ReuseMargin = TimeSpan.FromMinutes(10);
  public static readonly TimeSpan[] RevokeRetries = [TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(30), TimeSpan.FromMinutes(2)];
  private readonly Func<string, CancellationToken, Task<TurnLogin?>> turn;
  private readonly Func<string, string?, CancellationToken, Task<bool>> revoke;
  private readonly TimeProvider clock;
  private readonly IReadOnlyDictionary<string, string>? environment;
  private readonly TimeSpan[] retries;
  private readonly object gate = new();
  private readonly Dictionary<string, TurnLogin> cached = [];
  private readonly Dictionary<string, int> issued = [];

  public LinkIceSource(Func<string, CancellationToken, Task<TurnLogin?>> turn, Func<string, string?, CancellationToken, Task<bool>> revoke,
    TimeProvider? time = null, IReadOnlyDictionary<string, string>? environment = null, TimeSpan[]? retries = null)
  {
    this.turn = turn; this.revoke = revoke; clock = time ?? TimeProvider.System; this.environment = environment;
    this.retries = retries ?? RevokeRetries;
  }

  /// Measurement knobs are read only in a debug build.
  public static bool KnobsAllowed =>
#if DEBUG
    true;
#else
    false;
#endif

  private string? Setting(string name)
  {
    if (!KnobsAllowed) return null;
    return environment is not null ? environment.GetValueOrDefault(name) : Environment.GetEnvironmentVariable(name);
  }

  private bool WorkerTurn => Setting("TD_PEER_WORKER_TURN") != "0";

  public async ValueTask<LinkServers> ServersAsync(string device, CancellationToken cancellationToken)
  {
    var policy = Setting("TD_PEER_POLICY") is "nohost" or "relay" ? Setting("TD_PEER_POLICY")! : "all";
    if (Setting("TD_PEER_ICE_SERVERS") is { Length: > 0 } json && ParseList(json) is { Count: > 0 } given) return new(given, policy);
    if (!WorkerTurn) return new([LinkPaths.CloudflareStun], policy);
    var now = clock.GetUtcNow().ToUnixTimeMilliseconds();
    lock (gate) if (cached.TryGetValue(device, out var hit) && hit.ExpiresAtMs - now > ReuseMargin.TotalMilliseconds) return new(WithStun(hit.Servers), policy);
    var minted = await turn(device, cancellationToken).ConfigureAwait(false);
    if (minted is null) return new([LinkPaths.CloudflareStun], policy);
    lock (gate) { cached[device] = minted; issued[device] = issued.GetValueOrDefault(device) + 1; }
    return new(WithStun(minted.Servers), policy);
  }

  /// `force` (unpaired, access off): withdraw whatever the device holds, unconditionally. Otherwise (its last link
  /// closed): withdraw only the login handed out in this run, by name, so a fresh one after a reconnect survives.
  public async Task ReleaseAsync(string device, bool force)
  {
    TurnLogin? held; int generation;
    lock (gate) { cached.Remove(device, out held); generation = issued.GetValueOrDefault(device); }
    if ((held is null && !force) || !WorkerTurn) return;
    var login = force ? null : held?.Login;
    if (await revoke(device, login, CancellationToken.None).ConfigureAwait(false)) return;
    foreach (var wait in retries)
    {
      await Task.Delay(wait, clock).ConfigureAwait(false);
      if (!force) lock (gate) if (issued.GetValueOrDefault(device) != generation) return;
      if (await revoke(device, login, CancellationToken.None).ConfigureAwait(false)) return;
    }
  }

  /// The phone host is stopping (device access switched off for the whole app, or the app closing): every login this
  /// run handed out is withdrawn now, by name, while the relay settings still exist (Security S1, #27), instead of
  /// waiting for the 2-minute timers that would fire after the relay client is gone. Waits at most `within`.
  public async Task WithdrawAllAsync(TimeSpan within)
  {
    var holders = Holders;
    if (holders.Count == 0) return;
    var all = Task.WhenAll(holders.Select(device => ReleaseAsync(device, force: false)));
    await Task.WhenAny(all, Task.Delay(within, clock)).ConfigureAwait(false);
  }

  /// For tests: the devices holding a cached login.
  public IReadOnlyCollection<string> Holders { get { lock (gate) return cached.Keys.ToArray(); } }

  private static IReadOnlyList<LinkIceServer> WithStun(IReadOnlyList<LinkIceServer> servers) =>
    servers.Any(s => s.Urls.Any(u => u.StartsWith("stun:", StringComparison.Ordinal))) ? servers : [LinkPaths.CloudflareStun, .. servers.Take(7)];

  /// `[{"urls":[…],"username":…,"credential":…}]`.
  public static IReadOnlyList<LinkIceServer>? ParseList(string json)
  {
    try
    {
      using var document = JsonDocument.Parse(json);
      return document.RootElement.ValueKind == JsonValueKind.Array ? RelayTurnLogins.ParseServers(document.RootElement) : null;
    }
    catch (JsonException) { return null; }
  }
}
