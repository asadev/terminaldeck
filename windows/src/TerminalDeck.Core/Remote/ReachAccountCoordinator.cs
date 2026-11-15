using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Remote;

/// What the page and `cloud.reach.status` show. No keys, tokens or signatures.
public sealed record ReachStatus(bool SignedIn, bool? Entitled, bool Enabled, ReachPresenceStatus Presence, bool Tied,
  IReadOnlyList<ReachStatus.Device> Devices, IReadOnlyList<ReachAccountGate.Connection> Recent)
{
  public sealed record Device(string DeviceId, string Label, string Platform, bool Connected, bool Removed, double? AddedAtMs, double? LastSeenAtMs);

  public static string PresenceWord(ReachPresenceStatus p) => p switch
  {
    ReachPresenceStatus.Off => "off", ReachPresenceStatus.SignedOut => "signedOut", ReachPresenceStatus.NotEntitled => "notEntitled",
    ReachPresenceStatus.NotRegistered => "notRegistered", ReachPresenceStatus.Published => "published", _ => "failed"
  };

  /// Names, dates and states only: no ids, keys or codes (owner, 13 Nov).
  public JsonElement WireValue() => JsonSerializer.SerializeToElement(new
  {
    signedIn = SignedIn, entitled = Entitled, enabled = Enabled, presence = PresenceWord(Presence), relayTied = Tied,
    newDevices = Enabled && SignedIn && Entitled == true ? "join by signing in" : "not let in",
    devices = Devices.Where(d => !d.Removed).Select(d => new { name = d.Label, addedAt = d.AddedAtMs, lastSeenAt = d.LastSeenAtMs, connected = d.Connected }),
    lastConnections = Recent.Select(r => new { name = r.Label, at = r.AtMs, result = r.Refused is { } why ? "refused: " + Word(why) : "opened" })
  });
  public static string Word(ReachRefusal why) => char.ToLowerInvariant(why.ToString()[0]) + why.ToString()[1..];
}

/// The Devices page's plain states, decided here so they are tested without a window.
public sealed record ReachPage
{
  public enum PageMode { Hidden, Off, On }
  public sealed record Row(string DeviceId, string Title, string Detail, bool CanRemove);
  public const string SwitchTitle = "Let my signed-in devices open this PC";
  public const string OnDetail = "Your phones, browsers and other computers signed in to your account can open this PC.";
  public const string OffDetail = "Off: this PC is not offered to your phones, browsers and other computers.";
  public const string NotEntitledDetail = "Opening this PC from your other devices is not on for your account yet. This starts working by itself once it is.";
  public const string LastConnectionsTitle = "Last connections";
  public const string RemoveTitle = "Remove";
  /// One Remove means one thing.
  public const string RemoveMeans = "Remove does both: the device can no longer reach this PC, and this PC stops taking its synced changes.";
  /// What every place that used to start the old way says while reach is on.
  public const string JoinBySigningIn = "Devices now join by signing in to your Terminal Deck account on that device. There is nothing to set up on this PC.";
  public const string PairingLocked = "This PC is opened by signing in to your Terminal Deck account. Sign in on the other device instead.";
  public const string OldTitle = "Connected before accounts";
  public const string OldLine = "These were connected before you signed in. They keep working until you remove them; new devices join by signing in.";

  public PageMode Mode { get; }
  public string Explanation { get; } = "";
  public IReadOnlyList<Row> Rows { get; } = [];
  public IReadOnlyList<string> Recent { get; } = [];
  /// Whether any view may offer a pairing code (Devices page, its dialog, the empty state).
  public bool OffersPairing => Mode != PageMode.On;
  /// Whether any view may ask which folders or logins a device gets.
  public bool AsksFolders => Mode != PageMode.On;

