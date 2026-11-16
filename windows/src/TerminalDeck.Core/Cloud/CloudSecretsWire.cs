using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;

namespace TerminalDeck.Core.Cloud;

// Saved passwords on the wire, byte for byte the Mac's (td-mac-next2 CloudContract.swift CloudSecretRecord,
// CloudSecretsLogical.swift CloudSecretRemoval / CloudSecretVersionedPut, CloudSecretsPorts.swift CloudSecretsProof,
// CloudSecretsAutoTrust.swift the request / policy proofs, CloudRecoveryCrypto.swift the recovery keys and the
// placeholder, BackendCloudSecretsControl.swift the `/secrets/*` shapes). Everything that is signed or hashed here is the
// shared canonical form (CloudCanonical), so a Mac and this PC sign, check and open each other's records.

/// One saved value of one source (`api`, `servers`, ...). `Payload` is the owner's own JSON; it travels only inside the
/// saved-passwords seal.
public sealed record CloudSecretRecord(string SourceId, string RecordId, string Domain, CloudJson Payload)
{
  public CloudJson.Object ToJson() => CloudJson.Obj(("sourceId", CloudJson.From(SourceId)), ("recordId", CloudJson.From(RecordId)),
    ("domain", CloudJson.From(Domain)), ("payload", Payload));
  public byte[] Canonical() => CloudCanonical.Encode(ToJson());
  /// As Swift's decoder reads it: the four members with their types; other members are ignored.
  public static CloudSecretRecord FromJson(CloudJson value) => value is CloudJson.Object o && o["payload"] is { } payload and not CloudJson.Null
    ? new(CloudFields.Text(o, "sourceId"), CloudFields.Text(o, "recordId"), CloudFields.Text(o, "domain"), payload)
    : throw new CloudFailure("invalid_request");
  public bool Same(CloudSecretRecord other) => Canonical().AsSpan().SequenceEqual(other.Canonical());
  public override string ToString() => "<saved value " + SourceId + ">";
}

/// A removal, carried only inside the saved-passwords seal (`archive` record). `Version` names exactly the removed
/// edit (a UUID, or the keyed fingerprint of an unversioned value); `Fields` are the delete rule's six travel fields.
public sealed record CloudSecretRemoval(string SourceId, string RecordId, string Domain, string Version, IReadOnlyDictionary<string, string> Fields,
  string Mac, string MacName, long At, CloudSecretRecord? Removed = null, string? RemovedDigest = null)
{
  public CloudJson.Object ToJson() => CloudJson.Obj(("sourceId", CloudJson.From(SourceId)), ("recordId", CloudJson.From(RecordId)),
    ("domain", CloudJson.From(Domain)), ("version", CloudJson.From(Version)), ("removedDigest", RemovedDigest is { } d ? CloudJson.From(d) : null),
    ("fields", CloudJson.Obj(Fields.OrderBy(f => f.Key, StringComparer.Ordinal).Select(f => (f.Key, (CloudJson?)CloudJson.From(f.Value))).ToArray())),
    ("mac", CloudJson.From(Mac)), ("macName", CloudJson.From(MacName)), ("at", CloudJson.From(At)), ("removed", Removed?.ToJson()));
  public byte[] Canonical() => CloudCanonical.Encode(ToJson());
  public static CloudSecretRemoval FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o || o["fields"] is not CloudJson.Object f) throw new CloudFailure("invalid_request");
    var fields = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var (k, v) in f.Members) fields[k] = v.AsString ?? throw new CloudFailure("invalid_request");
    return new(CloudFields.Text(o, "sourceId"), CloudFields.Text(o, "recordId"), CloudFields.Text(o, "domain"), CloudFields.Text(o, "version"), fields,
      CloudFields.Text(o, "mac"), CloudFields.Text(o, "macName"), CloudFields.Integer(o, "at"),
      o["removed"] is { } r and not CloudJson.Null ? CloudSecretRecord.FromJson(r) : null, CloudFields.OptionalText(o, "removedDigest"));
  }
  /// The same removal without the carried copy (a Bin row that aged out keeps only the opaque tombstone).
  public CloudSecretRemoval WithoutCopy() => this with { Removed = null };
}

