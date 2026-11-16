using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Remote;

// Reach by account on this PC (Devices seat, 15 Nov 2026): a port of the Mac's BackendReachAccount*.swift (lane/mac-next2).
// A phone, browser or computer signed in to the same Terminal Deck account opens this PC with no pairing code: signing
// in is the permission (owner, 13 Nov: "sign in once and everything follows"). This PC still judges every device itself
// (ReachAccountGate): its switch, its own sign-in, the account's device list fetched with its own token, the key it pinned
// for the device, the relay's mark. The service (cloud/worker/src/reach.ts) and the relay (relay/cloudflare/src/reach.ts)
// are unchanged. A device paired with a code before keeps working exactly as before: an unmarked relay channel never
// reaches anything in this file.

/// Policy A = account only (the owner's decision). Policy B = A plus one approval of each new device.
public enum ReachPolicy { AccountOnly, ApproveNew }

/// This PC's reach settings. `Enabled` is false until switched on, and false on any read failure.
public sealed record ReachSettings(bool Enabled = false, ReachPolicy Policy = ReachPolicy.AccountOnly);

/// One device of the account as the service lists it for a machine (`GET /v1/reach/devices`, one row of `devices`).
public sealed record ReachRosterDevice(string DeviceId, string Label, string Platform, byte[] ReachKey, bool Active = true, bool Removed = false,
  bool SessionLive = true, double? ExpiresAtMs = null, bool Approved = false, string? ApprovedBy = null, string? ApprovalSig = null);

/// The account's devices, as fetched with this PC's own token.
public sealed record ReachRoster(string Account, string Version, ReachPolicy Policy, IReadOnlyList<ReachRosterDevice> Devices);

/// What a machine publishes for its account (`PUT /v1/reach/presence`); the HTTP client adds `signedAt` and `sig`.
public sealed record ReachPresenceRecord(string DeviceId, string HostId, string HostKey, string Name, string Platform, ReachPolicy Policy);

/// A short-lived `aud=relay` token (15 minutes) from `POST /v1/reach/token`. Scope "reach", or "reach-host" (policy B,
/// this machine not approved yet: it may tie its room, never join).
public sealed record ReachRelayToken(string Token, double ExpiresAtMs, string Scope = "reach")
{
  public override string ToString() => "<reach relay token>";
}

/// The account service as reach needs it. Real: ReachAccountHttpService over this PC's Cloud sign-in.
public interface IReachAccountService
{
  /// The signed-in account's `sub`, or null when this PC is signed out.
  string? SignedInAccount();
  /// This PC's Cloud device id (null before registration).
  string? MachineDeviceId();
  Task<bool> ReachEntitledAsync(CancellationToken ct = default);
  Task<ReachRoster> RosterAsync(CancellationToken ct = default);
  Task<ReachRelayToken> RelayTokenAsync(CancellationToken ct = default);
  Task PublishAsync(ReachPresenceRecord presence, CancellationToken ct = default);
  Task WithdrawAsync(string deviceId, CancellationToken ct = default);
  /// `POST /v1/reach/devices/remove {deviceId}`: final for that device id.
  Task RemoveDeviceAsync(string deviceId, CancellationToken ct = default);
}

/// The relay as reach needs it: this PC's room tied to its account (only devices whose relay token names the same
/// account may then open an account channel) or untied again.
public interface IReachRelayDoor
{
  Task AttachAccountAsync(ReachRelayToken token);
  Task DetachAccountAsync();
}

public enum ReachNoticeKind { FirstConnection, KeyChanged, AwaitingApproval }

/// What the person must see. Names only (owner, 13 Nov): never an id, code, fingerprint or key.
public sealed record ReachNotice(ReachNoticeKind Kind, string DeviceId, string Label, string Platform = "")
{
  public string Sentence => Kind switch
  {
    ReachNoticeKind.FirstConnection => Label + " connected to this PC for the first time.",
    ReachNoticeKind.KeyChanged => Label + " tried to reach this PC from a different install and was refused. Remove it, then sign in on it again.",
    _ => Label + " asks to reach this PC and waits for your approval."
  };
}

