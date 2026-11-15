using System.Text;

namespace TerminalDeck.Core.Cloud;

// The delete rule for saved passwords (J-3), port of the Mac's BackendProjectSecretFilesDelete.swift
// (BackendProjectSecretFilesDeleteState = the keeper, BackendProjectSecretFilesSavedDeleteOwner = the owner that wraps
// every travelling store). The Bin is SEALED on this PC (AES-GCM under this device's own key derived from the
// saved-passwords key): old values, names, dates and removals live only inside it. Rules kept from the Mac:
// - The Bin row and the removal are saved (sealed) first; the intent is written LAST and cleared FIRST (cancel) or
//   whatever happens (finish). One left by a crash is dropped when the Bin opens.
// - Every "prepare, then remove" has an exact undo when the owner's compare-and-remove refuses.
// - A value this owner already knows is ALWAYS kept away after a removal; it comes back only by Put back (it travels)
//   or by saving a NEW value. A removal applies whenever the CURRENT value here equals the removed one.
// - An arriving removal that cannot be checked or applied gets a final "not applied", never a throw (only "locked").
// - A copy carried only inside a removal passes the owner's own arrival rules at every put back, and fills at most
//   2,000 rows / 8 MB of the Bin. The Bin ages by the SERVICE clock only, from BOTH the removal's date and the date
//   this PC put it in. A Bin that cannot be read is set aside (renamed, never deleted) with one line, never "locked".
// - An item gone OUTSIDE the app (`claude mcp remove`): an AI session = everywhere; his hand or unknown = "Not on this
//   PC". A missing file judges nothing; an empty list is his choice only when exactly ONE known item went.

public sealed class CloudSecretsVanished(Func<string, long, long, Task<CloudDeleteWitnessAnswer>> who, Func<string?> device, Func<string> deviceName, bool judgesAbsence = true)
{
  public Task<CloudDeleteWitnessAnswer> WhoAsync(string id, long lastSeen, long goneAt) => who(id, lastSeen, goneAt);
  public string? Device => device();
  public string DeviceName => deviceName();
  public bool JudgesAbsence { get; } = judgesAbsence;
  /// Only this PC's id and name (an id retired from Cloud); an absent item is never judged.
  public static CloudSecretsVanished IdentityOnly(Func<string?> device, Func<string> deviceName) =>
    new((_, _, _) => Task.FromResult(CloudDeleteWitnessAnswer.CannotKnow), device, deviceName, judgesAbsence: false);
}

/// A store that can say whether its source file was there (MCP: Claude Code's settings file). Null = cannot say.
public interface ICloudSecretsFileFound { Task<(IReadOnlyList<CloudSecretRecord> Records, bool? FileFound)> CaptureReadAsync(); }

internal sealed class CloudSecretsKeeper(string root, string source)
{
  public const long LatestAt = 4_102_444_800_000;
  public const int SafetyPerItem = 3, SafetyInAll = 200, CarriedRows = 2_000, CarriedBytes = 8 * 1024 * 1024;
  public const string BinDamaged = "Part of your saved-passwords Bin on this PC could not be read. It was set aside; the rest is as it was.";

  internal sealed record Binned(CloudDeleteItem Item, CloudDeleteActor Actor, CloudSecretRecord Record, long Until, long? BinnedAt);
  internal sealed record Version(string Id, string? Digest, string? FileMark);
  internal sealed record Safety(CloudSecretRecord Record, long At);
  internal sealed class Held
  {
    public Dictionary<string, List<Version>> History = new(StringComparer.Ordinal);
    public Dictionary<string, string> WireHeads = new(StringComparer.Ordinal);
    public Dictionary<string, Safety> Safety = new(StringComparer.Ordinal);
    public Dictionary<string, CloudSecretRecord> Newest = new(StringComparer.Ordinal);
    public Dictionary<string, CloudSecretRemoval> Removals = new(StringComparer.Ordinal);
    public Dictionary<string, string> Republications = new(StringComparer.Ordinal);
    public Dictionary<string, CloudDeleteScope> LocalRemovals = new(StringComparer.Ordinal);
    public HashSet<string> Sendable = new(StringComparer.Ordinal), Deliberate = new(StringComparer.Ordinal), Unplaced = new(StringComparer.Ordinal),
      ByHand = new(StringComparer.Ordinal);
    public Dictionary<string, Binned> Bin = new(StringComparer.Ordinal);
    public int Skipped;
    public Held Copy() => Decode(Encode());

