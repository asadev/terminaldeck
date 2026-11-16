using System.Globalization;
using System.Security.Cryptography;

namespace TerminalDeck.Core.Cloud;

// The saved-passwords key on this PC and its hand-over with no click (the Mac's CloudRecoveryCoordinator: setupSilently,
// requestApproval, receiveApproval, answerAutomatically, reopenOwnCopy, confirmPendingAcknowledgement; the hand-over book
// of CloudSecretsAutoTrust.swift; the owner's 14 Nov rule "your devices open it by themselves").
// - The account's FIRST device makes the key by itself (no sheet, no recovery words; a placeholder recovery copy).
// - A later device signs its own request; one of his devices that holds the key answers BY ITSELF when its own trusted
//   list holds the requester with exactly that signing key, of the same kind, the request is signed by it over its
//   wrapping key, once per device per key generation, not under "Ask me on each new device", not a phone or browser
//   under "Keep saved passwords and secret files off my phones and browsers".
// - The key arrives sealed to this PC's own key-agreement key; this PC takes it only from an author its own list holds.
// The key, its older generations, the newest generation seen and the book live in this PC's protected slots (Windows:
// DPAPI, current user, `WindowsCloudSecretsSlots`), one set per account and device id. Never a plain file, never synced.

/// One account's protected slots on this PC for one device id: "key", "archive-<epoch>", "seen", "book". `Read`
/// returns null only when nothing was saved under that name; a damaged slot throws.
public interface ICloudSecretsSlots
{
  byte[]? Read(string name);
  void Write(string name, byte[] bytes);
  void Remove(string name);
  /// Every slot of this device id, and whatever the platform keeps beside them (B4: a sign-out by another device).
  void RemoveAll();
}

/// The saved-passwords key as this PC holds it. `Acknowledged` false: saved, the Cloud has not confirmed this PC yet.
/// `RecoveryWords` false: the account was set up with no recovery words.
public sealed record CloudSecretsLocalKey(string Subject, string DeviceId, int Epoch, string Version, byte[] Root, CloudPublicJwk RecoveryPublicKey,
  bool? Acknowledged = null, bool? RecoveryWords = null)
{
  public override string ToString() => "<saved-passwords key, generation " + Epoch.ToString(CultureInfo.InvariantCulture) + ">";
  public CloudJson ToJson() => CloudJson.Obj(("subject", CloudJson.From(Subject)), ("deviceId", CloudJson.From(DeviceId)), ("epoch", CloudJson.From(Epoch)),
    ("version", CloudJson.From(Version)), ("root", CloudJson.From(CloudBytes.Base64Url(Root))), ("recoveryPublicKey", CloudP256.Json(RecoveryPublicKey)),
    ("acknowledged", Acknowledged is { } a ? CloudJson.From(a) : null), ("recoveryWords", RecoveryWords is { } w ? CloudJson.From(w) : null));
  public static CloudSecretsLocalKey FromJson(CloudJson value) => value is CloudJson.Object o && o["recoveryPublicKey"] is { } key
    ? new(CloudFields.Text(o, "subject"), CloudFields.Text(o, "deviceId"), (int)CloudFields.Integer(o, "epoch"), CloudSecretsWire.Sequence(CloudFields.Text(o, "version")),
      CloudBytes.Unbase64(CloudFields.Text(o, "root"), 32), CloudP256.FromJson(key),
      o["acknowledged"] is CloudJson.Bool a ? a.Value : null, o["recoveryWords"] is CloudJson.Bool w ? w.Value : null)
    : throw new CloudFailure("unsupported_format");
  public bool SameRoot(byte[] root) => CryptographicOperations.FixedTimeEquals(Root, root);
}

/// What THIS PC keeps about the automatic hand-over, in its own slot beside the key (CloudSecretsHandOverBook).
public sealed class CloudSecretsHandOverBook
{
  public List<string> Answered { get; set; } = [];
  public bool AskOnNewDevice { get; set; }
  public long PolicyAt { get; set; }
  public bool? PhonesOff { get; set; }
  public long? PhonesOffAt { get; set; }
  /// deviceId -> "<hash of its signing key>|<hash of its wrapping key>" for every device whose OWN signature over that
  /// wrapping key THIS PC checked. A key change seals a copy only to a wrapping key found here. At most 256.
  public Dictionary<string, string> VerifiedWrapKeys { get; set; } = [];

  public static string Key(string deviceId, int epoch) => deviceId.ToLowerInvariant() + "@" + epoch.ToString(CultureInfo.InvariantCulture);
  public bool HasAnswered(string deviceId, int epoch) => Answered.Contains(Key(deviceId, epoch));
  public static string WrapKeyMark(CloudDeviceRegistration device) =>
    CloudBytes.Sha256Hex(CloudCanonical.Encode(CloudP256.Json(device.SignPublicJwk))) + "|" + CloudBytes.Sha256Hex(CloudCanonical.Encode(CloudP256.Json(device.WrapPublicJwk)));
  public bool WrapKeyVerified(CloudDeviceRegistration device) => VerifiedWrapKeys.TryGetValue(device.DeviceId.ToLowerInvariant(), out var mark) && mark == WrapKeyMark(device);
  public void NoteWrapKeyVerified(CloudDeviceRegistration device)
  {
    var id = device.DeviceId.ToLowerInvariant();
    VerifiedWrapKeys[id] = WrapKeyMark(device);
    if (VerifiedWrapKeys.Count > 256) VerifiedWrapKeys = new() { [id] = VerifiedWrapKeys[id] };
  }
  public void TrimAnswered() { if (Answered.Count > 256) Answered.RemoveRange(0, Answered.Count - 256); }