/// A deliberate Put back / Put in Cloud again (decision 6): never an ordinary upload.
public sealed record CloudSecretVersionedPut(CloudSecretRecord Record, string Version, string? RemovalGroup)
{
  public CloudJson.Object ToJson() => CloudJson.Obj(("record", Record.ToJson()), ("version", CloudJson.From(Version)),
    ("removalGroup", RemovalGroup is { } g ? CloudJson.From(g) : null));
  /// Null when the value is not this shape (it is then an ordinary record).
  public static CloudSecretVersionedPut? TryFromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o || o["record"] is not CloudJson.Object record || o["version"]?.AsString is not { } version) return null;
    try { return new(CloudSecretRecord.FromJson(record), version, CloudFields.OptionalText(o, "removalGroup")); }
    catch (CloudFailure) { return null; }
  }
}

/// The saved-passwords domains and the lean source list (BackendCloudSecretsLean.sources). The purpose seals each kind.
public static class CloudSecretsDomains
{
  public const string ApiKey = "api-key", Server = "server", Ssh = "ssh", Mcp = "mcp", TaskConnection = "task-connection", Receiver = "receiver",
    BrowserCookies = "browser-cookies", BrowserPassword = "browser-password", Project = "project", App = "app", AiSubscription = "ai-subscription",
    /// 15 Nov 2026: WhatsApp agents' keys (store "whatsapp").
    WhatsApp = "whatsapp";
  public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal)
    { ApiKey, Server, Ssh, Mcp, TaskConnection, Receiver, BrowserCookies, BrowserPassword, Project, App, AiSubscription, WhatsApp };
  public static string Purpose(string domain) => domain switch
  {
    AiSubscription => "ai-subscription",
    BrowserCookies or BrowserPassword => "browser",
    _ => "secret"
  };
  /// The sources of this version, each under its own domain. Anything else is never admitted (browser cookies, saved
  /// browser passwords, AI-subscription sign-ins, GitHub: as on the Mac). "voice" has no Windows owner.
  public static readonly IReadOnlyDictionary<string, string> Sources = new Dictionary<string, string>(StringComparer.Ordinal)
  {
    ["api"] = ApiKey, ["servers"] = Server, ["ssh"] = Ssh, ["mcp-user"] = Mcp, ["tasks"] = TaskConnection, ["receiver"] = Receiver, ["voice"] = App,
    ["project-files"] = Project, ["whatsapp"] = WhatsApp
  };
  public static bool Admitted(string sourceId, string domain) => Sources.TryGetValue(sourceId, out var d) && d == domain;
}

/// A request another device made for the key, as `/secrets/status` lists it.
public sealed record CloudPendingApproval(CloudApproval Approval, string? TargetSignature, bool SignedOutBefore);

/// The signed stricter setting ("Ask me on each new device") and the phones (and browsers) switch, as relayed.
public sealed record CloudSecretsAskPolicy(bool AskOnNewDevice, long At, string By, string Signature);
public sealed record CloudSecretsPhonesPolicy(bool PhonesOff, long At, string By, string Signature);

/// `rotationDue` of `/secrets/status`: a device that held the key was signed out by another device.
public sealed record CloudSecretsRotationDue(long Since, string RemovedDeviceId, string RemovedName, IReadOnlyList<string> Holders)
{
  /// The object form only; a field of the wrong shape counts as absent (a malformed answer never starts a key change).
  public static CloudSecretsRotationDue? Read(CloudJson? found)
  {
    if (found is not CloudJson.Object o || o["since"]?.AsInteger is not { } since || since <= 0 || o["removedDeviceId"]?.AsString is not { Length: > 0 and <= 64 } removed
      || o["holders"] is not CloudJson.Array { Items.Count: <= 256 } listed) return null;
    var holders = listed.Items.Select(i => i.AsString).Where(s => s is { Length: > 0 and <= 64 }).Select(s => s!).ToArray();
    if (holders.Length != listed.Items.Count) return null;
    var name = new string((o["removedName"]?.AsString ?? "").Where(c => c is not ('\n' or '\r')).Take(80).ToArray());
    return new(since, removed, name, holders);
  }
}