    // ---- one sealed JSON, each entry read on its own (a damaged entry is skipped, never the whole holding) ----
    private static CloudJson Item(CloudDeleteItem i) => CloudJson.Obj(("id", CloudJson.From(i.Id)), ("kind", CloudJson.From(i.Kind)), ("name", CloudJson.From(i.Name)),
      ("place", i.Place is { } p ? CloudJson.From(p) : null));
    private static CloudDeleteItem Item(CloudJson v) => v is CloudJson.Object o
      ? new(CloudFields.Text(o, "id"), CloudFields.Text(o, "kind"), CloudFields.Text(o, "name"), CloudFields.OptionalText(o, "place")) : throw new CloudFailure("invalid_request");
    private static CloudJson Actor(CloudDeleteActor a) => CloudJson.Obj(("by", CloudJson.From(CloudDeleteText.Raw(a.By))), ("mac", CloudJson.From(a.Mac)),
      ("macName", CloudJson.From(a.MacName)), ("session", a.Session is { } s ? CloudJson.From(s) : null), ("agent", a.Agent is { } g ? CloudJson.From(g) : null),
      ("at", CloudJson.From(a.At)), ("group", CloudJson.From(a.Group)));
    private static CloudDeleteActor Actor(CloudJson v) => v is CloudJson.Object o && CloudDeleteText.By(o["by"]?.AsString) is { } by
      ? new(by, CloudFields.Text(o, "mac"), CloudFields.Text(o, "macName"), CloudFields.OptionalText(o, "session"), CloudFields.OptionalText(o, "agent"),
        CloudFields.Integer(o, "at"), CloudFields.Text(o, "group")) : throw new CloudFailure("invalid_request");
    private static CloudJson Map<T>(Dictionary<string, T> map, Func<T, CloudJson> write) =>
      CloudJson.Obj(map.OrderBy(m => m.Key, StringComparer.Ordinal).Select(m => (m.Key, (CloudJson?)write(m.Value))).ToArray());
    private static CloudJson Set(HashSet<string> set) => CloudJson.Arr(set.Order(StringComparer.Ordinal).Select(s => CloudJson.From(s)));
    public byte[] Encode() => CloudCanonical.Encode(CloudJson.Obj(
      ("history", Map(History, l => CloudJson.Arr(l.Select(v => (CloudJson)CloudJson.Obj(("version", CloudJson.From(v.Id)),
        ("digest", v.Digest is { } d ? CloudJson.From(d) : null), ("fileMark", v.FileMark is { } f ? CloudJson.From(f) : null)))))),
      ("wireHeads", Map(WireHeads, CloudJson.From)),
      ("safety", Map(Safety, s => CloudJson.Obj(("record", s.Record.ToJson()), ("at", CloudJson.From(s.At))))),
      ("newest", Map(Newest, r => r.ToJson())), ("removals", Map(Removals, r => r.ToJson())), ("republications", Map(Republications, CloudJson.From)),
      ("localRemovals", Map(LocalRemovals, s => CloudJson.From(CloudDeleteText.Raw(s)))),
      ("sendable", Set(Sendable)), ("deliberate", Set(Deliberate)), ("unplaced", Set(Unplaced)), ("byHand", Set(ByHand)),
      ("bin", Map(Bin, b => CloudJson.Obj(("item", Item(b.Item)), ("actor", Actor(b.Actor)), ("record", b.Record.ToJson()), ("until", CloudJson.From(b.Until)),
        ("binnedAt", b.BinnedAt is { } at ? CloudJson.From(at) : null))))));
    public static Held Decode(byte[] bytes)
    {
      var o = CloudJson.Parse(bytes) as CloudJson.Object ?? throw new CloudFailure("unsupported_format");
      var held = new Held();
      void Read<T>(string key, Dictionary<string, T> into, Func<CloudJson, T> read)
      {
        if (o[key] is null) return;
        if (o[key] is not CloudJson.Object m) { held.Skipped++; return; }
        foreach (var (k, v) in m.Members) { try { into[k] = read(v); } catch (Exception) { held.Skipped++; } }
      }
      void Names(string key, HashSet<string> into)
      {
        if (o[key] is null) return;
        if (o[key] is not CloudJson.Array a || a.Items.Any(i => i.AsString is null)) { held.Skipped++; return; }
        foreach (var i in a.Items) into.Add(i.AsString!);
      }
      Read("history", held.History, v => ((CloudJson.Array)v).Items.Select(x => x is CloudJson.Object r
        ? new Version(CloudFields.Text(r, "version"), CloudFields.OptionalText(r, "digest"), CloudFields.OptionalText(r, "fileMark")) : throw new CloudFailure("x")).ToList());
      Read("wireHeads", held.WireHeads, v => v.AsString ?? throw new CloudFailure("x"));
      Read("safety", held.Safety, v => v is CloudJson.Object s && s["record"] is { } r ? new Safety(CloudSecretRecord.FromJson(r), CloudFields.Integer(s, "at")) : throw new CloudFailure("x"));
      Read("newest", held.Newest, CloudSecretRecord.FromJson);
      Read("removals", held.Removals, CloudSecretRemoval.FromJson);
      Read("republications", held.Republications, v => v.AsString ?? throw new CloudFailure("x"));
      Read("localRemovals", held.LocalRemovals, v => CloudDeleteText.Scope(v.AsString) ?? throw new CloudFailure("x"));
      Names("sendable", held.Sendable); Names("deliberate", held.Deliberate); Names("unplaced", held.Unplaced); Names("byHand", held.ByHand);
      Read("bin", held.Bin, v => v is CloudJson.Object b && b["item"] is { } i && b["actor"] is { } a && b["record"] is { } r
        ? new Binned(Item(i), Actor(a), CloudSecretRecord.FromJson(r), CloudFields.Integer(b, "until"), CloudFields.OptionalInteger(b, "binnedAt")) : throw new CloudFailure("x"));
      return held;
    }
  }

  private CloudSecretsStoreKeys? keys;
  private string? file;
  private Held held = new();
  private CloudDeleteState? state;
  public string? Notice { get; private set; }
  private bool problem;
  /// Tests only: makes the next sealed saves fail.
  internal bool FailSaves;