  public byte[] Encode() => CloudCanonical.Encode(CloudJson.Obj(("answered", CloudJson.Arr(Answered.Select(a => CloudJson.From(a)))),
    ("askOnNewDevice", CloudJson.From(AskOnNewDevice)), ("policyAt", CloudJson.From(PolicyAt)),
    ("phonesOff", PhonesOff is { } p ? CloudJson.From(p) : null), ("phonesOffAt", PhonesOffAt is { } at ? CloudJson.From(at) : null),
    ("verifiedWrapKeys", CloudJson.Obj(VerifiedWrapKeys.OrderBy(k => k.Key, StringComparer.Ordinal).Select(k => (k.Key, (CloudJson?)CloudJson.From(k.Value))).ToArray()))));
  public static CloudSecretsHandOverBook Decode(byte[] bytes)
  {
    if (CloudJson.Parse(bytes) is not CloudJson.Object o || o["answered"] is not CloudJson.Array answered) throw new CloudFailure("unsupported_format");
    var book = new CloudSecretsHandOverBook
    {
      Answered = answered.Items.Select(a => a.AsString ?? throw new CloudFailure("unsupported_format")).ToList(),
      AskOnNewDevice = o["askOnNewDevice"] is CloudJson.Bool { Value: true }, PolicyAt = o["policyAt"]?.AsInteger ?? 0,
      PhonesOff = o["phonesOff"] is CloudJson.Bool p ? p.Value : null, PhonesOffAt = o["phonesOffAt"]?.AsInteger
    };
    if (o["verifiedWrapKeys"] is CloudJson.Object marks)
      foreach (var (k, v) in marks.Members) book.VerifiedWrapKeys[k] = v.AsString ?? throw new CloudFailure("unsupported_format");
    return book;
  }
}

/// The key, its archives, the newest generation seen and the book, each in its own slot: bookkeeping never rewrites
/// the key's slot (R8-2), and an older generation's key is kept as that generation's archive before a newer one is
/// saved (never discarded, never used to seal).
public sealed class CloudSecretsLocalKeys(ICloudSecretsSlots slots)
{
  public CloudSecretsLocalKey? Read() => slots.Read("key") is { } bytes ? Open(bytes) : null;
  private static CloudSecretsLocalKey Open(byte[] bytes)
  {
    try { return CloudSecretsLocalKey.FromJson(CloudJson.Parse(bytes)); }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  private static byte[] Bytes(CloudSecretsLocalKey key) => CloudCanonical.Encode(key.ToJson());
  public void SaveVerified(CloudSecretsLocalKey key) { var b = Bytes(key); try { slots.Write("key", b); } finally { CryptographicOperations.ZeroMemory(b); } }
  public void Archive(CloudSecretsLocalKey key) { var b = Bytes(key); try { slots.Write("archive-" + key.Epoch.ToString(CultureInfo.InvariantCulture), b); } finally { CryptographicOperations.ZeroMemory(b); } }
  public CloudSecretsLocalKey? Archived(int epoch) => slots.Read("archive-" + epoch.ToString(CultureInfo.InvariantCulture)) is { } bytes ? Open(bytes) : null;
  public int? SeenCloudEpoch() => slots.Read("seen") is { } bytes && int.TryParse(System.Text.Encoding.UTF8.GetString(bytes), NumberStyles.None, CultureInfo.InvariantCulture, out var e) ? e : null;
  public void SaveSeenCloudEpoch(int epoch) => slots.Write("seen", System.Text.Encoding.UTF8.GetBytes(epoch.ToString(CultureInfo.InvariantCulture)));
  /// Null = never written (a new account on this PC). Throws when unreadable (callers fail safe).
  public CloudSecretsHandOverBook? Book() => slots.Read("book") is { } bytes ? CloudSecretsHandOverBook.Decode(bytes) : null;
  public void SaveBook(CloudSecretsHandOverBook book) => slots.Write("book", book.Encode());
  /// B4 only (signed out by ANOTHER device): this device id's Cloud keys go; a new sign-in gets a new device id and new
  /// slots, so nothing removed here could ever be used again. Never any data.
  public void ForgetAfterRemoteSignOut() => slots.RemoveAll();
}

public enum CloudSecretsProtection { Locked, WaitingForCloud, Protected }

/// One account's hand-over on this PC (single caller at a time: a second call while one runs is refused as busy, as
/// on the Mac). `sign`: this PC's ES256 device signature; `shared`: this PC's ECDH with a sealed key's ephemeral key.
public sealed partial class CloudSecretsHandover
{
  private readonly string subject;
  public CloudDeviceRegistration Device { get; }
  private readonly Func<byte[], byte[]> sign;
  private readonly Func<CloudPublicJwk, byte[]> shared;
  private readonly CloudSecretsLocalKeys local;
  private readonly CloudSecretsControl control;
  private readonly CloudSecretsAutoTrust? automatic;
  private readonly Func<long> now;
  private readonly Func<bool> permitted;
  private readonly Action<string> log;
  private readonly SemaphoreSlim busy = new(1, 1);
  private CloudApproval? requested;
  private CloudDeviceKeyEnvelope? staleEnvelope;
  private bool possessionUnconfirmed, signedRequest;
  private readonly HashSet<string> refusalsSaid = new(StringComparer.Ordinal);
  /// The random wait before a due key change (fixtures: 0) and the wait itself.
  internal Func<long> RotationJitter { get; set; } = () => Random.Shared.NextInt64(0, 20_001);
  internal Func<long, Task> Sleep { get; set; } = ms => Task.Delay(TimeSpan.FromMilliseconds(Math.Max(0, ms)));

