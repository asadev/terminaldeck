using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

/// Every address the account uses, read through this one interface so the identity host can move by configuration
/// (architect's plan §0: a discovery document will fill it; today it holds the addresses the Mac uses).
public interface AccountEndpoints
{
  Uri SignInStart { get; }
  Uri Exchange { get; }
  Uri CloudBase { get; }
  Uri Token { get; }
  Uri Logout { get; }
  string Issuer { get; }
}
public static class AccountEndpointChecks
{
  public static Uri Cloud(this AccountEndpoints endpoints, string path) => new(endpoints.CloudBase.AbsoluteUri.TrimEnd('/') + path);
  /// HTTPS only, no user info or fragment, and a Cloud base that ends in /v1 (the device proof signs `/v1/...`).
  public static void Check(this AccountEndpoints endpoints)
  {
    foreach (var url in new[] { endpoints.SignInStart, endpoints.Exchange, endpoints.CloudBase, endpoints.Token, endpoints.Logout })
      if (url.Scheme != "https" || string.IsNullOrEmpty(url.Host) || !string.IsNullOrEmpty(url.UserInfo) || !string.IsNullOrEmpty(url.Fragment))
        throw new CloudFailure("unsafe_configuration");
    if (endpoints.CloudBase.AbsolutePath.TrimEnd('/') != "/v1" || string.IsNullOrEmpty(endpoints.Issuer)) throw new CloudFailure("unsafe_configuration");
  }
}
/// Today's addresses, the same the Mac 0.22.0 uses.
public sealed record FixedAccountEndpoints(Uri SignInStart, Uri Exchange, Uri CloudBase, Uri Token, Uri Logout, string Issuer) : AccountEndpoints
{
  public static FixedAccountEndpoints Today { get; } = new(new Uri(CloudWire.WebsiteStart), new Uri(CloudWire.ProductionBase + "/auth/exchange"),
    new Uri(CloudWire.ProductionBase), new Uri(CloudWire.Issuer + "/token?grant_type=refresh_token"), new Uri(CloudWire.Issuer + "/logout"), CloudWire.Issuer);
}
/// What this device says about itself, plus the Store's public client key (needed to refresh a token; empty until
/// release tooling supplies it, as on the Mac).
public sealed record CloudConfiguration(AccountEndpoints Endpoints, string DeviceLabel, string AppVersion, string PublishableKey = "", string Platform = "windows")
{
  public static CloudConfiguration Today(string deviceLabel, string appVersion, string publishableKey = "") =>
    new(FixedAccountEndpoints.Today, deviceLabel.Length > 80 ? deviceLabel[..80] : deviceLabel, appVersion, publishableKey);
}

/// Cloud sign-in on this PC: sign in through the official website with the same account as the Mac, register this PC as
/// a device with its own keys, show the account's devices, sign out.
///
/// Inert until the person presses Sign in: constructing it does no IO, `ResumeAsync` only looks whether a protected
/// record exists, and only `BeginSignInAsync` (reached from the Settings button, never from a tool) makes a key, sends
/// a request or writes a file. 13 Nov (owner): the browser comes back on `terminaldeck://cloud/return/<token>`; there is
/// no listener and no "Sign in on this PC?" question. The app finishes by itself, but only a return that answers the
/// sign-in THIS app started (token and state, within its lifetime, once).
public sealed partial class CloudAccountClient : IDisposable
{
  private sealed record Flow(string Verifier, string State, CloudHandoffCallback Callback, DateTimeOffset Expires);
  /// `CloudOff`: the person turned "Use Cloud on this PC" off. A sign-in always starts with it on (joining is automatic).
  private sealed record Saved(CloudAuthSession Session, string DeviceId, string Signing, string Wrapping, bool Registered, bool CloudOff = false);

  private readonly CloudConfiguration configuration;
  private readonly ICloudSecretStore store;
  private readonly ICloudHttp http;
  private readonly ICloudRandom random;
  private readonly ICloudBrowser browser;
  private readonly TimeProvider clock;
  private readonly SemaphoreSlim work = new(1, 1);
  private readonly object gate = new();
  private CloudSnapshot current = CloudSnapshot.Dormant;
  private Flow? flow;
  private Saved? saved;
  private CloudDeviceKeys? keys;
  private int generation;