  public void Use(CloudSecretsStoreKeys? next)
  {
    if (next is null) { keys = null; file = null; held = new(); state = null; problem = false; Notice = null; return; }
    var slot = next.Shared(Encoding.UTF8.GetBytes("delete-rule\n" + source));
    var path = Path.Combine(root, slot + ".sealed");
    if (file == path && keys is not null) return;
    keys = next; file = path; held = new(); state = null; problem = false; Notice = null;
    try { Directory.CreateDirectory(root); } catch (Exception) { problem = true; return; }
    try
    {
      if (File.Exists(path))
      {
        held = Held.Decode(CloudSecretsLocalSeal.Open(File.ReadAllBytes(path), next.Local));
        if (held.Skipped > 0) Notice = BinDamaged;
      }
    }
    catch (Exception) { held = new(); SetAside(path); Notice = BinDamaged; }
    var statePath = Path.Combine(root, slot + ".state.json");
    try { state = new CloudDeleteState(new CloudFileSlot(statePath)); }
    catch (Exception)
    {
      SetAside(statePath); Notice = BinDamaged;
      try { state = new CloudDeleteState(new CloudFileSlot(statePath)); } catch (Exception) { problem = true; return; }
    }
    // An intent never outlives the action that wrote it: one left by a crash or a sign-out mid-delete is dropped here.
    foreach (var place in state.IntentPlaces()) { try { state.ClearIntent(place); } catch (Exception) { } }
  }
  private static void SetAside(string path)
  {
    try { if (File.Exists(path)) File.Move(path, path + ".unreadable-" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()); } catch (Exception) { }
  }
  /// Locked only when the saved-passwords key is not here; a Bin that could not be made at all is "unavailable".
  public void Ready()
  {
    if (keys is null || file is null) throw new CloudFailure("secrets_locked");
    if (problem || state is null) throw new CloudFailure("unavailable");
  }
  public bool Active => keys is not null;
  private CloudDeleteState State() { Ready(); return state!; }
  public void Save()
  {
    Ready();
    if (FailSaves) throw new CloudFailure("unavailable");
    var bytes = CloudSecretsLocalSeal.Seal(held.Encode(), keys!.Local);
    new CloudFileSlot(file!).Write(bytes);
    // Durably sealed and read back BEFORE a caller may remove or forget its live value.
    if (!File.ReadAllBytes(file!).AsSpan().SequenceEqual(bytes)) throw new CloudFailure("checksum_mismatch");
  }
  private string Fingerprint(CloudSecretRecord record) { Ready(); return keys!.Shared([.. "removed-version\n"u8, .. record.Canonical()]); }
  private static string? FileMark(CloudSecretRecord record) => record.Payload is CloudJson.Object o ? o["mark"]?.AsString : null;
  public string VersionOf(CloudSecretRecord record) =>
    held.Newest.TryGetValue(record.RecordId, out var n) && n.Same(record) && held.WireHeads.TryGetValue(record.RecordId, out var v) ? v : Fingerprint(record);

  public void Remember(CloudSecretRecord record)
  {
    Ready();
    var id = record.RecordId;
    if (held.Newest.TryGetValue(id, out var old) && old.Same(record)) return;
    if (old is not null)
    {
      var mark = new Version(VersionOf(old), Fingerprint(old), FileMark(old));
      var list = held.History.TryGetValue(id, out var l) ? l : held.History[id] = [];
      if (!list.Contains(mark)) list.Add(mark);
      if (FileMark(old) is not { } before || before != FileMark(record)) held.Deliberate.Remove(id);
    }
    held.Newest[id] = record;
    held.WireHeads.Remove(id);
    Save();
  }
  public void KeepSafety(CloudSecretRecord record, long at)
  {
    Ready();
    held.Safety[Fingerprint(record)] = new(record, at);
    foreach (var rows in held.Safety.GroupBy(s => s.Value.Record.RecordId).Where(g => g.Count() > SafetyPerItem))
      foreach (var row in rows.OrderByDescending(r => r.Value.At).Skip(SafetyPerItem).ToArray()) held.Safety.Remove(row.Key);
    if (held.Safety.Count > SafetyInAll)
      foreach (var row in held.Safety.OrderByDescending(r => r.Value.At).Skip(SafetyInAll).ToArray()) held.Safety.Remove(row.Key);
    Save();
  }
  public CloudSecretRecord? Newest(string id) => held.Newest.GetValueOrDefault(id);
  public IReadOnlyList<string> KnownIds() => held.Newest.Keys.Order(StringComparer.Ordinal).ToArray();
  public bool HasVersion(CloudSecretRecord record)
  {
    if (held.Newest.TryGetValue(record.RecordId, out var n) && n.Same(record)) return true;
    var value = Fingerprint(record);
    return held.History.TryGetValue(record.RecordId, out var list) && list.Any(v => (v.Digest ?? v.Id) == value);
  }
  /// Decision 6: a version id only for a deliberate Put back / Put in Cloud again; every other upload keeps the old form.
  public string? UploadVersion(CloudSecretRecord record)
  {
    if (!held.Deliberate.Contains(record.RecordId)) return null;
    Remember(record);
    if (!held.Deliberate.Contains(record.RecordId)) return null;
    if (held.WireHeads.TryGetValue(record.RecordId, out var version)) return version;
    version = CloudBytes.NewTransportId();
    held.WireHeads[record.RecordId] = version;
    Save();
    return version;
  }
  public void MarkDeliberate(string id) { if (held.Deliberate.Add(id)) Save(); }
  public bool EarlierVersion(string id, string version) =>
    held.WireHeads.GetValueOrDefault(id) != version && held.History.TryGetValue(id, out var list) && list.Any(v => v.Id == version);
  public bool NewVersion(string id, string version) => held.WireHeads.GetValueOrDefault(id) != version;
  public void AdoptVersion(CloudSecretRecord record, string version)
  {
    Remember(record);
    if (held.WireHeads.TryGetValue(record.RecordId, out var old) && old != version)
      (held.History.TryGetValue(record.RecordId, out var l) ? l : held.History[record.RecordId] = []).Add(new(old, Fingerprint(record), FileMark(record)));
    held.WireHeads[record.RecordId] = version;
    Save();
  }
  /// A leaked password must go everywhere: the removal applies whenever the CURRENT value equals the removed one.
  public bool Matches(CloudSecretRecord record, CloudSecretRemoval removal)
  {
    if (held.Newest.TryGetValue(record.RecordId, out var n) && n.Same(record) && held.WireHeads.TryGetValue(record.RecordId, out var v) && v == removal.Version) return true;
    var digest = Fingerprint(record);
    return removal.Version == digest || removal.RemovedDigest == digest;
  }
  public CloudDeleteMark? Mark(string id) => State().Mark(id);
  public void PutMark(string id, CloudLocalMark mark, long at) => State().PutMark(new(id, mark, at));
  public void ClearMark(string id) => State().ClearMark(id);
  public CloudDeleteIntent? Intent(string id) => State().Intent(id);
  public void KeepHandMark(string id) { if (held.ByHand.Add(id)) Save(); }

