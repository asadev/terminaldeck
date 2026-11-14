using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Deck Memory travelling on Windows (7C-1). Windows has no Deck Memory screen yet, so what arrives is kept in this PC's
// own memory copy for the signed-in account (FileDeckMemoryStore: the notes as files, the labels as tables) and
// nothing on Windows reads it yet. Record shapes, ids, stamps and the merge rule are the Mac's (CloudMemoryFormat.cs).
//
// The rules, read from the Mac (td-mac-next, 14 Nov) and kept here on purpose:
// - Order: this PC's own records go first, then the feed in order; one kind per pack, exact order within a kind.
// - Never sent: `meta`, every memory setting outside the shared allow-list, the board and its history (I03, this
//   device's live status), local database backups, hidden files and folders, links, the app's own help files, and a
//   file whose text is a removal marker (only the Mac's removal path may make one).
// - First sync (rule J): a value this PC had before it ever held the Cloud's version travels as a BASELINE and loses
//   to the Cloud's version on every device; the Cloud's version is shown here and this PC's own is kept and listed.
//   A fresh PC's empty memory sends nothing at all: empty is "nothing yet", never "everything removed".
// - Two different texts of one file: the newer revision by the Cloud's order is used; the other text is kept, outside
//   the memory folder (it never travels), and listed. Never a second live copy beside the file.
// - Removals do NOT travel from Windows yet, and nothing is ever deleted by sync here: a removed setting or a removal
//   marker arriving from a Mac leaves this PC's copy in place and is listed.

/// One row of a memory table, cells in the table's column order (DeckMemoryCloudSchema).
public sealed record DeckMemoryRow(string Table, IReadOnlyList<DeckMemoryCell> Cells)
{
  public bool Same(DeckMemoryRow other) => Table == other.Table && Cells.SequenceEqual(other.Cells);
}

/// A file in the memory folder: '/'-separated relative path, size and last write time (ticks, any fixed origin).
public sealed record DeckMemoryFileInfo(string Path, long Length, long ModifiedTicks);

/// What a Deck Memory store gives Cloud. There is deliberately no way to remove a row or a file through it: sync on
/// Windows never deletes. Every write here comes from Cloud's apply and is recognised as such by content.
public interface IDeckMemoryCloudStore
{
  /// A stable random id for this memory store (a UUID made once, kept with the memory).
  string StoreId { get; }
  /// Every row of one table now (tables and columns as DeckMemoryCloudSchema; `meta` may be empty).
  IReadOnlyList<DeckMemoryRow> Rows(string table);
  /// The row whose key columns equal `keys`, or null.
  DeckMemoryRow? Find(string table, IReadOnlyList<DeckMemoryCell> keys);
  /// The first row whose `column` equals `value`, or null.
  DeckMemoryRow? FindWhere(string table, string column, DeckMemoryCell value);
  /// Insert, or replace the row whose key columns equal `replacing` (null: insert).
  void PutRow(DeckMemoryRow row, IReadOnlyList<DeckMemoryCell>? replacing);
  /// A fresh integer id for an integer-keyed table (diary, board_history, rewinds, questions), never reused.
  long AllocateInteger(string table);
  /// Every regular file under the memory folder (hidden names and links are not listed).
  IReadOnlyList<DeckMemoryFileInfo> ListFiles();
  /// The file's bytes, or null when it is not there.
  byte[]? ReadFile(string path);
  void WriteFile(string path, byte[] bytes);
  /// Makes every row written so far durable (files are durable when WriteFile returns).
  void Flush();
}

/// Where the text that is not in use goes (the other side of two different texts of one file). Outside the memory
/// folder, so it never travels and no AI reads it as memory. Returns where it was kept, for the page.
public interface ICloudMemoryKeeper
{
  string Keep(string path, byte[] bytes, string device, long at);
}

/// A value this PC does not show because the other one won (or a removal it did not apply): listed, never lost.
public sealed record CloudMemoryOtherVersion(string Key, string Table, string Version, string Device, long Stamp, string Value, string Why);

/// The capture and apply sides for Deck Memory (inventory rows I01..I06), one adapter for all six kinds.
public sealed class CloudMemoryAdapter : ICloudSyncAdapter
{
  /// MAC-NEXT-8: the board and its history are a device's live status; never sent, and an arrival is acknowledged
  /// and ignored (not placed, not kept, not waiting).
  public const string LocalOnlyRow = "I03";
  public const string KeptRemovalWhy = "removed on another device; this PC keeps its copy (removals do not travel to Windows yet)";
  private readonly IDeckMemoryCloudStore memory;
  private readonly ICloudLedgerSlot slot;
  private readonly ICloudMemoryKeeper keeper;
  private readonly string deviceId;
  private readonly Func<long> localNow;
  private readonly Func<string, string, string?>? projects;
  private readonly HashSet<string> rows;
  private State state;
  private bool dirty;

  /// `enabledRows`: the inventory rows switched on for this account (null: all). `projects(projectId, originStore)`:
  /// this PC's project for another device's project-scoped memory (7C-2's project list), null while not matched (waits).
  public CloudMemoryAdapter(IDeckMemoryCloudStore memory, ICloudLedgerSlot slot, string deviceId, IEnumerable<string>? enabledRows = null,
    Func<string, string, string?>? projects = null, Func<long>? localNow = null, ICloudMemoryKeeper? keeper = null)
  {
    CloudBytes.TransportId(deviceId);
    if (!Guid.TryParse(memory.StoreId, out _)) throw new CloudFailure("invalid_request");
    this.memory = memory; this.slot = slot; this.deviceId = deviceId; this.projects = projects;
    this.localNow = localNow ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.keeper = keeper ?? new CloudMemoryKeptInMemory();
    rows = (enabledRows ?? CloudMemoryFormat.InventoryRows).ToHashSet();
    if (rows.Any(r => !CloudMemoryFormat.InventoryRows.Contains(r))) throw new CloudFailure("invalid_request");
    rows.Remove(LocalOnlyRow);
    state = slot.Read() is { } bytes ? JsonSerializer.Deserialize<State>(bytes) ?? new State() : new State();
  }