  /// `permitted`: Cloud is allowed for this account and the issuer is production's (or the scratch permit's).
  public CloudSecretsHandover(string subject, CloudDeviceRegistration device, Func<byte[], byte[]> sign, Func<CloudPublicJwk, byte[]> shared,
    CloudSecretsLocalKeys local, CloudSecretsControl control, CloudSecretsAutoTrust? automatic, Func<bool> permitted, Func<long>? now = null, Action<string>? log = null)
  {
    CloudBytes.Uuid(subject);
    this.subject = subject; Device = device; this.sign = sign; this.shared = shared; this.local = local; this.control = control; this.automatic = automatic;
    this.permitted = permitted; this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()); this.log = log ?? (_ => { });
  }

  private string KeyHash => CloudKeyWrap.KeyHash(Device);
  private bool AutomaticOn => automatic?.On == true;
  private void Permitted() { if (!permitted()) throw new CloudFailure("gate_closed"); }
  private async Task<IDisposable> EnterAsync()
  {
    if (!await busy.WaitAsync(0)) throw new CloudFailure("unavailable");
    return new Release(busy);
  }
  private sealed class Release(SemaphoreSlim s) : IDisposable { public void Dispose() => s.Release(); }
  private void Refusal(string approvalId, string why)
  {
    if (!refusalsSaid.Add(approvalId + "|" + why)) return;
    if (refusalsSaid.Count > 256) { refusalsSaid.Clear(); refusalsSaid.Add(approvalId + "|" + why); }
    log("saved passwords: did not answer " + why);
  }
  private string Sign(byte[] bytes) { var s = sign(bytes); if (s.Length != 64) throw new CloudFailure("invalid_request"); return CloudBytes.Base64Url(s); }
  private bool Mine(CloudSecretsLocalKey? key) => key is not null && key.Subject == subject && key.DeviceId == Device.DeviceId;

  /// The request this PC waits on, if any (asked again by itself after it ran out).
  public CloudApproval? WaitingRequest => requested;
  /// The matching code this PC shows under "Ask me on each new device" (the answering device shows the same); null
  /// when nothing waits or the hand-over is automatic. For the page.
  public string? MatchingCode { get; private set; }

  /// The Cloud's status; its generation is noted (while it is newer than this PC's key, nothing is sealed).
  public async Task<CloudSecretsStatus> StatusAsync()
  {
    Permitted();
    var status = await control.StatusAsync();
    NoteCloudEpoch(status.Epoch);
    return status;
  }

  public CloudSecretsProtection Protection()
  {
    CloudSecretsLocalKey? key;
    try { key = local.Read(); } catch (Exception) { return CloudSecretsProtection.Locked; }
    if (!Mine(key)) return CloudSecretsProtection.Locked;
    return key!.Acknowledged == false ? CloudSecretsProtection.WaitingForCloud : CloudSecretsProtection.Protected;
  }

  /// The confirmed key of the Cloud's current generation, or a failure.
  private async Task<CloudSecretsLocalKey> CurrentKeyAsync()
  {
    Permitted();
    var key = local.Read();
    if (!Mine(key) || key!.Root.Length != 32) throw new CloudFailure("secrets_locked");
    var status = await control.StatusAsync();
    if (status.State != CloudSecretsStatus.Ready || !status.RecoveryReady || key.Epoch != status.Epoch) throw new CloudFailure("version_changed");
    return key;
  }

  /// The highest key generation this PC has seen (its own key's, the Cloud's last notice). Null = cannot be read.
  private int? HighestEpochSeen()
  {
    try { return Math.Max(local.SeenCloudEpoch() ?? 0, local.Read()?.Epoch ?? 0); }
    catch (Exception) { return null; }
  }
  /// From status reads and the `vault` notice: the Cloud's newest generation.
  public void NoteCloudEpoch(int epoch)
  {
    if (epoch <= 0) return;
    try { if ((local.SeenCloudEpoch() ?? 0) != epoch) local.SaveSeenCloudEpoch(epoch); } catch (Exception) { }
  }

  // ---- the book and the two stricter settings ----