  /// The Bin row and the removal are saved (sealed) first; the intent LAST, only after that save succeeded.
  public CloudSecretRemoval Prepare(CloudSecretRecord record, CloudDeleteItem item, CloudDeleteScope scope, CloudDeleteActor actor, bool travel = true, long? binnedAt = null)
  {
    Ready();
    if (!CloudDeleteText.IsUuid(actor.Group) || actor.At <= 0 || actor.At > LatestAt) throw new CloudDeleteRuleException(CloudDeleteRuleException.InvalidState);
    var intent = actor.Intent(record.RecordId, scope);
    var before = held.Copy();
    var fields = new Dictionary<string, string>(StringComparer.Ordinal);
    CloudDeleteTravel.Write(intent, fields);
    var removal = new CloudSecretRemoval(record.SourceId, record.RecordId, record.Domain, VersionOf(record), fields, actor.Mac, actor.MacName, actor.At, record, Fingerprint(record));
    held.Republications.Remove(record.RecordId);
    held.Deliberate.Remove(record.RecordId);
    held.Removals[record.RecordId] = removal;
    if (travel) held.Sendable.Add(record.RecordId); else held.Sendable.Remove(record.RecordId);
    held.Bin[BinKey(actor.Group, record.RecordId)] = new(item, actor, record, actor.At + CloudBinGroup.RetentionMilliseconds, binnedAt);
    try { Save(); } catch (Exception) { held = before; throw; }
    try { State().PutIntent(intent); } catch (Exception) { held = before; try { Save(); } catch (Exception) { } throw; }
    return removal;
  }
  /// The intent is cleared whatever happens here. When this cannot complete, the Bin copy stays, but the removal neither
  /// travels nor counts as done on this PC.
  public void Finish(CloudSecretRemoval removal, bool unplaced = false)
  {
    var id = removal.RecordId;
    try
    {
      var before = held.Copy();
      held.Removals[id] = removal;
      var cloud = removal.Fields.GetValueOrDefault(CloudDeleteTravel.Scope) == "cloud";
      held.LocalRemovals[id] = cloud ? CloudDeleteScope.Cloud : CloudDeleteScope.Everywhere;
      if (unplaced && !cloud) held.Unplaced.Add(id); else held.Unplaced.Remove(id);
      try
      {
        Save();
        PutMark(id, cloud ? CloudLocalMark.OnlyOnThisPc : CloudLocalMark.NotOnThisPc, removal.At);
      }
      catch (Exception)
      {
        held = before; held.Sendable.Remove(id); try { Save(); } catch (Exception) { }
        throw;
      }
    }
    finally { try { State().ClearIntent(id); } catch (Exception) { } }
  }
  public sealed record Undo(string Id, Held Before);
  public Undo UndoFor(string id) => new(id, held.Copy());
  /// The intent goes FIRST, whether or not the rest can be saved.
  public void Cancel(Undo undo)
  {
    try { State().ClearIntent(undo.Id); } catch (Exception) { }
    held = undo.Before;
    Save();
  }
  public IReadOnlyList<CloudSecretRemoval> Pending()
  {
    Ready();
    return held.Removals.Values.Where(r => held.Sendable.Contains(r.RecordId) && held.LocalRemovals.ContainsKey(r.RecordId) && State().Intent(r.RecordId) is null).ToArray();
  }
  public bool IsDeleted(string id) => held.LocalRemovals.TryGetValue(id, out var s) && s == CloudDeleteScope.Everywhere;
  // Project secret files (lane S3, the Mac's fileMarks / isUnplaced / placedUnplaced).
  public bool IsUnplaced(string id) => held.Unplaced.Contains(id);
  /// The file of an unplaced removal went into the Bin after all: from now on it counts as applied here.
  public void PlacedUnplaced(string id) { if (held.Unplaced.Remove(id)) Save(); }
  /// Every content mark this item had here (its history and its newest), for J-7 "old bytes came back".
  public IReadOnlyList<string> FileMarks(string id) =>
    [.. (held.History.GetValueOrDefault(id) ?? []).Select(v => v.FileMark).OfType<string>(), .. Newest(id) is { } n && FileMark(n) is { } m ? new[] { m } : []];
  public bool Superseded(CloudSecretRemoval removal) =>
    held.Republications.TryGetValue(removal.RecordId, out var g) && g == removal.Fields.GetValueOrDefault(CloudDeleteTravel.Group);
  public void Validate(CloudSecretRemoval removal)
  {
    if (removal.At <= 0 || removal.At > LatestAt) throw new CloudFailure("invalid_request");
    if (removal.Removed is { } removed && (removed.SourceId != removal.SourceId || removed.RecordId != removal.RecordId || removed.Domain != removal.Domain
      || Fingerprint(removed) != (removal.RemovedDigest ?? removal.Version))) throw new CloudFailure("invalid_request");
  }
  /// Decision 5: room in the Bin for one more copy that arrived only inside a removal.
  public bool RoomForCarried(CloudSecretRecord record)
  {
    if (held.Bin.Count >= CarriedRows) return false;
    long total = record.Canonical().Length;
    foreach (var row in held.Bin.Values) { total += row.Record.Canonical().Length; if (total > CarriedBytes) return false; }
    return true;
  }
  public string? Republication(string id) => held.Republications.GetValueOrDefault(id);
  public bool Reintroduces(string id, string group) => held.Removals.TryGetValue(id, out var r) && r.Fields.GetValueOrDefault(CloudDeleteTravel.Group) == group;
  /// Back in sync. `keepHandMark`: an arrival ended a removal that had covered his own by-hand mark, so that mark stays.
  public void Restored(string id, bool keepHandMark = true)
  {
    if (held.Removals.TryGetValue(id, out var removal) && removal.Fields.GetValueOrDefault(CloudDeleteTravel.Group) is { } group)
    {
      held.Republications[id] = group;
      if (held.Newest.TryGetValue(id, out var record) && held.WireHeads.TryGetValue(id, out var version))
      {
        (held.History.TryGetValue(id, out var l) ? l : held.History[id] = []).Add(new(version, Fingerprint(record), FileMark(record)));
        held.WireHeads.Remove(id);
      }
    }
    held.Removals.Remove(id); held.Sendable.Remove(id); held.LocalRemovals.Remove(id); held.Unplaced.Remove(id);
    var hand = held.ByHand.Remove(id);
    Save();
    try { State().ClearIntent(id); } catch (Exception) { }
    if (hand && keepHandMark) PutMark(id, CloudLocalMark.NotOnThisPc, Mark(id)?.At ?? 0);
    else ClearMark(id);
  }
  /// Live Bin rows after ageing (the SERVICE clock; null while unknown: nothing ages).
  public IReadOnlyList<Binned> Entries(long? now)
  {
    Expire(now);
    return held.Bin.Values.Where(b => State().Intent(b.Item.Id) is null).ToArray();
  }
  /// A row goes only when BOTH the removal's date and the date this PC put it in are 30 days old by the service clock.
  public void Expire(long? now)
  {
    Ready();
    if (now is not { } n || n <= 0) return;
    var filled = false;
    foreach (var (key, row) in held.Bin.ToArray()) if (row.BinnedAt is null) { held.Bin[key] = row with { BinnedAt = n }; filled = true; }
    var old = held.Bin.Where(b => b.Value.Until <= n && (b.Value.BinnedAt ?? n) <= n - CloudBinGroup.RetentionMilliseconds).Select(b => b.Key).ToHashSet(StringComparer.Ordinal);
    if (old.Count == 0) { if (filled) Save(); return; }
    Drop(old, safetyToo: false);
  }
  public IReadOnlyList<CloudBinGroup> Groups(long? now) => Entries(now).GroupBy(e => e.Actor.Group).Select(rows =>
  {
    var a = rows.First().Actor;
    return new CloudBinGroup(a.Group, a.By, a.MacName, a.Session, a.Agent, a.At, rows.Select(r => r.Item).OrderBy(i => i.Name, StringComparer.Ordinal).ToArray());
  }).OrderByDescending(g => g.At).ToArray();
  public void PutBackDone(string group, string id) { if (held.Bin.Remove(BinKey(group, id))) Save(); }
  public void ForgetBin(IReadOnlyList<CloudDeleteItem> items)
  {
    Ready();
    var ids = items.Select(i => i.Id).ToHashSet(StringComparer.Ordinal);
    Drop(held.Bin.Where(b => ids.Contains(b.Value.Item.Id)).Select(b => b.Key).ToHashSet(StringComparer.Ordinal), safetyToo: true);
  }
  private void Drop(HashSet<string> keysToDrop, bool safetyToo)
  {
    var gone = keysToDrop.Where(held.Bin.ContainsKey).Select(k => held.Bin[k]).ToArray();
    foreach (var key in keysToDrop) held.Bin.Remove(key);
    if (safetyToo)
    {
      var ids = gone.Select(g => g.Item.Id).ToHashSet(StringComparer.Ordinal);
      foreach (var row in held.Safety.Where(s => ids.Contains(s.Value.Record.RecordId)).ToArray()) held.Safety.Remove(row.Key);
    }
    foreach (var row in gone.Where(g => !held.Bin.Values.Any(b => b.Item.Id == g.Item.Id)))
    {
      var record = row.Record;
      // No second copy of a gone Bin row in the cached head.
      if (held.Newest.TryGetValue(record.RecordId, out var n) && n.Same(record) && Mark(record.RecordId)?.Mark == CloudLocalMark.NotOnThisPc) held.Newest.Remove(record.RecordId);
      if (held.Removals.TryGetValue(record.RecordId, out var removal)) held.Removals[record.RecordId] = removal.WithoutCopy();
    }
    Save();
  }
  public IReadOnlyList<CloudDeleteMark> Marks() => State().Marks();
  private static string BinKey(string group, string id) => group + "/" + id;
}

