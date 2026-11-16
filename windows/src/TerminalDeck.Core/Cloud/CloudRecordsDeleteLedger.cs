using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// The record owners' delete-rule bookkeeping (the Mac's RecordsDeleteLedger in BackendCloudBrainTasks.swift, 87941cff8 and
// the review fixes after it), on Windows. Not another Bin: agents' and projects' bytes go into the account's ONE keeper
// Bin (CloudBin.ForAccount, lane D); tasks keep using their Trash. One small JSON file per owner instead of the Mac's
// SQLite tables; the intents and the local marks are lane D's CloudDeleteState in a slot of their own.
public sealed class CloudRecordsDeleteLedger
{
  private sealed class Entry { public string Value { get; set; } = ""; public bool Restoring { get; set; } }
  private sealed class Body
  {
    public Dictionary<string, Entry> Saved { get; set; } = [];
    public Dictionary<string, long> Seen { get; set; } = [];
  }
  private sealed record ActorJson(string By, string Mac, string MacName, string? Session, string? Agent, long At, string Group);

  public const string ThisPc = "this PC";
  private readonly object gate = new();
  private readonly CloudFileSlot slot;
  private readonly CloudDeleteState state;
  private readonly CloudBin bin;
  private readonly Func<long> clock;
  private readonly Body body;
  private CloudRecordStore? store;
  private string? device;
  private Func<bool> open = () => false;
  private Func<string, string?> names = _ => null;
  private Func<long?> service = () => null;

  /// `accountFolder`: `cloud\accounts\<account>` (its keeper Bin is shared by every owner). `name`: this owner's files,
  /// `<folder>\<name>-delete.json` and `<folder>\<name>-delete-state.json`.
  public CloudRecordsDeleteLedger(string accountFolder, string folder, string name, Func<long>? clock = null)
  {
    Directory.CreateDirectory(folder);
    slot = new CloudFileSlot(Path.Combine(folder, name + "-delete.json"));
    state = new CloudDeleteState(new CloudFileSlot(Path.Combine(folder, name + "-delete-state.json")));
    bin = CloudBin.ForAccount(accountFolder);
    this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    Body? loaded = null;
    try { loaded = slot.Read() is { } bytes ? JsonSerializer.Deserialize<Body>(bytes) : null; } catch (JsonException) { }
    body = loaded ?? new Body();
  }
  private void Save() => slot.Write(JsonSerializer.SerializeToUtf8Bytes(body));

  /// The adapter's store and this PC's device id (the Mac's `bind`): views of a record and its history.
  public void Bind(CloudRecordStore records, string deviceId) { lock (gate) { store = records; device = deviceId; } }
  /// `gate`: the delete rule is open (every device of the account announced it); `deviceName`: a device id → its name
  /// from the device list (null: not known); `serviceNow`: the service clock (null while not known: then nothing ages).
  public void Configure(Func<bool>? gate = null, Func<string, string?>? deviceName = null, Func<long?>? serviceNow = null)
  {
    lock (this.gate)
    {
      if (gate is not null) open = gate;
      if (deviceName is not null) names = deviceName;
      if (serviceNow is not null) service = serviceNow;
    }
  }
  public bool IsOpen() { Func<bool> read; lock (gate) read = open; try { return read(); } catch (Exception error) when (error is not OutOfMemoryException) { return false; } }
  public long? ServiceNow() { Func<long?> read; lock (gate) read = service; return read(); }
  public string? OwnDevice() { lock (gate) return device; }
  public string MacName(string id)
  {
    Func<string, string?> read; lock (gate) read = names;
    return id.Length > 0 && read(id.ToLowerInvariant()) is { Length: > 0 } name ? name : CloudDeleteWords.AnotherDevice;
  }
  public string OwnName() => OwnDevice() is { } own && MacName(own) is var name && name != CloudDeleteWords.AnotherDevice ? name : ThisPc;
  public long Now() => clock();
  /// Who is deleting on this PC now: the person, unless an AI is named.
  public CloudDeleteActor Actor(CloudDeleteBy by = CloudDeleteBy.Person, string? agent = null, string? session = null, long? at = null) =>
    new(by, OwnDevice() ?? "this-pc", OwnName(), session, by == CloudDeleteBy.Ai ? agent : null, at ?? Now(), Guid.NewGuid().ToString("D"));

