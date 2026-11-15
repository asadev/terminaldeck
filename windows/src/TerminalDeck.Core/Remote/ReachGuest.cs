using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Remote;

// This PC as a reach GUEST (port of the Mac's BackendReachGuest.swift): it registers its own reach key with the account
// once, reads the account's machines, takes a 15-minute relay token and joins another machine's room with it. No pairing
// code and no question: signing in is the permission. The machine it joins still judges the join itself, exactly as it
// judges a phone. Used by the live chat page (lane U); nothing on the relay or the service changes for it.

/// One machine of the account as `GET /v1/reach/machines` lists it (service reach.ts machineList).
public sealed record ReachMachine(string DeviceId, string HostId, byte[] HostKey, string HostKeyText, string Name, string? DisplayName,
  string Platform, ReachPolicy Policy, long SignedAt, string Sig, bool Online, bool IsSelf, string SignX, string SignY)
{
  /// The friendly name, else the signed one, without ".local".
  public string ShownName
  {
    get
    {
      var shown = Bare(DisplayName ?? "");
      return shown.Length > 0 ? shown : Bare(Name).Length > 0 ? Bare(Name) : Name;
    }
  }
  public static string Bare(string name)
  {
    var text = name.Trim();
    if (text.EndsWith('.')) text = text[..^1];
    if (text.EndsWith(".local", StringComparison.OrdinalIgnoreCase) && text.Length > 6) text = text[..^6];
    return text.Trim();
  }

  /// The relay is never trusted: the record must carry the machine's own signature before any handshake.
  public bool PresenceValid
  {
    get
    {
      if (ReachWire.UnBase64Url(SignX, 32) is not { } x || ReachWire.UnBase64Url(SignY, 32) is not { } y || ReachWire.UnBase64Url(Sig, 64) is not { } signature) return false;
      try
      {
        using var key = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = x, Y = y } });
        var record = new ReachPresenceRecord(DeviceId, HostId, HostKeyText, Name, Platform, Policy);
        return key.VerifyData(Encoding.UTF8.GetBytes(ReachWire.PresenceMessage(record, SignedAt)), signature, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
      }
      catch (CryptographicException) { return false; }
    }
  }

  public override string ToString() => "<reach machine " + ShownName + ">";

  /// `GET /v1/reach/machines`. A row that cannot be read is dropped, never trusted.
  public static IReadOnlyList<ReachMachine> List(JsonElement value)
  {
    if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("machines", out var rows) || rows.ValueKind != JsonValueKind.Array) return [];
    var list = new List<ReachMachine>();
    static string? S(JsonElement e, string n) => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    foreach (var row in rows.EnumerateArray().Take(64))
    {
      var id = S(row, "deviceId"); var hostId = S(row, "hostId"); var keyText = S(row, "hostKey"); var name = S(row, "name");
      var platform = S(row, "platform"); var policy = S(row, "policy"); var sig = S(row, "sig");
      if (!ReachWire.ValidDeviceId(id) || hostId is null || !PairingCode.IsHostId(hostId) || ReachWire.UnBase64Url(keyText, 32) is not { } key ||
        name is null || platform is null || policy is not ("A" or "B") || sig is null) continue;
      if (!row.TryGetProperty("signedAt", out var at) || at.ValueKind != JsonValueKind.Number || !at.TryGetInt64(out var signedAt)) continue;
      if (!row.TryGetProperty("signPublicJwk", out var jwk) || S(jwk, "kty") != "EC" || S(jwk, "crv") != "P-256" || S(jwk, "x") is not { } x || S(jwk, "y") is not { } y) continue;
      list.Add(new(id!, hostId, key, keyText!, name, S(row, "displayName"), platform, policy == "B" ? ReachPolicy.ApproveNew : ReachPolicy.AccountOnly,
        signedAt, sig, row.TryGetProperty("online", out var on) && on.ValueKind == JsonValueKind.True,
        row.TryGetProperty("self", out var self) && self.ValueKind == JsonValueKind.True, x, y));
    }
    return list;
  }
}