/// `GET /secrets/status`, with the optional facts the Mac reads from the same answer.
public sealed record CloudSecretsStatus(string State, int Epoch, string Version, bool RecoveryReady, int ApprovedDeviceCount,
  IReadOnlyList<CloudPendingApproval> Pending, CloudSecretsAskPolicy? AskPolicy, bool AskTurnedOff, CloudSecretsPhonesPolicy? PhonesPolicy,
  CloudSecretsRotationDue? RotationDue, bool? NobodyCanOpen, bool? SecretsApproved)
{
  public const string Unset = "unset", Ready = "ready", Reset = "reset";
  public static CloudSecretsStatus FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o) throw new CloudFailure("invalid_response");
    var pending = new List<CloudPendingApproval>();
    if (o["pendingApprovals"] is CloudJson.Array rows)
      foreach (var row in rows.Items)
      {
        if (row is not CloudJson.Object a) throw new CloudFailure("invalid_response");
        pending.Add(new(new(CloudFields.Text(a, "approvalId"), CloudFields.Text(a, "targetDeviceId"), CloudFields.Text(a, "targetKeyHash"),
          CloudFields.Text(a, "challenge"), CloudFields.Integer(a, "expiresAt")), a["targetSignature"]?.AsString, a["signedOutBefore"] is CloudJson.Bool { Value: true }));
      }
    return new(CloudFields.Text(o, "state"), (int)CloudFields.Integer(o, "epoch"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")),
      o["recoveryReady"] is CloudJson.Bool { Value: true }, (int)(o["approvedDeviceCount"]?.AsInteger ?? 0), pending,
      ReadAskPolicy(o["askPolicy"]), o["askPolicyTurnedOff"] is CloudJson.Object, ReadPhonesPolicy(o["phonesPolicy"]), CloudSecretsRotationDue.Read(o["rotationDue"]),
      o["nobodyCanOpen"] is CloudJson.Bool n ? n.Value : null, o["secretsApproved"] is CloudJson.Bool s ? s.Value : null);
  }
  private static CloudSecretsAskPolicy? ReadAskPolicy(CloudJson? v) =>
    v is CloudJson.Object o && o["askOnNewDevice"] is CloudJson.Bool ask && o["at"]?.AsInteger is { } at && o["by"]?.AsString is { } by && o["signature"]?.AsString is { } sig
      ? new(ask.Value, at, by, sig) : null;
  private static CloudSecretsPhonesPolicy? ReadPhonesPolicy(CloudJson? v) =>
    v is CloudJson.Object o && o["phonesOff"] is CloudJson.Bool off && o["at"]?.AsInteger is { } at && o["by"]?.AsString is { } by && o["signature"]?.AsString is { } sig
      ? new(off.Value, at, by, sig) : null;
}