  private CloudSecretsHandOverBook? ReadBook()
  {
    try { return local.Book() ?? new CloudSecretsHandOverBook(); } catch (Exception) { return null; }
  }
  /// A relayed record is taken only when it is signed by THIS PC or a device its list holds (phones setting: a
  /// COMPUTER), newer than what this PC knows, not more than 5 minutes ahead, and only to switch the setting ON.
  private CloudPublicJwk? PolicyKey(string by, bool computerOnly)
  {
    if (by == Device.DeviceId) return Device.SignPublicJwk;
    return automatic?.Pinned(by) is { } pinned && (!computerOnly || pinned.IsComputer) ? pinned.SignKey : null;
  }
  private void AdoptRelayed(CloudSecretsHandOverBook book, CloudSecretsStatus? status)
  {
    if (status?.AskPolicy is { AskOnNewDevice: true } ask && ask.At > book.PolicyAt && ask.At <= now() + 300_000 && PolicyKey(ask.By, false) is { } askKey)
    {
      try
      {
        CloudKeyWrap.Verify(ask.Signature, CloudSecretsProof.AskPolicy(subject, true, ask.At, ask.By), askKey);
        book.AskOnNewDevice = true; book.PolicyAt = ask.At; local.SaveBook(book);
        log("saved passwords: took the stricter setting (ask on each new device)");
      }
      catch (Exception) { }
    }
    if (status?.PhonesPolicy is { PhonesOff: true } phones && phones.At > (book.PhonesOffAt ?? 0) && phones.At <= now() + 300_000 && PolicyKey(phones.By, true) is { } phonesKey)
    {
      try
      {
        CloudKeyWrap.Verify(phones.Signature, CloudSecretsProof.PhonesPolicy(subject, true, phones.At, phones.By), phonesKey);
        book.PhonesOff = true; book.PhonesOffAt = phones.At; local.SaveBook(book);
        log("saved passwords: took the setting that keeps saved passwords off your phones and browsers");
      }
      catch (Exception) { }
    }
  }
  /// "Ask me on each new device" as THIS PC applies it. Unreadable = true (a person decides).
  public async Task<bool> AskOnNewDeviceAsync()
  {
    if (ReadBook() is not { } book) return true;
    CloudSecretsStatus? status = null;
    try { status = await control.StatusAsync(); } catch (Exception) { }
    AdoptRelayed(book, status);
    return book.AskOnNewDevice;
  }
  /// "Keep saved passwords and secret files off my phones and browsers" as THIS PC applies it (off by default).
  /// Unreadable = true: nothing reaches a phone or a browser when this PC cannot tell.
  public async Task<bool> PhonesOffAsync()
  {
    if (ReadBook() is not { } book) return true;
    CloudSecretsStatus? status = null;
    try { status = await control.StatusAsync(); } catch (Exception) { }
    AdoptRelayed(book, status);
    return book.PhonesOff == true;
  }
  /// A PC with no key yet: what the stricter setting probably is, for its waiting line only (never for a decision).
  public async Task<bool> AskHintAsync()
  {
    try
    {
      var status = await control.StatusAsync();
      if (status.NobodyCanOpen is not null || status.AskTurnedOff) return status.AskPolicy?.AskOnNewDevice ?? false;
      if (status.AskPolicy is { } found) return found.AskOnNewDevice;
    }
    catch (Exception) { }
    return ReadBook()?.AskOnNewDevice ?? false;
  }
  /// His switches on the Cloud page (his press only; the page checks that). Kept beside the key FIRST, then signed and
  /// handed to the service for his other devices. False when the service could not carry it (kept on this PC only).
  public async Task<bool> SetPhonesOffAsync(bool value)
  {
    Permitted();
    var book = ReadBook() ?? throw new CloudFailure("unavailable");
    var at = Math.Max(now(), (book.PhonesOffAt ?? 0) + 1);
    book.PhonesOff = value; book.PhonesOffAt = at; local.SaveBook(book);
    try { await control.PublishPhonesPolicyAsync(new(value, at, Device.DeviceId, Sign(CloudSecretsProof.PhonesPolicy(subject, value, at, Device.DeviceId)))); return true; }
    catch (Exception) { return false; }
  }
  public async Task<bool> SetAskOnNewDeviceAsync(bool value)
  {
    Permitted();
    var book = ReadBook() ?? throw new CloudFailure("unavailable");
    var at = Math.Max(now(), book.PolicyAt + 1);
    book.AskOnNewDevice = value; book.PolicyAt = at; local.SaveBook(book);
    try { await control.PublishAskPolicyAsync(new(value, at, Device.DeviceId, Sign(CloudSecretsProof.AskPolicy(subject, value, at, Device.DeviceId)))); return true; }
    catch (Exception) { return false; }
  }
  /// A computer always; one of his phones or browsers unless his switch keeps saved passwords off them; else never.
  private async Task<bool> MayHoldAsync(string? platform)
  {
    if (CloudSecretsKinds.IsComputer(platform)) return true;
    if (!CloudSecretsKinds.IsPhone(platform) && !CloudSecretsKinds.IsBrowser(platform)) return false;
    return !await PhonesOffAsync();
  }

  // ---- this PC gets the key ----