/// One travelling store under the delete rule (the Mac's BackendProjectSecretFilesSavedDeleteOwner). `remove` is the
/// owner's compare-and-remove: it must not remove a changed value. Tools get only CloudDeleteOwning's ordinary actions.
public sealed class CloudSecretsDeleteOwner : ICloudSecretsDeletingStore, ICloudDeleteOwning
{
  private readonly ICloudSecretsStore store;
  private readonly Func<CloudSecretRecord, Task<bool>> remove;
  private readonly Func<CloudSecretRecord, Task<CloudApplyStatus>> restore;
  private readonly Func<CloudSecretRecord, string> name;
  private readonly Func<bool> gate;
  private readonly Func<long> now;
  private readonly Func<string, string?> deviceName;
  private readonly Func<long?> serviceClock;
  private readonly Func<CloudSecretRecord, CloudSecretRecord, bool>? sameValue;
  private readonly CloudSecretsVanished? vanished;
  private readonly Dictionary<string, long> seenAt = new(StringComparer.Ordinal);
  private readonly SemaphoreSlim turn = new(1, 1);
  internal CloudSecretsKeeper Keeper { get; }
  public string SourceId => store.SourceId;
  public string InventoryRow => store.InventoryRow;
  public string Domain => store.Domain;

  /// `stateRoot`: this source's own state folder (its `sealed-bin` lives there). `gate`: the delete rule is open (every
  /// computer announced it). `deviceName(id)`: one of his devices by id, for Bin rows. `serviceClock`: null while unknown.
  public CloudSecretsDeleteOwner(ICloudSecretsStore store, string stateRoot, Func<bool> gate, Func<CloudSecretRecord, string> name,
    Func<CloudSecretRecord, Task<bool>> remove, Func<CloudSecretRecord, Task<CloudApplyStatus>>? restore = null, Func<string, string?>? deviceName = null,
    Func<long?>? serviceClock = null, Func<long>? now = null, Func<CloudSecretRecord, CloudSecretRecord, bool>? sameValue = null, CloudSecretsVanished? vanished = null)
  {
    this.store = store; this.gate = gate; this.name = name; this.remove = remove; this.restore = restore ?? store.MergeAsync;
    this.deviceName = deviceName ?? (_ => null); this.serviceClock = serviceClock ?? (() => null); this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.sameValue = sameValue; this.vanished = vanished;
    Keeper = new(Path.Combine(stateRoot, "sealed-bin"), store.SourceId);
  }