  public event Action<CloudSnapshot>? Changed;
  public CloudSnapshot Snapshot { get { lock (gate) return current; } }
  /// One plain line per sign-in stage (`cloud sign-in: <stage> ok|failed: <kind>`), never a token, code, key, e-mail or
  /// name. The app appends it to its log.
  public Action<string>? StageLog { get; set; }

  public CloudAccountClient(CloudConfiguration configuration, ICloudSecretStore store, ICloudHttp http, ICloudRandom random, ICloudBrowser browser,
    TimeProvider? clock = null)
  {
    this.configuration = configuration; configuration.Endpoints.Check(); this.store = store; this.http = http; this.random = random; this.browser = browser;
    this.clock = clock ?? TimeProvider.System;
  }

  private long Now => clock.GetUtcNow().ToUnixTimeMilliseconds();
  private void Publish(CloudSnapshot next)
  {
    if (next.Phase is CloudPhase.SignedIn or CloudPhase.NotAllowed or CloudPhase.Paused && saved is { } record) next = next with { Provider = record.Session.User.Provider };
    lock (gate) current = next;
    Changed?.Invoke(next);
  }
  private string Random(int bytes) { var buffer = new byte[bytes]; random.Fill(buffer); var text = CloudWire.Base64Url(buffer); CryptographicOperations.ZeroMemory(buffer); return text; }

  private string stage = "";
  private void Log(string line) { try { StageLog?.Invoke(line); } catch (Exception) { } }
  private void Stage(string next) { if (stage.Length > 0) Log("cloud sign-in: " + stage + " ok"); stage = next; }
  private void StageFailed(Exception error) { if (stage.Length > 0) Log("cloud sign-in: " + stage + " failed: " + Kind(error)); stage = ""; }
  /// The error's kind only: the service's own code or a plain word, never a payload.
  public static string Kind(Exception error) => error switch
  {
    CloudFailure f => "service " + new string(f.Code.Where(c => char.IsAsciiLetterOrDigit(c) || c == '_').Take(60).ToArray()),
    CloudTrustRefusal r => "trust " + r.Kind,
    HttpRequestException => "network",
    OperationCanceledException => "cancelled",
    JsonException => "invalid answer",
    _ => error.GetType().Name
  };

  /// At launch. Without a saved record this is the dormant state and nothing is asked of anyone.
  public async Task ResumeAsync(CancellationToken ct = default)
  {
    if (!store.Exists) { Publish(CloudSnapshot.Dormant); return; }
    await work.WaitAsync(ct);
    try
    {
      if (!Load()) { Publish(CloudSnapshot.Dormant); return; }
      Publish(new(CloudPhase.SignedIn, saved!.Session.User.Email, saved.Session.User.DisplayName, saved.DeviceId, configuration.DeviceLabel, Problem: "Checking Cloud…"));
      await RefreshLockedAsync(generation, ct);
    }
    finally { work.Release(); }
  }

