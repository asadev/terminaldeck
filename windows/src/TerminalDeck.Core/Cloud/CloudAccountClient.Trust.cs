namespace TerminalDeck.Core.Cloud;

/// What device trust needs from the platform. `ListSlot(issuer, subject)`: the protected slot of one account's trusted
/// list. `ModeSlot`: the protected slot of "How this PC trusts your other devices". `PressRefused`: true while a press
/// cannot be taken as the person's own (Windows: within two seconds of this app's own remote input).
public sealed record CloudTrustPorts(Func<string, string, ICloudTrustSlot> ListSlot, ICloudTrustSlot ModeSlot, Func<bool> PressRefused);

// Device trust on the account's status read (the Mac's trustRows) and the person's trust presses on the Cloud page.
// Nothing here is reachable from a tool.
public sealed partial class CloudAccountClient
{
  private CloudTrustStore? trustStore;
  private CloudTrustModeStore? modeStore;
  private CloudTrustMode? trustMode;
  /// "joined your account" notices the person already answered in this run.
  private readonly HashSet<string> dismissedJoins = new(StringComparer.Ordinal);
  /// How long a "joined your account" notice stays on the page.
  public static readonly TimeSpan JoinedNoticeFor = TimeSpan.FromDays(7);

  public const string ListUnreadable = "This PC cannot read its list of trusted devices; changes from other devices are waiting.";
  public const string AnotherKeyForThisPc = "Cloud lists a different key for this PC than the one this PC holds. Compare codes only with the code this PC shows here.";
  public const string AnotherKeyForThisPcPlain = "Cloud does not list this PC the way this PC knows itself, so your other devices may not take its changes. Sign out and in again if this stays.";

  private CloudTrustStore? TrustFor(Saved record)
  {
    if (trustPorts is null) return null;
    var issuer = configuration.Endpoints.Issuer; var subject = record.Session.User.Id;
    if (trustStore is { } known && known.Issuer == issuer && known.Subject == subject) return known;
    return trustStore = new CloudTrustStore(issuer, subject, trustPorts.ListSlot(issuer, subject), trustPorts.PressRefused, () => Now);
  }
  private CloudTrustMode CurrentTrustMode() => trustMode ??= (modeStore ??= trustPorts is null ? null : new CloudTrustModeStore(trustPorts.ModeSlot))?.Load() ?? CloudTrustMode.Ask;
  private void ForgetTrust() { trustStore = null; trustMode = null; dismissedJoins.Clear(); }

  /// The Devices section seen through this PC's trusted list. This PC's own identity joins its list here (`how: self`);
  /// in automatic mode every device the account lists joins too, and a device the account removed leaves.
  private (IReadOnlyList<CloudTrustRow>? Rows, string? Notice, CloudTrustMode? Mode) TrustRowsLocked(Saved record, CloudDeviceList list)
  {
    if (TrustFor(record) is not { } trust) return (null, null, null);
    var registration = keys!.Registration(configuration.DeviceLabel, configuration.AppVersion, configuration.Platform);
    CloudTrustedList? stored = null; string? notice = null;
    try { trust.AddSelf(registration); stored = trust.List(); }
    catch (CloudTrustRefusal refusal) { notice = refusal.Kind is CloudTrustRefusalKind.Unreadable or CloudTrustRefusalKind.NotSaved ? ListUnreadable : refusal.Words; }
    var mode = CurrentTrustMode();
    var automatic = mode == CloudTrustMode.Account;
    if (notice is null && CloudTrustRows.ServiceShowsAnotherKeyForThisPc(list.Devices, record.DeviceId, registration.SignPublicJwk))
      notice = automatic ? AnotherKeyForThisPcPlain : AnotherKeyForThisPc;
    var rows = CloudTrustRows.Build(list.Devices, stored, record.DeviceId, registration.SignPublicJwk, automatic);
    if (automatic && notice is null && stored is not null)
    {
      try
      {
        var stopped = trust.StopRemovedFromAccount(list.Devices.Where(d => d.Status != "active").Select(d => d.DeviceId));
        var added = trust.TrustByAccount(rows);
        if (added.Count > 0) Log("cloud sign-in: device trust ok: " + added.Count + " added");
        // The sync core (W3) asks the list for each pack at the moment of applying it, so what waited from these
        // devices is applied at its next pull; nothing more is needed here.
        if (added.Count + stopped.Count > 0) rows = CloudTrustRows.Build(list.Devices, trust.List(), record.DeviceId, registration.SignPublicJwk, true);
      }
      catch (CloudTrustRefusal refusal)
      {
        Log("cloud sign-in: device trust failed: " + Kind(refusal));
        notice = refusal.Kind is CloudTrustRefusalKind.Unreadable or CloudTrustRefusalKind.NotSaved ? ListUnreadable : refusal.Words;
      }
    }
    return (rows, notice, mode);
  }

