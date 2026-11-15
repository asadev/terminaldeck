using System.Security.Cryptography;

namespace TerminalDeck.Core.Cloud;

// A lost device signed out from another device (sign-out-lost-mac-design.md, MAC AS BUILT, and the service as built:
// rotationDue, POST /secrets/rotate, refusedCopies, device_revoked {removedByName, removedAt}). Port of the Mac's
// CloudRecoveryCoordinator keyChange / rotate / takeKeyChangeCopy / markCopies and BackendCloudSecretsProtectedStore
// forgetAfterRemoteSignOut. No sheet, no click; nothing local is deleted except, on THIS device being signed out by
// ANOTHER device, this device id's own Cloud keys.

public enum CloudSecretsKeyChange { Nothing, Rotated, TookCopy }

public sealed partial class CloudSecretsHandover
{
  /// This PC holds a key of an OLDER generation than the Cloud's. Unreadable = false.
  public async Task<bool> KeyBehindAsync()
  {
    try
    {
      var key = local.Read();
      if (!Mine(key)) return false;
      var status = await control.StatusAsync();
      return status.State == CloudSecretsStatus.Ready && key!.Epoch < status.Epoch;
    }
    catch (Exception) { return false; }
  }

  /// On every `vault`, `devices` and `hello` notice (no timer). Behind: take the copy another device sealed for this
  /// PC. Current and the account says a key change is due: wait a moment, look again, then make the new key here.
  public async Task<CloudSecretsKeyChange> KeyChangeAsync()
  {
    Permitted();
    if (await KeyBehindAsync()) return await TakeKeyChangeCopyAsync() ? CloudSecretsKeyChange.TookCopy : CloudSecretsKeyChange.Nothing;
    CloudSecretsRotationDue? due = null;
    try { due = (await control.StatusAsync()).RotationDue; } catch (Exception) { }
    CloudSecretsLocalKey? key = null;
    try { key = local.Read(); } catch (Exception) { }
    if (due is null || due.RemovedDeviceId.Length > 0 && due.RemovedDeviceId.Equals(Device.DeviceId, StringComparison.OrdinalIgnoreCase)
      || !Mine(key) || key!.Acknowledged == false) return CloudSecretsKeyChange.Nothing;
    await Sleep(RotationJitter());
    CloudSecretsRotationDue? again = null;
    try { again = (await control.StatusAsync()).RotationDue; } catch (Exception) { }
    if (again is null || again.Since != due.Since) return await CopyIfBehindAsync();
    try { await RotateAsync(again); }
    catch (CloudFailure failure) when (LostTheRace(failure))
    {
      log("saved passwords: the key change was made on another of your devices first; taking its copy");
      return await CopyIfBehindAsync();
    }
    return CloudSecretsKeyChange.Rotated;
  }
  private async Task<CloudSecretsKeyChange> CopyIfBehindAsync() =>
    await KeyBehindAsync() && await TakeKeyChangeCopyAsync() ? CloudSecretsKeyChange.TookCopy : CloudSecretsKeyChange.Nothing;
  public static bool LostTheRace(CloudFailure failure) => failure.Code is "version_changed" or "not_due";
  /// The refusals of `/secrets/rotate` that can be about one copy (not about the caller or the race).
  public static bool RefusesACopy(string code) => code is "not_approved" or "phones_off" or "bad_signature" or "invalid_request";