  /// The person's Sign in press. Returns the address the browser was sent to: the website's start with the "app" callback
  /// kind (`platform=windows`, `device=<PC name, at most 64>`), the 22-character token, the 43-character state and PKCE.
  public async Task<Uri> BeginSignInAsync(CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try
    {
      if (Load()) throw new CloudFailure("already_signed_in");
      var version = ++generation;
      var verifier = Random(CloudWire.VerifierBytes);
      var state = Random(CloudWire.StateBytes);
      var token = Random(CloudWire.CallbackCodeBytes);
      var challenge = CloudWire.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
      var callback = CloudHandoffCallback.App(configuration.Platform, token);
      flow = new(verifier, state, callback, clock.GetUtcNow() + CloudWire.SignInLifetime);
      var query = $"challenge={challenge}&state={state}&callback={token}&platform={Uri.EscapeDataString(configuration.Platform)}"
        + $"&device={Uri.EscapeDataString(StartDeviceLabel(configuration.DeviceLabel))}";
      var url = new Uri(configuration.Endpoints.SignInStart.GetLeftPart(UriPartial.Path) + "?" + query);
      Publish(new(CloudPhase.SigningIn));
      try { await browser.OpenAsync(url, ct); }
      catch { flow = null; Publish(new(CloudPhase.SignedOut, Problem: "Could not open the browser. Try again.")); throw; }
      _ = ForgetLaterAsync(version);
      return url;
    }
    finally { work.Release(); }
  }
  /// The optional `device=` of the website's start: the label the registration sends, cut to 64 UTF-16 units.
  public static string StartDeviceLabel(string label)
  {
    if (label.Length <= 64) return label;
    var cut = label[..64];
    return char.IsHighSurrogate(cut[^1]) ? cut[..^1] : cut;
  }
  private async Task ForgetLaterAsync(int version)
  {
    try { await Task.Delay(CloudWire.SignInLifetime, clock); } catch (Exception) { return; }
    Abandon(version);
  }

  /// The person closed the sign-in, or five minutes passed: nothing is left behind.
  public void CancelSignIn() => Abandon(Volatile.Read(ref generation));
  private void Abandon(int version)
  {
    if (version != Volatile.Read(ref generation) || Snapshot.Phase != CloudPhase.SigningIn) return;
    flow = null;
    Publish(new(CloudPhase.SignedOut));
  }

  /// Is a sign-in this app started still waiting for its return?
  public bool HasPendingSignIn => flow is { } pending && pending.Expires > clock.GetUtcNow();

  /// The return link from the website. Finished only when its token AND state are those of the pending sign-in this app
  /// started, within its lifetime, and only once (the pending sign-in is consumed before anything is awaited, so a
  /// second copy of the link finds nothing to answer). Anything else returns false and changes nothing: no state, no
  /// notice, no request; it only writes one plain line to the log.
  public async Task<bool> FinishAppReturnAsync(Uri link, CancellationToken ct = default)
  {
    var back = CloudAppReturn.Parse(link);
    await work.WaitAsync(ct);
    try
    {
      var pending = flow;
      var refused = back is null ? "not a sign-in return"
        : pending is null || !pending.Callback.IsApp ? "no pending sign-in"
        : pending.Expires <= clock.GetUtcNow() ? "sign-in expired"
        : !CloudAppReturn.Same(pending.Callback.PathToken, back.Token) || !CloudAppReturn.Same(pending.State, back.State) ? "sign-in does not match"
        : null;
      if (refused is not null) { Log("cloud sign-in: return to app failed: " + refused); return false; }
      flow = null;
      stage = "";
      Stage("return to app");
      await FinishLockedAsync(pending!, back!.Code, generation, ct);
      return true;
    }
    finally { work.Release(); }
  }

  private async Task FinishLockedAsync(Flow pending, string code, int version, CancellationToken ct)
  {
    try
    {
      Stage("code exchange");
      var exchange = new CloudHandoffExchange(code, pending.Verifier, pending.Callback);
      var answer = await SendAsync(HttpMethod.Post, configuration.Endpoints.Exchange, CloudWire.Canonical(exchange), Json(), ct);
      var session = CloudWire.Decode<CloudAuthSession>(answer);
      Validate(session);
      if (version != generation)
      {
        // The service already issued this session; a sign-in this PC abandoned meanwhile ends it there too.
        await LogoutAsync(session.AccessToken);
        throw new OperationCanceledException();
      }
      Stage("save sign-in");
      var fresh = CloudDeviceKeys.Fresh();
      var (signing, wrapping) = fresh.Sealed();
      Save(new Saved(session, fresh.DeviceId, signing, wrapping, false));
      keys = fresh;
      await RefreshLockedAsync(version, ct, firstSignIn: true);
      Stage("");
      Log(Snapshot.Phase == CloudPhase.NotAllowed ? "cloud sign-in: finished, Cloud not allowed" : "cloud sign-in: finished");
    }
    catch (Exception error) when (version == generation)
    {
      StageFailed(error);
      if (Snapshot.Phase is CloudPhase.SigningIn or CloudPhase.SignedIn && saved is not null && !saved.Registered) ClearLocal();
      if (Snapshot.Phase is not (CloudPhase.SignedIn or CloudPhase.NotAllowed)) Publish(new(CloudPhase.SignedOut, Problem: "Could not sign in. Try again."));
      throw;
    }
  }