/// The recovery copy. After a silent set-up it is a PLACEHOLDER (1024 random bytes under a key thrown away at once).
public sealed record CloudRecoveryEnvelope(int V, string Version, int Epoch, string Suite, string Nonce, string Ciphertext, string Tag, CloudPublicJwk PublicSigningJwk)
{
  public const int PlaceholderBytes = 1024;
  public CloudJson.Object ToJson() => CloudJson.Obj(("v", CloudJson.From(V)), ("version", CloudJson.From(Version)), ("epoch", CloudJson.From(Epoch)),
    ("suite", CloudJson.From(Suite)), ("nonce", CloudJson.From(Nonce)), ("ciphertext", CloudJson.From(Ciphertext)), ("tag", CloudJson.From(Tag)),
    ("publicSigningJwk", CloudP256.Json(PublicSigningJwk)));
  public static CloudRecoveryEnvelope FromJson(CloudJson value) => value is CloudJson.Object o && o["publicSigningJwk"] is { } key
    ? new((int)CloudFields.Integer(o, "v"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")), (int)CloudFields.Integer(o, "epoch"), CloudFields.Text(o, "suite"),
      CloudFields.Text(o, "nonce"), CloudFields.Text(o, "ciphertext"), CloudFields.Text(o, "tag"), CloudP256.FromJson(key))
    : throw new CloudFailure("invalid_response");
  /// A real recovery copy holds a few dozen bytes; the placeholder holds 1024.
  public bool IsPlaceholder
  {
    get { try { return CloudBytes.Unbase64(Ciphertext).Length >= 512; } catch (CloudFailure) { return false; } }
  }
  public bool Same(CloudRecoveryEnvelope other) => CloudCanonical.Encode(ToJson()).AsSpan().SequenceEqual(CloudCanonical.Encode(other.ToJson()));
}

/// CloudRecoveryKeys from 32 bytes of entropy: the recovery signing key (Ed25519) and its public JWK.
public sealed class CloudRecoveryKeys
{
  public CloudPublicJwk PublicKey { get; }
  public CloudRecoveryKeys(byte[] entropy, string subject)
  {
    if (entropy.Length != 32) throw new CloudFailure("invalid_request");
    var salt = CloudBytes.Uuid(subject);
    var seed = HKDF.DeriveKey(HashAlgorithmName.SHA256, entropy, 32, salt, Encoding.UTF8.GetBytes("TD-CLOUD-RECOVERY-SIGN-1"));
    try { PublicKey = new("OKP", "Ed25519", CloudBytes.Base64Url(new Ed25519PrivateKeyParameters(seed, 0).GeneratePublicKey().GetEncoded())); }
    finally { CryptographicOperations.ZeroMemory(seed); }
  }
  /// No words: 1024 random bytes sealed under a key that is thrown away at once. It never contains the key.
  public CloudRecoveryEnvelope SealPlaceholder(string subject, string version, int epoch)
  {
    if (epoch <= 0 || CloudSecretsWire.Number(version) == 0) throw new CloudFailure("invalid_request");
    var throwaway = RandomNumberGenerator.GetBytes(32); var nonce = RandomNumberGenerator.GetBytes(12); var plain = RandomNumberGenerator.GetBytes(CloudRecoveryEnvelope.PlaceholderBytes);
    try
    {
      var (ciphertext, tag) = CloudContentCrypto.Seal(plain, throwaway, nonce, Encoding.UTF8.GetBytes($"TD-CLOUD-RECOVERY-NONE-1\n{subject}\n{version}\n{epoch.ToString(CultureInfo.InvariantCulture)}"));
      return new(1, version, epoch, "A256GCM", CloudBytes.Base64Url(nonce), CloudBytes.Base64Url(ciphertext), CloudBytes.Base64Url(tag), PublicKey);
    }
    finally { CryptographicOperations.ZeroMemory(throwaway); }
  }
}

/// What a device signs (CloudSecretsProof), each the canonical JSON the service and the Macs check.
public static class CloudSecretsProof
{
  public static byte[] Approval(CloudApproval approval, bool allow, string version, CloudDeviceKeyEnvelope? envelope, string? canaryHash) =>
    CloudCanonical.Encode(CloudJson.Obj(("approvalId", CloudJson.From(approval.ApprovalId)), ("allow", CloudJson.From(allow)),
      ("targetKeyHash", CloudJson.From(approval.TargetKeyHash)), ("challenge", CloudJson.From(approval.Challenge)), ("expiresAt", CloudJson.From(approval.ExpiresAt)),
      ("expectedVersion", CloudJson.From(version)), ("deviceEnvelopeHash", envelope is null ? null : CloudJson.From(CloudBytes.Sha256Hex(CloudCanonical.Encode(envelope.ToJson())))),
      ("canaryHash", canaryHash is null ? null : CloudJson.From(canaryHash))));
  public static byte[] Possession(string subject, string deviceId, string version, string canary) =>
    Encoding.UTF8.GetBytes($"TD-CLOUD-POSSESSION-1\n{subject}\n{deviceId}\n{version}\n{canary}");
  /// The requesting device's own signature over its request, its wrapping key by hash and the key generation.
  public static byte[] Request(string subject, CloudApproval approval, CloudPublicJwk wrapPublicJwk, int epoch) =>
    CloudCanonical.Encode(CloudJson.Obj(("purpose", CloudJson.From("TD-APPROVAL-REQUEST-1")), ("sub", CloudJson.From(subject)),
      ("approvalId", CloudJson.From(approval.ApprovalId)), ("challenge", CloudJson.From(approval.Challenge)), ("targetDeviceId", CloudJson.From(approval.TargetDeviceId)),
      ("targetKeyHash", CloudJson.From(approval.TargetKeyHash)), ("wrapKeyHash", CloudJson.From(CloudBytes.Sha256Hex(CloudCanonical.Encode(CloudP256.Json(wrapPublicJwk))))),
      ("epoch", CloudJson.From(epoch)), ("expiresAt", CloudJson.From(approval.ExpiresAt))));
  public static byte[] PhonesPolicy(string subject, bool phonesOff, long at, string by) =>
    CloudCanonical.Encode(CloudJson.Obj(("purpose", CloudJson.From("TD-PASSWORDS-PHONES-1")), ("sub", CloudJson.From(subject)), ("phonesOff", CloudJson.From(phonesOff)),
      ("at", CloudJson.From(at)), ("by", CloudJson.From(by))));
  public static byte[] AskPolicy(string subject, bool askOnNewDevice, long at, string by) =>
    CloudCanonical.Encode(CloudJson.Obj(("purpose", CloudJson.From("TD-PASSWORDS-POLICY-1")), ("sub", CloudJson.From(subject)), ("askOnNewDevice", CloudJson.From(askOnNewDevice)),
      ("at", CloudJson.From(at)), ("by", CloudJson.From(by))));
}

public sealed record CloudSecretsEnvelopeReceipt(int Epoch, string Version, CloudDeviceKeyEnvelope DeviceEnvelope);
public sealed record CloudRecoveryChallenge(string ChallengeId, string Challenge, long ExpiresAt, int Epoch, string Version, CloudRecoveryEnvelope RecoveryEnvelope);
public sealed record CloudSecretsRotateCopy(string TargetDeviceId, CloudDeviceKeyEnvelope Envelope, string CanaryHash);
public sealed record CloudSecretsRotateReceipt(int Epoch, string Version, string State, string PreservedArchiveId, bool SecretsApproved, IReadOnlyList<(string Device, string Code)> Refused);

/// The `/secrets/*` routes over the sync transport's own signed, budgeted path. `Call(method, path, body, requestId)`:
/// a POST body carries `requestId` and the transport sends it as the request's id (the service checks they match).
public sealed class CloudSecretsControl(Func<string, string, CloudJson?, string?, CancellationToken, Task<CloudJson>> call,
  Func<CancellationToken, Task<IReadOnlyList<CloudDevice>>> devices)
{
  private static string NewId() => CloudBytes.NewTransportId();
  private async Task<CloudJson.Object> Post(string path, params (string Key, CloudJson? Value)[] members)
  {
    var id = NewId();
    var body = CloudJson.Obj([("requestId", CloudJson.From(id)), .. members]);
    if (CloudCanonical.Encode(body).Length > 131_072) throw new CloudFailure("invalid_request");
    return await call("POST", path, body, id, CancellationToken.None) as CloudJson.Object ?? throw new CloudFailure("invalid_response");
  }
  public async Task<CloudSecretsStatus> StatusAsync(CancellationToken ct = default) => CloudSecretsStatus.FromJson(await call("GET", "/secrets/status", null, null, ct));
  public async Task<CloudSecretsEnvelopeReceipt> EnvelopeAsync(CancellationToken ct = default)
  {
    var o = await call("GET", "/secrets/envelope", null, null, ct) as CloudJson.Object ?? throw new CloudFailure("invalid_response");
    return new((int)CloudFields.Integer(o, "epoch"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")),
      CloudDeviceKeyEnvelope.FromJson(o["deviceEnvelope"] ?? throw new CloudFailure("invalid_response")));
  }
  public async Task<CloudApproval> RequestApprovalAsync(string deviceId, string keyHash)
  {
    var o = await Post("/secrets/approval/request", ("targetDeviceId", CloudJson.From(deviceId)), ("targetKeyHash", CloudJson.From(keyHash)));
    return new(CloudFields.Text(o, "approvalId"), deviceId, keyHash, CloudFields.Text(o, "challenge"), CloudFields.Integer(o, "expiresAt"));
  }
  public async Task SignRequestAsync(string approvalId, string signature)
  {
    var o = await Post("/secrets/approval/sign", ("approvalId", CloudJson.From(approvalId)), ("signature", CloudJson.From(signature)));
    if (o["approvalId"]?.AsString != approvalId) throw new CloudFailure("checksum_mismatch");
  }
  public async Task<string> AnswerAsync(string approvalId, bool allow, string expectedVersion, CloudDeviceKeyEnvelope? envelope, string? canaryHash, string signer, string signature)
  {
    var o = await Post("/secrets/approval/answer", ("approvalId", CloudJson.From(approvalId)), ("allow", CloudJson.From(allow)),
      ("expectedVersion", CloudJson.From(expectedVersion)), ("deviceEnvelope", envelope?.ToJson()), ("canaryHash", canaryHash is null ? null : CloudJson.From(canaryHash)),
      ("proof", CloudJson.Obj(("signerDeviceId", CloudJson.From(signer)), ("signature", CloudJson.From(signature)))));
    if (o["approvalId"]?.AsString != approvalId) throw new CloudFailure("checksum_mismatch");
    return CloudFields.Text(o, "state");
  }
  public async Task<(bool Approved, int Epoch, string Version)> PossessionAsync(string expectedVersion, string canary, string signature)
  {
    var o = await Post("/secrets/possession", ("expectedVersion", CloudJson.From(expectedVersion)), ("canary", CloudJson.From(canary)), ("signature", CloudJson.From(signature)));
    return (o["secretsApproved"] is CloudJson.Bool { Value: true }, (int)CloudFields.Integer(o, "epoch"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")));
  }
  public async Task<CloudRecoveryChallenge> RecoveryChallengeAsync(string keyHash)
  {
    var o = await Post("/secrets/recovery/challenge", ("targetKeyHash", CloudJson.From(keyHash)));
    return new(CloudFields.Text(o, "challengeId"), CloudFields.Text(o, "challenge"), CloudFields.Integer(o, "expiresAt"), (int)CloudFields.Integer(o, "epoch"),
      CloudSecretsWire.Sequence(CloudFields.Text(o, "version")), CloudRecoveryEnvelope.FromJson(o["recoveryEnvelope"] ?? throw new CloudFailure("invalid_response")));
  }
  public async Task<CloudSecretsEnvelopeReceipt> InitializeAsync(CloudRecoveryEnvelope recovery, CloudDeviceKeyEnvelope envelope, string canaryHash)
  {
    var o = await Post("/secrets/initialize", ("expectedVersion", CloudJson.From("0")), ("recoveryEnvelope", recovery.ToJson()), ("deviceEnvelope", envelope.ToJson()),
      ("canaryHash", CloudJson.From(canaryHash)), ("confirmation", CloudJson.From(true)));
    return new((int)CloudFields.Integer(o, "epoch"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")),
      CloudDeviceKeyEnvelope.FromJson(o["deviceEnvelope"] ?? throw new CloudFailure("invalid_response")));
  }
  public async Task<CloudSecretsRotateReceipt> RotateAsync(string expectedVersion, CloudRecoveryEnvelope recovery, CloudDeviceKeyEnvelope envelope, string canaryHash,
    IReadOnlyList<CloudSecretsRotateCopy> copies)
  {
    var o = await Post("/secrets/rotate", ("expectedVersion", CloudJson.From(expectedVersion)), ("newRecoveryEnvelope", recovery.ToJson()),
      ("newDeviceEnvelope", envelope.ToJson()), ("canaryHash", CloudJson.From(canaryHash)),
      ("copies", CloudJson.Arr(copies.Select(c => (CloudJson)CloudJson.Obj(("targetDeviceId", CloudJson.From(c.TargetDeviceId)), ("envelope", c.Envelope.ToJson()),
        ("canaryHash", CloudJson.From(c.CanaryHash)))))));
    var refused = o["refusedCopies"] is CloudJson.Array rows
      ? rows.Items.OfType<CloudJson.Object>().Select(r => (r["targetDeviceId"]?.AsString ?? "", r["code"]?.AsString ?? "")).ToArray() : [];
    return new((int)CloudFields.Integer(o, "epoch"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")), CloudFields.Text(o, "state"),
      CloudFields.Text(o, "preservedArchiveId"), o["secretsApproved"] is CloudJson.Bool { Value: true }, refused);
  }
  public async Task PublishPhonesPolicyAsync(CloudSecretsPhonesPolicy policy)
  {
    var o = await Post("/secrets/policy/phones", ("phonesPolicy", CloudJson.Obj(("phonesOff", CloudJson.From(policy.PhonesOff)), ("at", CloudJson.From(policy.At)),
      ("by", CloudJson.From(policy.By)), ("signature", CloudJson.From(policy.Signature)))));
    if (CloudFields.Integer(o, "at") < policy.At) throw new CloudFailure("checksum_mismatch");
  }
  public async Task PublishAskPolicyAsync(CloudSecretsAskPolicy policy)
  {
    var o = await Post("/secrets/policy", ("askPolicy", CloudJson.Obj(("askOnNewDevice", CloudJson.From(policy.AskOnNewDevice)), ("at", CloudJson.From(policy.At)),
      ("by", CloudJson.From(policy.By)), ("signature", CloudJson.From(policy.Signature)))));
    if (CloudFields.Integer(o, "at") < policy.At) throw new CloudFailure("checksum_mismatch");
  }
  /// The account's ACTIVE device with this id (its registered keys), or a failure.
  public async Task<CloudDeviceRegistration> RegisteredDeviceAsync(string deviceId, CancellationToken ct = default)
  {
    var found = (await devices(ct)).FirstOrDefault(d => string.Equals(d.DeviceId, deviceId, StringComparison.OrdinalIgnoreCase) && d.Status == "active")
      ?? throw new CloudFailure("not_found");
    return new(found.DeviceId, found.Label, found.Platform, found.AppVersion, found.SignPublicJwk, found.WrapPublicJwk);
  }
  /// The account's device list (names for log lines, "signed out before" marks are read from status).
  public Task<IReadOnlyList<CloudDevice>> DevicesAsync(CancellationToken ct = default) => devices(ct);
}

public static class CloudSecretsWire
{
  /// A version / feed position as text (CloudSequence): digits, no leading zero.
  public static string Sequence(string text) =>
    text.Length > 0 && text.Length <= 20 && text.All(char.IsAsciiDigit) && (text == "0" || text[0] != '0') && ulong.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out _)
      ? text : throw new CloudFailure("invalid_response");
  public static ulong Number(string sequence) => ulong.Parse(Sequence(sequence), NumberStyles.None, CultureInfo.InvariantCulture);
  public static string Next(string sequence) => checked(Number(sequence) + 1).ToString(CultureInfo.InvariantCulture);
  public static string Lower(string uuid) => uuid.ToLowerInvariant();
}
