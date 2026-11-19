namespace TerminalDeck.Core.Cloud;

/// What the sync bridge needs from the signed-in account: who is signed in (null while signed out or while "Use Cloud on
/// this PC" is off), the login for requests, this PC's device-signed headers and pack signatures, and this PC's trusted
/// list. Nothing here is reachable from a tool.
public interface ICloudSyncAccount : ICloudSyncAuth
{
  CloudSnapshot Snapshot { get; }
  event Action<CloudSnapshot>? Changed;
  /// The signed-in account and this PC's device id while Cloud is on here; null otherwise.
  (string Subject, string DeviceId)? SyncIdentity { get; }
  /// This PC's ES256 signature over a pack descriptor's signing bytes (raw r||s).
  byte[] SignPack(byte[] bytes);
  /// This PC's trusted list as it stands at each call (fail safe: nothing trusted while it cannot be read).
  ICloudDeviceTrust SyncTrust { get; }
  /// Asks the account again (device list; in automatic trust mode new devices join this PC's list here).
  Task RefreshAsync(CancellationToken ct = default);
}

// The account's side of sync (W3 wiring). The token is refreshed here, under the account's own lock, when it is about
// to expire; a session the service refused ends the sign-in exactly as the page's own refresh does.
public sealed partial class CloudAccountClient : ICloudSyncAccount
{
  public (string Subject, string DeviceId)? SyncIdentity
  {
    get
    {
      var record = saved;
      return record is not null && keys is not null && Snapshot.Phase == CloudPhase.SignedIn && Snapshot.Subscription.AllowsCloudServices && !record.CloudOff && record.Registered
        ? (record.Session.User.Id, record.DeviceId) : null;
    }
  }

  /// Reach by account (this PC reachable by its devices, and reaching its other computers): the sync identity, or, for a
  /// free account (19 Nov), the signed-in account and this PC's registered device with Cloud sync not running.
  public (string Subject, string DeviceId)? ReachIdentity
  {
    get
    {
      if (SyncIdentity is { } synced) return synced;
      var record = saved;
      return record is not null && keys is not null && FreeReach(record) ? (record.Session.User.Id, record.DeviceId) : null;
    }
  }
  // A free account's sign-in: kept, this PC registered, only the relay in use (the snapshot says "not allowed" to Cloud).
  private bool FreeReach(Saved record) => Snapshot.Phase == CloudPhase.NotAllowed && Snapshot.Subscription.LimitsRemoteToSessions && !record.CloudOff && record.Registered;

  public async Task<CloudSyncCredentials> CredentialsAsync(CancellationToken ct)
  {
    await work.WaitAsync(ct);
    try
    {
      if (!Load() || (Snapshot.Phase != CloudPhase.SignedIn && !FreeReach(saved!)) || saved!.CloudOff || keys is null) throw new CloudFailure("sign_in_required", 401);
      var record = saved;
      if (record.Session.ExpiresAt <= Now + 60_000)
      {
        try { record = await RefreshTokenAsync(record, ct); }
        catch (CloudFailure refused) when (SessionRefused(refused)) { await ClearSignInAsync(); throw new CloudFailure("sign_in_required", 401); }
      }
      return new(record.Session.User.Id, record.Session.AccessToken, record.Session.ExpiresAt, record.DeviceId);
    }
    finally { work.Release(); }
  }

  public IReadOnlyDictionary<string, string> Proof(string method, string pathAndQuery, byte[] body, long timeMs, string requestId) =>
    (keys ?? throw new CloudFailure("sign_in_required", 401)).Proof(method, pathAndQuery, body, timeMs, requestId);

  public byte[] SignPack(byte[] bytes) => (keys ?? throw new CloudFailure("sign_in_required", 401)).Sign(bytes);

  public ICloudDeviceTrust SyncTrust => syncTrust ??= new ListTrust(this);
  private ListTrust? syncTrust;
  private sealed class ListTrust(CloudAccountClient account) : ICloudDeviceTrust
  {
    public CloudPublicJwk? TrustedSigningKey(string deviceId)
    {
      try { return account.saved is { } record && account.TrustFor(record) is { } list ? list.TrustedSigningKey(deviceId) : null; }
      catch (Exception) { return null; }
    }
  }
}
