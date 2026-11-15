using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Remote;

/// A reach route the service refused. `Retryable`: a 5xx or 429.
public sealed class ReachServiceException(string code, int status) : Exception("Cloud could not finish this reach request.")
{
  public string Code { get; } = code;
  public int Status { get; } = status;
  public bool Retryable => Status >= 500 || Status == 429;
}

/// What the reach service needs of this PC's Cloud sign-in (bound to CloudAccountClient by the app; fakes in tests).
/// Nothing here keeps a token: each call asks the account for its current one.
public sealed record ReachAccountPort(
  Func<string?> Subject,
  Func<string?> DeviceId,
  Func<CancellationToken, Task<string>> AccessToken,
  /// Raw 64-byte P-256 signature (r||s) with this PC's Cloud device sign key.
  Func<byte[], byte[]> Sign);

/// The account service for reach, over this PC's Cloud sign-in (port of BackendReachAccountHTTP.swift; service:
/// cloud/worker/src/reach.ts). Every reach route is a signed device request exactly like the sync core's (`TD-CLOUD-1`
/// proof with this PC's device sign key, bearer access token); `/capabilities` takes the bearer only.
public sealed class ReachAccountHttpService(Uri @base, ICloudSyncHttp http, ReachAccountPort account, Func<long>? now = null) : IReachAccountService, IReachGuestService
{
  private readonly string root = @base.AbsoluteUri.TrimEnd('/');
  private readonly Func<long> now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

  public string? SignedInAccount() => account.Subject();
  public string? MachineDeviceId() => account.DeviceId();

  public async Task<bool> ReachEntitledAsync(CancellationToken ct = default)
  {
    var value = await CallAsync("GET", "/capabilities", null, ct, signed: false).ConfigureAwait(false);
    return value.TryGetProperty("features", out var features) && features.ValueKind == JsonValueKind.Array &&
      features.EnumerateArray().Any(f => f.ValueKind == JsonValueKind.String && f.GetString() == "reach");
  }

  public async Task<ReachRoster> RosterAsync(CancellationToken ct = default) =>
    ReachWire.Roster(await CallAsync("GET", "/reach/devices", null, ct).ConfigureAwait(false));