/// Why a reach connection was refused. Never told to the connecting device in detail (it learns only "closed").
public enum ReachRefusal { SwitchOff, SignedOut, NotEntitled, OtherAccount, UnknownDevice, Removed, SessionEnded, KeyChanged, NotApproved, RateLimited, Unavailable, WrongDevice }

public sealed class ReachRefusedException(ReachRefusal why) : Exception("This device may not reach this PC.")
{
  public ReachRefusal Why { get; } = why;
}

/// A switch or approval press within the remote-input guard's window: not the person's own press.
public sealed class ReachRemoteInputException() : Exception("Turn this on at the PC itself, not from a connected device.");

/// The settings file could not be written.
public sealed class ReachStorageException(Exception inner) : IOException("The reach settings could not be saved.", inner);

public sealed record ReachAdmission(string DeviceId, string Label, string Platform, byte[] ReachKey, bool FirstTime)
{
  /// The id the phone host knows this device by. Never a paired device's id (those are minted base64url strings).
  public string HostDeviceId => HostId(DeviceId);
  public static string HostId(string deviceId) => "reach-" + deviceId;
  public static bool IsHostId(string id) => id.StartsWith("reach-", StringComparison.Ordinal);
  /// The hello's `token` for this device: a public name, not a credential.
  public string HelloToken => "reach:" + DeviceId;
  public override string ToString() => "<reach admission " + Label + ">";
}

public abstract record ReachDecision
{
  public sealed record Admitted(ReachAdmission Admission) : ReachDecision;
  public sealed record Refused(ReachRefusal Why) : ReachDecision;
}

public static class ReachWords
{
  public static string Kind(string platform) => platform.ToLowerInvariant() switch
  {
    "ios" => "iPhone", "android" => "Android phone", "web" => "Browser", "macos" => "Mac", "windows" => "Windows PC", _ => "Device"
  };
}

/// The service's and the relay's exact formats (keys and signatures base64url without padding; domain-separated signed
/// texts; canonical JSON as the service's `canonical()`; the relay's open mark).
public static partial class ReachWire
{
  public const byte OpenMark = 0x52;
  public const byte OpenVersion = 0x01;

  public enum OpenKindTag { Paired, Account, Invalid }
  public readonly record struct OpenKind(OpenKindTag Tag, string? DeviceId = null);

  /// A channel's `open` payload. An unmarked payload is today's paired join, exactly as before.
  public static OpenKind ReadOpen(ReadOnlySpan<byte> payload)
  {
    if (payload.Length < 1 || payload[0] != OpenMark) return new(OpenKindTag.Paired);
    if (payload.Length < 3 || payload.Length > 2 + 64 || payload[1] != OpenVersion) return new(OpenKindTag.Invalid);
    foreach (var b in payload[2..]) if (b > 0x7f) return new(OpenKindTag.Invalid);
    var id = Encoding.ASCII.GetString(payload[2..]);
    return ValidDeviceId(id) ? new(OpenKindTag.Account, id) : new(OpenKindTag.Invalid);
  }
  public static byte[] OpenPayload(string deviceId) => [OpenMark, OpenVersion, .. Encoding.ASCII.GetBytes(deviceId)];