  /// Owner's decision (14 Nov): the account's FIRST device makes the key by itself: no sheet, no recovery words.
  public async Task SetupSilentlyAsync()
  {
    using var _ = await EnterAsync();
    Permitted();
    var old = await control.StatusAsync();
    if (old.State != CloudSecretsStatus.Unset || old.Version != "0" || local.Read() is not null) throw new CloudFailure("version_changed");
    var epoch = old.Epoch + 1; const string version = "1";
    var vaultVersion = CloudSecretsWire.Next(old.Version);
    var root = RandomNumberGenerator.GetBytes(32); var entropy = RandomNumberGenerator.GetBytes(32);
    try
    {
      var recovery = new CloudRecoveryKeys(entropy, subject);
      var recoveryEnvelope = recovery.SealPlaceholder(subject, version, epoch);
      var (envelope, canaryHash) = CloudKeyWrap.Wrap(root, subject, Device, epoch, version, Device.DeviceId, sign);
      var receipt = await control.InitializeAsync(recoveryEnvelope, envelope, canaryHash);
      if (receipt.Epoch != epoch || receipt.Version != vaultVersion || !SameEnvelope(receipt.DeviceEnvelope, envelope)) throw new CloudFailure("checksum_mismatch");
      await ReadBackAndKeepAsync(root, epoch, version, vaultVersion, recoveryEnvelope, envelope, canaryHash, recovery.PublicKey);
      log("saved passwords: set the Cloud copy up on this PC (the first device of the account)");
    }
    finally { CryptographicOperations.ZeroMemory(root); CryptographicOperations.ZeroMemory(entropy); }
  }
  /// A new generation made here (set-up or key change): read back independently, opened, saved, then possession.
  private async Task ReadBackAndKeepAsync(byte[] root, int epoch, string version, string vaultVersion, CloudRecoveryEnvelope recoveryEnvelope,
    CloudDeviceKeyEnvelope envelope, string canaryHash, CloudPublicJwk recoveryKey, bool saveFirst = false)
  {
    var cloudRecovery = await control.RecoveryChallengeAsync(KeyHash);
    if (cloudRecovery.Epoch != epoch || cloudRecovery.Version != vaultVersion || !cloudRecovery.RecoveryEnvelope.Same(recoveryEnvelope)) throw new CloudFailure("checksum_mismatch");
    var readback = await control.EnvelopeAsync();
    if (readback.Epoch != epoch || readback.Version != vaultVersion || !SameEnvelope(readback.DeviceEnvelope, envelope)) throw new CloudFailure("checksum_mismatch");
    var body = CloudKeyWrap.Unwrap(readback.DeviceEnvelope, subject, Device.DeviceId, epoch, version, Device.DeviceId, Device.SignPublicJwk, shared);
    var opened = CloudBytes.Unbase64(body.RootKey, 32);
    try
    {
      if (!CryptographicOperations.FixedTimeEquals(opened, root) || CloudBytes.Sha256Hex(CloudBytes.Unbase64(body.Canary, 32)) != canaryHash) throw new CloudFailure("checksum_mismatch");
    }
    finally { CryptographicOperations.ZeroMemory(opened); }
    if (saveFirst)
    {
      // A key change: saved before possession, so a lost answer never leaves this PC without the key it just made.
      Save(root, epoch, version, recoveryKey, acknowledged: false, recoveryWords: false);
      try { await PossessAsync(body, readback.Version); } catch (CloudFailure f) when (f.Code == "secrets_locked") { }
      MarkAcknowledged();
      return;
    }
    await PossessAsync(body, readback.Version);
    Save(root, epoch, version, recoveryKey, acknowledged: true, recoveryWords: false);
  }
  private static bool SameEnvelope(CloudDeviceKeyEnvelope a, CloudDeviceKeyEnvelope b) => CloudCanonical.Encode(a.ToJson()).AsSpan().SequenceEqual(CloudCanonical.Encode(b.ToJson()));

  private async Task PossessAsync(CloudSecretsUnwrapped body, string version)
  {
    Permitted();
    var signature = Sign(CloudSecretsProof.Possession(subject, Device.DeviceId, version, body.Canary));
    var receipt = await control.PossessionAsync(version, body.Canary, signature);
    if (!receipt.Approved || receipt.Epoch != body.Epoch || CloudSecretsWire.Number(receipt.Version) <= CloudSecretsWire.Number(version)) throw new CloudFailure("checksum_mismatch");
  }

  /// Saved only forward: a newer generation's key never discards the older one (kept as that generation's archive
  /// first, refused if it cannot be kept); a replayed older generation never replaces a newer one. Read back exactly.
  private void Save(byte[] root, int epoch, string version, CloudPublicJwk recoveryKey, bool acknowledged, bool? recoveryWords)
  {
    Permitted();
    var value = new CloudSecretsLocalKey(subject, Device.DeviceId, epoch, version, root.ToArray(), recoveryKey, acknowledged, recoveryWords);
    if (local.Read() is { } existing && Mine(existing))
    {
      if (epoch < existing.Epoch || CloudSecretsWire.Number(version) < CloudSecretsWire.Number(existing.Version)) throw new CloudFailure("version_changed");
      if (existing.Epoch < epoch)
      {
        local.Archive(existing);
        if (local.Archived(existing.Epoch) is not { } kept || !kept.SameRoot(existing.Root) || !Mine(kept)) throw new CloudFailure("checksum_mismatch");
      }
    }
    local.SaveVerified(value);
    try { if ((local.SeenCloudEpoch() ?? 0) < epoch) local.SaveSeenCloudEpoch(epoch); } catch (Exception) { }
    if (local.Read() is not { } saved || !Mine(saved) || saved.Epoch != epoch || saved.Version != version || !saved.SameRoot(root)
      || saved.Acknowledged != acknowledged || saved.RecoveryWords != recoveryWords) throw new CloudFailure("checksum_mismatch");
  }
  private void MarkAcknowledged()
  {
    var key = local.Read();
    if (!Mine(key)) throw new CloudFailure("secrets_locked");
    if (key!.Acknowledged != false) return;
    Save(key.Root, key.Epoch, key.Version, key.RecoveryPublicKey, acknowledged: true, key.RecoveryWords);
  }