  /// The six memory kinds. The board's kind is taken only to acknowledge and ignore what an older device sends.
  public IReadOnlyCollection<string> Domains => rows.Append(LocalOnlyRow).Distinct().Select(CloudMemoryFormat.Domain).ToArray();
  public IReadOnlyList<CloudMemoryOtherVersion> OtherVersions => state.Others.ToArray();
  public int WaitingCount => state.Versions.Values.Count(v => v.Waiting is not null);

  /// The memory store for one signed-in account on this PC: `<account folder>/memory` (notes and tables),
  /// `<account folder>/sync/memory.json` (this adapter's bookkeeping), `<account folder>/kept/memory` (kept texts).
  /// Per account, so signing in with another account never sends one account's memory into the other.
  public static CloudMemoryAdapter ForAccount(string accountFolder, string deviceId, Func<string, string, string?>? projects = null) =>
    new(FileDeckMemoryStore.At(Path.Combine(accountFolder, "memory")), new CloudFileSlot(Path.Combine(accountFolder, "sync", "memory.json")), deviceId,
      projects: projects, keeper: new CloudMemoryKeptFolder(Path.Combine(accountFolder, "kept", "memory")));

  // ---- Durable bookkeeping (beside the sync store, one atomic file) ----

  private sealed class Head { public string Hash { get; set; } = ""; public string Version { get; set; } = ""; public List<string> Parents { get; set; } = []; public string? Base { get; set; } }
  private sealed class Version
  {
    public string StoreId { get; set; } = ""; public string Key { get; set; } = ""; public string Id { get; set; } = ""; public string Row { get; set; } = "";
    public string Hash { get; set; } = ""; public List<string> Parents { get; set; } = []; public long Stamp { get; set; } public bool Baseline { get; set; }
    public bool Own { get; set; } public string? FirstOp { get; set; } public Dictionary<int, string> PartOps { get; set; } = []; public int Count { get; set; }
    public Dictionary<int, string> Parts { get; set; } = []; public string? Body { get; set; } public string? Projection { get; set; }
    public string? Waiting { get; set; } public bool Done { get; set; } public string Device { get; set; } = "";
  }
  private sealed class Origin { public string StoreId { get; set; } = ""; public string Key { get; set; } = ""; public string Version { get; set; } = ""; public string Keys { get; set; } = ""; }
  private sealed class State
  {
    public Dictionary<string, Head> Heads { get; set; } = [];
    public Dictionary<string, Version> Versions { get; set; } = [];
    public Dictionary<string, Origin> Origins { get; set; } = [];
    public Dictionary<string, Origin> FileOrigins { get; set; } = [];
    /// path → "length:ticks:hash" of the last read, so an unchanged file is not read again.
    public Dictionary<string, string> FileStamps { get; set; } = [];
    public Dictionary<string, string> Ids { get; set; } = [];
    public List<CloudMemoryOtherVersion> Others { get; set; } = [];
    public HashSet<string> Applied { get; set; } = [];
    public List<string> Pending { get; set; } = [];
    /// The whole feed was read once: before that nothing of this PC is captured (its first copy waits for the Cloud's).
    public bool FeedRead { get; set; }
  }
  private void Save() { slot.Write(JsonSerializer.SerializeToUtf8Bytes(state)); dirty = false; }
  private static string V(string storeId, string key, string version) => storeId + "\n" + key + "\n" + version;

  // Versions by resource key, rebuilt whenever the state object changes (capture swaps it).
  private State? indexed;
  private Dictionary<string, List<Version>> byKey = new(StringComparer.Ordinal);
  private List<Version> VersionsOf(string key)
  {
    if (!ReferenceEquals(indexed, state))
    {
      byKey = new(StringComparer.Ordinal);
      foreach (var v in state.Versions.Values) (byKey.TryGetValue(v.Key, out var l) ? l : byKey[v.Key] = []).Add(v);
      indexed = state;
    }
    return byKey.TryGetValue(key, out var list) ? list : [];
  }
  private void Put(string vk, Version v)
  {
    var list = VersionsOf(v.Key);
    if (state.Versions.TryGetValue(vk, out var old)) list.Remove(old);
    state.Versions[vk] = v;
    if (!byKey.ContainsKey(v.Key)) byKey[v.Key] = list;
    list.Add(v);
  }
  private Version? Find(string key, string version) => VersionsOf(key).FirstOrDefault(v => v.Id == version);

  /// Called by the engine once a pack's records are applied, before it counts them as applied: the memory's rows,
  /// then this bookkeeping, are made durable once per pack (not once per record).
  public Task SettleAsync(CancellationToken ct)
  {
    if (!dirty) return Task.CompletedTask;
    memory.Flush();
    Save();
    return Task.CompletedTask;
  }

  /// The Mac's rule (hand-back 4): a device never cuts its first copy before it has taken in what the devices it
  /// trusts already saved, so a value the Cloud already holds goes out as a baseline and loses (rule J) instead of
  /// winning by its fresh stamp. Until the engine read the whole feed once, capture takes nothing.
  public bool FeedRead()
  {
    if (state.FeedRead) return false;
    state.FeedRead = true;
    memory.Flush();
    Save();
    return true;
  }

  // ---- Capture ----

  private sealed record Resource(string Row, string StoreId, string Key, byte[] Data, string Hash, string? Base, DeckMemoryRow? Physical, string? Path);