  /// Ask Cloud again (the page's "Check again", and at launch). Never signs in.
  public async Task RefreshAsync(CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try { if (Load()) await RefreshLockedAsync(generation, ct); }
    finally { work.Release(); }
  }

  private async Task RefreshLockedAsync(int version, CancellationToken ct, bool firstSignIn = false, bool triedToken = false, bool triedRegister = false)
  {
    var record = saved ?? throw new CloudFailure("gate_closed");
    try
    {
      if (firstSignIn) Stage("Cloud status");
      if (record.Session.ExpiresAt <= Now + 60_000) record = await RefreshTokenAsync(record, ct);
      var gateAnswer = await CapabilitiesAsync(record, ct);
      if (version != generation) return;
      if (gateAnswer is null)
      {
        // The service did not accept the token: refresh it once, then a repeat means the session is gone.
        if (triedToken) { await ClearSignInAsync(); return; }
        await RefreshTokenAsync(record, ct, force: true);
        await RefreshLockedAsync(version, ct, firstSignIn, triedToken: true, triedRegister);
        return;
      }
      var user = record.Session.User;
      if (!gateAnswer.EntitlesCloud)
      {
        // An explicit "not allowed": the sign-in is kept, nothing runs, no device is registered.
        Publish(new(CloudPhase.NotAllowed, user.Email, user.DisplayName, record.DeviceId, configuration.DeviceLabel));
        return;
      }
      var own = keys!;
      if (!record.Registered || triedRegister)
      {
        if (firstSignIn) Stage("device registration");
        var registration = own.Registration(configuration.DeviceLabel, configuration.AppVersion, configuration.Platform);
        var receipt = CloudWire.Decode<CloudDeviceRegistrationReceipt>(await SignedAsync(record, HttpMethod.Post, "/devices", CloudWire.Canonical(registration), ct));
        if (receipt.DeviceId != registration.DeviceId || receipt.Status != "active") throw new CloudFailure("device_revoked");
        if (version != generation) return;
        record = record with { Registered = true }; Save(record);
      }
      if (firstSignIn) Stage("devices");
      var list = CloudWire.Decode<CloudDeviceList>(await SignedAsync(record, HttpMethod.Get, "/devices", [], ct));
      if (version != generation) return;
      Publish(new(record.CloudOff ? CloudPhase.Paused : CloudPhase.SignedIn, user.Email, user.DisplayName, record.DeviceId, configuration.DeviceLabel, Rows(list, record.DeviceId)));
    }
    catch (CloudFailure failure) when (version == generation)
    {
      if (failure.Code is "sign_in_required" or "token_expired" && !triedToken)
      {
        try { await RefreshTokenAsync(saved ?? record, ct, force: true); }
        catch (CloudFailure again) when (SessionRefused(again)) { await ClearSignInAsync(); throw; }
        await RefreshLockedAsync(version, ct, firstSignIn, triedToken: true, triedRegister); return;
      }
      if (failure.Code == "bad_device_proof" && !triedRegister) { await RefreshLockedAsync(version, ct, firstSignIn, triedToken, triedRegister: true); return; }
      if (SessionRefused(failure) || failure.Code is "sign_in_required" or "token_expired") { await ClearSignInAsync(); throw; }
      if (firstSignIn) throw;
      var now = Snapshot;
      var phase = now.Phase is CloudPhase.SignedIn or CloudPhase.NotAllowed or CloudPhase.Paused ? now.Phase : CloudPhase.SignedIn;
      Publish(now with { Phase = phase, Email = record.Session.User.Email, DisplayName = record.Session.User.DisplayName, Problem = failure.Code == "clock_skew"
        ? "Cloud could not check this PC's request. Check this PC's date and time."
        : "Could not reach Cloud. Try again later." });
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException && version == generation && !firstSignIn && !ct.IsCancellationRequested)
    {
      Publish(Snapshot with { Problem = "Could not reach Cloud. Try again later." });
    }
  }