  /// A set-up the service accepted whose key never reached this PC's slot: the copy this PC sealed FOR ITSELF opens,
  /// only when addressed to this PC and signed by this PC's own signing key. Nothing new is trusted.
  public async Task<bool> ReopenOwnCopyAsync()
  {
    using var _ = await EnterAsync();
    Permitted();
    if (local.Read() is not null) return false;
    var status = await control.StatusAsync();
    if (status.State != CloudSecretsStatus.Ready) return false;
    CloudSecretsEnvelopeReceipt receipt;
    try { receipt = await control.EnvelopeAsync(); } catch (Exception) { return false; }
    if (receipt.Epoch != status.Epoch || receipt.DeviceEnvelope.TargetDeviceId != Device.DeviceId || receipt.DeviceEnvelope.AuthorDeviceId != Device.DeviceId) return false;
    if (HighestEpochSeen() is not { } highest || receipt.Epoch < highest) return false;
    var recovery = await control.RecoveryChallengeAsync(KeyHash);
    if (recovery.Epoch != receipt.Epoch) return false;
    var body = CloudKeyWrap.Unwrap(receipt.DeviceEnvelope, subject, Device.DeviceId, receipt.Epoch, recovery.RecoveryEnvelope.Version, Device.DeviceId, Device.SignPublicJwk, shared);
    await KeepOpenedAsync(body, receipt, recovery);
    log("saved passwords: opened this PC's own copy (a set-up that had not finished here)");
    return true;
  }
  /// Store first (unconfirmed), then prove possession; an approved device's refusal means "already done".
  private async Task KeepOpenedAsync(CloudSecretsUnwrapped body, CloudSecretsEnvelopeReceipt receipt, CloudRecoveryChallenge recovery)
  {
    var root = CloudBytes.Unbase64(body.RootKey, 32);
    try
    {
      Save(root, receipt.Epoch, recovery.RecoveryEnvelope.Version, recovery.RecoveryEnvelope.PublicSigningJwk, acknowledged: false, !recovery.RecoveryEnvelope.IsPlaceholder);
      try { await PossessAsync(body, receipt.Version); } catch (CloudFailure f) when (f.Code == "secrets_locked") { }
      MarkAcknowledged();
    }
    finally { CryptographicOperations.ZeroMemory(root); }
  }

  /// Asks his other devices. This PC signs its own request (no code shown) unless the hand-over is not automatic here.
  public async Task<CloudApproval> RequestApprovalAsync()
  {
    using var _ = await EnterAsync();
    Permitted();
    CloudDeviceKeyEnvelope? leftover = null;
    try { leftover = (await control.EnvelopeAsync()).DeviceEnvelope; } catch (Exception) { }
    var approval = await control.RequestApprovalAsync(Device.DeviceId, KeyHash);
    if (approval.TargetDeviceId != Device.DeviceId || approval.TargetKeyHash != KeyHash || approval.ExpiresAt <= now() || approval.ExpiresAt > now() + 600_000)
      throw new CloudFailure("invalid_request");
    requested = approval; staleEnvelope = leftover; possessionUnconfirmed = false;
    var signed = false;
    if (AutomaticOn)
    {
      try
      {
        var epoch = (await control.StatusAsync()).Epoch;
        await control.SignRequestAsync(approval.ApprovalId, Sign(CloudSecretsProof.Request(subject, approval, Device.WrapPublicJwk, epoch)));
        signed = true;
      }
      catch (Exception) { }
    }
    signedRequest = signed;
    // Under his stricter setting the answering device shows the code, so this PC shows the same code to compare.
    MatchingCode = signed && !await AskHintAsync() ? null : CloudKeyWrap.MatchingCode(approval);
    return approval;
  }

  /// Called on the `vault` notice. True only when a key was installed here; false = still waiting (a leftover envelope).
  /// The author must be a device THIS PC's own list holds with exactly that signing key; otherwise it stays waiting.
  /// `confirmTransfer`: the person's code comparison for a request that was not signed (the page; null = none here).
  public async Task<bool> ReceiveApprovalAsync(Func<string, string, Task<bool>>? confirmTransfer = null)
  {
    using var _ = await EnterAsync();
    Permitted();
    if (requested is not { } pending || pending.ExpiresAt <= now() || pending.TargetKeyHash != KeyHash) throw new CloudFailure("invalid_request");
    var status = await control.StatusAsync(); var receipt = await control.EnvelopeAsync();
    if (staleEnvelope is { } stale && SameEnvelope(stale, receipt.DeviceEnvelope)) return false;
    if (!status.RecoveryReady || status.State != CloudSecretsStatus.Ready || status.Version != receipt.Version || status.Epoch != receipt.Epoch
      || receipt.DeviceEnvelope.AuthorDeviceId == Device.DeviceId || receipt.DeviceEnvelope.AuthorDeviceId == "recovery") throw new CloudFailure("invalid_request");
    var author = await control.RegisteredDeviceAsync(receipt.DeviceEnvelope.AuthorDeviceId);
    var recovery = await control.RecoveryChallengeAsync(pending.TargetKeyHash);
    if (recovery.Epoch != receipt.Epoch || recovery.Version != receipt.Version) throw new CloudFailure("version_changed");
    var body = CloudKeyWrap.Unwrap(receipt.DeviceEnvelope, subject, Device.DeviceId, receipt.Epoch, recovery.RecoveryEnvelope.Version, author.DeviceId, author.SignPublicJwk, shared);
    var root = CloudBytes.Unbase64(body.RootKey, 32);
    try
    {
      var existing = local.Read();
      var alreadyHeld = Mine(existing) && existing!.Epoch == receipt.Epoch && existing.SameRoot(root);
      var answeredBy = CloudTrustStore.PlainName(author.Label);
      if (!alreadyHeld && signedRequest && automatic is not null)
      {
        if (automatic.Pinned(author.DeviceId) is not { } pinned || !pinned.SameKey(author.SignPublicJwk))
        {
          log("saved passwords: an answer was not taken: its author is not listed on this PC with that key");
          throw new CloudFailure("invalid_request");
        }
        answeredBy = pinned.Name;
      }
      else if (!alreadyHeld)
      {
        // Possession alone does not authenticate a server-supplied author key: the person compares the second code.
        var code = CloudKeyWrap.TransferCode(CloudWire.Issuer, subject, pending, Device, author.SignPublicJwk, receipt.DeviceEnvelope);
        if (confirmTransfer is null || !await confirmTransfer(answeredBy, code))
        {
          requested = null; staleEnvelope = null; possessionUnconfirmed = false; MatchingCode = null;
          throw new OperationCanceledException();
        }
      }
      Permitted();
      if (pending.ExpiresAt <= now()) throw new CloudFailure("invalid_request");
      if (!alreadyHeld) Save(root, receipt.Epoch, recovery.RecoveryEnvelope.Version, recovery.RecoveryEnvelope.PublicSigningJwk, acknowledged: false, !recovery.RecoveryEnvelope.IsPlaceholder);
      try { await PossessAsync(body, receipt.Version); }
      catch (CloudFailure f)
      {
        if (!(f.Code == "secrets_locked" && alreadyHeld && possessionUnconfirmed))
        {
          if (f.Status == 0) possessionUnconfirmed = true;
          throw;
        }
      }
      catch (Exception) { possessionUnconfirmed = true; throw; }
      MarkAcknowledged();
      requested = null; staleEnvelope = null; possessionUnconfirmed = false; MatchingCode = null;
      if (!alreadyHeld) log("saved passwords: opened by itself: answered by " + answeredBy);
      return true;
    }
    finally { CryptographicOperations.ZeroMemory(root); }
  }