  /// A "joined your account" notice shows for a week after the device joined, until the person answers it.
  private bool Joined(CloudTrustRow row) => row.ByAccount && !row.KeyChanged && !row.Removed && row.Standing == CloudTrustStanding.Trusted
    && !dismissedJoins.Contains(row.DeviceId) && row.KnownSince is { } since && Now - since < (long)JoinedNoticeFor.TotalMilliseconds;

  /// The person's choice under "How this PC trusts your other devices". A press in this PC's own window only.
  public async Task SetTrustModeAsync(CloudTrustMode mode, CancellationToken ct = default)
  {
    await TrustPressAsync(async (record, trust) =>
    {
      trust.RequirePress();
      CurrentTrustMode();
      modeStore!.Save(mode);
      trustMode = mode;
      await Task.CompletedTask;
    }, ct);
  }

  /// "Remove" on "<device> joined your account and is now trusted on this PC.": this PC stops taking that device's
  /// changes and never adds it again by itself.
  public Task RemoveJoinedDeviceAsync(string deviceId, CancellationToken ct = default) => TrustPressAsync((_, trust) =>
  {
    trust.StopTrusting(deviceId);
    dismissedJoins.Add(deviceId);
    return Task.CompletedTask;
  }, ct);

  /// "Trust it again" for a device whose key changed. `deviceId` names the row as the page drew it; that row's key is
  /// the one stored. A device list read now can only cancel the press.
  public Task TrustAgainAsync(string deviceId, CancellationToken ct = default) => TrustPressAsync(async (record, trust) =>
  {
    trust.RequirePress();
    if (Snapshot.DeviceRows.FirstOrDefault(r => r.DeviceId == deviceId)?.Trust is not { KeyChanged: true } shown) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
    var fresh = CloudWire.Decode<CloudDeviceList>(await SignedAsync(record, HttpMethod.Get, "/devices", [], ct));
    if (fresh.Devices.Where(d => d.DeviceId == deviceId).ToArray() is not [{ Status: "active" } now] || CloudDeviceCode.KeyId(now.SignPublicJwk) != shown.KeyId)
      throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
    trust.TrustChangedKey(shown);
  }, ct);

  /// "Ask me for each new device": the Trust press in the compare dialog. `captured` is what the dialog showed when it was
  /// drawn (device, key and code); that key is the one stored. A device list read now can only cancel the press.
  public Task TrustNewDeviceAsync(CloudTrustCapture captured, CancellationToken ct = default) => TrustPressAsync(async (record, trust) =>
  {
    trust.RequirePress();
    IReadOnlyList<CloudTrustLatestRow>? latest = null;
    try
    {
      var fresh = CloudWire.Decode<CloudDeviceList>(await SignedAsync(record, HttpMethod.Get, "/devices", [], ct));
      CloudTrustedList? stored; try { stored = trust.List(); } catch (CloudTrustRefusal) { stored = null; }
      latest = CloudTrustRows.Latest(CloudTrustRows.Build(fresh.Devices, stored, record.DeviceId, keys!.Registration(configuration.DeviceLabel, configuration.AppVersion, configuration.Platform).SignPublicJwk, false));
    }
    catch (Exception ex) when (ex is CloudFailure or HttpRequestException) { }
    trust.Trust([captured], restore: false, latest);
  }, ct);

  /// The capture of a new device's row for the compare dialog, as the row stands now; null when no dialog may offer it.
  public CloudTrustCapture? CaptureForDialog(string deviceId) =>
    Snapshot.DeviceRows.FirstOrDefault(r => r.DeviceId == deviceId)?.Trust is { CanBeTrusted: true, SignKey: { } key } row ? CloudTrustCapture.Shown(row.DeviceId, row.Name, key) : null;
  /// This PC's own code, for the other side of a comparison (ask mode only).
  public string? ThisPcCode => Snapshot.DeviceRows.FirstOrDefault(r => r.ThisDevice)?.Trust?.Code;

  private async Task TrustPressAsync(Func<Saved, CloudTrustStore, Task> press, CancellationToken ct)
  {
    await work.WaitAsync(ct);
    try
    {
      if (!Load() || Snapshot.Phase is not (CloudPhase.SignedIn or CloudPhase.Paused) || TrustFor(saved!) is not { } trust) throw new CloudFailure("gate_closed");
      await press(saved!, trust);
      await RefreshLockedAsync(generation, ct);
    }
    finally { work.Release(); }
  }
}
