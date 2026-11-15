using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// The Mac's lean record framework (td-mac-next TerminalDeckNativeCore CloudBrainRecordSync.swift: CloudBrainRecordKind,
// CloudBrainRecordPlan, CloudBrainRecordOwner, CloudBrainRecordOrigins, CloudBrainRecordAdapter, the activation's join)
// on the Windows engine (ICloudSyncAdapter). ONE adapter per domain over ONE owner; several adapters of one account
// share one CloudRecordStore. 7C-2: projects (I11) and agents (I10). 7C-4 adds tasks (I12) and settings (I21) as two
// more owners on the same pieces. Records, ids, stamps, op shapes and payload bytes are the Mac's.
//
// What Windows does differently from the Mac, on purpose (the engine shape and the 7C rules):
// - No setup page: a PC sends its own records only after the engine read the whole feed once (FeedRead); until the join
//   is finished every first copy goes out as a BASELINE (rule J) and loses to what the Macs already hold.
// - Removals follow the delete rule (lane D2, the Mac's 87941cff8): a record gone from its owner travels as a removal
//   only with the owner's intent (CloudMissing); an arriving removal is the owner's to apply (CloudRemove, into its Bin).
// - A record that cannot be applied now (its owner refuses, the record it needs has not arrived, it was made by a newer
//   app) waits inside this adapter and is tried again at every capture; the feed moves on (the Mac parks it).

/// One kind of record of an owner as it travels: how its record ids are spelled, its signed field table, and the record
/// that must have arrived before it (an agent after its instruction text).
public sealed record CloudRecordKind(string Prefix, CloudMergeTable Table, string Suffix = "", IReadOnlySet<string>? ListedValues = null,
  Func<string, string>? Requires = null)
{
  public string Entity(string id) => Prefix + id + Suffix;
  /// The record's own id, or null when `entity` is not of this kind.
  public string? IdOf(string entity) =>
    entity.StartsWith(Prefix, StringComparison.Ordinal) && (Suffix.Length == 0 || entity.EndsWith(Suffix, StringComparison.Ordinal)) && entity.Length > Prefix.Length + Suffix.Length
      ? entity[Prefix.Length..^Suffix.Length] : null;
}

/// What this PC does with the Cloud's merged value of one record. Made by the owner, written by nothing but CloudWrite.
/// `Store`: the travelling value this PC holds afterwards, exactly as the owner will store it (null: no such record here).
/// `Held`: fields whose Cloud value is not shown here, each with its reason. `Waiting`: the whole record waits (nothing is
/// written). `Note`: one plain line shown once for this record.
public sealed record CloudRecordPlan(CloudJson.Object? Store, IReadOnlyDictionary<string, string>? Held = null, string? Waiting = null, string? Note = null);

/// "This PC cannot take this record right now" (the owner wrote nothing): the record waits and is tried again later.
public sealed class CloudRecordRefusal(string reason) : Exception(reason)
{
  public string Reason => Message;
}

/// What an owner gives the record adapter. Every call is the owner's own narrow path: no session, task, run or
/// notification may start from any of them.
public interface ICloudRecordOwner
{
  /// Every record stored here now: record id → its stored value (only signed fields travel). Throws while the saved list
  /// cannot be read whole: nothing is captured then.
  IReadOnlyDictionary<string, CloudJson.Object> CloudRecords();
  /// What this PC stores for `entity` given the Cloud's merged value (null: removed in the Cloud). Writes nothing. Throws
  /// CloudRecordRefusal when this PC cannot take the record right now.
  CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud);
  /// Stores exactly `value` (a plan's Store). `expecting`: the travelling value this PC held when the plan was made; when
  /// the record changed since, throw CloudRecordRefusal and write nothing.
  void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting);
  /// After records arrived and were written: screens refresh, things that waited for them are tried again. Display only.
  void CloudImported(IReadOnlyList<string> entities);
  /// A short fingerprint of what this owner's plans depend on besides its own records; when it changes, records that
  /// wait are looked at again.
  string CloudContext() => "";

  // ---- the delete rule (the Mac's CloudBrainRecordOwner removal calls, 87941cff8). Absence is never intent: a record
  // gone from its owner travels as a removal only when the owner says so. ----

  /// A record this PC held is gone from its owner: its owner's intended removal (with the delete fields to write first,
  /// or null for the old form), or null = keep (never sent).
  CloudRecordMissing? CloudMissing(string entity, CloudJson.Object last) => null;
  /// Records with a removal intent stored by the owner (they may never have been captured).
  IReadOnlyList<string> CloudPendingRemovals() => [];
  /// The last value of a removed record this PC never captured (so its first version can go before its removal).
  CloudJson.Object? CloudRemovalBase(string entity) => null;
  /// The Cloud removed the record: the owner takes it out (into its Bin). Throws CloudRecordRefusal when it cannot now.
  void CloudRemove(string entity, CloudJson.Object? expecting, CloudJson.Object removal, string device, long at) =>
    throw new CloudRecordRefusal("This record's owner cannot apply a removal.");
  /// "Not on this PC" / "Only on this PC": the record is this PC's only and is not captured.
  bool CloudLocalOnly(string entity) => false;
  /// The owner put the record back: its next capture undoes the removal.
  bool CloudRestoring(string entity) => false;
  void CloudCaptured(string entity, bool removed) { }
  /// Who and when the version being shown came from (before CloudPlan / CloudWrite / CloudRemove).
  void CloudReceiving(string entity, string device, long at) { }
  /// The Cloud's view of the record is a removal (also for a record this PC keeps only here).
  void CloudTombstone(string entity, CloudJson.Object removal, string device, long at) { }
}