  // ---- intents and marks (lane D's CloudDeleteState) ----

  public CloudDeleteIntent? Intent(string entity) { lock (gate) return state.Intent(entity); }
  public void SaveIntent(CloudDeleteIntent intent) { lock (gate) state.PutIntent(intent); }
  public void ClearIntent(string entity) { lock (gate) state.ClearIntent(entity); }
  public IReadOnlyList<string> Pending(string prefix) { lock (gate) return state.IntentPlaces().Where(p => p.StartsWith(prefix, StringComparison.Ordinal)).ToArray(); }
  public CloudDeleteMark? Mark(string entity) { lock (gate) return state.Mark(entity); }
  public void PutMark(string entity, CloudLocalMark mark, long at) { lock (gate) state.PutMark(new(entity, mark, at)); }
  public IReadOnlyList<CloudDeleteMark> Marks() { lock (gate) return state.Marks(); }
  public void ClearMark(string entity) { lock (gate) state.ClearMark(entity); }

  // ---- saved values ----

  public void Put(string entity, CloudJson value, bool restoring = false)
  {
    lock (gate)
    {
      var text = CloudRecordJson.Encode(value);
      body.Saved[entity] = new Entry { Value = text, Restoring = restoring || body.Saved.GetValueOrDefault(entity)?.Restoring == true };
      Save();
    }
  }
  public CloudJson? Saved(string entity) { lock (gate) return body.Saved.TryGetValue(entity, out var e) ? CloudJson.Parse(e.Value) : null; }
  public IReadOnlyList<(string Key, CloudJson Value)> SavedAll(string prefix)
  {
    lock (gate) return body.Saved.Where(s => s.Key.StartsWith(prefix, StringComparison.Ordinal)).OrderBy(s => s.Key, StringComparer.Ordinal)
      .Select(s => (s.Key, CloudJson.Parse(s.Value.Value))).ToArray();
  }
  public void ClearSaved(string entity) { lock (gate) if (body.Saved.Remove(entity)) Save(); }
  /// A new delete is never a put back: a put-back flag left from before it is dropped.
  public void ClearRestoring(string entity) { lock (gate) if (body.Saved.TryGetValue(entity, out var e) && e.Restoring) { e.Restoring = false; Save(); } }
  public bool Restoring(string entity) { lock (gate) return body.Saved.GetValueOrDefault(entity)?.Restoring == true; }
  public void Captured(string entity, bool removed)
  {
    lock (gate)
    {
      if (body.Saved.TryGetValue(entity, out var e)) e.Restoring = false;
      if (removed)
      {
        state.ClearIntent(entity);
        body.Saved.Remove("purged:" + entity);
        if (state.Mark(entity) is null) body.Saved.Remove(entity);
      }
      Save();
    }
  }
  public void Seen(string entity, long at) { lock (gate) { body.Seen[entity] = at; Save(); } }
  public long? LastSeen(string entity) { lock (gate) return body.Seen.TryGetValue(entity, out var at) ? at : null; }

  // ---- the keeper Bin (agents and projects) ----