  /// Compares what the memory holds now with what this PC last published, and makes a new version of every resource
  /// that changed: rows of the enabled tables (shared settings only; `meta` never) and memory-folder files. Never a
  /// removal. Stamped once, here, on the service clock. Deterministic ids: a capture repeated after a crash makes the
  /// same records.
  public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    if (!state.FeedRead) return Task.FromResult(CloudCapture.None);
    var before = JsonSerializer.SerializeToUtf8Bytes(state);
    var operations = new List<CloudOperation>();
    foreach (var pending in state.Pending) operations.Add(CloudOperation.FromJson(CloudJson.Parse(pending)));
    foreach (var t in DeckMemoryCloudSchema.Tables.Where(t => rows.Contains(t.Row) && t.Name != "meta"))
      foreach (var row in memory.Rows(t.Name))
      {
        ct.ThrowIfCancellationRequested();
        if (row.Cells.Count != t.Columns.Count) throw new CloudFailure("unsupported_format");
        if (DeckMemoryCloudSchema.IsMachineLocal(t, row.Cells)) continue;
        // A shared setting with no value is a removal; removals do not travel from Windows.
        if (DeckMemoryCloudSchema.IsSettingTombstone(t, row.Cells)) continue;
        // "This device understands removal records" is never claimed by Windows.
        if (t.Name == "settings" && row.Cells[t.Index("key")].Value is { } key && key.StartsWith(DeckMemoryCloudSchema.SharedSettingPrefix, StringComparison.Ordinal)) continue;
        operations.AddRange(Export(Logical(t, row), stampNow));
      }
    foreach (var file in memory.ListFiles().OrderBy(f => f.Path, StringComparer.Ordinal))
    {
      ct.ThrowIfCancellationRequested();
      if (FileResource(file) is { } resource) operations.AddRange(Export(resource, stampNow));
    }
    var committed = state;
    state = JsonSerializer.Deserialize<State>(before)!;
    var staged = committed;
    return Task.FromResult(new CloudCapture(operations, () => { state = staged; state.Pending.Clear(); Save(); }));
  }

  /// A memory-folder file as it travels, or null when it never travels or did not change since it was last read and
  /// published. The bytes are read only when the size or time changed.
  private Resource? FileResource(DeckMemoryFileInfo file)
  {
    var path = file.Path;
    if (DeckMemoryCloudSchema.AppHelpFiles.Contains(path) || !DeckMemoryCloudSchema.SafePath(path)) return null;
    var origin = state.FileOrigins.GetValueOrDefault(path);
    var row = DeckMemoryCloudSchema.FileRow(origin is null ? path : origin.Key[5..]);
    if (row is null || !rows.Contains(row)) return null;
    var storeId = origin?.StoreId ?? memory.StoreId;
    var key = origin?.Key ?? "file/" + path;
    var stamp = file.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + file.ModifiedTicks.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":";
    var head = state.Heads.GetValueOrDefault(storeId + ":" + key);
    if (state.FileStamps.TryGetValue(path, out var known) && known.StartsWith(stamp, StringComparison.Ordinal) && head?.Hash == known[stamp.Length..]) return null;
    if (memory.ReadFile(path) is not { } bytes) return null;
    var hash = CloudMemoryFormat.Hash(bytes);
    state.FileStamps[path] = stamp + hash;
    if (head?.Hash == hash) return null;
    // Removal-marker text written into a file (by a script, an AI in a terminal) is never sent as an edit.
    if (CloudMemoryFormat.IsRemovalMarker(bytes)) return null;
    return new Resource(row, storeId, key, bytes, hash, origin?.Version, null, path);
  }

  /// A row as it travels (DeckMemoryStoreCloudOrigins.cloudLogicalRow): a row that came from another store keeps
  /// that store's identity, original keys and version; references name their target's ORIGINAL identity.
  private Resource Logical(DeckMemoryTable t, DeckMemoryRow row)
  {
    var values = row.Cells.ToArray();
    var logical = row.Cells.ToArray();
    var origin = state.Origins.GetValueOrDefault(t.Name + "\n" + CloudMemoryFormat.NativeKey(t, values));
    if (origin is not null)
    {
      var keys = (CloudJson.Parse(origin.Keys) as CloudJson.Array)!.Items.Select(DeckMemoryCell.FromJson).ToArray();
      for (var i = 0; i < t.Keys.Count; i++) logical[t.Index(t.Keys[i])] = keys[i];
      // Local remaps made at apply (another store's diary/board ids) travel back as the original values. A version
      // whose body was dropped had none (its body equalled its projection).
      if (Find(origin.Key, origin.Version) is { Body: { } body, Projection: { Length: > 0 } projection })
      {
        var original = CloudMemoryFormat.DecodeRow(Encoding.UTF8.GetBytes(body)).Cells;
        var mapped = CloudMemoryFormat.DecodeRow(Encoding.UTF8.GetBytes(projection)).Cells;
        for (var i = 0; i < values.Length; i++) if (values[i] == mapped[i] && t.Keys.All(k => t.Index(k) != i)) logical[i] = original[i];
      }
    }
    var references = new Dictionary<string, DeckMemoryReference>(StringComparer.Ordinal);
    foreach (var (column, target) in DeckMemoryCloudSchema.ReferenceColumns(t.Name))
    {
      var i = t.Index(column);
      if (values[i].IsNull || t.Name == "rewinds" && column == "after_row" && values[i].AsInteger == 0) continue;
      var targetOrigin = state.Origins.GetValueOrDefault(target + "\n" + CloudMemoryFormat.NativeKey(DeckMemoryCloudSchema.Table(target), Single(target, values[i])));
      var id = targetOrigin is not null ? (CloudJson.Parse(targetOrigin.Keys) as CloudJson.Array)!.Items.Select(DeckMemoryCell.FromJson).First() : values[i];
      references[column] = new(targetOrigin?.StoreId ?? memory.StoreId, target, id);
      logical[i] = id;
    }
    if (t.Index("path") is >= 0 and var pi && values[pi] is { Type: "text", Value: { } path })
    {
      var fileOrigin = state.FileOrigins.GetValueOrDefault(path);
      var relative = fileOrigin is null ? path : fileOrigin.Key[5..];
      references["path"] = new(fileOrigin?.StoreId ?? memory.StoreId, "file", DeckMemoryCell.Text(relative));
      logical[pi] = DeckMemoryCell.Text(relative);
    }
    var data = CloudMemoryFormat.RowBody(t, logical, references);
    return new(t.Row, origin?.StoreId ?? memory.StoreId, origin?.Key ?? CloudMemoryFormat.RowKey(t, logical), data, CloudMemoryFormat.Hash(data), origin?.Version, row, null);
  }
  private static DeckMemoryCell[] Single(string table, DeckMemoryCell id)
  {
    var t = DeckMemoryCloudSchema.Table(table);
    var cells = Enumerable.Repeat(DeckMemoryCell.Null, t.Columns.Count).ToArray();
    cells[t.Index("id")] = id;
    return cells;
  }

  /// A new version of `r` when its content changed since this PC last published it (cloudExportVersion), as parts.
  private IEnumerable<CloudOperation> Export(Resource r, Func<long> stampNow)
  {
    var sk = r.StoreId + ":" + r.Key;
    var head = state.Heads.GetValueOrDefault(sk);
    if (head?.Hash == r.Hash) return [];
    // Content equal to the version it came from (a received value not edited here): nothing to publish.
    if (r.Base is not null && Find(r.Key, r.Base) is { } received && received.Hash == r.Hash)
    {
      state.Heads[sk] = new Head { Hash = r.Hash, Version = r.Base, Parents = received.Parents.ToList(), Base = r.Base };
      return [];
    }
    List<string> parents = head is null ? (r.Base is null ? [] : [r.Base]) : [r.Base is not null && head.Base != r.Base ? r.Base : head.Version];
    var version = CloudMemoryFormat.Uuid((parents.Count > 0 ? parents[0] : sk) + "\n" + r.Hash);
    state.Heads[sk] = new Head { Hash = r.Hash, Version = version, Parents = parents, Base = r.Base };
    var vk = V(r.StoreId, r.Key, version);
    if (state.Versions.TryGetValue(vk, out var existing) && existing.Done) return [];
    // M4b: stamped ONCE, here, on the service clock, never earlier than a parent's stamp + 1.
    var stamp = stampNow();
    foreach (var parent in parents) if (Find(r.Key, parent) is { } p) stamp = Math.Max(stamp, p.Stamp + 1);
    // Rule J: a baseline only when this PC already holds another store's Cloud version of this record.
    var baseline = parents.Count == 0 && VersionsOf(r.Key).Any(v => v.Id != version && (!v.Own || v.StoreId != r.StoreId));
    var count = CloudMemoryFormat.PartCount(r.Data.Length);
    var body = r.Path is null ? Encoding.UTF8.GetString(r.Data) : null;
    var projection = r.Physical is { } physical ? Encoding.UTF8.GetString(CloudMemoryFormat.RowBody(DeckMemoryCloudSchema.Table(physical.Table), physical.Cells)) : r.Path;
    var v = new Version
    {
      StoreId = r.StoreId, Key = r.Key, Id = version, Row = r.Row, Hash = r.Hash, Parents = parents, Stamp = stamp, Baseline = baseline, Own = true, Count = count, Done = true,
      Device = deviceId, Body = body == projection ? null : body, Projection = projection
    };
    var createdAt = localNow();
    var operations = new List<CloudOperation>();
    for (var index = 0; index < count; index++)
    {
      var slice = r.Data.AsSpan(index * CloudMemoryFormat.PartBytes, Math.Min(CloudMemoryFormat.PartBytes, r.Data.Length - index * CloudMemoryFormat.PartBytes));
      var part = new CloudMemoryPart(r.StoreId, r.Row, r.Key, version, r.Hash, r.Data.Length, index, count, parents, Convert.ToBase64String(slice), stamp, baseline);
      var parentOps = new List<string>();
      foreach (var parent in parents)
        if (Find(r.Key, parent) is { } pv && (pv.PartOps.GetValueOrDefault(index) ?? pv.PartOps.GetValueOrDefault(0)) is { } op && CloudBytes.IsTransportId(op) && !parentOps.Contains(op))
          parentOps.Add(op);
      var operation = CloudMemoryFormat.Operation(part, deviceId, parentOps, createdAt);
      v.PartOps[index] = operation.OpId;
      if (index == 0) v.FirstOp = operation.OpId;
      state.Applied.Add(operation.OpId);
      operations.Add(operation);
    }
    Put(vk, v);
    return operations;
  }

  // ---- Apply ----

  public Task ApplyAsync(CloudOperation op, CloudImportOrigin origin, CancellationToken ct)
  {
    if (state.Applied.Contains(op.OpId)) return Task.CompletedTask;
    var row = CloudMemoryFormat.RowOfDomain(op.Domain) ?? throw new CloudFailure("unsupported_format");
    dirty = true;
    // The board (an older device's live status): acknowledged and ignored.
    if (row == LocalOnlyRow) { state.Applied.Add(op.OpId); return Task.CompletedTask; }
    if (!rows.Contains(row)) throw new CloudFailure("unsupported_format");
    var p = CloudMemoryFormat.ValidatePart(op, row);
    // Local database backups and the app's own help files never travel; an incoming one changes nothing.
    if (p.Key.StartsWith("backup/", StringComparison.Ordinal) || p.Key.StartsWith("file/", StringComparison.Ordinal) && DeckMemoryCloudSchema.AppHelpFiles.Contains(p.Key[5..]))
    { state.Applied.Add(op.OpId); return Task.CompletedTask; }
    var vk = V(p.StoreId, p.Key, p.Version);
    if (!state.Versions.TryGetValue(vk, out var v))
      Put(vk, v = new Version { StoreId = p.StoreId, Key = p.Key, Id = p.Version, Row = row, Hash = p.ResourceHash, Parents = p.Parents.ToList(), Count = p.Count, Device = origin.DeviceId });
    else if (v.Hash != p.ResourceHash || v.Count != p.Count || !v.Parents.SequenceEqual(p.Parents)) throw new CloudFailure("id_reused");
    if (p.Index == 0 && (v.FirstOp is null || string.CompareOrdinal(op.OpId, v.FirstOp) < 0))
    {
      // M4b: the stamp travels inside the version's first part (older parts: their build time).
      v.FirstOp = op.OpId; v.Stamp = p.Stamp ?? op.CreatedAt; v.Baseline = p.Baseline ?? false;
    }
    v.PartOps.TryAdd(p.Index, op.OpId);
    if (!v.Done)
    {
      if (v.Parts.TryGetValue(p.Index, out var known) && known != p.Data) throw new CloudFailure("id_reused");
      v.Parts[p.Index] = p.Data;
      if (v.Parts.Count == v.Count)
      {
        var body = v.Parts.OrderBy(x => x.Key).SelectMany(x => Convert.FromBase64String(x.Value)).ToArray();
        if (body.LongLength != p.Bytes || CloudMemoryFormat.Hash(body) != p.ResourceHash) throw new CloudFailure("checksum_mismatch");
        v.Parts.Clear(); v.Done = true;
        if (p.Key.StartsWith("file/", StringComparison.Ordinal)) { ProjectFile(v, body); RetryWaitingRows(); }
        else { v.Body = Encoding.UTF8.GetString(body); ProjectRow(v); }
      }
    }
    state.Applied.Add(op.OpId);
    return Task.CompletedTask;
  }

  private CloudMemoryRevision Revision(Version v)
  {
    var ancestors = new HashSet<string>(StringComparer.Ordinal);
    var frontier = new Stack<string>([v.Id]);
    for (var steps = 0; frontier.Count > 0 && steps < 4096; steps++)
      if (Find(v.Key, frontier.Pop()) is { } next) foreach (var parent in next.Parents) if (ancestors.Add(parent)) frontier.Push(parent);
    return new(v.StoreId, v.Id, v.Stamp, v.Baseline, v.FirstOp ?? v.PartOps.GetValueOrDefault(0) ?? "", ancestors);
  }
  private void List(Version loser, string table, string value, string why) =>
    state.Others.Add(new(loser.Key, table, loser.Id, loser.Device, loser.Stamp, value, why));

  private void ProjectFile(Version v, byte[] bytes)
  {
    var logical = v.Key[5..];
    var placed = Placement(logical, v.StoreId);
    if (placed is null) { v.Waiting = "waiting_project_not_matched"; return; }
    v.Waiting = null;
    // A name Windows cannot hold (a ':' or '?', a reserved name such as CON) is kept under the nearest allowed name;
    // the record keeps its original name, so it travels back unchanged.
    var path = FileDeckMemoryStore.WindowsName(placed);
    var local = memory.ReadFile(path);
    // A removal from a Mac (its one rule): this PC keeps its copy. Nothing is deleted or blanked by sync here.
    if (bytes.Length < CloudMemoryFormat.RemovalMarkerLimit && CloudMemoryFormat.IsRemovalMarker(bytes))
    {
      v.Projection = "";
      if (local is not null) List(v, "file", path, KeptRemovalWhy);
      return;
    }
    if (local is null) { memory.WriteFile(path, bytes); Claim(path, v, onlyIfUnowned: false); return; }
    var current = CloudMemoryFormat.Hash(local);
    if (current == v.Hash) { Claim(path, v, onlyIfUnowned: true); return; }
    // A causal descendant replaces its untouched predecessor (an earlier version of this very record).
    var ancestors = Revision(v).Ancestors;
    if (VersionsOf(v.Key).Any(x => ancestors.Contains(x.Id) && x.Hash == current)) { memory.WriteFile(path, bytes); Claim(path, v, onlyIfUnowned: false); return; }
    // Two different texts of one file (the Mac's one rule for files): the newer revision is used here; the other text
    // is kept outside the memory folder and listed. This PC's text that never became a version (a joining PC's own
    // file, or an edit since the last capture) becomes one now, by the ordinary capture rule: rule J makes a joiner's
    // first copy a baseline, so the Cloud's text wins and this PC's text is kept.
    var mine = LocalVersion(path, local, current);
    if (mine is not null && (v.Parents.Contains(mine.Id) || CloudMemoryRevision.Winner(Revision(v), Revision(mine)).Version == v.Id))
    {
      var kept = keeper.Keep(path, local, "this PC", localNow());
      memory.WriteFile(path, bytes);
      Claim(path, v, onlyIfUnowned: false);
      List(mine, "file", kept, "this PC's text; the newer text from another device is in use");
      return;
    }
    v.Projection = "";
    List(v, "file", keeper.Keep(path, bytes, v.Device, localNow()), "another device's text; this PC's is newer and stays in use");
  }

  /// This PC's version of the text at `path` now: the version it already published, or (when the text never became
  /// one) a version made now and queued for the next send. Null when the file never travels.
  private Version? LocalVersion(string path, byte[] local, string hash)
  {
    var origin = state.FileOrigins.GetValueOrDefault(path);
    var storeId = origin?.StoreId ?? memory.StoreId;
    var key = origin?.Key ?? "file/" + path;
    if (state.Heads.GetValueOrDefault(storeId + ":" + key) is { } head && head.Hash == hash && Find(key, head.Version) is { } published) return published;
    var row = DeckMemoryCloudSchema.FileRow(key[5..]);
    if (row is null || !rows.Contains(row) || CloudMemoryFormat.IsRemovalMarker(local)) return null;
    var resource = new Resource(row, storeId, key, local, hash, origin?.Version, null, path);
    foreach (var op in Export(resource, localNow)) state.Pending.Add(Encoding.UTF8.GetString(CloudCanonical.Encode(op.ToJson())));
    return state.Heads.GetValueOrDefault(storeId + ":" + key) is { } minted ? Find(key, minted.Version) : null;
  }

  private void Claim(string path, Version v, bool onlyIfUnowned)
  {
    v.Projection = path;
    var owned = state.FileOrigins.GetValueOrDefault(path);
    if (onlyIfUnowned && owned is not null && (owned.StoreId != v.StoreId || owned.Key != v.Key)) return;
    state.FileOrigins[path] = new Origin { StoreId = v.StoreId, Key = v.Key, Version = v.Id };
    state.Heads[v.StoreId + ":" + v.Key] = new Head { Hash = v.Hash, Version = v.Id, Parents = v.Parents.ToList(), Base = v.Id };
  }
  /// `projects/<id>/…` of another device goes only under the project this PC matched (7C-2); otherwise it waits.
  private string? Placement(string logical, string storeId)
  {
    var parts = logical.Split('/');
    if (parts.Length < 3 || parts[0] != "projects") return logical;
    return ProjectTarget(parts[1], storeId) is { } local ? string.Join('/', new[] { "projects", local }.Concat(parts.Skip(2))) : null;
  }
  private string? ProjectTarget(string project, string storeId) => storeId == memory.StoreId ? project : projects?.Invoke(project, storeId) is { Length: > 0 } local ? local : null;

  private void RetryWaitingRows()
  {
    foreach (var waiting in state.Versions.Values.Where(x => x.Waiting is not null && x.Body is not null).ToArray()) ProjectRow(waiting);
  }

  /// cloudProjectRow: places one incoming row version, or keeps it as history, by the Mac's rules.
  private void ProjectRow(Version v)
  {
    var (t, original, references) = CloudMemoryFormat.DecodeRow(Encoding.UTF8.GetBytes(v.Body!));
    if (CloudMemoryFormat.RowKey(t, original) != v.Key) throw new CloudFailure("invalid_request");
    v.Waiting = null;
    // Settings about the other device itself (its own bookkeeping) are kept as history only.
    if (DeckMemoryCloudSchema.IsMachineLocal(t, original)) { v.Projection = ""; return; }
    var tombstone = DeckMemoryCloudSchema.IsSettingTombstone(t, original);
    var values = original.ToArray();
    int Index(string c) => t.Index(c);
    if (Index("owner") is >= 0 and var oi && values[oi] is { Type: "text", Value: { } owner } && OwnerProject(owner) is { } owned)
    {
      if (ProjectTarget(owned, v.StoreId) is not { } local) { v.Waiting = "waiting_project_not_matched"; return; }
      values[oi] = DeckMemoryCell.Text(RemapOwner(owner, owned, local));
      if (Index("project") is >= 0 and var pj && values[pj] is { Type: "text", Value: var pv } && pv == owned) values[pj] = DeckMemoryCell.Text(local);
    }
    if (t.IntegerKey)
    {
      var i = Index("id");
      DeckMemoryCell? parentId = null;
      foreach (var parent in v.Parents)
        if (Find(v.Key, parent) is { Projection: { Length: > 0 } projection } && CloudMemoryFormat.DecodeRow(Encoding.UTF8.GetBytes(projection)) is var row && row.Table.Name == t.Name)
        { parentId = row.Cells[i]; break; }
      values[i] = parentId ?? Resolve(new(v.StoreId, t.Name, original[i]));
    }
    var referenceColumns = DeckMemoryCloudSchema.ReferenceColumns(t.Name);
    foreach (var (column, reference) in references.Where(r => r.Key != "path"))
    {
      if (!referenceColumns.TryGetValue(column, out var target) || target != reference.Table || original[Index(column)] != reference.Id) throw new CloudFailure("invalid_request");
      values[Index(column)] = Resolve(reference);
    }
    foreach (var (column, _) in referenceColumns)
      if (!original[Index(column)].IsNull && !(t.Name == "rewinds" && column == "after_row" && original[Index(column)].AsInteger == 0) && !references.ContainsKey(column))
        throw new CloudFailure("invalid_request");
    if (t.Name == "diary" && v.StoreId != memory.StoreId && values[Index("external_id")] is { Type: "text", Value: { } external })
      values[Index("external_id")] = DeckMemoryCell.Text("cloud:" + v.StoreId + ":" + external);
    // File-backed labels join the file actually kept; labels that arrive before their file wait for it.
    if (Index("path") is >= 0 and var pi && original[pi] is { Type: "text", Value: { } originalPath })
    {
      if (!references.TryGetValue("path", out var fileRef) || fileRef.Table != "file" || fileRef.Id != original[pi] || !Guid.TryParse(fileRef.StoreId, out _)) throw new CloudFailure("invalid_request");
      var mapped = VersionsOf("file/" + originalPath).Where(x => x.StoreId == fileRef.StoreId && !string.IsNullOrEmpty(x.Projection)).Select(x => x.Projection).LastOrDefault()
        ?? state.FileOrigins.FirstOrDefault(f => f.Value.StoreId == fileRef.StoreId && f.Value.Key == "file/" + originalPath).Key;
      if (mapped is null) { v.Waiting = "waiting_for_file"; return; }
      values[pi] = DeckMemoryCell.Text(mapped);
    }
    var keys = t.Keys.Select(k => values[Index(k)]).ToArray();
    DeckMemoryRow? existing = t.Name is "notes" or "topics" or "files" or "handoffs" && Index("path") >= 0
      ? memory.FindWhere(t.Name, "path", values[Index("path")])
      : memory.Find(t.Name, keys);
    if (existing is not null && t.Name is "notes" or "topics" or "files" or "handoffs" && Index("id") is >= 0 and var idi) values[idi] = existing.Cells[idi];
    var placed = new DeckMemoryRow(t.Name, values);
    if (existing is not null)
    {
      var existingKeys = t.Keys.Select(k => existing.Cells[Index(k)]).ToArray();
      if (existing.Same(placed)) { Keep(v, t, placed); return; }
      var encodedExisting = Encoding.UTF8.GetString(CloudMemoryFormat.RowBody(t, existing.Cells));
      var mayUpdate = v.Parents.Any(parent => Find(v.Key, parent)?.Projection == encodedExisting);
      if (!mayUpdate && DeckMemoryCloudSchema.LastWriterTables.Contains(t.Name))
      {
        // The local value's own version; one never published yet (a joiner's value at first sign-in) gets its version
        // now by the ordinary capture rule (a baseline by rule J when it never descended from a Cloud version) and is
        // queued, so every device keeps the same history.
        var local = VersionsOf(v.Key).LastOrDefault(x => x.Projection == encodedExisting && x != v) ?? PublishLocal(t, existing);
        if (CloudMemoryRevision.Winner(Revision(v), Revision(local)).Version != v.Id)
        {
          v.Projection = "";
          List(v, t.Name, v.Body!, "another device's value; yours is newer");
          return;
        }
        if (!tombstone) List(local, t.Name, encodedExisting, "this PC's value; the other device's is newer");
        mayUpdate = true;
      }
      // A removed shared setting: this PC keeps its value (removals do not travel to Windows yet).
      if (mayUpdate && tombstone) { v.Projection = ""; List(v, t.Name, encodedExisting, KeptRemovalWhy); return; }
      if (mayUpdate) { memory.PutRow(placed, existingKeys); Keep(v, t, placed); return; }
      // Rows that keep both (diary, history, questions, rewinds): the other version gets its own row.
      if (t.IntegerKey)
      {
        values[Index("id")] = DeckMemoryCell.Integer(memory.AllocateInteger(t.Name));
        if (t.Name == "diary" && values[Index("external_id")] is { Type: "text", Value: { } ext }) values[Index("external_id")] = DeckMemoryCell.Text(ext + ":cloud-" + v.Hash[..16]);
      }
      else { v.Projection = ""; List(v, t.Name, v.Body!, "kept as another version"); return; }
      placed = new DeckMemoryRow(t.Name, values);
      memory.PutRow(placed, null);
      Keep(v, t, placed);
      return;
    }
    // No row here and the other device removed it: nothing to place.
    if (tombstone) { v.Projection = ""; return; }
    memory.PutRow(placed, null);
    Keep(v, t, placed);
  }

  /// The placed row is this version here: later local edits descend from it (origin), and it is not sent back.
  private void Keep(Version v, DeckMemoryTable t, DeckMemoryRow placed)
  {
    v.Projection = Encoding.UTF8.GetString(CloudMemoryFormat.RowBody(t, placed.Cells));
    var originalKeys = CloudMemoryFormat.DecodeRow(Encoding.UTF8.GetBytes(v.Body!)).Cells;
    state.Origins[t.Name + "\n" + CloudMemoryFormat.NativeKey(t, placed.Cells)] = new Origin
    {
      StoreId = v.StoreId, Key = v.Key, Version = v.Id, Keys = Encoding.UTF8.GetString(CloudCanonical.Encode(CloudJson.Arr(t.Keys.Select(k => originalKeys[t.Index(k)].ToJson()))))
    };
    state.Heads[v.StoreId + ":" + v.Key] = new Head { Hash = v.Hash, Version = v.Id, Parents = v.Parents.ToList(), Base = v.Id };
    // The body is needed later only where it differs from what was placed (remapped ids travel back as the original).
    if (v.Body == v.Projection) v.Body = null;
  }

  /// Gives a never-published local value its version now and queues it for the next send.
  private Version PublishLocal(DeckMemoryTable t, DeckMemoryRow existing)
  {
    var resource = Logical(t, existing);
    foreach (var op in Export(resource, localNow)) state.Pending.Add(Encoding.UTF8.GetString(CloudCanonical.Encode(op.ToJson())));
    return state.Versions[V(resource.StoreId, resource.Key, state.Heads[resource.StoreId + ":" + resource.Key].Version)];
  }

  /// Another store's row id → this PC's id for it (allocated once, remembered).
  private DeckMemoryCell Resolve(DeckMemoryReference reference)
  {
    if (!Guid.TryParse(reference.StoreId, out _)) throw new CloudFailure("invalid_request");
    var t = DeckMemoryCloudSchema.Table(reference.Table);
    if (!t.Keys.SequenceEqual(["id"])) throw new CloudFailure("unsupported_format");
    if (reference.StoreId == memory.StoreId) return reference.Id;
    var key = reference.StoreId + "\n" + t.Name + "\n" + Encoding.UTF8.GetString(CloudCanonical.Encode(reference.Id.ToJson()));
    if (state.Ids.TryGetValue(key, out var known)) return DeckMemoryCell.FromJson(CloudJson.Parse(known));
    var local = reference.Id.Type switch
    {
      "integer" => DeckMemoryCell.Integer(memory.AllocateInteger(t.Name)),
      "text" => DeckMemoryCell.Text("cloud:" + reference.StoreId + ":" + reference.Id.Value),
      _ => throw new CloudFailure("invalid_request")
    };
    state.Ids[key] = Encoding.UTF8.GetString(CloudCanonical.Encode(local.ToJson()));
    return local;
  }

  /// DeckMemoryOwner: "project:<id>", "lead:<id>", "role:<project>/<role>" belong to a project; "hoot", "role:<role>" do not.
  private static string? OwnerProject(string owner)
  {
    var colon = owner.IndexOf(':');
    if (colon < 0) return null;
    var (kind, id) = (owner[..colon], owner[(colon + 1)..]);
    return kind switch { "project" or "lead" => id, "role" when id.Contains('/') => id[..id.IndexOf('/')], _ => null };
  }
  private static string RemapOwner(string owner, string from, string to) =>
    from == to ? owner : owner == "project:" + from ? "project:" + to : owner == "lead:" + from ? "lead:" + to
      : owner.StartsWith("role:" + from + "/", StringComparison.Ordinal) ? "role:" + to + owner[("role:" + from).Length..] : owner;
}