  /// The change itself: a new 32-byte key (generation + 1), a placeholder recovery copy, this PC's own copy, and one copy
  /// for each device the service lists as holding the current key AND this PC's own list holds with exactly that signing
  /// key, of the same kind, allowed to hold it, whose OWN signature over that wrapping key this PC checked earlier.
  /// Never the removed device, never a browser. One call; then read back and saved as a set-up is.
  private async Task RotateAsync(CloudSecretsRotationDue due)
  {
    using var _ = await EnterAsync();
    var key = await CurrentKeyAsync();
    var old = await control.StatusAsync();
    if (old.State != CloudSecretsStatus.Ready || old.Epoch != key.Epoch) throw new CloudFailure("version_changed");
    var vaultVersion = CloudSecretsWire.Next(old.Version); var epoch = old.Epoch + 1;
    var current = await control.RecoveryChallengeAsync(KeyHash);
    if (current.Epoch != old.Epoch || current.Version != old.Version) throw new CloudFailure("version_changed");
    var version = CloudSecretsWire.Next(current.RecoveryEnvelope.Version);
    var root = RandomNumberGenerator.GetBytes(32); var entropy = RandomNumberGenerator.GetBytes(32);
    try
    {
      var recovery = new CloudRecoveryKeys(entropy, subject);
      var recoveryEnvelope = recovery.SealPlaceholder(subject, version, epoch);
      var (envelope, canaryHash) = CloudKeyWrap.Wrap(root, subject, Device, epoch, version, Device.DeviceId, sign);
      var verified = ReadBook();
      var planned = new List<(CloudSecretsRotateCopy Copy, string Name)>();
      foreach (var id in due.Holders.Select(h => h.ToLowerInvariant()).Distinct().Order(StringComparer.Ordinal))
      {
        if (id == Device.DeviceId.ToLowerInvariant() || id == due.RemovedDeviceId.ToLowerInvariant()) continue;
        if (planned.Count >= 64) { log("saved passwords: key change: more than 64 devices hold the key; the rest ask again by themselves"); break; }
        CloudDeviceRegistration? target = null;
        try { target = await control.RegisteredDeviceAsync(id); } catch (Exception) { }
        var pinned = target is null ? null : automatic?.Pinned(target.DeviceId);
        if (target is null || target.DeviceId.ToLowerInvariant() != id || pinned is null || !pinned.SameKey(target.SignPublicJwk)
          || CloudSecretsKinds.Kind(pinned.Platform) is null || !CloudSecretsKinds.SameKind(pinned.Platform, target.Platform) || !await MayHoldAsync(pinned.Platform))
        {
          log("saved passwords: key change: no copy for a device this PC does not list with its key; it asks again by itself");
          continue;
        }
        // Key-box sign-off finding 2: a browser may be the one still signed in on the lost device. Never a browser here.
        if (CloudSecretsKinds.IsBrowser(pinned.Platform) || CloudSecretsKinds.IsBrowser(target.Platform))
        {
          log("saved passwords: key change: no copy for a browser after a sign-out from another device; it asks again by itself");
          continue;
        }
        if (verified?.WrapKeyVerified(target) != true)
        {
          log("saved passwords: key change: no copy for " + pinned.Name + ": its own signature over its key was not checked here; it asks again by itself");
          continue;
        }
        var (copy, hash) = CloudKeyWrap.Wrap(root, subject, target, epoch, version, Device.DeviceId, sign);
        planned.Add((new(target.DeviceId, copy, hash), pinned.Name));
      }
      var sent = planned;
      CloudSecretsRotateReceipt? receipt = null;
      for (var attempt = 0; attempt < 2; attempt++)
      {
        MarkCopies(sent.Select(s => s.Copy.TargetDeviceId), epoch, keep: true);
        Permitted();
        try { receipt = await control.RotateAsync(old.Version, recoveryEnvelope, envelope, canaryHash, sent.Select(s => s.Copy).ToArray()); break; }
        catch (CloudFailure refused) when (sent.Count > 0 && attempt == 0 && RefusesACopy(refused.Code))
        {
          // The call changed nothing: the "answered" marks of the copies that did not go are taken back first.
          MarkCopies(sent.Select(s => s.Copy.TargetDeviceId), epoch, keep: false);
          log("saved passwords: key change: Cloud did not take the copies (" + refused.Code + "); changing the key with none; your devices ask again by themselves");
          sent = [];
        }
      }
      if (receipt is null) throw new CloudFailure("unavailable");
      var refusedIds = receipt.Refused.Select(r => r.Device.ToLowerInvariant()).ToHashSet(StringComparer.Ordinal);
      if (refusedIds.Count > 0)
      {
        MarkCopies(sent.Select(s => s.Copy.TargetDeviceId).Where(d => refusedIds.Contains(d.ToLowerInvariant())), epoch, keep: false);
        log("saved passwords: key change: " + refusedIds.Count + " of the copies were not taken by Cloud; those devices ask again by themselves");
        sent = sent.Where(s => !refusedIds.Contains(s.Copy.TargetDeviceId.ToLowerInvariant())).ToList();
      }
      if (receipt.Epoch != epoch || receipt.Version != vaultVersion || receipt.State != CloudSecretsStatus.Ready || receipt.PreservedArchiveId.Length == 0)
        throw new CloudFailure("checksum_mismatch");
      await ReadBackAndKeepAsync(root, epoch, version, vaultVersion, recoveryEnvelope, envelope, canaryHash, recovery.PublicKey, saveFirst: true);
      log("saved passwords: changed the key after " + (due.RemovedName.Length == 0 ? "a device" : CloudTrustStore.PlainName(due.RemovedName))
        + " was signed out; sealed for " + (sent.Count == 0 ? "this PC only" : string.Join(", ", sent.Select(s => s.Name))));
    }
    finally { CryptographicOperations.ZeroMemory(root); CryptographicOperations.ZeroMemory(entropy); }
  }