  public ReachPage(ReachStatus status, double? nowMs = null)
  {
    if (!status.SignedIn || status.Entitled != true) { Mode = PageMode.Hidden; return; }
    Mode = status.Enabled ? PageMode.On : PageMode.Off;
    Explanation = status.Enabled ? OnDetail : OffDetail;
    var now = DateTimeOffset.FromUnixTimeMilliseconds((long)(nowMs ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
    static DateTimeOffset At(double ms) => DateTimeOffset.FromUnixTimeMilliseconds((long)ms);
    string Ago(double ms) => Ago_(now - At(ms));
    // A row says the device's name, when it was added and when it was last seen: nothing else (owner, 13 Nov).
    Rows = status.Devices.Where(d => !d.Removed).Select(d =>
    {
      var added = d.AddedAtMs is { } a ? "Added " + At(a).ToLocalTime().ToString("d MMM yyyy", System.Globalization.CultureInfo.InvariantCulture) : "Not connected yet";
      var seen = d.Connected ? "Connected now" : d.LastSeenAtMs is { } s ? "Last seen " + Ago(s) : null;
      return new Row(d.DeviceId, d.Label, string.Join(" · ", new[] { added, seen }.OfType<string>()), true);
    }).ToArray();
    Recent = status.Recent.Take(8).Select(r => r.Label + " · " + (r.Refused is null ? "opened a session" : "was refused") + " · " + Ago(r.AtMs)).ToArray();
  }

  public static string Ago_(TimeSpan age) =>
    age.TotalMinutes < 1 ? "just now" : age.TotalHours < 1 ? (int)age.TotalMinutes + " min ago" : age.TotalDays < 1 ? (int)age.TotalHours + " h ago" : (int)age.TotalDays + (age.TotalDays < 2 ? " day ago" : " days ago");
}

/// Reach by account on this PC: one owner for the gate, the door, presence and the cut-offs (port of the Mac's
/// BackendReachAccountCoordinator). Built by the app when the phone host and the Cloud sign-in both exist. Nothing here
/// publishes or lets anyone in while the switch is off.
public sealed class ReachAccountCoordinator : IAsyncDisposable
{
  public ReachAccountGate Gate { get; }
  public ReachPresence Presence { get; }
  private readonly IReachAccountService service;
  private readonly ReachRelayLink link;
  private readonly DeviceTrust? host;
  private readonly TimeSpan tick;
  private CancellationTokenSource? ticker;
  private readonly object judgeOwner = new();
  /// One Remove means one thing: the app links this PC's Cloud trusted-device list here.
  private Func<string, Task>? trustLink;
  public event Action? Changed;

  public ReachAccountCoordinator(string directory, IReachAccountService service, Action<ReachNotice> notices, DeviceTrust? host,
    Func<ReachHostCard?> card, ReachRelayLink link, Func<bool>? remoteInputJustNow = null, Func<double>? now = null, Func<double>? steady = null, TimeSpan? tick = null)
  {
    Gate = new ReachAccountGate(directory, service, notices, remoteInputJustNow, now, steady);
    this.service = service; this.link = link; this.host = host; this.tick = tick ?? TimeSpan.FromSeconds(60);
    Presence = new ReachPresence(Gate, service, link, card, now);
  }

  public void SetTrustLink(Func<string, Task>? value) => trustLink = value;

  /// Wires the door into this process's relay clients and keeps presence fresh every 60 seconds.
  public async Task StartAsync()
  {
    // The phone host asks the gate again at every account device's hello: a door admission that raced a removal, the
    // switch going off or a sign-out never gets a welcome.
    host?.SetReachJudge(judgeOwner, Gate.StillAdmitted);
    link.SetDoor(new ReachAccountDoor(Gate));
    await SyncAsync().ConfigureAwait(false);
    if (ticker is not null) return;
    var stop = ticker = new CancellationTokenSource();
    _ = Task.Run(async () =>
    {
      while (!stop.IsCancellationRequested)
      {
        try { await Task.Delay(tick, stop.Token).ConfigureAwait(false); await SyncAsync().ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        catch (Exception ex) when (ex is not OutOfMemoryException) { System.Diagnostics.Trace.WriteLine("reach: sync failed: " + ex.GetType().Name); }
      }
    });
  }

  public async Task StopAsync()
  {
    ticker?.Cancel(); ticker = null;
    await Presence.WithdrawAsync().ConfigureAwait(false);
    host?.EndReachJudge(judgeOwner);
    await CutAsync(null).ConfigureAwait(false);
    link.SetDoor(null);
    host?.SetPairingLockedByReach(false);
  }
  public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

  /// Presence, the relay room and the pairing lock follow the switch, the sign-in and the entitlement.
  public async Task<ReachPresenceStatus> SyncAsync()
  {
    var status = await Presence.SyncAsync().ConfigureAwait(false);
    // A passing service failure keeps pairing out of the way while the switch is on and the account entitled.
    var live = status == ReachPresenceStatus.Published;
    if (status == ReachPresenceStatus.Failed && Gate.Settings().Enabled) live = await Gate.EntitledNowAsync().ConfigureAwait(false) == true;
    host?.SetPairingLockedByReach(live);
    if (status is ReachPresenceStatus.Off or ReachPresenceStatus.SignedOut or ReachPresenceStatus.NotEntitled) await CutAsync(null).ConfigureAwait(false);
    else await RejudgeAsync().ConfigureAwait(false);
    Changed?.Invoke();
    return status;
  }

  /// The switch. On is a trust press (refused within 2 s of remote input); off ends every account channel now.
  public async Task SetEnabledAsync(bool on)
  {
    Gate.SetEnabled(on);
    await SyncAsync().ConfigureAwait(false);
  }

  /// "Remove": refused here at once, its live channels end, this PC stops trusting it for synced data, and the service
  /// is told (final for that device). A trust failure is thrown after the rest is done.
  public async Task RemoveAsync(string deviceId)
  {
    Gate.Remove(deviceId);
    await CutAsync([deviceId]).ConfigureAwait(false);
    Exception? trustFailure = null;
    if (trustLink is { } trust) try { await trust(deviceId).ConfigureAwait(false); } catch (Exception ex) when (ex is not OutOfMemoryException) { trustFailure = ex; }
    await service.RemoveDeviceAsync(deviceId).ConfigureAwait(false);
    Gate.RosterChanged();
    Changed?.Invoke();
    if (trustFailure is not null) throw trustFailure;
  }

  /// "Sign out this device": this PC's block first (held in memory when its file cannot be written), its live channels
  /// end, this PC stops trusting it (best effort), and the service is told. Throws only when the service was not told.
  public async Task SignOutAsync(string deviceId)
  {
    Gate.RemoveKeepingInMemory(deviceId);
    await CutAsync([deviceId]).ConfigureAwait(false);
    if (trustLink is { } trust) try { await trust(deviceId).ConfigureAwait(false); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
    await service.RemoveDeviceAsync(deviceId).ConfigureAwait(false);
    Gate.RosterChanged();
    Changed?.Invoke();
  }

  /// The other direction: "Remove" on a device trusted by the account (Cloud page) also takes its reach away, but only
  /// while reach's switch is on. Never calls the trust link back. Returns whether reach was removed.
  public async Task<bool> RemoveIfOnAsync(string deviceId)
  {
    if (!Gate.Settings().Enabled) return false;
    Gate.Remove(deviceId);
    await CutAsync([deviceId]).ConfigureAwait(false);
    await service.RemoveDeviceAsync(deviceId).ConfigureAwait(false);
    Gate.RosterChanged();
    Changed?.Invoke();
    return true;
  }

  /// The account's event socket. `devices`: the roster changed; `reachRemoved` ids are cut off at once, then every live
  /// account device is judged again against the fresh list. `gate`/`hello`: the entitlement or connection changed.
  public async Task EventAsync(string type, JsonElement payload)
  {
    switch (type)
    {
      case "devices":
        var version = payload.ValueKind == JsonValueKind.Object && payload.TryGetProperty("devicesVersion", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        var removed = Gate.DevicesRemoved(ReachWire.RemovedIds(payload), version);
        if (removed.Count > 0) await CutAsync(removed).ConfigureAwait(false);
        _ = await Gate.RefreshRosterAsync().ConfigureAwait(false);
        await RejudgeAsync().ConfigureAwait(false);
        Changed?.Invoke();
        break;
      case "gate" or "hello": await SyncAsync().ConfigureAwait(false); break;
    }
  }

  /// Signed out on this PC: nothing of reach stays reachable.
  public async Task SignedOutAsync()
  {
    await Presence.WithdrawAsync().ConfigureAwait(false);
    host?.EndReachJudge(judgeOwner);
    await CutAsync(null).ConfigureAwait(false);
    Gate.SignedOut();
    host?.SetPairingLockedByReach(false);
    Changed?.Invoke();
  }

  public async Task<ReachStatus> StatusAsync()
  {
    var account = service.SignedInAccount();
    var machine = service.MachineDeviceId();
    var devices = (await Gate.RefreshRosterAsync().ConfigureAwait(false))?.Where(d => d.DeviceId != machine).ToArray() ?? [];
    var snapshot = Gate.Snap(machine);
    var connected = host?.ReachConnectedDeviceIds() ?? new HashSet<string>();
    return new(account is not null, account is null ? null : await Gate.EntitledNowAsync().ConfigureAwait(false), snapshot.Settings.Enabled, Presence.Last, link.Tied,
      devices.Select(d => new ReachStatus.Device(d.DeviceId, d.Label, d.Platform, connected.Contains(d.DeviceId),
        d.Removed || !d.Active || snapshot.RemovedHere.Contains(d.DeviceId), snapshot.FirstSeen.TryGetValue(d.DeviceId, out var first) ? first : null,
        snapshot.Recent.FirstOrDefault(r => r.DeviceId == d.DeviceId && r.Refused is null)?.AtMs)).ToArray(),
      snapshot.Recent);
  }

  /// Every account device connected now is judged again against the account's list: one that left the list, was signed
  /// out or whose sign-in ended is cut. A device found gone on a cached list is judged again on a list fetched now.
  private async Task RejudgeAsync()
  {
    if (host is null) return;
    var connected = host.ReachConnectedDeviceIds();
    if (connected.Count == 0) return;
    _ = await Gate.RefreshRosterAsync().ConfigureAwait(false);
    var gone = connected.Where(id => !Gate.StillAdmitted(id)).ToArray();
    if (gone.Length > 0) { _ = await Gate.RefreshRosterNowAsync().ConfigureAwait(false); gone = gone.Where(id => !Gate.StillAdmitted(id)).ToArray(); }
    if (gone.Length > 0) await CutAsync(gone).ConfigureAwait(false);
  }

  private async Task CutAsync(IReadOnlyCollection<string>? ids)
  {
    await link.CloseAccountChannelsAsync(ids).ConfigureAwait(false);
    host?.DropReachDevices(ids);
  }
}

/// The agent tool: READ the reach state only. Nothing switches reach on or removes a device (those stay the person's own
/// presses on this PC).
public static class ReachAccountTools
{
  public static IReadOnlyList<McpToolSpec> Specs => [
    new("cloud.reach.status", "cloud_reach_status", McpTier.Read, JsonSerializer.SerializeToElement(new { type = "object", properties = new { }, additionalProperties = false }))
  ];
  public const string Description = "Read whether devices signed in to this PC's account may reach it (the switch \"Let my signed-in devices open this PC\", whether the account has the feature), the devices that may reach it by name with when each was added and last seen, and the last connections. Read only: it never switches reach on or removes a device, and returns no keys or tokens.";

  public static void Register(McpDoor door, Func<Task<ReachStatus?>> status) => door.Register("cloud.reach.status", async (_, _, _) =>
    await status().ConfigureAwait(false) is { } value ? value.WireValue() : JsonSerializer.SerializeToElement(new { available = false }));
}