  public void UseKeys(CloudSecretsStoreKeys? keys)
  {
    Keeper.Use(keys);
    (store as ICloudSecretsKeyedStore)?.UseKeys(keys);
  }
  /// Whether "Everywhere" (and "Cloud") can be honoured now; pages hide both buttons when false.
  public Task<bool> CanDeleteEverywhereAsync()
  {
    if (!Keeper.Active) return Task.FromResult(false);
    try { Keeper.Ready(); } catch (CloudFailure) { return Task.FromResult(false); }
    return Task.FromResult(gate());
  }
  public string? BinNotice => Keeper.Notice;

  // Store/command refusals can echo input: only fixed errors cross this owner's boundary.
  private async Task<IReadOnlyList<CloudSecretRecord>> RawCaptureAsync() { try { return await store.CaptureAsync(); } catch (Exception) { throw new CloudFailure("unavailable"); } }
  private async Task<CloudApplyStatus> RawMergeAsync(CloudSecretRecord r) { try { return await store.MergeAsync(r); } catch (Exception) { throw new CloudFailure("unavailable"); } }
  private async Task RawValidateAsync(CloudSecretRecord r)
  {
    try { await store.ValidateAsync(r); }
    catch (CloudFailure f) when (f.Code == "secrets_locked") { throw; }
    catch (Exception) { throw new CloudFailure("invalid_request"); }
  }
  private async Task<bool> RawVerifyAsync(CloudSecretRecord r, CloudApplyStatus o) { try { return await store.VerifyAsync(r, o); } catch (Exception) { throw new CloudFailure("unavailable"); } }
  private async Task<CloudApplyStatus> RawRestoreAsync(CloudSecretRecord r) { try { return await restore(r); } catch (Exception) { throw new CloudFailure("unavailable"); } }
  private async Task<bool> RawRemoveAsync(CloudSecretRecord r) { try { return await remove(r); } catch (Exception) { throw new CloudFailure("unavailable"); } }
  /// One action at a time; a second one waits its turn (never fails as "busy").
  private async Task<IDisposable> EnterAsync()
  {
    await turn.WaitAsync();
    try { Keeper.Ready(); } catch (Exception) { turn.Release(); throw; }
    return new Done(turn);
  }
  private sealed class Done(SemaphoreSlim s) : IDisposable { public void Dispose() => s.Release(); }
  private CloudDeleteItem Item(CloudSecretRecord record) => new(record.RecordId, Domain == CloudSecretsDomains.Mcp ? "mcp-servers" : "saved-passwords", name(record), SourceId);