  [GeneratedRegex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")]
  private static partial Regex DeviceIdPattern();
  /// Device ids are lowercase UUIDs (devices and browser session keys alike).
  public static bool ValidDeviceId(string? id) => id is { Length: 36 } && DeviceIdPattern().IsMatch(id);

  public static string Base64Url(ReadOnlySpan<byte> data) => Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
  /// Strict: only the unpadded url alphabet, and it must round-trip (as the service's `unb64`).
  public static byte[]? UnBase64Url(string? text, int? length = null)
  {
    if (text is null || text.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '-' or '_'))) return null;
    byte[] data;
    try { data = Convert.FromBase64String(text.Replace('-', '+').Replace('_', '/').PadRight((text.Length + 3) / 4 * 4, '=')); }
    catch (FormatException) { return null; }
    if (Base64Url(data) != text || length is { } n && data.Length != n) return null;
    return data;
  }

  public static string ReachKeyMessage(string deviceId, string key) => "TD-REACH-KEY-1\n" + deviceId + "\n" + key;
  public static string ApproveMessage(string deviceId, string key) => "TD-REACH-APPROVE-1\n" + deviceId + "\n" + key;
  public static string PolicyText(ReachPolicy policy) => policy == ReachPolicy.ApproveNew ? "B" : "A";
  public static string PresenceMessage(ReachPresenceRecord record, long signedAt) => "TD-REACH-PRESENCE-1\n" + PresenceCanonical(record, signedAt);
  /// The seven signed fields, keys sorted, as the service's `canonical()` writes them.
  public static string PresenceCanonical(ReachPresenceRecord r, long signedAt) => CanonicalObject([
    ("deviceId", JsonString(r.DeviceId)), ("hostId", JsonString(r.HostId)), ("hostKey", JsonString(r.HostKey)), ("name", JsonString(r.Name)),
    ("platform", JsonString(r.Platform)), ("policy", JsonString(PolicyText(r.Policy))), ("signedAt", signedAt.ToString(CultureInfo.InvariantCulture))]);
  /// The PUT body: the signed fields plus `sig`.
  public static string PresenceBody(ReachPresenceRecord r, long signedAt, string sig) => CanonicalObject([
    ("deviceId", JsonString(r.DeviceId)), ("hostId", JsonString(r.HostId)), ("hostKey", JsonString(r.HostKey)), ("name", JsonString(r.Name)),
    ("platform", JsonString(r.Platform)), ("policy", JsonString(PolicyText(r.Policy))), ("sig", JsonString(sig)), ("signedAt", signedAt.ToString(CultureInfo.InvariantCulture))]);
  public static string CanonicalObject(IEnumerable<(string Key, string Value)> fields) =>
    // JS sorts keys by UTF-16 code units; every key here is ASCII, so ordinal order is the same.
    "{" + string.Join(",", fields.OrderBy(f => f.Key, StringComparer.Ordinal).Select(f => JsonString(f.Key) + ":" + f.Value)) + "}";
  /// `JSON.stringify` of a string: `"` and `\` escaped, \b \f \n \r \t short forms, other controls as \u00xx, everything
  /// else (non-ASCII included) as is.
  public static string JsonString(string text)
  {
    var out_ = new StringBuilder("\"");
    foreach (var c in text)
    {
      switch (c)
      {
        case '"': out_.Append("\\\""); break;
        case '\\': out_.Append("\\\\"); break;
        case '\b': out_.Append("\\b"); break;
        case '\f': out_.Append("\\f"); break;
        case '\n': out_.Append("\\n"); break;
        case '\r': out_.Append("\\r"); break;
        case '\t': out_.Append("\\t"); break;
        default:
          if (c < 0x20) out_.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); else out_.Append(c);
          break;
      }
    }
    return out_.Append('"').ToString();
  }

  private static string? Str(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
  private static bool True(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
  private static double? Num(JsonElement row, string name) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;

  /// `GET /v1/reach/devices`. Rows with an unreadable id or key are dropped (never trusted); a missing account, version
  /// or list is an error.
  public static ReachRoster Roster(JsonElement value)
  {
    var account = Str(value, "account"); var version = Str(value, "version");
    if (string.IsNullOrEmpty(account) || version is null || !value.TryGetProperty("devices", out var rows) || rows.ValueKind != JsonValueKind.Array)
      throw new ReachRefusedException(ReachRefusal.Unavailable);
    var devices = new List<ReachRosterDevice>();
    foreach (var row in rows.EnumerateArray().Take(128))
    {
      var id = Str(row, "deviceId");
      if (!ValidDeviceId(id) || UnBase64Url(Str(row, "reachKey"), 32) is not { } key) continue;
      var label = Str(row, "label") ?? "Device";
      devices.Add(new(id!, label.Length > 80 ? label[..80] : label, Str(row, "platform") ?? "unknown", key, True(row, "active"), True(row, "removed"),
        True(row, "sessionLive"), Num(row, "expiresAtMs"), True(row, "approved"), Str(row, "approvedBy"), Str(row, "approvalSig")));
    }
    return new(account, version, Str(value, "policy") == "B" ? ReachPolicy.ApproveNew : ReachPolicy.AccountOnly, devices);
  }

  /// A `devices` event on the account's socket: {devicesVersion, reachRemoved?: [ids]}.
  public static IReadOnlyList<string> RemovedIds(JsonElement payload) =>
    payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("reachRemoved", out var list) && list.ValueKind == JsonValueKind.Array
      ? list.EnumerateArray().Take(64).Where(e => e.ValueKind == JsonValueKind.String && ValidDeviceId(e.GetString())).Select(e => e.GetString()!).ToArray()
      : [];
}

/// The PC's answer to a reach device's first sealed frame: the same Noise IK handshake as a paired device, the only
/// difference is WHICH keys are accepted (the account roster's, judged by the gate). The reply is handed back only after
/// the gate admits the device, so a refused device never gets a working channel. The relay connection calls this ONLY
/// for a channel the relay marked as an account channel; an unmarked channel never reaches it.
public sealed class ReachAccountDoor(ReachAccountGate gate)
{
  public ReachAccountGate Gate { get; } = gate;
  public sealed record Opened(NoiseResponse Response, ReachAdmission Admission);

  /// Throws ReachRefusedException for every refusal; the caller closes the channel and says nothing more.
  public async Task<Opened> AnswerAsync(NoiseIdentity identity, byte[] message, string? marked = null, CancellationToken ct = default)
  {
    if (!Gate.Settings().Enabled) throw new ReachRefusedException(ReachRefusal.SwitchOff);
    var keys = await Gate.CandidateKeysAsync(ct).ConfigureAwait(false);
    if (keys.Count == 0) throw new ReachRefusedException(ReachRefusal.UnknownDevice);
    NoiseResponse response;
    try { response = NoiseChannel.Respond(identity, message, keys, permitPairing: false); }
    catch (ProtocolException) { throw new ReachRefusedException(ReachRefusal.UnknownDevice); }
    switch (await Gate.AdmitAsync(response.PeerPublicKey, marked, ct).ConfigureAwait(false))
    {
      case ReachDecision.Admitted a: return new(response, a.Admission);
      case ReachDecision.Refused r: response.Transport.Dispose(); throw new ReachRefusedException(r.Why);
      default: response.Transport.Dispose(); throw new ReachRefusedException(ReachRefusal.Unavailable);
    }
  }
}

public enum ReachPresenceStatus { Off, SignedOut, NotEntitled, NotRegistered, Published, Failed }
public sealed record ReachHostCard(string HostId, string HostKey, string Name);

/// Publishes this PC for its account while reach is on, and withdraws it when it is not (a machine appears only while
/// signed in, entitled, running and switched on). The coordinator syncs every 60 s, on sign-in/out and when the switch
/// changes. The relay room is tied with a relay token only while published; renewed with less than five minutes left.
public sealed class ReachPresence(ReachAccountGate gate, IReachAccountService service, IReachRelayDoor relay, Func<ReachHostCard?> host, Func<double>? now = null)
{
  public const double TokenRenewMs = 300_000;
  private readonly Func<double> now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
  private readonly SemaphoreSlim one = new(1, 1);
  private string? publishedAs;
  private ReachRelayToken? token;
  public ReachPresenceStatus Last { get; private set; } = ReachPresenceStatus.Off;

  public async Task<ReachPresenceStatus> SyncAsync(CancellationToken ct = default)
  {
    await one.WaitAsync(ct).ConfigureAwait(false);
    try { return Last = await DecideAsync(ct).ConfigureAwait(false); }
    finally { one.Release(); }
  }

  private async Task<ReachPresenceStatus> DecideAsync(CancellationToken ct)
  {
    var settings = gate.Settings();
    if (!settings.Enabled) { await WithdrawCoreAsync().ConfigureAwait(false); return ReachPresenceStatus.Off; }
    if (service.SignedInAccount() is null) { await WithdrawCoreAsync().ConfigureAwait(false); return ReachPresenceStatus.SignedOut; }
    if (await gate.EntitledNowAsync(ct).ConfigureAwait(false) != true) { await WithdrawCoreAsync().ConfigureAwait(false); return ReachPresenceStatus.NotEntitled; }
    if (service.MachineDeviceId() is not { } deviceId || host() is not { } card) { await WithdrawCoreAsync().ConfigureAwait(false); return ReachPresenceStatus.NotRegistered; }
    try
    {
      if (token is null || token.ExpiresAtMs - now() < TokenRenewMs)
      {
        var fresh = await service.RelayTokenAsync(ct).ConfigureAwait(false);
        token = fresh;
        await relay.AttachAccountAsync(fresh).ConfigureAwait(false);
      }
      publishedAs = deviceId; // from here a later withdraw also unties the relay room
      await service.PublishAsync(new(deviceId, card.HostId, card.HostKey, card.Name, "windows", settings.Policy), ct).ConfigureAwait(false);
      return ReachPresenceStatus.Published;
    }
    catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { return ReachPresenceStatus.Failed; }
  }

  /// Off, signed out, not entitled or the app quitting: the record goes and the relay room is untied.
  public async Task WithdrawAsync()
  {
    await one.WaitAsync().ConfigureAwait(false);
    try { await WithdrawCoreAsync().ConfigureAwait(false); }
    finally { one.Release(); }
  }
  private async Task WithdrawCoreAsync()
  {
    token = null;
    if (publishedAs is not { } deviceId) return;
    publishedAs = null;
    await relay.DetachAccountAsync().ConfigureAwait(false);
    try { await service.WithdrawAsync(deviceId).ConfigureAwait(false); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}

/// This process's one place for the reach door and the relay token. Presence ties and unties every live relay client
/// through it; clients started later read it when they dial.
public sealed class ReachRelayLink : IReachRelayDoor
{
  private readonly object gate = new();
  private ReachAccountDoor? door;
  private ReachRelayToken? token;
  private readonly List<WeakReference<RelayHostClient>> clients = [];
  /// Called after the door admitted an account channel, before the device says hello (the phone host learns which
  /// admission the channel carries; nothing else can set it).
  public Action<string, ReachAdmission>? Admitted { get; set; }
  public ReachAccountDoor? Door { get { lock (gate) return door; } }
  public ReachRelayToken? Token { get { lock (gate) return token; } }
  public void SetDoor(ReachAccountDoor? value) { lock (gate) door = value; }

  internal void Add(RelayHostClient client) { lock (gate) { clients.RemoveAll(w => !w.TryGetTarget(out _)); clients.Add(new(client)); } }
  internal void Remove(RelayHostClient client) { lock (gate) clients.RemoveAll(w => !w.TryGetTarget(out var c) || ReferenceEquals(c, client)); }
  private RelayHostClient[] Live() { lock (gate) return clients.Select(w => w.TryGetTarget(out var c) ? c : null).OfType<RelayHostClient>().ToArray(); }

  public Task AttachAccountAsync(ReachRelayToken value)
  {
    lock (gate) token = value;
    foreach (var client in Live()) client.ReachTokenChanged();
    return Task.CompletedTask;
  }
  public Task DetachAccountAsync()
  {
    bool had;
    lock (gate) { had = token is not null; token = null; }
    if (had) foreach (var client in Live()) client.ReachTokenChanged();
    return Task.CompletedTask;
  }
  /// Ends account channels now (null = all); paired channels stay.
  public async Task CloseAccountChannelsAsync(IReadOnlyCollection<string>? deviceIds)
  {
    foreach (var client in Live()) await client.CloseAccountChannelsAsync(deviceIds).ConfigureAwait(false);
  }
  public bool Tied => Live().Any(c => c.AccountTied);
}
