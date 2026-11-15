using System.Text.Json;
using System.Text.Json.Serialization;

namespace TerminalDeck.Core.Remote;

/// This PC's own judgement of a reach connection (port of the Mac's BackendReachAccountGate.swift). It never trusts the
/// relay: a device is let in only when this PC's switch is on, this PC is signed in and entitled, the device's key is in
/// this account's roster (fetched with this PC's own token), the device is neither removed nor signed out, its key
/// matches the one this PC pinned for it, the relay's mark names that same device, policy B's approval (when chosen) is
/// there, and it is not knocking too often. Anything this PC cannot find out is a refusal.
///
/// Everything it keeps lives in ONE file in the folder it is given (`reach-account.json`): the switch, the policy, the
/// pinned keys, devices removed or approved here, the last connections. A missing or unreadable file means OFF.
public sealed class ReachAccountGate
{
  public const string FileName = "reach-account.json";
  public const double RosterFreshMs = 10_000;
  public const double RosterMaxAgeMs = 60_000;
  public const double EntitlementMaxAgeMs = 300_000;
  public const int HandshakesPerMinute = 10;
  public const int RecentKept = 20;
  /// No good list of the account's devices for this long: every account device is cut, and comes back by itself with
  /// the next good list. Someone blocking this PC's way to the Cloud cannot hold a link open.
  public const double ListMissingCutMs = 600_000;
  public const int RemovalsKept = 256;