  public async Task<ReachRelayToken> RelayTokenAsync(CancellationToken ct = default)
  {
    var value = await CallAsync("POST", "/reach/token", "{}"u8.ToArray(), ct).ConfigureAwait(false);
    var token = value.TryGetProperty("token", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;
    if (token is null || token.Split('.').Length != 3 || !value.TryGetProperty("expiresAt", out var e) || e.ValueKind != JsonValueKind.Number)
      throw new ReachRefusedException(ReachRefusal.Unavailable);
    var scope = value.TryGetProperty("scope", out var s) && s.ValueKind == JsonValueKind.String ? s.GetString()! : "reach";
    return new(token, e.GetDouble(), scope);
  }

  public async Task PublishAsync(ReachPresenceRecord presence, CancellationToken ct = default)
  {
    if (account.DeviceId() is not { } id || id != presence.DeviceId) throw new ReachRefusedException(ReachRefusal.Unavailable);
    var signedAt = now();
    var sig = ReachWire.Base64Url(account.Sign(Encoding.UTF8.GetBytes(ReachWire.PresenceMessage(presence, signedAt))));
    await CallAsync("PUT", "/reach/presence", Encoding.UTF8.GetBytes(ReachWire.PresenceBody(presence, signedAt, sig)), ct).ConfigureAwait(false);
  }

  public Task WithdrawAsync(string deviceId, CancellationToken ct = default) =>
    CallAsync("DELETE", "/reach/presence", Encoding.UTF8.GetBytes(ReachWire.CanonicalObject([("deviceId", ReachWire.JsonString(deviceId))])), ct);

  public Task RemoveDeviceAsync(string deviceId, CancellationToken ct = default)
  {
    if (!ReachWire.ValidDeviceId(deviceId)) throw new ReachRefusedException(ReachRefusal.UnknownDevice);
    return CallAsync("POST", "/reach/devices/remove", Encoding.UTF8.GetBytes(ReachWire.CanonicalObject([("deviceId", ReachWire.JsonString(deviceId))])), ct);
  }

  // The guest half (ReachGuest): this PC reaching his other machines by the same sign-in.
  public async Task RegisterReachKeyAsync(string deviceId, string publicKey, CancellationToken ct = default)
  {
    if (account.DeviceId() is not { } id || id != deviceId) throw new ReachRefusedException(ReachRefusal.SignedOut);
    var sig = ReachWire.Base64Url(account.Sign(Encoding.UTF8.GetBytes(ReachWire.ReachKeyMessage(id, publicKey))));
    var body = ReachWire.CanonicalObject([("deviceId", ReachWire.JsonString(id)), ("reachPublicKey", ReachWire.JsonString(publicKey)), ("sig", ReachWire.JsonString(sig))]);
    await CallAsync("POST", "/devices/reach-key", Encoding.UTF8.GetBytes(body), ct).ConfigureAwait(false);
  }
  public async Task<IReadOnlyList<ReachMachine>> ReachMachinesAsync(CancellationToken ct = default) =>
    ReachMachine.List(await CallAsync("GET", "/reach/machines", null, ct).ConfigureAwait(false));

  /// The device proof the service checks (cloud/worker/src/user.ts): over method, path, time, request id and the body's
  /// SHA-256 (hex; the empty body's for GET).
  public static string ProofText(string method, string path, long time, string requestId, byte[] body) =>
    "TD-CLOUD-1\n" + method + "\n" + path + "\n" + time.ToString(CultureInfo.InvariantCulture) + "\n" + requestId + "\n" + Convert.ToHexStringLower(SHA256.HashData(body));

  internal async Task<CloudSyncHttpRequest> RequestAsync(string method, string path, byte[]? body, bool signed, CancellationToken ct)
  {
    var url = new Uri(root + path);
    var bytes = body ?? [];
    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
      ["authorization"] = "Bearer " + await account.AccessToken(ct).ConfigureAwait(false), ["cache-control"] = "no-store"
    };
    var requestId = Guid.NewGuid().ToString("D");
    if (signed)
    {
      if (account.DeviceId() is not { } id) throw new ReachRefusedException(ReachRefusal.SignedOut);
      var time = now();
      headers["x-td-device"] = id;
      headers["x-td-time"] = time.ToString(CultureInfo.InvariantCulture);
      headers["x-td-request"] = requestId;
      headers["x-td-signature"] = ReachWire.Base64Url(account.Sign(Encoding.UTF8.GetBytes(ProofText(method, url.AbsolutePath, time, requestId, bytes))));
      headers["content-type"] = "application/json";
    }
    else headers["x-td-request"] = requestId;
    return new(method, url, headers, bytes, 262_144);
  }

  private async Task<JsonElement> CallAsync(string method, string path, byte[]? body, CancellationToken ct, bool signed = true)
  {
    var answer = await http.SendAsync(await RequestAsync(method, path, body, signed, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
    // A refused access token: asked again once (the account renews it when it is about to expire).
    if (answer.Status == 401) answer = await http.SendAsync(await RequestAsync(method, path, body, signed, ct).ConfigureAwait(false), ct).ConfigureAwait(false);
    if (answer.Status is < 200 or > 299)
    {
      var code = "unavailable";
      try
      {
        using var doc = JsonDocument.Parse(answer.Body);
        if (doc.RootElement.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object && error.TryGetProperty("code", out var c) && c.ValueKind == JsonValueKind.String) code = c.GetString()!;
      }
      catch (JsonException) { }
      throw new ReachServiceException(code, answer.Status);
    }
    try { using var doc = JsonDocument.Parse(answer.Body.Length == 0 ? "{}"u8.ToArray() : answer.Body); return doc.RootElement.Clone(); }
    catch (JsonException) { throw new ReachServiceException("unavailable", 502); }
  }
}