  /// A PC that saved its key but never got the Cloud's confirmation: acknowledged from the waiting envelope when it
  /// opens to the exact root already held. No new request, nothing new trusted.
  public async Task<bool> ConfirmPendingAcknowledgementAsync()
  {
    using var _ = await EnterAsync();
    Permitted();
    var key = local.Read();
    if (!Mine(key) || key!.Acknowledged != false) return false;
    var receipt = await control.EnvelopeAsync();
    if (receipt.Epoch != key.Epoch || receipt.DeviceEnvelope.TargetDeviceId != Device.DeviceId || receipt.DeviceEnvelope.AuthorDeviceId == Device.DeviceId
      || receipt.DeviceEnvelope.AuthorDeviceId == "recovery") return false;
    var author = await control.RegisteredDeviceAsync(receipt.DeviceEnvelope.AuthorDeviceId);
    var body = CloudKeyWrap.Unwrap(receipt.DeviceEnvelope, subject, Device.DeviceId, key.Epoch, key.Version, author.DeviceId, author.SignPublicJwk, shared);
    var root = CloudBytes.Unbase64(body.RootKey, 32);
    try
    {
      if (!key.SameRoot(root)) return false;
      try { await PossessAsync(body, receipt.Version); } catch (CloudFailure f) when (f.Code == "secrets_locked") { }
      MarkAcknowledged();
      requested = null; staleEnvelope = null; possessionUnconfirmed = false;
      return true;
    }
    finally { CryptographicOperations.ZeroMemory(root); }
  }

  // ---- this PC hands the key on ----