/// Kept texts in memory (tests).
public sealed class CloudMemoryKeptInMemory : ICloudMemoryKeeper
{
  public readonly List<(string Path, byte[] Bytes, string Device, long At)> Kept = [];
  public string Keep(string path, byte[] bytes, string device, long at) { Kept.Add((path, bytes.ToArray(), device, at)); return "kept/" + Kept.Count + "/" + path; }
}

/// Kept texts on disk: `<folder>/<yyyy-MM-dd>/<16 hex of the text's hash>/<path>`. Outside the memory folder, never
/// sent, never read as memory. Nothing here is removed by sync.
public sealed class CloudMemoryKeptFolder(string folder) : ICloudMemoryKeeper
{
  public string Keep(string path, byte[] bytes, string device, long at)
  {
    var day = DateTimeOffset.FromUnixTimeMilliseconds(at).UtcDateTime.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
    var relative = day + "/" + CloudMemoryFormat.Hash(bytes)[..16] + "/" + FileDeckMemoryStore.WindowsName(path);
    var target = Path.Combine(new[] { folder }.Concat(relative.Split('/')).ToArray());
    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
    new CloudFileSlot(target).Write(bytes);
    return relative;
  }
}

/// The memory store used by the tests: everything in memory.
public sealed class InMemoryDeckMemoryStore(string storeId) : IDeckMemoryCloudStore
{
  private readonly Dictionary<string, List<DeckMemoryRow>> tables = new(StringComparer.Ordinal);
  private readonly SortedDictionary<string, byte[]> files = new(StringComparer.Ordinal);
  private readonly Dictionary<string, long> sequences = new(StringComparer.Ordinal);
  private long ticks;
  private readonly Dictionary<string, long> written = new(StringComparer.Ordinal);
  public string StoreId { get; } = storeId;
  public IReadOnlyList<DeckMemoryRow> Rows(string table) => tables.TryGetValue(table, out var list) ? list.ToArray() : [];
  public DeckMemoryRow? Find(string table, IReadOnlyList<DeckMemoryCell> keys)
  {
    var t = DeckMemoryCloudSchema.Table(table);
    return Rows(table).FirstOrDefault(r => t.Keys.Select(k => r.Cells[t.Index(k)]).SequenceEqual(keys));
  }
  public DeckMemoryRow? FindWhere(string table, string column, DeckMemoryCell value)
  {
    var i = DeckMemoryCloudSchema.Table(table).Index(column);
    return i < 0 ? null : Rows(table).FirstOrDefault(r => r.Cells[i] == value);
  }
  public void PutRow(DeckMemoryRow row, IReadOnlyList<DeckMemoryCell>? replacing)
  {
    var t = DeckMemoryCloudSchema.Table(row.Table);
    if (row.Cells.Count != t.Columns.Count) throw new CloudFailure("invalid_request");
    var list = tables.TryGetValue(row.Table, out var l) ? l : tables[row.Table] = [];
    var keys = replacing ?? t.Keys.Select(k => row.Cells[t.Index(k)]).ToArray();
    var at = list.FindIndex(r => t.Keys.Select(k => r.Cells[t.Index(k)]).SequenceEqual(keys));
    if (at >= 0) list[at] = row; else list.Add(row);
    if (t.IntegerKey && row.Cells[t.Index("id")].AsInteger is { } id) sequences[row.Table] = Math.Max(sequences.GetValueOrDefault(row.Table), id);
  }
  /// The person's own removal on this device (tests only; sync has no way to remove).
  public void RemoveRow(string table, IReadOnlyList<DeckMemoryCell> keys)
  {
    var t = DeckMemoryCloudSchema.Table(table);
    if (tables.TryGetValue(table, out var list)) list.RemoveAll(r => t.Keys.Select(k => r.Cells[t.Index(k)]).SequenceEqual(keys));
  }
  public long AllocateInteger(string table) => sequences[table] = sequences.GetValueOrDefault(table) + 1;
  public IReadOnlyDictionary<string, byte[]> Files() => new Dictionary<string, byte[]>(files, StringComparer.Ordinal);
  public IReadOnlyList<DeckMemoryFileInfo> ListFiles() => files.Select(f => new DeckMemoryFileInfo(f.Key, f.Value.Length, written[f.Key])).ToArray();
  public byte[]? ReadFile(string path) => files.TryGetValue(path, out var bytes) ? bytes.ToArray() : null;
  public void WriteFile(string path, byte[] bytes)
  {
    if (!DeckMemoryCloudSchema.SafePath(path)) throw new CloudFailure("invalid_request");
    files[path] = bytes.ToArray(); written[path] = ++ticks;
  }
  public void Flush() { }
}