  public async Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync()
  {
    using var _ = await EnterAsync();
    IReadOnlyList<CloudSecretRecord> all; bool? fileFound = null;
    if (store is ICloudSecretsFileFound reader)
    {
      try { var read = await reader.CaptureReadAsync(); all = read.Records; fileFound = read.FileFound; }
      catch (Exception) { throw new CloudFailure("unavailable"); }
    }
    else all = await RawCaptureAsync();
    if (!Keeper.Active) throw new CloudFailure("secrets_locked");
    Keeper.Expire(serviceClock());
    var rows = new List<CloudSecretRecord>();
    foreach (var record in all)
    {
      if (Keeper.Mark(record.RecordId) is { } mark)
      {
        if (mark.Mark == CloudLocalMark.OnlyOnThisPc) continue;
        // A value this owner already knows is ALWAYS kept away; it comes back only by Put back or a NEW value.
        if (Keeper.HasVersion(record)) continue;
        Keeper.Restored(record.RecordId, keepHandMark: false);
      }
      Keeper.Remember(record); rows.Add(record);
    }
    await SettleVanishedAsync(all, fileFound);
    return rows;
  }
  /// Known items missing from this capture, never marked yet and not in the middle of an app delete.
  private async Task SettleVanishedAsync(IReadOnlyList<CloudSecretRecord> present, bool? fileFound)
  {
    var at = now();
    var here = present.Select(p => p.RecordId).ToHashSet(StringComparer.Ordinal);
    foreach (var id in here) seenAt[id] = at;
    if (vanished is not { JudgesAbsence: true }) return;
    if (fileFound == false) return;
    var gone = new List<(string Id, CloudSecretRecord Record)>();
    foreach (var id in Keeper.KnownIds().Where(i => !here.Contains(i)))
      if (Keeper.Mark(id) is null && !Keeper.IsDeleted(id) && Keeper.Intent(id) is null && Keeper.Newest(id) is { } record) gone.Add((id, record));
    // An empty list is his choice only when exactly ONE known item went; two or more at once = cannot tell.
    if (here.Count == 0 && (gone.Count >= 2 || fileFound is null)) return;
    foreach (var (id, record) in gone)
    {
      var who = CloudDeleteWitnessAnswer.CannotKnow;
      if (seenAt.Remove(id, out var since)) who = await vanished.WhoAsync(id, since, at);
      if (gate() && who is { Kind: CloudDeleteWitnessAnswer.Kinds.Ai, Session: { } session, Group: { } group } && CloudDeleteText.IsUuid(group)
        && vanished.Device is { Length: > 0 } device && serviceClock() is { } stamp)
      {
        var actor = new CloudDeleteActor(CloudDeleteBy.Ai, device, vanished.DeviceName, session, who.Agent, stamp, group);
        try { Keeper.Finish(Keeper.Prepare(record, Item(record), CloudDeleteScope.Everywhere, actor, true, stamp)); continue; } catch (Exception) { }
      }
      // His own hand (or nobody can tell): this PC only, the safe side; sync never brings it back here.
      Keeper.PutMark(id, CloudLocalMark.NotOnThisPc, at);
    }
  }
  /// The value this PC last took from or sent to Cloud for `id` (nil when none).
  public CloudSecretRecord? LastExchanged(string id) => Keeper.Newest(id);
  /// An id this PC no longer uses in Cloud leaves Cloud only (no Bin row: nothing of his went away). Called from
  /// inside this owner's own merge, so it takes no turn of its own.
  public void RetireFromCloud(string id)
  {
    if (!Keeper.Active || !gate() || vanished is null || Keeper.Newest(id) is not { } record || Keeper.Mark(id) is not null
      || vanished.Device is not { Length: > 0 } device || serviceClock() is not { } stamp) return;
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, device, vanished.DeviceName, null, null, stamp, CloudBytes.NewTransportId());
    try { Keeper.Finish(Keeper.Prepare(record, Item(record), CloudDeleteScope.Cloud, actor, true, stamp)); Keeper.ForgetBin([Item(record)]); } catch (Exception) { }
  }
  public Task ValidateAsync(CloudSecretRecord record) => RawValidateAsync(record);
  public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
  {
    using var _ = await EnterAsync();
    return await MergeLockedAsync(record);
  }
  private async Task<CloudApplyStatus> MergeLockedAsync(CloudSecretRecord record)
  {
    var mark = Keeper.Mark(record.RecordId);
    // A cloud-only tombstone is superseded only by a new put; record equality alone never supersedes it.
    if (mark?.Mark == CloudLocalMark.NotOnThisPc && !Keeper.IsDeleted(record.RecordId)) { Keeper.Remember(record); return CloudApplyStatus.AlreadyPresent; }
    if (mark is not null && Keeper.HasVersion(record)) return CloudApplyStatus.AlreadyPresent;
    var outcome = await RawMergeAsync(record);
    if (!Keeper.Active) throw new CloudFailure("secrets_locked");
    if (outcome != CloudApplyStatus.KeptBoth) { Keeper.Remember(record); Keeper.Restored(record.RecordId); }
    return outcome;
  }
  public async Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
  {
    if (Keeper.Mark(record.RecordId) is not null) return true;
    if (outcome == CloudApplyStatus.AlreadyPresent && Keeper.HasVersion(record)) return true;
    return await RawVerifyAsync(record, outcome);
  }
  public Task<string?> VersionForUploadAsync(CloudSecretRecord record)
  {
    Keeper.Ready();
    return Task.FromResult(gate() ? Keeper.UploadVersion(record) : null);
  }
  public async Task<CloudApplyStatus> MergeVersionedAsync(CloudSecretRecord record, string version, string? removalGroup)
  {
    using var _ = await EnterAsync();
    if (!CloudDeleteText.IsUuid(version)) throw new CloudFailure("invalid_request");
    if (Keeper.EarlierVersion(record.RecordId, version)) return CloudApplyStatus.AlreadyPresent;
    if (Keeper.NewVersion(record.RecordId, version) && Keeper.Mark(record.RecordId) is { } mark && (mark.Mark == CloudLocalMark.OnlyOnThisPc || Keeper.IsDeleted(record.RecordId)))
      Keeper.Restored(record.RecordId);
    if (removalGroup is { } group && Keeper.Reintroduces(record.RecordId, group)) Keeper.Restored(record.RecordId);
    var outcome = await MergeLockedAsync(record);
    if (outcome != CloudApplyStatus.KeptBoth) Keeper.AdoptVersion(record, version);
    return outcome;
  }
  public Task<string?> RepublicationAsync(string recordId) { Keeper.Ready(); return Task.FromResult(gate() ? Keeper.Republication(recordId) : null); }
  public Task<IReadOnlyList<CloudSecretRemoval>> CaptureRemovalsAsync() => Task.FromResult(gate() ? Keeper.Pending() : (IReadOnlyList<CloudSecretRemoval>)[]);
  public async Task ValidateRemovalAsync(CloudSecretRemoval removal)
  {
    Keeper.Ready();
    if (removal.SourceId != SourceId || removal.Domain != Domain || !(removal.Version.Length == 64 || CloudDeleteText.IsUuid(removal.Version)) || removal.RecordId.Length == 0
      || removal.At <= 0 || removal.At > CloudSecretsKeeper.LatestAt
      || CloudDeleteTravel.Read(removal.Fields, removal.RecordId, removal.Mac, removal.At).Intent is null) throw new CloudFailure("invalid_request");
    Keeper.Validate(removal);
    if (removal.Removed is { } removed) await RawValidateAsync(removed);
  }
  public async Task<CloudApplyStatus> MergeRemovalAsync(CloudSecretRemoval removal)
  {
    using var _ = await EnterAsync();
    await ValidateRemovalAsync(removal);
    if (Keeper.Superseded(removal)) return CloudApplyStatus.AlreadyPresent;
    var intent = CloudDeleteTravel.Read(removal.Fields, removal.RecordId, removal.Mac, removal.At).Intent ?? throw new CloudFailure("invalid_request");
    var found = (await RawCaptureAsync()).FirstOrDefault(r => r.RecordId == removal.RecordId);
    if (!Keeper.Active) throw new CloudFailure("secrets_locked");
    if ((found ?? removal.Removed) is not { } localValue) return CloudApplyStatus.AlreadyPresent;
    if (!Keeper.Matches(localValue, removal) && !(removal.Removed is { } removedValue && sameValue?.Invoke(localValue, removedValue) == true)) return CloudApplyStatus.KeptBoth;
    // A copy that never was on this PC fills only a bounded part of the Bin.
    if (found is null && !Keeper.RoomForCarried(localValue)) return CloudApplyStatus.KeptBoth;
    var actor = new CloudDeleteActor(intent.By, intent.Mac, deviceName(intent.Mac) ?? "another device", intent.Session, intent.Agent, intent.At, intent.Group);
    Keeper.Remember(localValue);
    var undo = Keeper.UndoFor(localValue.RecordId);
    Keeper.Prepare(localValue, Item(localValue), intent.Scope, actor, travel: false, binnedAt: serviceClock());
    if (intent.Scope == CloudDeleteScope.Everywhere && found is not null)
    {
      // Compare-and-remove by the owner's own writer. Changed meanwhile or refused: his value stays, the removal is
      // closed as not applied, and nothing of it is left behind.
      bool removed;
      try { removed = await RawRemoveAsync(localValue); } catch (Exception) { removed = false; }
      if (!removed) { try { Keeper.Cancel(undo); } catch (Exception) { } return CloudApplyStatus.KeptBoth; }
    }
    if (!Keeper.Active) throw new CloudFailure("secrets_locked");
    Keeper.Finish(removal, unplaced: intent.Scope == CloudDeleteScope.Everywhere && found is null);
    return CloudApplyStatus.Applied;
  }
  public Task<bool> VerifyRemovalAsync(CloudSecretRemoval removal, CloudApplyStatus outcome) =>
    Task.FromResult(outcome != CloudApplyStatus.Applied || Keeper.Mark(removal.RecordId) is not null);

  // ---- the person's (and an AI tool's) ordinary actions ----

  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    using var _ = await EnterAsync();
    // While an older device exists, neither "Everywhere" nor "Cloud" can be honoured for these kinds.
    if (!gate()) throw new CloudFailure("gate_closed");
    var records = await RawCaptureAsync();
    if (!Keeper.Active) throw new CloudFailure("secrets_locked");
    var done = new List<CloudDeleteItem>();
    foreach (var wanted in items)
    {
      if (records.FirstOrDefault(r => r.RecordId == wanted.Id) is not { } record || wanted.Kind != Item(record).Kind) throw new CloudFailure("invalid_request");
      Keeper.Remember(record);
      var undo = Keeper.UndoFor(record.RecordId);
      var removal = Keeper.Prepare(record, Item(record), scope, by, true, serviceClock());
      if (scope == CloudDeleteScope.Everywhere)
      {
        bool removed;
        try { removed = await RawRemoveAsync(record); } catch (Exception) { try { Keeper.Cancel(undo); } catch (Exception) { } throw; }
        if (!removed) { try { Keeper.Cancel(undo); } catch (Exception) { } throw new CloudFailure("version_changed"); }
      }
      if (!Keeper.Active) throw new CloudFailure("secrets_locked");
      Keeper.Finish(removal); done.Add(Item(record));
    }
    return new(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, done);
  }
  /// Names for ordinary page rows. Never a Bin row or a saved value.
  public async Task<IReadOnlyList<CloudDeleteItem>> ItemsAsync() { Keeper.Ready(); return (await RawCaptureAsync()).Select(Item).ToArray(); }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>(Keeper.Marks()
    .Where(m => !Keeper.IsDeleted(m.Place) && Keeper.Newest(m.Place) is not null).Select(m => new CloudNotHereItem(Item(Keeper.Newest(m.Place)!), m.Mark, m.At)).ToArray());
  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    using var _ = await EnterAsync();
    var done = new List<CloudDeleteItem>();
    foreach (var wanted in items)
    {
      if (Keeper.IsDeleted(wanted.Id)) throw new CloudFailure("invalid_request");
      if (Keeper.Newest(wanted.Id) is not { } record) continue;
      if (to == CloudBringBackDestination.ThisPc)
      {
        var outcome = await RawRestoreAsync(record);
        if (outcome == CloudApplyStatus.KeptBoth || !await RawVerifyAsync(record, outcome)) throw new CloudFailure("version_changed");
      }
      if (!Keeper.Active) throw new CloudFailure("secrets_locked");
      Keeper.Restored(wanted.Id, keepHandMark: false);
      if (to == CloudBringBackDestination.Cloud) Keeper.MarkDeliberate(wanted.Id);
      done.Add(Item(record));
    }
    return done;
  }
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => Task.FromResult(Keeper.Groups(serviceClock()));
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
  {
    using var _ = await EnterAsync();
    var done = new List<CloudDeleteItem>();
    foreach (var entry in Keeper.Entries(serviceClock()).Where(e => e.Actor.Group == group))
    {
      // The owner's own writer and its own arrival rules decide (the same as any arriving value).
      CloudApplyStatus outcome;
      try { outcome = await RawRestoreAsync(entry.Record); } catch (Exception) { continue; }
      if (!Keeper.Active) throw new CloudFailure("secrets_locked");
      if (outcome == CloudApplyStatus.KeptBoth || !await RawVerifyAsync(entry.Record, outcome)) continue;
      Keeper.Remember(entry.Record); Keeper.Restored(entry.Item.Id, keepHandMark: false);
      Keeper.MarkDeliberate(entry.Item.Id);
      Keeper.PutBackDone(group, entry.Item.Id);
      done.Add(entry.Item);
    }
    return done;
  }
  public async Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    using var _ = await EnterAsync();
    Keeper.ForgetBin(items);
  }
}