  /// Answers one pending request with the key sealed for the requesting device's own registered key, with no sheet and
  /// no code, only when every check holds; otherwise the request is left for a person (never denied). Returns the name
  /// THIS PC pinned for the device answered, null when skipped.
  public async Task<string?> AnswerAutomaticallyAsync(string id)
  {
    if (automatic is null || !automatic.On) return null;
    if (await AskOnNewDeviceAsync()) { Refusal(id, "a request by itself: the stricter setting is on here, it waits for your click"); return null; }
    using var _ = await EnterAsync();
    var key = await CurrentKeyAsync();
    var state = await control.StatusAsync();
    if (state.State != CloudSecretsStatus.Ready || state.Epoch != key.Epoch || state.Pending.FirstOrDefault(p => p.Approval.ApprovalId == id) is not { } pending
      || pending.Approval.TargetDeviceId == Device.DeviceId || pending.Approval.ExpiresAt <= now() || pending.Approval.ExpiresAt > now() + 600_000) return null;
    var approval = pending.Approval;
    CloudDeviceRegistration target;
    try { target = await control.RegisteredDeviceAsync(approval.TargetDeviceId); }
    catch (Exception) { Refusal(id, "a request: its device is not active in the account"); return null; }
    var who = CloudTrustStore.PlainName(target.Label);
    if (CloudKeyWrap.KeyHash(target) != approval.TargetKeyHash) { Refusal(id, "a request from " + who + ": its keys do not match the request"); return null; }
    if (CloudSecretsKinds.Kind(target.Platform) is null) { Refusal(id, "a request from " + who + ": not a computer, a phone or a browser"); return null; }
    // D1 (decided by Decker): a new sign-in on a machine another device signed out waits for his "Yes, it's mine".
    if (pending.SignedOutBefore) { Refusal(id, "a request from " + who + ": signed out from another device before; it waits for your “Yes, it's mine”"); return null; }
    if (CloudSecretsKinds.IsPhone(target.Platform) && await PhonesOffAsync()) { Refusal(id, "a request from " + who + ": your setting keeps saved passwords off your phones"); return null; }
    if (CloudSecretsKinds.IsBrowser(target.Platform) && await PhonesOffAsync()) { Refusal(id, "a request from " + who + ": your setting keeps saved passwords off your browsers"); return null; }
    CloudSecretsPinned? signedBy;
    try { signedBy = SignedRequestAuthor(pending, target, key.Epoch); }
    catch (CloudFailure) { Refusal(id, "a request from " + who + ": wrong signature"); return null; }
    if (signedBy is null || !await MayHoldAsync(signedBy.Platform) || !CloudSecretsKinds.SameKind(signedBy.Platform, target.Platform))
    {
      if (automatic.Pinned(target.DeviceId) is { } listed && listed.SameKey(target.SignPublicJwk))
        Refusal(id, "a request from " + who + (CloudSecretsKinds.Kind(listed.Platform) is not null
          ? ": not signed (an older app), or not the kind of device kept here; it waits for your click" : ": not a computer, a phone or a browser"));
      else Refusal(id, "a request from " + who + ": not listed on this PC");
      return null;
    }
    // Once per device per key generation, from the book beside the key; unreadable = answered.
    if (ReadBook() is not { } book || book.HasAnswered(target.DeviceId, key.Epoch))
    {
      Refusal(id, "a request from " + who + ": already answered once for this key; it waits for your click"); return null;
    }
    Permitted();
    if (!automatic.On || await AskOnNewDeviceAsync() || !await MayHoldAsync(signedBy.Platform)) return null;
    // "Answered" is written beside the key BEFORE the answer goes out; if it cannot be written, nothing goes out.
    book.Answered.Add(CloudSecretsHandOverBook.Key(target.DeviceId, key.Epoch));
    book.NoteWrapKeyVerified(target);
    book.TrimAnswered();
    local.SaveBook(book);
    var (envelope, canaryHash) = CloudKeyWrap.Wrap(key.Root, subject, target, key.Epoch, key.Version, Device.DeviceId, sign);
    var proof = Sign(CloudSecretsProof.Approval(approval, true, state.Version, envelope, canaryHash));
    var answer = await control.AnswerAsync(id, true, state.Version, envelope, canaryHash, Device.DeviceId, proof);
    if (answer != "approved") throw new CloudFailure("checksum_mismatch");
    return signedBy.Name;
  }

  /// The requesting device's own signature over this request, checked with the signing key THIS PC pinned for it.
  /// Null = unsigned, or not on this PC's list with exactly that key, or no known kind. A signature that is present and
  /// does not verify throws: such a request is never answered and never shown.
  private CloudSecretsPinned? SignedRequestAuthor(CloudPendingApproval pending, CloudDeviceRegistration target, int epoch)
  {
    if (automatic is null || pending.TargetSignature is not { } signature) return null;
    if (automatic.Pinned(target.DeviceId) is not { } pinned || !pinned.SameKey(target.SignPublicJwk)) return null;
    try { CloudKeyWrap.Verify(signature, CloudSecretsProof.Request(subject, pending.Approval, target.WrapPublicJwk, epoch), pinned.SignKey); }
    catch (Exception) { throw new CloudFailure("checksum_mismatch"); }
    return CloudSecretsKinds.Kind(pinned.Platform) is not null ? pinned : null;
  }

  /// Answers every pending request of another device that passes every check. True when something was left (for a
  /// person or a later look).
  public async Task<bool> AnswerAllAsync()
  {
    if (automatic is not { On: true } || Protection() != CloudSecretsProtection.Protected) return false;
    CloudSecretsStatus status;
    try { status = await control.StatusAsync(); } catch (Exception) { return false; }
    var left = false;
    foreach (var pending in status.Pending.Where(p => p.Approval.TargetDeviceId != Device.DeviceId && p.Approval.ExpiresAt > now()))
    {
      try
      {
        if (await AnswerAutomaticallyAsync(pending.Approval.ApprovalId) is { } name) log("saved passwords: answered a request from " + name + " by itself");
        else left = true;
      }
      catch (Exception error) { log("saved passwords: answering a request by itself failed: " + CloudAccountClient.Kind(error)); left = true; }
    }
    return left;
  }

  /// Whether this account has no recovery words (a silent set-up): from this PC's key.
  public bool? RecoveryWordsExist() { try { return local.Read() is { } key && Mine(key) ? key.RecoveryWords ?? true : null; } catch (Exception) { return null; } }

  /// The confirmed key of `epoch` (or the current one), for sealing and opening: never while it waits for the Cloud's
  /// confirmation, and never while the Cloud is known to be at a newer generation.
  internal CloudSecretsLocalKey? UsableKey(int? epoch = null)
  {
    if (!permitted()) return null;
    CloudSecretsLocalKey? key;
    try { key = local.Read(); } catch (Exception) { return null; }
    if (!Mine(key) || key!.Root.Length != 32 || key.Epoch <= 0 || CloudSecretsWire.Number(key.Version) == 0 || key.Acknowledged == false) return null;
    if (epoch is { } wanted && key.Epoch != wanted) return null;
    int seen;
    try { seen = local.SeenCloudEpoch() ?? 0; } catch (Exception) { seen = 0; }
    return key.Epoch >= seen ? key : null;
  }
  /// The Cloud's newer generation while this PC's key is behind it (0 when not behind).
  internal int NewerCloudEpoch()
  {
    try { var key = local.Read(); var seen = local.SeenCloudEpoch() ?? 0; return Mine(key) && key!.Epoch < seen ? seen : 0; }
    catch (Exception) { return 0; }
  }
}