  /// A copy of the NEW generation another of his devices sealed for this PC at a key change. Taken only when this PC
  /// holds an older key, the copy is addressed to this PC at the Cloud's current generation, and its author is a
  /// COMPUTER on this PC's own trusted list with exactly that signing key (never the service's word alone).
  public async Task<bool> TakeKeyChangeCopyAsync()
  {
    using var _ = await EnterAsync();
    Permitted();
    var held = local.Read();
    if (!Mine(held)) return false;
    var status = await control.StatusAsync();
    CloudSecretsEnvelopeReceipt? receipt = null;
    try { receipt = await control.EnvelopeAsync(); } catch (Exception) { }
    if (status.State != CloudSecretsStatus.Ready || held!.Epoch >= status.Epoch || receipt is null || receipt.Epoch != status.Epoch || receipt.Version != status.Version
      || receipt.DeviceEnvelope.TargetDeviceId != Device.DeviceId || receipt.DeviceEnvelope.AuthorDeviceId == Device.DeviceId || receipt.DeviceEnvelope.AuthorDeviceId == "recovery")
      return false;
    if (HighestEpochSeen() is not { } highest || receipt.Epoch < highest) return false;
    var author = await control.RegisteredDeviceAsync(receipt.DeviceEnvelope.AuthorDeviceId);
    if (automatic?.Pinned(author.DeviceId) is not { } pinned || !pinned.SameKey(author.SignPublicJwk) || !pinned.IsComputer || !CloudSecretsKinds.SameKind(pinned.Platform, author.Platform))
    {
      log("saved passwords: a new key copy was not taken: its author is not one of your computers listed on this PC");
      return false;
    }
    var recovery = await control.RecoveryChallengeAsync(KeyHash);
    if (recovery.Epoch != receipt.Epoch || recovery.Version != receipt.Version) throw new CloudFailure("version_changed");
    var body = CloudKeyWrap.Unwrap(receipt.DeviceEnvelope, subject, Device.DeviceId, receipt.Epoch, recovery.RecoveryEnvelope.Version, author.DeviceId, pinned.SignKey, shared);
    await KeepOpenedAsync(body, receipt, recovery);
    log("saved passwords: took the new key from " + pinned.Name + " after a key change");
    return true;
  }

  /// "Answered at this generation" for the copies of a key change: written BEFORE they go out (`keep`), taken back for
  /// copies a refused call never delivered, so those devices are answered by themselves when they ask again.
  private void MarkCopies(IEnumerable<string> ids, int epoch, bool keep)
  {
    var keys = ids.Select(i => CloudSecretsHandOverBook.Key(i, epoch)).ToHashSet(StringComparer.Ordinal);
    if (keys.Count == 0) return;
    var book = ReadBook() ?? new CloudSecretsHandOverBook();
    if (keep) book.Answered.AddRange(keys.Where(k => !book.Answered.Contains(k)).Order(StringComparer.Ordinal));
    else book.Answered.RemoveAll(keys.Contains);
    book.TrimAnswered();
    local.SaveBook(book);
  }

  /// B4: this PC was signed out by ANOTHER device (the service said `device_revoked` with who and when, twice). This
  /// device id's Cloud keys go: the key, its older generations, the seen mark and the book. Never any data.
  public void ForgetAfterRemoteSignOut()
  {
    try { local.ForgetAfterRemoteSignOut(); log("saved passwords: signed out from another device: this PC's Cloud keys were removed; everything else is kept"); }
    catch (Exception error) { log("saved passwords: signed out from another device: this PC's Cloud keys could not all be removed: " + CloudAccountClient.Kind(error)); }
  }
}