/// An owner's intended removal of a record gone from it. `Metadata`: the delete fields captured first (only while every
/// device reads table version 2); null = the old form (a plain removal).
public sealed record CloudRecordMissing(CloudJson.Object? Metadata);

/// Which Cloud account each record on this PC came from. One file for the PC, beside the account folders. A record that
/// belongs to another account only is never sent and never merged for this one.
public sealed class CloudRecordOrigins
{
  private const string UnknownAccount = "unknown-account";
  private readonly string file;
  private readonly object gate = new();
  private readonly Dictionary<string, HashSet<string>> rows;
  public bool LostBesideAnotherAccount { get; }

  /// `accountsFolder`: `cloud\accounts` (every account's folder is inside it).
  public CloudRecordOrigins(string accountsFolder, string account, string fileName = "records-origins.json")
  {
    Directory.CreateDirectory(accountsFolder);
    file = Path.Combine(accountsFolder, fileName);
    Dictionary<string, HashSet<string>>? loaded = null;
    if (File.Exists(file))
    {
      try { loaded = JsonSerializer.Deserialize<Dictionary<string, List<string>>>(File.ReadAllBytes(file))?.ToDictionary(r => r.Key, r => r.Value.ToHashSet(StringComparer.Ordinal), StringComparer.Ordinal); }
      catch (JsonException) { loaded = null; }
      if (loaded is null) File.Move(file, file + ".damaged-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    }
    var others = Directory.EnumerateDirectories(accountsFolder).Select(d => Path.GetFileName(d)).Any(name => name != account);
    LostBesideAnotherAccount = loaded is null && others;
    rows = loaded ?? new(StringComparer.Ordinal);
  }
  private static string Key(string domain, string entity) => domain + "\n" + entity;
  public bool BelongsElsewhere(string domain, string entity, string account)
  {
    lock (gate) return rows.TryGetValue(Key(domain, entity), out var known) && known.Count > 0 && !known.Contains(account);
  }
  public void Add(string domain, string entity, string account)
  {
    lock (gate)
    {
      var key = Key(domain, entity);
      if (rows.TryGetValue(key, out var known) && known.Contains(account)) return;
      (rows.TryGetValue(key, out known) ? known : rows[key] = new(StringComparer.Ordinal)).Add(account);
      Save();
    }
  }
  /// After a lost file beside another account: every record already here without an origin is marked as another
  /// account's, once per domain.
  public void Quarantine(string domain, IEnumerable<string> entities)
  {
    if (!LostBesideAnotherAccount) return;
    lock (gate)
    {
      var marker = "\u0001" + domain;
      if (rows.ContainsKey(marker)) return;
      foreach (var entity in entities) rows.TryAdd(Key(domain, entity), new(StringComparer.Ordinal) { UnknownAccount });
      rows[marker] = new(StringComparer.Ordinal) { "done" };
      Save();
    }
  }
  private void Save() => new CloudFileSlot(file).Write(JsonSerializer.SerializeToUtf8Bytes(rows.OrderBy(r => r.Key, StringComparer.Ordinal)
    .ToDictionary(r => r.Key, r => r.Value.OrderBy(v => v, StringComparer.Ordinal).ToList())));
}

/// What the Cloud page can show for one row, read-only: earlier versions kept, what waits here, what changed here from
/// other devices. No value from another device is in it except the one-line fields a kind lists.
public sealed record CloudRecordListing(int KeptCount, IReadOnlyList<CloudRecordListing.Kept> KeptVersions, IReadOnlyList<CloudRecordListing.Waiting> WaitingHere,
  IReadOnlyList<CloudRecordListing.Change> Changes, IReadOnlyList<string> Gaps, IReadOnlyList<string> Mentions, IReadOnlyList<string> Notes)
{
  public sealed record Kept(string Record, string Field, string Device, long Time, bool Mine, string? Preview);
  public sealed record Waiting(string Record, string Field, string Reason);
  public sealed record Change(string Record, string Field, string Device, long Time, string? From, string? To);
  /// "N earlier versions kept".
  public static string KeptSentence(int count) => count switch { 0 => "No earlier versions kept.", 1 => "1 earlier version kept.", _ => count + " earlier versions kept." };
}

/// One domain of records of one owner, between that owner and the sync engine. Bound to one signed-in account.
public sealed class CloudRecordAdapter : ICloudSyncAdapter
{
  private sealed class Parked { public string Op { get; set; } = ""; public string Device { get; set; } = ""; public string Reason { get; set; } = ""; }
  private sealed class State
  {
    public Dictionary<string, Dictionary<string, string>> Reasons { get; set; } = [];
    public Dictionary<string, string> Waiting { get; set; } = [];
    public List<CloudRecordListing.Change> Changes { get; set; } = [];
    public Dictionary<string, string> Notes { get; set; } = [];
    /// Records whose write this PC's owner refused: tried again at every capture.
    public List<string> Retry { get; set; } = [];
    /// Incoming records that could not be taken in yet (the record they need is not here, a newer app made them, this
    /// PC's list could not be read), in arrival order, tried again later.
    public List<Parked> Parked { get; set; } = [];
  }
  private sealed record ParsedOp(CloudRecordKey Key, CloudRecordKind Kind, string Id, CloudMergeVersion Version);
  private sealed class Park(string reason) : Exception(reason);

  public const int MaximumRecordBytes = 179_998;
  public string Domain { get; }
  public string InventoryRow { get; }
  public string SourceId { get; }
  public IReadOnlyCollection<string> Domains => [Domain];
  /// How many records of this domain this PC held at the last capture.
  public int Items { get { lock (gate) return items; } }
  private readonly IReadOnlyList<CloudRecordKind> kinds;
  private readonly CloudRecordStore store;
  private readonly string account, deviceId;
  private readonly ICloudRecordOwner owner;
  private readonly CloudRecordOrigins origins;
  private readonly IReadOnlyList<string> exclusions;
  private readonly ICloudLedgerSlot slot;
  private readonly object gate = new();
  private State state;
  private bool stopped;
  private readonly Dictionary<string, CloudJson.Object> lastSeen = new(StringComparer.Ordinal);
  private readonly HashSet<string> incomplete = new(StringComparer.Ordinal), waitingFor = new(StringComparer.Ordinal);
  private int tooLarge, elsewhere, items;
  private string? unreadable;
  private bool retryWanted, reconsidered;
  private string? lastContext;
  private Dictionary<string, CloudJson.Object>? packRecords;
  private readonly List<string> written = [];

  /// `store`: this account's record bookkeeping; its folder also keeps this adapter's small state file.
  public CloudRecordAdapter(string domain, string inventoryRow, string sourceId, IReadOnlyList<CloudRecordKind> kinds, CloudRecordStore store, string account,
    string deviceId, ICloudRecordOwner owner, CloudRecordOrigins origins, IReadOnlyList<string>? exclusions = null)
  {
    CloudBytes.TransportId(deviceId);
    _ = CloudRecordKey.Of(domain, "x");
    if (kinds.Count == 0 || kinds.Any(k => k.Table.Domain != domain || k.Prefix.Length == 0) || sourceId.Length == 0 || inventoryRow.Length == 0 || account.Length == 0)
      throw new CloudFailure("invalid_request");
    Domain = domain; InventoryRow = inventoryRow; SourceId = sourceId; this.kinds = kinds; this.store = store; this.account = account; this.deviceId = deviceId;
    this.owner = owner; this.origins = origins; this.exclusions = exclusions ?? [];
    slot = new CloudFileSlot(Path.Combine(store.Folder, domain.Replace('/', '_') + "-state.json"));
    State? loaded = null;
    try { loaded = slot.Read() is { } bytes ? JsonSerializer.Deserialize<State>(bytes) : null; } catch (JsonException) { }
    state = loaded ?? new State();
    store.Register(domain);
  }

  // ---- small helpers ----

  /// Sign-out: final. Nothing is deleted; nothing is captured or applied after it.
  public void Stop() { lock (gate) stopped = true; }
  private void Live() { if (stopped) throw new CloudFailure("gate_closed"); }
  private (CloudRecordKind Kind, string Id)? KindOf(string entity)
  {
    foreach (var kind in kinds) if (kind.IdOf(entity) is { } id) return (kind, id);
    return null;
  }
  /// Only the signed fields travel: every other key of a stored row stays on this PC.
  public static CloudJson.Object Travelling(CloudJson.Object value, CloudMergeTable table) =>
    CloudRecordJson.Object(table.Classes.Keys.OrderBy(k => k, StringComparer.Ordinal)
      .Where(name => table.Classes[name] is not CloudMergeClass.ThisDevice && CloudRecordJson.Has(value, name))
      .Select(name => (name, CloudRecordJson.Get(value, name)!)));
  public static bool Equal(CloudJson? a, CloudJson? b) => CloudRecordJson.Same(a, b);
  private static CloudJson Field(CloudJson? value, string name) =>
    CloudRecordJson.Has(value, name) && !CloudRecordJson.Nullish(CloudRecordJson.Get(value, name)) ? CloudRecordJson.Get(value, name)! : CloudJson.Null.Value;
  private void SaveState()
  {
    if (state.Changes.Count > 200) state.Changes.RemoveRange(0, state.Changes.Count - 200);
    slot.Write(JsonSerializer.SerializeToUtf8Bytes(state));
  }
  private void Persist() { store.Flush(); SaveState(); }

  // ---- capture (this PC → Cloud) ----

  private bool Capture(CloudRecordKey key, CloudJson.Object? value, CloudMergeTable table, bool restore = false)
  {
    try { store.Capture(key, value, table, CloudBytes.NewTransportId(), deviceId, restore: restore); incomplete.Remove(key.Entity); return true; }
    catch (CloudMergeHistoryIncomplete) { incomplete.Add(key.Entity); return false; }
  }
  private static CloudJson.Object Merged(CloudJson.Object value, CloudJson.Object extra)
  {
    foreach (var member in extra.Members) value = CloudRecordJson.Set(value, member.Key, member.Value);
    return value;
  }
  /// A field stops waiting when this PC's value has become the Cloud's value (the person set it here).
  private void Release(CloudRecordKey key, CloudJson.Object value, CloudMergeTable table)
  {
    var held = store.Held(key);
    if (held.Count == 0) return;
    CloudMergeView? view;
    try { view = store.View(key, table); } catch (CloudMergeHistoryIncomplete) { return; }
    if (view is null) return;
    var shown = CloudRecordJson.Object(view.Fields.Select(f => (f.Key, f.Value)));
    var still = held.Where(name => !Equal(Field(shown, name), Field(value, name))).ToHashSet(StringComparer.Ordinal);
    if (still.SetEquals(held)) return;
    store.SetHeld(key, still);
    if (state.Reasons.TryGetValue(key.Entity, out var reasons))
    {
      foreach (var name in held.Except(still)) reasons.Remove(name);
      if (reasons.Count == 0) state.Reasons.Remove(key.Entity);
    }
  }

  /// This PC's own new versions since the last capture. Nothing before the first full read of the feed.
  public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    lock (gate)
    {
      store.Clock = stampNow;
      if (stopped || !store.FeedReadDone) return Task.FromResult(CloudCapture.None);
      packRecords = null;
      RetryParked();
      packRecords = null;
      CaptureLocal();
      var operations = Pending(256);
      var ids = operations.Select(o => o.OpId).ToArray();
      return Task.FromResult(new CloudCapture(operations, () =>
      {
        lock (gate) { store.MarkHanded(ids); store.Committed(Domain); Persist(); }
      }));
    }
  }
  /// The capture pass: every record the owner stores now is compared with what was last captured; a changed one becomes
  /// one version. True when anything of the owner had changed.
  private bool CaptureLocal()
  {
    IReadOnlyDictionary<string, CloudJson.Object> records;
    try { records = owner.CloudRecords(); }
    catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException)
    {
      unreadable = "This PC's saved list could not be read whole, so nothing of it is sent until it can be.";
      return false;
    }
    unreadable = null;
    origins.Quarantine(Domain, records.Keys.OrderBy(k => k, StringComparer.Ordinal));
    bool changed = false; int count = 0, foreign = 0;
    foreach (var kind in kinds)
      foreach (var entity in records.Keys.Where(e => kind.IdOf(e) is not null).OrderBy(e => e, StringComparer.Ordinal))
      {
        if (origins.BelongsElsewhere(Domain, entity, account)) { foreign++; continue; }
        if (owner.CloudLocalOnly(entity)) continue;
        count++;
        var value = Travelling(records[entity], kind.Table);
        if (lastSeen.TryGetValue(entity, out var seen) && Equal(seen, value)) continue;
        var key = CloudRecordKey.Of(Domain, entity);
        if (!Capture(key, value, kind.Table, owner.CloudRestoring(entity))) continue;
        owner.CloudCaptured(entity, removed: false);
        origins.Add(Domain, entity, account);
        Release(key, value, kind.Table);
        lastSeen[entity] = value; changed = true;
      }
    // Absence is not intent: every missing record asks its owner before a removal is captured. A record made and removed
    // before its first capture still sends its first version first, so the removal has a history in the Cloud.
    var pending = owner.CloudPendingRemovals();
    foreach (var kind in kinds)
      foreach (var entity in pending.Where(e => kind.IdOf(e) is not null).OrderBy(e => e, StringComparer.Ordinal))
      {
        var key = CloudRecordKey.Of(Domain, entity);
        if (store.Holds(key) || owner.CloudRemovalBase(entity) is not { } @base || owner.CloudMissing(entity, @base) is null) continue;
        Capture(key, Travelling(@base, kind.Table), kind.Table);
      }
    foreach (var entity in store.StoredEntities(Domain).Concat(pending).Distinct(StringComparer.Ordinal).OrderBy(e => e, StringComparer.Ordinal))
    {
      if (records.ContainsKey(entity) || KindOf(entity) is not { } found) continue;
      var key = CloudRecordKey.Of(Domain, entity);
      CloudMergeView? view;
      try { view = store.View(key, found.Kind.Table); }
      catch (CloudMergeHistoryIncomplete) { incomplete.Add(entity); continue; }
      var last = store.Image(key).Value ?? (view?.Shown()) ?? owner.CloudRemovalBase(entity);
      if (last is null || owner.CloudMissing(entity, last) is not { } removal) continue;
      var restoring = view?.Exists == false;
      if (removal.Metadata is { } metadata)
      {
        if (!Capture(key, Travelling(Merged(last, metadata), found.Kind.Table), found.Kind.Table, restoring)) continue;
      }
      else if (view is null || restoring)
      {
        if (!Capture(key, Travelling(last, found.Kind.Table), found.Kind.Table, restoring)) continue;
      }
      if (!Capture(key, null, found.Kind.Table)) continue;
      owner.CloudCaptured(entity, removed: true);
      lastSeen.Remove(entity); changed = true;
    }
    items = count; elsewhere = foreign;
    var context = owner.CloudContext();
    if (changed || !reconsidered || context != lastContext || state.Retry.Count > 0)
    {
      reconsidered = true; lastContext = context;
      Reconsider(records);
    }
    return changed;
  }
  /// Records that wait here, or hold fields back, are looked at again: the cause may have ended.
  private void Reconsider(IReadOnlyDictionary<string, CloudJson.Object> given)
  {
    var entities = state.Waiting.Keys.Concat(store.HeldEntities(Domain).Keys).Concat(state.Retry).Distinct(StringComparer.Ordinal).OrderBy(e => e, StringComparer.Ordinal).ToArray();
    var placed = new List<string>(); var records = given;
    foreach (var entity in entities)
    {
      if (KindOf(entity) is not { } found) continue;
      var mine = records.TryGetValue(entity, out var raw) ? Travelling(raw, found.Kind.Table) : null;
      try
      {
        if (Show(CloudRecordKey.Of(Domain, entity), entity, found.Kind, mine, "", 0) is not null)
        {
          placed.Add(entity);
          // A record placed now can make another one placeable (an agent, then its instructions): read the owner again.
          try { records = owner.CloudRecords(); } catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException) { }
        }
      }
      catch (CloudRecordRefusal refusal) { Refused(entity, refusal.Reason); }
    }
    if (placed.Count > 0) owner.CloudImported(placed);
  }
  private void Refused(string entity, string reason)
  {
    state.Waiting[entity] = reason;
    if (!state.Retry.Contains(entity)) state.Retry.Add(entity);
  }

  // ---- hand-over to the engine ----

  private CloudOperation Operation(CloudRecordKey key, CloudMergeRevision revision)
  {
    var payload = revision.Version.Payload();
    return new CloudOperation(1, revision.OpId, deviceId, Domain, key.Entity, revision.OpId, revision.Parents.ToArray(), "put", null, null,
      new CloudSourceReference(SourceId, key.Entity), revision.Time, payload, CloudOperation.PayloadHashOf(payload));
  }
  /// This PC's own versions not yet with the engine, oldest first (within one moment a required record first). A version
  /// too large to send is held back together with every later version of the same record, and counted.
  private IReadOnlyList<CloudOperation> Pending(int limit)
  {
    int Rank(string entity) { for (var i = 0; i < kinds.Count; i++) if (kinds[i].IdOf(entity) is not null) return i; return kinds.Count; }
    var rows = store.OwnUnhanded(Domain).OrderBy(r => r.Revision.Time).ThenBy(r => Rank(r.Key.Entity)).ThenBy(r => r.Revision.OpId, StringComparer.Ordinal);
    var blocked = new HashSet<string>(StringComparer.Ordinal); var result = new List<CloudOperation>();
    foreach (var (key, revision) in rows)
    {
      if (blocked.Contains(key.Entity)) continue;
      if (KindOf(key.Entity) is { } found && found.Kind.Requires?.Invoke(found.Id) is { } needs && blocked.Contains(needs)) { blocked.Add(key.Entity); continue; }
      var op = Operation(key, revision);
      if (CloudCanonical.Encode(op.Payload).Length > CloudPackFormat.MaximumPayloadBytes || CloudCanonical.Encode(op.ToJson()).Length > MaximumRecordBytes) { blocked.Add(key.Entity); continue; }
      if (result.Count < limit) result.Add(op);
    }
    tooLarge = blocked.Count;
    return result;
  }

  /// The engine read the whole feed: from now on this PC's own records may go (the first ones as baselines).
  public bool FeedRead()
  {
    lock (gate)
    {
      if (!store.MarkFeedRead()) return false;
      store.Flush();
      return true;
    }
  }

  // ---- apply (Cloud → this PC) ----

  private ParsedOp Parse(CloudOperation op)
  {
    if (op.V != 1 || op.Domain != Domain || op.Kind != "put" || op.Revision != op.OpId || KindOf(op.EntityId) is not { } found) throw new CloudFailure("invalid_request");
    var key = CloudRecordKey.Of(Domain, op.EntityId);
    if (CloudOperation.PayloadHashOf(op.Payload) != op.PayloadHash) throw new CloudFailure("invalid_request");
    CloudMergeVersion version;
    try { version = CloudMergeVersion.Parse(op.Payload); } catch (CloudMergeInvalid) { throw new CloudFailure("invalid_request"); }
    if (CloudRecordJson.Text(version.Fields.GetValueOrDefault("id")) is { } named && named != found.Id) throw new CloudFailure("invalid_request");
    if (version.MinTable > found.Kind.Table.Version) throw new Park("This record was written by a newer version of the app than this PC runs.");
    var limit = store.Clock() + CloudRecordStore.MaximumAhead;
    var newest = op.CreatedAt;
    foreach (var stamp in version.Stamps.Values) newest = Math.Max(newest, stamp.Time);
    foreach (var elements in version.Collections.Values) foreach (var element in elements.Values) newest = Math.Max(newest, element.Stamp.Time);
    foreach (var marks in version.Removed.Values) foreach (var mark in marks.Values) newest = Math.Max(newest, mark.Time);
    if (newest > limit) throw new Park("This record is dated more than a day ahead of the Cloud's clock.");
    return new(key, found.Kind, found.Id, version);
  }

  /// Shows the Cloud's merged view of one record here as its owner decides. Returns the value written, or null when
  /// nothing was written (already the same, waiting, or its history is incomplete here).
  private sealed record ShownValue(CloudJson.Object? Value);
  private ShownValue? Show(CloudRecordKey key, string entity, CloudRecordKind kind, CloudJson.Object? mine, string device, long time)
  {
    CloudMergeView? view;
    try { view = store.View(key, kind.Table); }
    catch (CloudMergeHistoryIncomplete) { incomplete.Add(entity); return null; }
    incomplete.Remove(entity);
    if (view is null) return null;
    // A reconsidered old-form removal still names its author, never the device delivering the retry.
    var sourceStamp = view.Stamps.TryGetValue(Domain == "tasks" && view.Exists ? "place" : CloudRecordMerge.ExistsField, out var s) ? s : (CloudMergeStamp?)null;
    var source = sourceStamp is { } stamp && store.GraphOf(key).Nodes.TryGetValue(stamp.Op, out var node) ? node : null;
    var sourceDevice = source?.Device ?? device; var sourceTime = sourceStamp?.Time ?? time;
    owner.CloudReceiving(entity, sourceDevice, sourceTime);
    if (!view.Exists) owner.CloudTombstone(entity, view.Shown(), sourceDevice, sourceTime);
    var plan = owner.CloudPlan(entity, view.Exists ? view.Shown() : null);
    var reasons = plan.Waiting is null ? plan.Held ?? new Dictionary<string, string>() : new Dictionary<string, string>();
    if (plan.Waiting is null) state.Waiting.Remove(entity); else state.Waiting[entity] = plan.Waiting;
    if (reasons.Count == 0) state.Reasons.Remove(entity); else state.Reasons[entity] = reasons.ToDictionary(r => r.Key, r => r.Value, StringComparer.Ordinal);
    store.SetHeld(key, reasons.Keys);
    var line = plan.Waiting is null ? plan.Note : null;
    if (line is null) state.Notes.Remove(entity); else state.Notes[entity] = line;
    var next = plan.Store;
    if (plan.Waiting is not null || Equal(next, mine))
    {
      if (plan.Waiting is null) state.Retry.Remove(entity);
      return null;
    }
    if (next is not null) owner.CloudWrite(entity, next, mine);
    else owner.CloudRemove(entity, mine, view.Shown(), sourceDevice, sourceTime);
    store.Shown(key, view.Heads, next);
    if (next is null) lastSeen.Remove(entity); else lastSeen[entity] = Travelling(next, kind.Table);
    state.Retry.Remove(entity);
    if (device.Length > 0)
    {
      foreach (var name in kind.Table.Classes.Keys.OrderBy(k => k, StringComparer.Ordinal).Where(n => kind.Table.Classes[n] is not CloudMergeClass.ThisDevice))
      {
        var before = Field(mine, name); var after = Field(next, name);
        if (Equal(before, after)) continue;
        var listed = kind.ListedValues?.Contains(name) == true;
        state.Changes.Add(new(entity, name, device, time, listed ? CloudRecordJson.Text(before) : null, listed ? CloudRecordJson.Text(after) : null));
      }
      if (mine is null) state.Changes.Add(new(entity, CloudRecordMerge.ExistsField, device, time, null, null));
    }
    return new(next);
  }

  public Task ApplyAsync(CloudOperation operation, CloudImportOrigin origin, CancellationToken ct)
  {
    lock (gate)
    {
      Live();
      ParsedOp parsed;
      try { parsed = Parse(operation); }
      catch (Park park) { ParkOp(operation, origin.DeviceId, park.Message); return Task.CompletedTask; }
      Apply(operation, parsed, origin.DeviceId);
      return Task.CompletedTask;
    }
  }
  private void ParkOp(CloudOperation op, string device, string reason)
  {
    if (state.Parked.Any(p => CloudOperation.FromJson(CloudJson.Parse(p.Op)).OpId == op.OpId)) return;
    state.Parked.Add(new Parked { Op = CloudRecordJson.Encode(op.ToJson()), Device = device, Reason = reason });
  }
  private void Apply(CloudOperation op, ParsedOp parsed, string device)
  {
    if (packRecords is null)
    {
      try { packRecords = owner.CloudRecords().ToDictionary(r => r.Key, r => r.Value, StringComparer.Ordinal); }
      catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException)
      { ParkOp(op, device, "This PC's saved list cannot be read right now; these records wait."); return; }
    }
    var entity = op.EntityId; var table = parsed.Kind.Table;
    if (origins.BelongsElsewhere(Domain, entity, account)) { ParkOp(op, device, "A record with this id on this PC came from another Cloud account; the two are kept apart."); return; }
    if (parsed.Kind.Requires?.Invoke(parsed.Id) is { } needs && needs != entity && !store.Holds(CloudRecordKey.Of(Domain, needs)))
    {
      waitingFor.Add(needs);
      ParkOp(op, device, "Waiting for a record this one needs, which has not arrived on this PC yet.");
      return;
    }
    var mine = packRecords.TryGetValue(entity, out var raw) ? Travelling(raw, table) : null;
    var stored = store.Image(parsed.Key).Stored;
    // An edit made here before this delivery stays concurrent with it, so it is captured first; so is an intended removal
    // made here (a record merely gone from this PC's owner is not).
    if (stored)
    {
      if (mine is not null && !owner.CloudLocalOnly(entity))
      {
        if (Capture(parsed.Key, mine, table, owner.CloudRestoring(entity))) owner.CloudCaptured(entity, removed: false);
      }
      else if (store.Image(parsed.Key).Value is { } last && owner.CloudMissing(entity, last) is { } removal)
      {
        var enriched = removal.Metadata is not { } metadata || Capture(parsed.Key, Merged(last, metadata), table);
        if (enriched && Capture(parsed.Key, null, table)) owner.CloudCaptured(entity, removed: true);
      }
    }
    var revision = new CloudMergeRevision(new CloudMergeNode(op.OpId, op.Parents, device, op.CreatedAt, parsed.Version.Baseline), parsed.Version);
    try { store.Receive(parsed.Key, [revision], table); }
    catch (CloudRecordTooFarAhead) { ParkOp(op, device, "This record is dated more than a day ahead of the Cloud's clock."); return; }
    // A copy this PC had and never synced joins as a baseline (rule J): the Cloud's version wins and this PC's differing
    // values are kept as other versions.
    if (!stored && mine is not null) Capture(parsed.Key, mine, table);
    origins.Add(Domain, entity, account);
    try
    {
      if (Show(parsed.Key, entity, parsed.Kind, mine, device, op.CreatedAt) is { } shown)
      {
        if (shown.Value is { } next) packRecords[entity] = next; else packRecords.Remove(entity);
        written.Add(entity);
      }
    }
    catch (CloudRecordRefusal refusal) { Refused(entity, refusal.Reason); }
    if (waitingFor.Remove(entity)) retryWanted = true;
  }
  /// Incoming records that waited are tried again, in arrival order.
  private void RetryParked()
  {
    if (state.Parked.Count == 0) return;
    var parked = state.Parked.ToArray();
    state.Parked.Clear();
    foreach (var row in parked)
    {
      var op = CloudOperation.FromJson(CloudJson.Parse(row.Op));
      try { Apply(op, Parse(op), row.Device); }
      catch (Park park) { ParkOp(op, row.Device, park.Message); }
      catch (CloudFailure) { /* no longer readable: dropped, as a refused record would be */ }
    }
  }

  /// Called once a pack's records were applied: what waited for them is placed, screens refresh, and this bookkeeping is
  /// made durable once per pack.
  public Task SettleAsync(CancellationToken ct)
  {
    lock (gate)
    {
      if (stopped) return Task.CompletedTask;
      if (written.Count > 0 && state.Waiting.Count > 0)
      {
        try { Reconsider(owner.CloudRecords()); } catch (Exception error) when (error is not OperationCanceledException and not OutOfMemoryException and not CloudRecordRefusal) { }
      }
      if (written.Count > 0) owner.CloudImported(written.ToArray());
      if (retryWanted) { retryWanted = false; packRecords = null; RetryParked(); }
      written.Clear(); packRecords = null;
      Persist();
      return Task.CompletedTask;
    }
  }

  // ---- the read-only list ----

  private List<string> Gaps()
  {
    var gaps = new List<string>();
    if (stopped) gaps.Add("Signed out of Cloud on this PC.");
    if (unreadable is not null) gaps.Add(unreadable);
    if (incomplete.Count > 0) gaps.Add(incomplete.Count + " records wait for earlier versions that have not arrived on this PC.");
    if (tooLarge > 0) gaps.Add(tooLarge + " records are too large to send in this version and stay on this PC.");
    return gaps;
  }
  public CloudRecordListing Listing()
  {
    lock (gate)
    {
      if (stopped) return new(0, [], [], [], Gaps(), [], []);
      var kept = store.OtherVersions(Domain).Select(row =>
      {
        var mine = row.Conflict.Device == deviceId;
        return new CloudRecordListing.Kept(row.Key.Entity, row.Conflict.Field, row.Conflict.Device, row.Conflict.Time, mine,
          mine && CloudRecordJson.Text(row.Conflict.Value) is { } text ? text[..Math.Min(80, text.Length)] : null);
      }).ToArray();
      var waiting = state.Waiting.OrderBy(w => w.Key, StringComparer.Ordinal).Select(w => new CloudRecordListing.Waiting(w.Key, "", w.Value)).ToList();
      foreach (var (entity, fields) in store.HeldEntities(Domain))
        foreach (var name in fields.OrderBy(f => f, StringComparer.Ordinal))
          waiting.Add(new(entity, name, state.Reasons.GetValueOrDefault(entity)?.GetValueOrDefault(name) ?? "A change from another device is waiting on this PC."));
      waiting.AddRange(state.Parked.Select(p => new CloudRecordListing.Waiting(CloudOperation.FromJson(CloudJson.Parse(p.Op)).EntityId, "", p.Reason)));
      var notes = exclusions.ToList();
      if (elsewhere > 0) notes.Add(elsewhere + " records came from another Cloud account and are kept on this PC only.");
      if (state.Waiting.Count > 0) notes.Add(state.Waiting.Count + " records from another device wait on this PC.");
      return new(store.OtherVersionCount(Domain), kept, waiting, state.Changes.ToArray(), Gaps(),
        state.Notes.OrderBy(n => n.Key, StringComparer.Ordinal).Select(n => n.Value).ToArray(), notes);
    }
  }
}
