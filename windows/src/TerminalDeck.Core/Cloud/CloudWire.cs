using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace TerminalDeck.Core.Cloud;

// The Cloud contract as the Mac speaks it (TerminalDeckNativeCore CloudContract.swift, CloudAccount.swift) and the
// service answers it (cloud/worker/src auth.ts, user.ts). Slice 1 needs only sign-in, refresh, device registration
// and the device list; nothing here syncs, applies or trusts anything.
public static class CloudWire
{
  public const string Issuer = "https://api.terminaldeck.dev/auth/v1";
  public const string ProductionBase = "https://cloud.terminaldeck.dev/v1";
  public const string WebsiteStart = "https://terminaldeck.dev/api/store/cloud/start";
  /// This app's name for itself at the identity service (`clients.client_id`) and its platform on the app callback.
  public const string ClientId = "windows", Platform = "windows";
  /// The service's lengths, as the Mac uses them: the callback path token is 16 random bytes (22 base64url
  /// characters, auth.ts `callback`), the sign-in state 32 bytes (43 characters, the website's `_flow.js`), the PKCE
  /// verifier 48 bytes (64 characters, within the service's 43..128).
  public const int CallbackCodeBytes = 16, StateBytes = 32, VerifierBytes = 48;
  public const int MaximumBodyBytes = 409_600;
  /// A sign-in that is not finished in five minutes is forgotten (the website's flow cookie lasts as long).
  public static readonly TimeSpan SignInLifetime = TimeSpan.FromMinutes(5);
  public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

  public static string Base64Url(ReadOnlySpan<byte> bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
  public static byte[]? FromBase64Url(string? text)
  {
    if (string.IsNullOrEmpty(text) || !text.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_')) return null;
    var padded = text.Replace('-', '+').Replace('_', '/');
    padded += new string('=', (4 - padded.Length % 4) % 4);
    try { return Convert.FromBase64String(padded); } catch (FormatException) { return null; }
  }
  public static string Sha256Hex(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

  /// Compact JSON with keys in code-unit order, the form the Mac sends (`CloudWire.canonical`).
  public static byte[] Canonical<T>(T value) => Encoding.UTF8.GetBytes(Sort(JsonSerializer.SerializeToNode(value, Json))?.ToJsonString() ?? "null");
  private static JsonNode? Sort(JsonNode? node) => node switch
  {
    JsonObject o => new JsonObject(o.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => KeyValuePair.Create(p.Key, Sort(p.Value?.DeepClone())))),
    JsonArray a => new JsonArray(a.Select(item => Sort(item?.DeepClone())).ToArray()),
    _ => node?.DeepClone()
  };

  public static T Decode<T>(byte[] body)
  {
    if (body.Length > MaximumBodyBytes) throw new CloudFailure("invalid_response");
    try { return JsonSerializer.Deserialize<T>(body, Json) ?? throw new CloudFailure("invalid_response"); }
    catch (JsonException) { throw new CloudFailure("invalid_response"); }
  }
}

/// A refusal or a failed request. `Code` is the service's own code when it gave one (`{error:{code}}` from Cloud,
/// `{error_code}` from the Store), otherwise one of ours.
public sealed class CloudFailure(string code, int status = 0, bool retryable = false) : Exception("Cloud could not finish this request.")
{
  public string Code { get; } = code;
  public int Status { get; } = status;
  public bool Retryable { get; } = retryable;
  public static CloudFailure From(int status, byte[] body)
  {
    string? code = null;
    try
    {
      using var doc = JsonDocument.Parse(body);
      var root = doc.RootElement;
      if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.Object && e.TryGetProperty("code", out var c)) code = c.GetString();
      else if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("error_code", out var s)) code = s.GetString();
    }
    catch (JsonException) { }
    return new CloudFailure(code ?? "unavailable", status, status >= 500 || status == 429);
  }
}

public enum CloudPhase { Dormant, SignedOut, SigningIn, SignedIn, NotAllowed, Paused }

/// The exchange's `callback`. 13 Nov (owner): Windows signs in through the official website and comes back on
/// `terminaldeck://cloud/return/<token>`, so it sends the app kind `{kind:"app", platform:"windows", pathToken}`; the
/// loopback form `{port, pathToken}` is no longer used here (nulls are left out of the canonical form).
public sealed record CloudHandoffCallback(int? Port, string PathToken, string? Kind = null, string? Platform = null)
{
  public static CloudHandoffCallback App(string platform, string pathToken) => new(null, pathToken, "app", platform);
  [JsonIgnore] public bool IsApp => Kind == "app" && Port is null;
}
public sealed record CloudHandoffExchange(string Code, string Verifier, CloudHandoffCallback Callback);
public sealed record CloudUserIdentity(string Id, string DisplayName, string? Email = null, string? Provider = null);
public sealed record CloudGate(IReadOnlyList<string> Features, bool? StorageEntitled = null, bool? AiSubscriptionsEnabled = null, string? Revision = null)
{
  public static CloudGate Closed { get; } = new([]);
  /// The server's explicit decision alone: "cloud" among the features AND storage entitled.
  public bool EntitlesCloud => Features.Contains("cloud") && StorageEntitled == true;
}
public sealed record CloudAuthSession(string AccessToken, string RefreshToken, long ExpiresAt, CloudUserIdentity User, CloudGate? Capabilities = null, string? ResetTicket = null)
{
  public override string ToString() => "<Cloud session>";
}
public sealed record CloudPublicJwk(string Kty, string Crv, string X, string? Y = null);
public sealed record CloudDeviceRegistration(string DeviceId, string Label, string Platform, string AppVersion, CloudPublicJwk SignPublicJwk, CloudPublicJwk WrapPublicJwk);
public sealed record CloudDeviceRegistrationReceipt(string DeviceId, string Status, bool SecretsApproved, string? HeadSeq = null, string? VaultState = null);
public sealed record CloudDevice(string DeviceId, string Label, string Platform, string AppVersion, string Status, bool SecretsApproved, long LastSeenAt,
  CloudPublicJwk SignPublicJwk, CloudPublicJwk WrapPublicJwk, long? RegisteredAt = null);
public sealed record CloudDeviceList(IReadOnlyList<CloudDevice> Devices, string? ReceiverDeviceId = null);

/// One row of the page's device list. Display only: nothing in slice 1 trusts a device.
/// `Trust`: the device as this PC's trusted list sees it (never drawn as such). `Joined`: show "joined your account".
public sealed record CloudDeviceRow(string DeviceId, string Name, string Platform, bool ThisDevice, bool Removed, DateTimeOffset? Added, DateTimeOffset? LastSeen, string ShortCode,
  CloudTrustRow? Trust = null, bool Joined = false);

/// What the Cloud page and `cloud.status` show. Never carries a token or a key.
public sealed record CloudSnapshot(CloudPhase Phase, string? Email = null, string? DisplayName = null, string? ThisDeviceId = null,
  string? ThisDeviceName = null, IReadOnlyList<CloudDeviceRow>? Devices = null, string? Problem = null, string? Provider = null,
  CloudTrustMode? TrustMode = null, string? TrustNotice = null)
{
  public static CloudSnapshot Dormant { get; } = new(CloudPhase.Dormant);
  public IReadOnlyList<CloudDeviceRow> DeviceRows => Devices ?? [];
  /// "Use Cloud on this PC": on from the moment of sign-in (joining is automatic); Paused is the switch turned off.
  public bool UseCloud => Phase == CloudPhase.SignedIn;
  public string Account => !string.IsNullOrEmpty(Email) ? Email! : !string.IsNullOrEmpty(DisplayName) ? DisplayName! : "this account";
}