/// The account service as a reach guest needs it (the phones' calls, for a computer).
public interface IReachGuestService
{
  string? MachineDeviceId();
  /// `POST /v1/devices/reach-key {deviceId, reachPublicKey, sig}`.
  Task RegisterReachKeyAsync(string deviceId, string publicKey, CancellationToken ct = default);
  /// `GET /v1/reach/machines`.
  Task<IReadOnlyList<ReachMachine>> ReachMachinesAsync(CancellationToken ct = default);
  /// `POST /v1/reach/token`.
  Task<ReachRelayToken> RelayTokenAsync(CancellationToken ct = default);
}

/// What a guest connection dials a machine with: its room and key, this PC's guest key, and the hello's
/// `reach:<deviceId>` (a public name, never a secret; the relay token goes on the join, read at every dial).
public sealed record ReachMachineSecrets(string HostId, byte[] HostPublicKey, Uri Relay, string Credential, NoiseIdentity GuestKey)
{
  public override string ToString() => "<reach machine secrets>";
}

/// This PC's reach key as a GUEST: its own X25519 pair (never the host key it publishes, never a pairing key), kept in
/// this copy's data folder (protected by the app's DPAPI when given), with the device id the service took it for. The
/// service keeps one key per device id, so the file is never replaced while that id lasts.
public sealed class ReachGuestKeyFile(string directory, Func<byte[], byte[]>? protect = null, Func<byte[], byte[]>? unprotect = null)
{
  public string File { get; } = Path.Combine(directory, "reach-guest-key.json");
  public sealed record Key(NoiseIdentity Identity, string? RegisteredFor);