  public sealed record Pin(string Key, double FirstSeenAtMs, string? Label = null, string? Platform = null);
  /// One line of "Last connections": opened (Refused null), or refused and why.
  public sealed record Connection(string? DeviceId, string Label, string Platform, double AtMs, ReachRefusal? Refused);
  internal sealed class State
  {
    public SettingsFile? Settings { get; set; }
    public Dictionary<string, Pin> Pins { get; set; } = [];
    public HashSet<string> RemovedHere { get; set; } = [];
    public HashSet<string> ApprovedHere { get; set; } = [];
    /// Removed (a `devices` push naming it, or Remove pressed here), id → the push's `devicesVersion` ("" when not known
    /// yet). Refused for good; forgotten (with its pin) once a list at least as new no longer lists it as usable.
    public Dictionary<string, string> Announced { get; set; } = [];
    public List<Connection> Recent { get; set; } = [];
    public State Copy() => JsonSerializer.Deserialize<State>(JsonSerializer.SerializeToUtf8Bytes(this, Json), Json)!;
  }
  internal sealed record SettingsFile(bool Enabled, string Policy);
  private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.Never, Converters = { new JsonStringEnumConverter() } };

  /// What the page and `cloud.reach.status` read. No keys, no tokens.
  public sealed record Snapshot(ReachSettings Settings, IReadOnlyList<ReachRosterDevice>? Devices, IReadOnlySet<string> Known,
    IReadOnlyDictionary<string, double> FirstSeen, IReadOnlySet<string> RemovedHere, IReadOnlyList<Connection> Recent, bool? Entitled);

  private readonly string file;
  private readonly IReachAccountService service;
  private readonly Action<ReachNotice> notices;
  private readonly Func<bool> remoteInputJustNow;
  private readonly Func<double> now;
  private readonly Func<double> steady;
  private readonly object gate = new();
  private State state;
  private bool neverChosen;
  private (ReachRoster Value, double AtMs)? roster;
  private bool rosterStale;
  private double lastGoodAtMs;
  private (bool Value, string Account, double AtMs)? entitlement;
  private readonly Dictionary<string, List<double>> knocks = [];
  private readonly HashSet<string> removedThisRun = [];
  private string? rosterRefusedFor;

  public ReachAccountGate(string directory, IReachAccountService service, Action<ReachNotice> notices, Func<bool>? remoteInputJustNow = null,
    Func<double>? now = null, Func<double>? steady = null)
  {
    file = Path.Combine(directory, FileName);
    this.service = service; this.notices = notices; this.remoteInputJustNow = remoteInputJustNow ?? (() => false);
    this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.steady = steady ?? (() => Environment.TickCount64);
    state = Load(file);
    lastGoodAtMs = this.steady();
    neverChosen = !File.Exists(file);
  }

  private static State Load(string file)
  {
    try
    {
      var loaded = JsonSerializer.Deserialize<State>(File.ReadAllBytes(file), Json);
      if (loaded?.Settings is null) return new();
      loaded.Pins ??= []; loaded.RemovedHere ??= []; loaded.ApprovedHere ??= []; loaded.Announced ??= []; loaded.Recent ??= [];
      return loaded;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or NotSupportedException) { return new(); }
  }

  private void Save(State next)
  {
    try
    {
      next.Settings ??= new(false, "A");
      Directory.CreateDirectory(Path.GetDirectoryName(file)!);
      var temporary = file + ".tmp";
      File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(next, Json));
      File.Move(temporary, file, overwrite: true);
      state = next;
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { throw new ReachStorageException(ex); }
  }

  private static ReachSettings Read(SettingsFile? s) => s is null ? new() : new(s.Enabled, s.Policy == "B" ? ReachPolicy.ApproveNew : ReachPolicy.AccountOnly);
  private bool IsRemoved(string id) => state.RemovedHere.Contains(id) || state.Announced.ContainsKey(id) || removedThisRun.Contains(id);

  /// The Devices switch is ON by default (owner, 13 Nov). A PC that never chose is switched on once, by the app, without
  /// a press; a choice that exists (on or off) is kept, and a damaged settings file still reads as OFF.
  public bool SwitchOnByDefaultIfNeverChosen()
  {
    lock (gate)
    {
      if (!neverChosen) return false;
      neverChosen = false;
      if (File.Exists(file)) return false;
      var next = state.Copy(); next.Settings = new(true, ReachWire.PolicyText(Read(state.Settings).Policy));
      try { Save(next); } catch (ReachStorageException) { return false; }
      return true;
    }
  }

  public ReachSettings Settings() { lock (gate) return Read(state.Settings); }

  public Snapshot Snap(string? machineDeviceId = null)
  {
    lock (gate) return new(Read(state.Settings), roster?.Value.Devices.Where(d => d.DeviceId != machineDeviceId).ToArray(),
      state.Pins.Keys.ToHashSet(), state.Pins.ToDictionary(p => p.Key, p => p.Value.FirstSeenAtMs),
      state.RemovedHere.Union(state.Announced.Keys).Union(removedThisRun).ToHashSet(), state.Recent.ToArray(), entitlement?.Value);
  }

  /// Turning reach ON (and loosening the policy) opens this PC to more devices: a trust press, refused within the
  /// remote-input guard's window. Turning it OFF is always taken.
  public void SetEnabled(bool on)
  {
    lock (gate)
    {
      var current = Read(state.Settings);
      if (on && !current.Enabled && remoteInputJustNow()) throw new ReachRemoteInputException();
      var next = state.Copy(); next.Settings = new(on, ReachWire.PolicyText(current.Policy));
      Save(next);
      if (!on) { roster = null; rosterStale = false; knocks.Clear(); }
    }
  }

  /// B is stricter and always taken; going back to A is guarded like switching on.
  public void SetPolicy(ReachPolicy policy)
  {
    lock (gate)
    {
      var current = Read(state.Settings);
      if (policy == ReachPolicy.AccountOnly && current.Policy != ReachPolicy.AccountOnly && remoteInputJustNow()) throw new ReachRemoteInputException();
      var next = state.Copy(); next.Settings = new(current.Enabled, ReachWire.PolicyText(policy));
      Save(next);
    }
  }

  /// Policy B: the person at this PC approves a device. A trust press, guarded.
  public void Approve(string deviceId)
  {
    lock (gate)
    {
      if (remoteInputJustNow()) throw new ReachRemoteInputException();
      var next = state.Copy(); next.ApprovedHere.Add(deviceId); next.RemovedHere.Remove(deviceId); next.Announced.Remove(deviceId);
      Save(next);
      removedThisRun.Remove(deviceId);
    }
  }

  /// One-click removal on this PC. Tightening, so never guarded; refused from the next handshake on.
  public void Remove(string deviceId)
  {
    lock (gate)
    {
      removedThisRun.Add(deviceId);
      var next = state.Copy(); next.Announced.TryAdd(deviceId, ""); next.ApprovedHere.Remove(deviceId);
      Save(next);
    }
  }

  /// "Sign out this device": the same removal, but held in memory when the file cannot be written. Returns whether saved.
  public bool RemoveKeepingInMemory(string deviceId)
  {
    lock (gate)
    {
      var next = state.Copy(); next.RemovedHere.Add(deviceId); next.ApprovedHere.Remove(deviceId);
      try { Save(next); return true; } catch (ReachStorageException) { state = next; return false; }
    }
  }

  /// The service pushed a new `devicesVersion`: the next judgement fetches the roster again.
  public void RosterChanged() { lock (gate) { rosterStale = true; rosterRefusedFor = null; } }

  /// Signed out on this PC: the account's list goes with it.
  public void SignedOut() { lock (gate) { roster = null; rosterStale = false; entitlement = null; } }

  /// A `devices` push naming removed devices: kept as removed here at once, and the roster is fetched again. Returns the
  /// ids the caller must cut off now.
  public IReadOnlyList<string> DevicesRemoved(IReadOnlyList<string> ids, string? version = null)
  {
    lock (gate)
    {
      rosterStale = true;
      removedThisRun.UnionWith(ids);
      var next = state.Copy();
      var known = version is not null && IsVersion(version) ? version : "";
      foreach (var id in ids)
        if (!next.RemovedHere.Contains(id) && (!next.Announced.TryGetValue(id, out var held) || held.Length == 0)) next.Announced[id] = known;
      next.ApprovedHere.ExceptWith(ids);
      if (next.Announced.Count > RemovalsKept)
        foreach (var old in next.Announced.OrderBy(p => p.Value, Comparer<string>.Create((a, b) => VersionLess(a, b) ? -1 : VersionLess(b, a) ? 1 : 0)).Take(next.Announced.Count - RemovalsKept).ToArray())
          next.Announced.Remove(old.Key);
      try { Save(next); } catch (ReachStorageException) { }
      return ids;
    }
  }

  private void ReconcileAnnounced(ReachRoster list)
  {
    if (state.Announced.Count == 0) return;
    var next = state.Copy(); var changed = false;
    foreach (var (id, version) in state.Announced)
    {
      if (!VersionAtLeast(list.Version, version)) continue;
      if (!list.Devices.Any(d => d.DeviceId == id && d.Active && !d.Removed)) { next.Announced.Remove(id); next.Pins.Remove(id); changed = true; }
    }
    if (changed) try { Save(next); } catch (ReachStorageException) { }
  }

  public static bool IsVersion(string text) => text.Length is > 0 and <= 30 && text.All(char.IsAsciiDigit);
  public static bool VersionAtLeast(string a, string b) => IsVersion(a) && IsVersion(b) && !VersionLess(a, b);
  /// Decimal `devicesVersion` order; "" (unknown) is older than everything.
  public static bool VersionLess(string a, string b)
  {
    var x = a.TrimStart('0'); var y = b.TrimStart('0');
    if (!(x.Length == 0 || IsVersion(x)) || !(y.Length == 0 || IsVersion(y))) return false;
    return x.Length != y.Length ? x.Length < y.Length : string.CompareOrdinal(x, y) < 0;
  }

  /// The list fetched now; null when it cannot be fetched (nothing is judged removed for being unreachable).
  public Task<IReadOnlyList<ReachRosterDevice>?> RefreshRosterNowAsync(CancellationToken ct = default)
  {
    lock (gate) rosterStale = true;
    return RefreshRosterAsync(ct);
  }

  /// The page's list: fetched now when older than a minute.
  public async Task<IReadOnlyList<ReachRosterDevice>?> RefreshRosterAsync(CancellationToken ct = default)
  {
    if (service.SignedInAccount() is not { } account) { SignedOut(); return null; }
    if (await EntitledAsync(account, ct).ConfigureAwait(false) == false) return null;
    try { return (await CurrentRosterAsync(account, unknownKey: false, ct).ConfigureAwait(false)).Devices; }
    catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { return null; }
  }

  /// The keys the sealed handshake may accept for reach now (empty when off, signed out, or nothing can be fetched).
  /// A key on this list still goes through Admit, which makes every check again.
  public async Task<IReadOnlyCollection<byte[]>> CandidateKeysAsync(CancellationToken ct = default)
  {
    if (!Settings().Enabled || service.SignedInAccount() is not { } account || await EntitledAsync(account, ct).ConfigureAwait(false) == false) return [];
    ReachRoster list;
    try { list = await CurrentRosterAsync(account, unknownKey: false, ct).ConfigureAwait(false); }
    catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { return []; }
    if (list.Account != account) return [];
    var at = now();
    lock (gate) return list.Devices.Where(d => Usable(d, at) is null).Select(d => d.ReachKey).ToArray();
  }

  /// The whole judgement for a device that finished the sealed handshake with `key`. `marked`: the device id the relay
  /// put in the channel's open mark; it must be the roster entry holding that key.
  public async Task<ReachDecision> AdmitAsync(byte[] key, string? marked = null, CancellationToken ct = default)
  {
    var decision = await JudgeAsync(key, marked, ct).ConfigureAwait(false);
    var at = now();
    switch (decision)
    {
      case ReachDecision.Admitted a: Note(new(a.Admission.DeviceId, a.Admission.Label, a.Admission.Platform, at, null)); break;
      case ReachDecision.Refused { Why: ReachRefusal.RateLimited or ReachRefusal.SwitchOff }: break; // not worth a line each
      case ReachDecision.Refused r:
        ReachRosterDevice? row; lock (gate) row = roster?.Value.Devices.FirstOrDefault(d => d.ReachKey.AsSpan().SequenceEqual(key));
        Note(new(row?.DeviceId ?? marked, row?.Label ?? "Unknown device", row?.Platform ?? "unknown", at, r.Why));
        break;
    }
    return decision;
  }

  private async Task<ReachDecision> JudgeAsync(byte[] key, string? marked, CancellationToken ct)
  {
    if (!Settings().Enabled) return new ReachDecision.Refused(ReachRefusal.SwitchOff);
    if (!Knock(key)) return new ReachDecision.Refused(ReachRefusal.RateLimited);
    if (service.SignedInAccount() is not { } account) return new ReachDecision.Refused(ReachRefusal.SignedOut);
    switch (await EntitledAsync(account, ct).ConfigureAwait(false))
    {
      case null: return new ReachDecision.Refused(ReachRefusal.Unavailable);
      case false: return new ReachDecision.Refused(ReachRefusal.NotEntitled);
    }
    ReachRoster list;
    try { list = await CurrentRosterAsync(account, unknownKey: true, ct).ConfigureAwait(false); }
    catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { return new ReachDecision.Refused(ReachRefusal.Unavailable); }
    if (list.Account != account) return new ReachDecision.Refused(ReachRefusal.OtherAccount);
    ReachNotice? notice = null; ReachDecision result;
    lock (gate)
    {
      // The switch may have been turned off while the roster was fetched.
      if (!Read(state.Settings).Enabled) return new ReachDecision.Refused(ReachRefusal.SwitchOff);
      var device = list.Devices.FirstOrDefault(d => d.ReachKey.AsSpan().SequenceEqual(key));
      if (device is null) return new ReachDecision.Refused(ReachRefusal.UnknownDevice);
      if (marked is not null && marked != device.DeviceId) return new ReachDecision.Refused(ReachRefusal.WrongDevice);
      if (Usable(device, now()) is { } refusal) return new ReachDecision.Refused(refusal);
      var encoded = ReachWire.Base64Url(key);
      if (state.Pins.TryGetValue(device.DeviceId, out var pin) && pin.Key != encoded ||
        state.Pins.Any(p => p.Key != device.DeviceId && p.Value.Key == encoded))
      {
        notice = new(ReachNoticeKind.KeyChanged, device.DeviceId, device.Label);
        result = new ReachDecision.Refused(ReachRefusal.KeyChanged);
      }
      else if (Read(state.Settings).Policy == ReachPolicy.ApproveNew && !device.Approved && !state.ApprovedHere.Contains(device.DeviceId))
      {
        notice = new(ReachNoticeKind.AwaitingApproval, device.DeviceId, device.Label, device.Platform);
        result = new ReachDecision.Refused(ReachRefusal.NotApproved);
      }
      else
      {
        var first = !state.Pins.ContainsKey(device.DeviceId);
        if (first)
        {
          var next = state.Copy(); next.Pins[device.DeviceId] = new(encoded, now(), device.Label, device.Platform);
          // A pin that cannot be kept would let the next key through unchecked: refuse instead.
          try { Save(next); } catch (ReachStorageException) { return new ReachDecision.Refused(ReachRefusal.Unavailable); }
          notice = new(ReachNoticeKind.FirstConnection, device.DeviceId, device.Label, device.Platform);
        }
        result = new ReachDecision.Admitted(new(device.DeviceId, device.Label, device.Platform, key, first));
      }
    }
    if (notice is not null) notices(notice);
    return result;
  }

  /// Whether an admitted device may still be connected, judged on the last GOOD list of the account signed in now. No
  /// good list for ListMissingCutMs: false for every account device.
  public bool StillAdmitted(string deviceId)
  {
    var account = service.SignedInAccount();
    lock (gate)
    {
      if (!Read(state.Settings).Enabled || IsRemoved(deviceId)) return false;
      if (account is null) { roster = null; rosterStale = false; entitlement = null; return false; }
      if (roster is { } held && held.Value.Account != account) roster = null;
      if (steady() - lastGoodAtMs > ListMissingCutMs) return false;
      if (roster is not { } list) return true; // none yet this run (within the limit): pushes cut by id
      var device = list.Value.Devices.FirstOrDefault(d => d.DeviceId == deviceId);
      return device is not null && Usable(device, now()) is null;
    }
  }

  private ReachRefusal? Usable(ReachRosterDevice device, double at)
  {
    if (IsRemoved(device.DeviceId) || device.Removed || !device.Active) return ReachRefusal.Removed;
    if (!device.SessionLive) return ReachRefusal.SessionEnded;
    if (device.ExpiresAtMs is { } ends && ends <= at) return ReachRefusal.SessionEnded;
    return null;
  }

  private void Note(Connection line)
  {
    lock (gate)
    {
      var next = state.Copy();
      next.Recent.Insert(0, line);
      if (next.Recent.Count > RecentKept) next.Recent.RemoveRange(RecentKept, next.Recent.Count - RecentKept);
      try { Save(next); } catch (ReachStorageException) { }
    }
  }

  private bool Knock(byte[] key)
  {
    lock (gate)
    {
      var at = now(); var id = Convert.ToHexString(key);
      var recent = (knocks.TryGetValue(id, out var list) ? list : []).Where(t => at - t < 60_000).ToList();
      if (recent.Count >= HandshakesPerMinute) { knocks[id] = recent; return false; }
      recent.Add(at); knocks[id] = recent;
      return true;
    }
  }

  /// Null when it cannot be found out (a refusal).
  private async Task<bool?> EntitledAsync(string account, CancellationToken ct)
  {
    lock (gate) if (entitlement is { } held && held.Account == account && now() - held.AtMs < EntitlementMaxAgeMs) return held.Value;
    bool value;
    try { value = await service.ReachEntitledAsync(ct).ConfigureAwait(false); }
    catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested) { return null; }
    lock (gate) entitlement = (value, account, now());
    return value;
  }

  /// The entitlement as last known, asked again when stale.
  public Task<bool?> EntitledNowAsync(CancellationToken ct = default) =>
    service.SignedInAccount() is { } account ? EntitledAsync(account, ct) : Task.FromResult<bool?>(null);

  private async Task<ReachRoster> CurrentRosterAsync(string account, bool unknownKey, CancellationToken ct)
  {
    lock (gate)
    {
      if (roster is { } held && held.Value.Account != account) roster = null;
      if (roster is { } current && !rosterStale && now() - current.AtMs < (unknownKey ? RosterFreshMs : RosterMaxAgeMs)) return current.Value;
      // An account without reach: the capabilities say so first; else a refusal is remembered for this launch.
      if (entitlement is { } e && e.Account == account && !e.Value || rosterRefusedFor == account) throw new ReachRefusedException(ReachRefusal.NotEntitled);
    }
    ReachRoster fetched;
    try { fetched = await service.RosterAsync(ct).ConfigureAwait(false); }
    catch (ReachServiceException refused) when (!refused.Retryable) { lock (gate) rosterRefusedFor = account; throw; }
    // Another account's list is never kept or judged with.
    if (fetched.Account != account) return fetched;
    lock (gate)
    {
      roster = (fetched, now()); rosterStale = false; lastGoodAtMs = steady();
      ReconcileAnnounced(fetched);
    }
    return fetched;
  }
}