  /// Only these mean the session itself is invalid or revoked (the Mac's list); anything else keeps the sign-in.
  public static bool SessionRefused(CloudFailure failure) => !failure.Retryable && failure.Code is "session_not_found" or "refresh_token_not_found" or "user_not_found"
    or "invalid_grant" or "session_revoked" or "session_invalid" or "invalid_session" or "device_revoked" or "user_banned";

  /// The person's Sign out press. Local only plus one logout request; never removes anything but Cloud's own record.
  public async Task SignOutAsync(CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try { Interlocked.Increment(ref generation); await ClearSignInAsync(); }
    finally { work.Release(); }
  }

  private async Task ClearSignInAsync()
  {
    var session = saved?.Session;
    flow = null;
    ClearLocal();
    Publish(new(CloudPhase.SignedOut));
    if (session is not null) await LogoutAsync(session.AccessToken);
  }
  private void ClearLocal() { saved = null; keys = null; store.Remove(); }

  private bool Load()
  {
    if (saved is not null) return true;
    var bytes = store.Read();
    if (bytes is null) return false;
    try
    {
      var record = CloudWire.Decode<Saved>(bytes);
      keys = CloudDeviceKeys.Load(record.DeviceId, record.Signing, record.Wrapping);
      saved = record;
      return true;
    }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  private void Save(Saved record)
  {
    var bytes = CloudWire.Canonical(record);
    try { store.Write(bytes); saved = record; }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }

  private async Task<CloudGate?> CapabilitiesAsync(Saved record, CancellationToken ct)
  {
    // Always a 2xx from the service; `session: "invalid"` says the token was not accepted.
    var body = await SendAsync(HttpMethod.Get, configuration.Endpoints.Cloud("/capabilities"), [], Bearer(record.Session.AccessToken), ct);
    using var doc = JsonDocument.Parse(body);
    var root = doc.RootElement;
    if (root.TryGetProperty("session", out var session) && session.GetString() != "valid") return null;
    var features = root.TryGetProperty("features", out var f) && f.ValueKind == JsonValueKind.Array ? f.EnumerateArray().Select(x => x.GetString() ?? "").ToArray() : [];
    bool? entitled = root.TryGetProperty("storageEntitled", out var s) && s.ValueKind is JsonValueKind.True or JsonValueKind.False ? s.GetBoolean() : null;
    // "cloud" without an entitlement value is no answer.
    if (features.Contains("cloud") && entitled is null) throw new CloudFailure("unavailable", 0, true);
    return new CloudGate(features, entitled);
  }

  private async Task<Saved> RefreshTokenAsync(Saved record, CancellationToken ct, bool force = false)
  {
    if (!force && record.Session.ExpiresAt > Now + 60_000) return record;
    var headers = Json();
    if (configuration.PublishableKey.Length > 0) headers["apikey"] = configuration.PublishableKey;
    // `client_id` names this app to the identity service (its `clients` table: windows); today's service ignores it.
    var body = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["refresh_token"] = record.Session.RefreshToken, ["client_id"] = CloudWire.ClientId });
    var answer = await SendAsync(HttpMethod.Post, configuration.Endpoints.Token, body, headers, ct);
    using var doc = JsonDocument.Parse(answer);
    var raw = doc.RootElement;
    if (!raw.TryGetProperty("access_token", out var access) || !raw.TryGetProperty("refresh_token", out var refresh) || !raw.TryGetProperty("expires_at", out var expiry)
      || expiry.GetDouble() * 1000 <= Now || !raw.TryGetProperty("user", out var user) || user.GetProperty("id").GetString() != record.Session.User.Id)
      throw new CloudFailure("invalid_response");
    var session = record.Session with { AccessToken = access.GetString()!, RefreshToken = refresh.GetString()!, ExpiresAt = (long)(expiry.GetDouble() * 1000) };
    Validate(session);
    var next = record with { Session = session };
    Save(next);
    return next;
  }

  private void Validate(CloudAuthSession session)
  {
    var now = Now;
    if (!Guid.TryParse(session.User.Id, out _) || session.RefreshToken.Length == 0 || session.ExpiresAt <= now || session.ExpiresAt > now + 3_630_000)
      throw new CloudFailure("invalid_request");
    var parts = session.AccessToken.Split('.');
    if (parts.Length != 3 || CloudWire.FromBase64Url(parts[1]) is not { } payload) throw new CloudFailure("invalid_request");
    using var doc = JsonDocument.Parse(payload);
    var c = doc.RootElement;
    string? S(string name) => c.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    double? N(string name) => c.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;
    if (S("iss") != configuration.Endpoints.Issuer || S("sub") != session.User.Id || S("role") != "authenticated" || S("aud") != "authenticated"
      || N("exp") is not { } exp || N("iat") is not { } iat || exp * 1000 < now - 30_000 || iat * 1000 > now + 30_000 || exp - iat > 3600
      || !Guid.TryParse(S("session_id"), out _))
      throw new CloudFailure("invalid_request");
  }

  private Task<byte[]> SignedAsync(Saved record, HttpMethod method, string path, byte[] body, CancellationToken ct)
  {
    var url = configuration.Endpoints.Cloud(path);
    var headers = Bearer(record.Session.AccessToken);
    if (body.Length > 0) headers["content-type"] = "application/json";
    foreach (var (name, value) in keys!.Proof(method.Method, url.PathAndQuery, body, Now, Guid.NewGuid().ToString("D"))) headers[name] = value;
    return SendAsync(method, url, body, headers, ct);
  }
  private async Task<byte[]> SendAsync(HttpMethod method, Uri url, byte[] body, Dictionary<string, string> headers, CancellationToken ct)
  {
    var response = await http.SendAsync(new(method, url, headers, body), ct);
    if (response.Status is < 200 or > 299) throw CloudFailure.From(response.Status, response.Body);
    return response.Body;
  }
  private async Task LogoutAsync(string accessToken)
  {
    var headers = Bearer(accessToken);
    if (configuration.PublishableKey.Length > 0) headers["apikey"] = configuration.PublishableKey;
    try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10)); await http.SendAsync(new(HttpMethod.Post, configuration.Endpoints.Logout, headers, []), timeout.Token); }
    catch (Exception) { } // Signing out here never waits on the network; the local record is already gone.
  }
  private static Dictionary<string, string> Json() => new() { ["content-type"] = "application/json" };
  private static Dictionary<string, string> Bearer(string token) => new() { ["Authorization"] = "Bearer " + token };

  internal static IReadOnlyList<CloudDeviceRow> Rows(CloudDeviceList list, string thisDevice) => list.Devices
    .Select(d => new CloudDeviceRow(d.DeviceId, OneLine(d.Label), d.Platform, d.DeviceId == thisDevice, d.Status != "active",
      d.RegisteredAt is { } added ? DateTimeOffset.FromUnixTimeMilliseconds(added) : null,
      d.LastSeenAt > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(d.LastSeenAt) : null,
      CloudDeviceCode.Code(d.DeviceId, d.SignPublicJwk) ?? "—"))
    .OrderByDescending(r => r.ThisDevice).ThenBy(r => r.Removed).ThenBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
  /// A device names itself; its text is shown as one plain line and never reaches an agent raw.
  internal static string OneLine(string label)
  {
    var text = new string(label.Select(c => char.IsControl(c) || char.GetUnicodeCategory(c) is System.Globalization.UnicodeCategory.Format ? ' ' : c).ToArray());
    text = string.Join(' ', text.Split(' ', StringSplitOptions.RemoveEmptyEntries));
    return text.Length == 0 ? "Unnamed device" : text.Length > 80 ? text[..80] : text;
  }

  public void Dispose() => work.Dispose();
}