  public Key? Read()
  {
    byte[] raw;
    try { raw = System.IO.File.ReadAllBytes(File); }
    catch (FileNotFoundException) { return null; }
    catch (DirectoryNotFoundException) { return null; }
    try
    {
      if (raw.Length > 4096) throw new FormatException();
      var plain = unprotect is null ? raw : unprotect(raw);
      using var doc = JsonDocument.Parse(plain);
      var text = doc.RootElement.GetProperty("privateKey").GetString();
      var data = text is null ? null : Convert.FromBase64String(text);
      if (data is not { Length: 32 }) throw new FormatException();
      var registered = doc.RootElement.TryGetProperty("registeredFor", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString() : null;
      try { return new(new NoiseIdentity(data), registered); } finally { CryptographicOperations.ZeroMemory(data); }
    }
    catch (Exception ex) when (ex is FormatException or JsonException or KeyNotFoundException or InvalidOperationException or CryptographicException)
    {
      // A file that cannot be read at all is moved aside: a new key is made (the service may refuse it for this device
      // id; then the page says so). Never a dead end that only throws at every dial.
      try { System.IO.File.Move(File, File + ".damaged-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), overwrite: true); } catch (IOException) { }
      return null;
    }
  }

  public void Write(Key key)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(File)!);
    var privateKey = key.Identity.PrivateKey;
    var plain = JsonSerializer.SerializeToUtf8Bytes(new { version = 1, privateKey = Convert.ToBase64String(privateKey), publicKey = ReachWire.Base64Url(key.Identity.PublicKey), registeredFor = key.RegisteredFor });
    try
    {
      var temporary = File + ".tmp";
      System.IO.File.WriteAllBytes(temporary, protect is null ? plain : protect(plain));
      System.IO.File.Move(temporary, File, overwrite: true);
    }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
}

/// This PC reaching his other machines by sign-in: the key (registered once), the machine list (30 s fresh), the relay
/// token (renewed with 2 minutes left) and the secrets a guest connection dials with.
public sealed class ReachGuest(IReachGuestService service, ReachGuestKeyFile keys, Uri relay, Func<double>? now = null)
{
  public const string LinkPrefix = "reach-";
  public static string LinkId(string deviceId) => LinkPrefix + deviceId;
  public static bool IsReachLink(string id) => id.StartsWith(LinkPrefix, StringComparison.Ordinal);
  public const double RenewBeforeMs = 120_000;
  public const double ListFreshMs = 30_000;
  public static readonly IReadOnlySet<string> RefusedCodes = new HashSet<string> { "reach_key_set", "key_in_use" };
  /// The one line the page shows when the service refused this PC's key.
  public const string KeyRefusedLine = "This PC could not connect to your other computers. Sign out and in again to fix it.";

  private readonly Func<double> now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
  private readonly SemaphoreSlim one = new(1, 1);
  private ReachGuestKeyFile.Key? key;
  private ReachRelayToken? token;
  private (double At, IReadOnlyList<ReachMachine> Machines)? listed;
  public Uri Relay { get; } = relay;
  /// The service refused this PC's key for its device id. Nothing is reached until he signs in again.
  public bool KeyRefused { get; private set; }

  /// The account's machines (cached 30 s; `fresh` reads again).
  public async Task<IReadOnlyList<ReachMachine>> MachinesAsync(bool fresh = false, CancellationToken ct = default)
  {
    if (!fresh && listed is { } held && now() - held.At < ListFreshMs) return held.Machines;
    var machines = await service.ReachMachinesAsync(ct).ConfigureAwait(false);
    listed = (now(), machines);
    return machines;
  }

  /// The machines this PC may dial now: on, not itself, a Mac or PC, and signed by their own key.
  public async Task<IReadOnlyList<ReachMachine>> ReachableAsync(bool fresh = false, CancellationToken ct = default) =>
    (await MachinesAsync(fresh, ct).ConfigureAwait(false)).Where(m => m.Online && !m.IsSelf && m.Platform is "macos" or "windows" && m.PresenceValid).ToArray();

  /// This PC's guest key, registered for its current device id (once; a new device id gets a new key, as a phone).
  public async Task<(string DeviceId, NoiseIdentity Identity)> PrepareAsync(CancellationToken ct = default)
  {
    if (service.MachineDeviceId() is not { } deviceId) throw new ReachRefusedException(ReachRefusal.SignedOut);
    await one.WaitAsync(ct).ConfigureAwait(false);
    try
    {
      key ??= keys.Read();
      if (key is { } held && held.RegisteredFor == deviceId) return (deviceId, held.Identity);
      // Never registered, or registered for an earlier device id of this PC: a new key goes with the new id.
      var identity = key is { RegisteredFor: null } unregistered ? unregistered.Identity : NoiseIdentity.Generate();
      var fresh = new ReachGuestKeyFile.Key(identity, null);
      keys.Write(fresh); key = fresh;
      try { await service.RegisterReachKeyAsync(deviceId, ReachWire.Base64Url(identity.PublicKey), ct).ConfigureAwait(false); }
      catch (ReachServiceException refused) when (RefusedCodes.Contains(refused.Code))
      {
        KeyRefused = true;
        throw new ReachRefusedException(ReachRefusal.KeyChanged);
      }
      KeyRefused = false;
      var done = new ReachGuestKeyFile.Key(identity, deviceId);
      keys.Write(done); key = done;
      return (deviceId, identity);
    }
    finally { one.Release(); }
  }

  /// A relay token with at least 2 minutes left. A `reach-host` token (policy B, this PC not approved yet) may not join
  /// anyone: refused here.
  public async Task<string> RelayTokenAsync(CancellationToken ct = default)
  {
    if (token is { } held && held.ExpiresAtMs - now() > RenewBeforeMs) return held.Token;
    var fresh = await service.RelayTokenAsync(ct).ConfigureAwait(false);
    if (fresh.Scope != "reach") throw new ReachRefusedException(ReachRefusal.NotApproved);
    token = fresh;
    return fresh.Token;
  }

  public async Task<ReachMachineSecrets> SecretsAsync(ReachMachine machine, CancellationToken ct = default)
  {
    var (deviceId, identity) = await PrepareAsync(ct).ConfigureAwait(false);
    return new(machine.HostId, machine.HostKey, Relay, "reach:" + deviceId, identity);
  }

  /// Sign-out: nothing kept in memory (the key file stays for this device id; a new id replaces it).
  public void Forget() { token = null; listed = null; key = null; KeyRefused = false; }
}