  private static byte[] Bytes(CloudJson value) => CloudCanonical.Encode(value);
  private static CloudBinEra Era(string group) => group.StartsWith("older:", StringComparison.Ordinal) ? CloudBinEra.OlderVersion
    : group.StartsWith("before:", StringComparison.Ordinal) ? CloudBinEra.BeforeNewRule : CloudBinEra.Current;
  private static CloudJson ActorValue(CloudDeleteActor a) => CloudRecordJson.Object([("by", CloudJson.From(CloudDeleteText.Raw(a.By))), ("mac", CloudJson.From(a.Mac)),
    ("macName", CloudJson.From(a.MacName)), ("session", a.Session is null ? CloudJson.Null.Value : CloudJson.From(a.Session)),
    ("agent", a.Agent is null ? CloudJson.Null.Value : CloudJson.From(a.Agent)), ("at", CloudJson.From(a.At)), ("group", CloudJson.From(a.Group))]);
  private static CloudDeleteActor ActorOf(CloudJson? v)
  {
    if (CloudDeleteText.By(CloudRecordJson.Text(CloudRecordJson.Get(v, "by"))) is not { } by || CloudRecordJson.Text(CloudRecordJson.Get(v, "group")) is not { Length: > 0 } group
      || CloudRecordJson.Number(CloudRecordJson.Get(v, "at")) is not { } at || CloudRecordJson.Exact(at) is not { } whole)
      throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidState);
    return new(by, CloudRecordJson.Text(CloudRecordJson.Get(v, "mac")) ?? "", CloudRecordJson.Text(CloudRecordJson.Get(v, "macName")) ?? CloudDeleteWords.AnotherDevice,
      CloudRecordJson.Text(CloudRecordJson.Get(v, "session")), CloudRecordJson.Text(CloudRecordJson.Get(v, "agent")), whole, group);
  }
  private CloudJson? BinContent(string entity, out CloudBin.Binned? row)
  {
    row = bin.Get(entity);
    return row is not null && bin.Content(row.Kind, row.Sha256) is { } bytes ? CloudJson.Parse(Encoding.UTF8.GetString(bytes)) : null;
  }
  /// The value a delete put in the Bin (without its attribution), or null when it is not in the Bin.
  public CloudJson.Object? BinnedValue(string entity)
  {
    lock (gate)
    {
      try { return BinContent(entity, out _) is CloudJson.Object o ? CloudRecordJson.Remove(o, "deleteActor") : null; }
      catch (CloudFailure) { return null; }
    }
  }
  public string? BinnedGroup(string entity)
  {
    lock (gate)
    {
      try { return CloudRecordJson.Text(CloudRecordJson.Get(CloudRecordJson.Get(BinContent(entity, out _), "deleteActor"), "group")); }
      catch (CloudFailure) { return null; }
    }
  }
  /// Into the Bin for 30 days, with who removed it. The same removal (group) arriving again is not put twice.
  public void PutBin(string kind, string entity, string name, CloudJson.Object value, CloudDeleteActor actor)
  {
    lock (gate)
    {
      if (BinnedGroupUnlocked(entity) == actor.Group) return;
      var payload = CloudRecordJson.Set(value, "deleteActor", ActorValue(actor));
      var group = new CloudBinGroup(actor.Group, actor.By, actor.MacName, actor.Session, actor.Agent, actor.At, [new CloudDeleteItem(entity, kind, name)], Era(actor.Group));
      bin.Put(kind, entity, name, null, entity, actor.At, actor.Mac, Bytes(payload), shown: true, now: Now(), group: group);
    }
  }
  private string? BinnedGroupUnlocked(string entity)
  {
    try { return CloudRecordJson.Text(CloudRecordJson.Get(CloudRecordJson.Get(BinContent(entity, out _), "deleteActor"), "group")); }
    catch (CloudFailure) { return null; }
  }
  /// The Bin of one kind: one row per item, with who removed it. One row that does not read is left out; the rest shows.
  /// Each device ages its own Bin by the service clock only; nothing ages while that clock is not known.
  public IReadOnlyList<(CloudDeleteItem Item, CloudDeleteActor Actor, CloudJson.Object Value)> BinRows(string kind)
  {
    var serviceNow = ServiceNow();
    lock (gate)
    {
      if (serviceNow is { } at) bin.Sweep(at);
      var rows = new List<(CloudDeleteItem, CloudDeleteActor, CloudJson.Object)>();
      foreach (var row in bin.List(kind))
      {
        try
        {
          if (bin.Content(kind, row.Sha256) is not { } bytes || CloudJson.Parse(Encoding.UTF8.GetString(bytes)) is not CloudJson.Object value) continue;
          rows.Add((new CloudDeleteItem(row.ItemKey, kind, row.Name), ActorOf(CloudRecordJson.Get(value, "deleteActor")), CloudRecordJson.Remove(value, "deleteActor")));
        }
        catch (Exception error) when (error is CloudFailure or CloudDeleteRuleException or FormatException or IOException) { /* left out, the rest shows */ }
      }
      return rows;
    }
  }
  /// Out of the Bin: put back (kept 30 days as an earlier version) or deleted for good.
  public void TakeBin(string entity, bool permanently = false) { lock (gate) { if (permanently) bin.DeleteForGood(entity); else bin.Take(entity, Now()); } }
  /// An earlier version replaced on this PC, kept 30 days.
  public void KeepReplacement(string kind, string entity, string name, CloudJson value) { lock (gate) { var at = Now(); bin.Keep(kind, entity, name, null, at, OwnDevice() ?? "this-pc", Bytes(value), at); } }
  public void RememberVersion(string entity, CloudJson value) => KeepReplacement("agent", entity, "Agent instructions", value);
  public IReadOnlyList<CloudJson> PriorValues(string entity)
  {
    lock (gate)
      return bin.Versions(entity).Select(v => bin.Content(v.Kind, v.Sha256)).OfType<byte[]>().Select(b =>
      {
        try { return CloudJson.Parse(Encoding.UTF8.GetString(b)); } catch (CloudFailure) { return null; }
      }).OfType<CloudJson>().ToArray();
  }

  // ---- the record as the Cloud has it ----

  public CloudMergeView? Merged(string entity, CloudMergeTable table)
  {
    CloudRecordStore? records; lock (gate) records = store;
    if (records is null) return null;
    try { return records.View(CloudRecordKey.Of(table.Domain, entity), table); } catch (CloudMergeHistoryIncomplete) { return null; }
  }
  /// The Cloud's newest value of a record that exists there, or null.
  public CloudJson.Object? Newest(string entity, CloudMergeTable table) => Merged(entity, table) is { Exists: true } view ? view.Shown() : null;
  public bool HasHistory(string entity, string domain)
  {
    CloudRecordStore? records; lock (gate) records = store;
    return records?.Holds(CloudRecordKey.Of(domain, entity)) == true;
  }
  public bool RemovalSeen(string entity, string group, CloudMergeTable table)
  {
    if (Merged(entity, table) is not { } view || CloudRecordJson.Text(view.Fields.GetValueOrDefault("deletedGroup")) != group) return false;
    return !view.Exists || view.Conflicts.Any(c => c.Field == CloudRecordMerge.ExistsField && CloudRecordJson.Bool(c.Value) == false);
  }

  // ---- the travel fields on a record ----

  public static CloudJson.Object Metadata(CloudDeleteIntent intent, string macName) => CloudRecordJson.Object([
    ("deletedBy", CloudJson.From(CloudDeleteText.Raw(intent.By))), ("deletedOn", CloudJson.From(intent.Mac)), ("deletedGroup", CloudJson.From(intent.Group)),
    ("deletedScope", CloudJson.From(CloudDeleteText.Raw(intent.Scope))), ("deletedTime", CloudJson.From(intent.At)), ("deletedMacName", CloudJson.From(macName)),
    ("deletedWithAgent", CloudJson.From(false)), ("deletedSession", intent.Session is null ? CloudJson.Null.Value : CloudJson.From(intent.Session)),
    ("deletedAgent", intent.Agent is null ? CloudJson.Null.Value : CloudJson.From(intent.Agent))]);
  public static CloudJson.Object Clearing(CloudJson.Object row)
  {
    foreach (var field in CloudMergeTablesV2.RecordDeleteFields) row = CloudRecordJson.Remove(row, field);
    return row;
  }
  /// What of a row's delete fields may travel: all of them while the gate is open and they name a real group; else none.
  public static CloudJson.Object WireRow(CloudJson.Object row, bool open) =>
    open && CloudDeleteText.IsUuid(CloudRecordJson.Text(CloudRecordJson.Get(row, "deletedGroup"))) ? row : Clearing(row);
  /// Old records carry no attribution. A partial or malformed new removal never becomes "Everywhere": refused.
  public static void Validate(CloudJson.Object value)
  {
    if (CloudRecordJson.Nullish(CloudRecordJson.Get(value, "deletedGroup")) && CloudRecordJson.Nullish(CloudRecordJson.Get(value, "deletedScope"))
      && CloudRecordJson.Nullish(CloudRecordJson.Get(value, "deletedBy"))) return;
    if (!CloudDeleteText.IsUuid(CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedGroup"))) || CloudDeleteText.By(CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedBy"))) is null
      || CloudDeleteText.Scope(CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedScope"))) is null
      || CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedOn")) is not { Length: > 0 }
      || CloudRecordJson.Number(CloudRecordJson.Get(value, "deletedTime")) is not { } time || !double.IsFinite(time) || time <= 0 || time >= 9.2233720368547758E18)
      throw new CloudRecordRefusal("This removal's attribution or scope cannot be read safely.");
  }
  /// Who removed an arriving record. An old-form removal is grouped by its device and day as "(older version)".
  public CloudDeleteActor Arriving(CloudJson.Object value, string device, long at)
  {
    Validate(value);
    var mac = CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedOn")) ?? device;
    var name = CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedMacName")) ?? MacName(mac);
    var when = CloudRecordJson.Number(CloudRecordJson.Get(value, "deletedTime")) is { } t ? (long)t : at;
    return new(CloudDeleteText.By(CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedBy"))) ?? CloudDeleteBy.Person, mac, name,
      CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedSession")), CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedAgent")), when,
      CloudRecordJson.Text(CloudRecordJson.Get(value, "deletedGroup")) ?? OlderGroup(mac, at));
  }
  public static string OlderGroup(string mac, long at) => "older:" + mac + ":" + (at / 86_400_000).ToString(System.Globalization.CultureInfo.InvariantCulture);
  public static string AgedKey(string entity) => "aged:" + entity;
  public static IReadOnlyList<CloudBinGroup> Groups(IEnumerable<(CloudDeleteItem Item, CloudDeleteActor Actor)> rows) =>
    rows.GroupBy(r => r.Actor.Group, StringComparer.Ordinal).Select(g =>
    {
      var a = g.First().Actor;
      return new CloudBinGroup(a.Group, a.By, a.MacName, a.Session, a.Agent, a.At, g.Select(r => r.Item).ToArray(), Era(a.Group));
    }).OrderByDescending(g => g.At).ThenBy(g => g.Id, StringComparer.Ordinal).ToArray();
}

/// What one "Put back all" press brought back and what it could not, by item (pages show the names only).
public sealed record CloudRecordsPutBack(IReadOnlyList<CloudDeleteItem> Restored, IReadOnlyList<CloudDeleteItem> NotRestored)
{
  /// One plain line, names only: "Put back: Reviewer, Writer. Not put back: Planner."
  public string Line
  {
    get
    {
      var parts = new List<string>();
      if (Restored.Count > 0) parts.Add("Put back: " + string.Join(", ", Restored.Select(i => i.Name)) + ".");
      if (NotRestored.Count > 0) parts.Add("Not put back: " + string.Join(", ", NotRestored.Select(i => i.Name)) + ".");
      return parts.Count == 0 ? "Nothing to put back." : string.Join(' ', parts);
    }
  }
}

/// THE ONE SWITCH for what this build announces for the delete rule (`onerule.understands.deleterule.<pc>`). `none` (J-1:
/// "applies no removals, sends none"; it still OPENS the gate on the Macs) until every kind Windows keeps follows the rule
/// in the joined build: memory and instruction files (lane D), tasks, agents and projects (lane D2), the Cloud folder and
/// artifacts (lane F), saved passwords and the keys that ride them (lane S). The join sets AnnounceV1 to true in the
/// commit that joins the last of them, and the composition calls Announce (in place of lane D's
/// CloudDeleteRuleAnnouncement.Announce) at start and every 12 hours on the sync thread.
public static class CloudDeleteRuleSwitch
{
  public const bool AnnounceV1 = false;
  public static bool Announce(CloudAnnounce announce, bool force = false) =>
    AnnounceV1 ? announce.Announce(CloudDeleteGate.Feature, CloudDeleteGate.Format, force) : CloudDeleteRuleAnnouncement.Announce(announce, force);
}
