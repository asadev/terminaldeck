using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// W3: Deck Memory travelling on Windows. The Windows app has NO Deck Memory store yet (notes, cards, topics, diary,
// handoffs and memory settings live only on the Mac; Windows has seat card/notes text in Agents and Hoot's own memory,
// neither of which is Deck Memory). So the capture and apply sides are written against `IDeckMemoryCloudStore`, the
// exact surface the Windows memory store must provide, with an in-memory store for tests and until the real one exists.
// Record shapes, ids, stamps and the merge rule are the Mac's (CloudMemoryFormat.cs).

/// One row of a memory table, cells in the table's column order (DeckMemoryCloudSchema).
public sealed record DeckMemoryRow(string Table, IReadOnlyList<DeckMemoryCell> Cells)
{
  public bool Same(DeckMemoryRow other) => Table == other.Table && Cells.SequenceEqual(other.Cells);
}

/// What the Windows Deck Memory store must provide for Cloud. Every write here comes from Cloud's apply and must not
/// be captured back as a local change (the adapter recognises its own writes by content, so no flag is needed).
public interface IDeckMemoryCloudStore
{
  /// A stable random id for this memory store (a UUID made once, kept with the memory).
  string StoreId { get; }
  /// Every row of one table now (tables and columns as DeckMemoryCloudSchema; `meta` may be empty).
  IReadOnlyList<DeckMemoryRow> Rows(string table);
  /// Insert, or replace the row whose key columns equal `replacing` (null: insert).
  void PutRow(DeckMemoryRow row, IReadOnlyList<DeckMemoryCell>? replacing);
  void RemoveRow(string table, IReadOnlyList<DeckMemoryCell> keys);
  /// A fresh integer id for an integer-keyed table (diary, board_history, rewinds, questions), never reused.
  long AllocateInteger(string table);
  /// Every regular file under the memory folder: relative path ('/' separated) → bytes. Links are not followed.
  IReadOnlyDictionary<string, byte[]> Files();
  void WriteFile(string path, byte[] bytes);
}

/// A value this PC does not show because the other one won (or both were kept): listed on the page, never lost.
public sealed record CloudMemoryOtherVersion(string Key, string Table, string Version, string Device, long Stamp, string Value, string Why);

/// The capture and apply sides for Deck Memory (inventory rows I01..I06), one adapter for all six kinds.
public sealed class CloudMemoryAdapter : ICloudSyncAdapter
{
  private readonly IDeckMemoryCloudStore memory;
  private readonly ICloudLedgerSlot slot;
  private readonly string deviceId;
  private readonly Func<long> localNow;
  private readonly Func<string, string, string?>? projects;
  private readonly HashSet<string> rows;
  private State state;

  /// `enabledRows`: the inventory rows switched on for this account (null: all). `projects(projectId, originStore)`:
  /// this PC's project for another device's project-scoped memory (W4's project list), null while not matched (waits).
  public CloudMemoryAdapter(IDeckMemoryCloudStore memory, ICloudLedgerSlot slot, string deviceId, IEnumerable<string>? enabledRows = null,
    Func<string, string, string?>? projects = null, Func<long>? localNow = null)
  {
    CloudBytes.TransportId(deviceId);
    if (!Guid.TryParse(memory.StoreId, out _)) throw new CloudFailure("invalid_request");
    this.memory = memory; this.slot = slot; this.deviceId = deviceId; this.projects = projects;
    this.localNow = localNow ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    rows = (enabledRows ?? CloudMemoryFormat.InventoryRows).ToHashSet();
    if (rows.Any(r => !CloudMemoryFormat.InventoryRows.Contains(r))) throw new CloudFailure("invalid_request");
    state = slot.Read() is { } bytes ? JsonSerializer.Deserialize<State>(bytes) ?? new State() : new State();
  }

  public IReadOnlyCollection<string> Domains => rows.Select(CloudMemoryFormat.Domain).ToArray();
  public IReadOnlyList<CloudMemoryOtherVersion> OtherVersions => state.Others.ToArray();
  public int WaitingCount => state.Versions.Values.Count(v => v.Waiting is not null);

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
    public Dictionary<string, string> Ids { get; set; } = [];
    public Dictionary<string, string> Removals { get; set; } = [];
    public HashSet<string> Settings { get; set; } = [];
    public List<CloudMemoryOtherVersion> Others { get; set; } = [];
    public HashSet<string> Applied { get; set; } = [];
    public List<string> Pending { get; set; } = [];
  }
  private void Save() => slot.Write(JsonSerializer.SerializeToUtf8Bytes(state));
  private static string V(string storeId, string key, string version) => storeId + "\n" + key + "\n" + version;
  private Version? Find(string key, string version) => state.Versions.Values.FirstOrDefault(v => v.Key == key && v.Id == version);

  // ---- Capture ----

  private sealed record Resource(string Row, string StoreId, string Key, byte[] Data, string Hash, string? Base, DeckMemoryRow? Physical, string? Path);

  /// Compares what the memory holds now with what this PC last published, and makes a new version of every resource
  /// that changed: rows of the enabled tables (shared settings only; `meta` never), memory-folder files, and the
  /// removal of a shared setting (a tombstone). Stamped once, here, on the service clock. Deterministic ids: a capture
  /// repeated after a crash makes the same records.
  public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    var before = JsonSerializer.SerializeToUtf8Bytes(state);
    var operations = new List<CloudOperation>();
    foreach (var pending in state.Pending) operations.Add(CloudOperation.FromJson(CloudJson.Parse(pending)));
    var seen = new HashSet<string>(StringComparer.Ordinal);
    foreach (var t in DeckMemoryCloudSchema.Tables.Where(t => rows.Contains(t.Row) && t.Name != "meta"))
    {
      foreach (var row in memory.Rows(t.Name))
      {
        ct.ThrowIfCancellationRequested();
        if (row.Cells.Count != t.Columns.Count) throw new CloudFailure("unsupported_format");
        if (DeckMemoryCloudSchema.IsMachineLocal(t, row.Cells)) continue;
        var resource = Logical(t, row);
        if (t.Name == "settings") seen.Add(CloudMemoryFormat.NativeKey(t, row.Cells));
        operations.AddRange(Export(resource, stampNow));
      }
      if (t.Name == "settings")
        foreach (var native in state.Settings.Where(s => !seen.Contains(s)).ToArray())
        {
          // A shared setting removed here travels as its tombstone: value null, `updated` the removal time (seconds).
          var keys = CloudJson.Parse(native) is CloudJson.Array a ? a.Items.Select(DeckMemoryCell.FromJson).ToArray() : throw new CloudFailure("unsupported_format");
          var cells = new DeckMemoryCell[t.Columns.Count];
          cells[t.Index("owner")] = keys[0]; cells[t.Index("key")] = keys[1];
          cells[t.Index("value")] = DeckMemoryCell.Null; cells[t.Index("updated")] = DeckMemoryCell.Real(stampNow() / 1000.0);
          operations.AddRange(Export(Logical(t, new DeckMemoryRow("settings", cells)), stampNow));
          state.Settings.Remove(native);
        }
      state.Settings.UnionWith(seen);
    }
    foreach (var (path, bytes) in memory.Files().OrderBy(f => f.Key, StringComparer.Ordinal))
    {
      if (DeckMemoryCloudSchema.AppHelpFiles.Contains(path) || !DeckMemoryCloudSchema.SafePath(path)) continue;
      var origin = state.FileOrigins.GetValueOrDefault(path);
      var row = DeckMemoryCloudSchema.FileRow(origin is null ? path : origin.Key[5..]);
      if (row is null || !rows.Contains(row)) continue;
      operations.AddRange(Export(new Resource(row, origin?.StoreId ?? memory.StoreId, origin?.Key ?? "file/" + path, bytes, CloudMemoryFormat.Hash(bytes), origin?.Version, null, path), stampNow));
    }
    var committed = state;
    state = JsonSerializer.Deserialize<State>(before)!;
    var staged = committed;
    return Task.FromResult(new CloudCapture(operations, () => { state = staged; state.Pending.Clear(); Save(); }));
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
      // Local remaps made at apply (another store's diary/board ids) travel back as the original values.
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
    var baseline = parents.Count == 0 && state.Versions.Values.Any(v => v.Key == r.Key && v.Id != version && (!v.Own || v.StoreId != r.StoreId));
    var count = CloudMemoryFormat.PartCount(r.Data.Length);
    var v = new Version
    {
      StoreId = r.StoreId, Key = r.Key, Id = version, Row = r.Row, Hash = r.Hash, Parents = parents, Stamp = stamp, Baseline = baseline, Own = true, Count = count, Done = true,
      Device = deviceId, Body = r.Path is null ? Encoding.UTF8.GetString(r.Data) : null,
      Projection = r.Physical is { } physical ? Encoding.UTF8.GetString(CloudMemoryFormat.RowBody(DeckMemoryCloudSchema.Table(physical.Table), physical.Cells)) : r.Path
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
    state.Versions[vk] = v;
    return operations;
  }

  // ---- Apply ----

  public Task ApplyAsync(CloudOperation op, CloudImportOrigin origin, CancellationToken ct)
  {
    if (state.Applied.Contains(op.OpId)) return Task.CompletedTask;
    var row = CloudMemoryFormat.RowOfDomain(op.Domain) ?? throw new CloudFailure("unsupported_format");
    if (!rows.Contains(row)) throw new CloudFailure("unsupported_format");
    var p = CloudMemoryFormat.ValidatePart(op, row);
    // Local database backups and the app's own help files never travel; an incoming one changes nothing.
    if (p.Key.StartsWith("backup/", StringComparison.Ordinal) || p.Key.StartsWith("file/", StringComparison.Ordinal) && DeckMemoryCloudSchema.AppHelpFiles.Contains(p.Key[5..]))
    { state.Applied.Add(op.OpId); Save(); return Task.CompletedTask; }
    var vk = V(p.StoreId, p.Key, p.Version);
    if (!state.Versions.TryGetValue(vk, out var v))
      state.Versions[vk] = v = new Version { StoreId = p.StoreId, Key = p.Key, Id = p.Version, Row = row, Hash = p.ResourceHash, Parents = p.Parents.ToList(), Count = p.Count, Device = origin.DeviceId };
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
    Save();
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
    var path = Placement(logical, v.StoreId);
    if (path is null) { v.Waiting = "waiting_project_not_matched"; return; }
    v.Waiting = null;
    var files = memory.Files();
    if (files.TryGetValue(path, out var local))
    {
      var current = CloudMemoryFormat.Hash(local);
      if (current == v.Hash) { Claim(path, v, onlyIfUnowned: true); return; }
      // Existing local text is never overwritten, except an untouched earlier version of this very record.
      var ancestors = Revision(v).Ancestors;
      if (!state.Versions.Values.Any(x => x.Key == v.Key && ancestors.Contains(x.Id) && x.Hash == current))
      {
        var suffix = "-cloud-" + v.Hash[..16];
        var sibling = path.EndsWith(".md", StringComparison.Ordinal) && !path.EndsWith("/card.md", StringComparison.Ordinal) && !path.EndsWith("/playbook.md", StringComparison.Ordinal)
          && !path.StartsWith("templates/", StringComparison.Ordinal) ? path[..^3] + suffix + ".md" : "archive/cloud-conflicts/" + v.StoreId + "/" + v.Hash + "/" + path;
        memory.WriteFile(sibling, bytes);
        state.FileOrigins[sibling] = new Origin { StoreId = v.StoreId, Key = v.Key, Version = v.Id };
        state.Heads[v.StoreId + ":" + v.Key] = new Head { Hash = v.Hash, Version = v.Id, Parents = v.Parents.ToList(), Base = v.Id };
        v.Projection = sibling;
        List(v, "file", sibling, "kept beside your own edit of " + path);
        return;
      }
    }
    memory.WriteFile(path, bytes);
    Claim(path, v, onlyIfUnowned: false);
  }
  private void Claim(string path, Version v, bool onlyIfUnowned)
  {
    v.Projection = path;
    var owned = state.FileOrigins.GetValueOrDefault(path);
    if (onlyIfUnowned && owned is not null && (owned.StoreId != v.StoreId || owned.Key != v.Key)) return;
    state.FileOrigins[path] = new Origin { StoreId = v.StoreId, Key = v.Key, Version = v.Id };
    state.Heads[v.StoreId + ":" + v.Key] = new Head { Hash = v.Hash, Version = v.Id, Parents = v.Parents.ToList(), Base = v.Id };
  }
  /// `projects/<id>/…` of another device goes only under the project this PC matched (W4); otherwise it waits.
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
    if (t.Name == "board" && v.StoreId != memory.StoreId && values[Index("id")] is { Type: "text", Value: { } boardId })
    {
      values[Index("id")] = DeckMemoryCell.Text("cloud:" + v.StoreId + ":" + boardId);
      values[Index("doing")] = DeckMemoryCell.Text("Stopped on another device");
    }
    // File-backed labels join the file actually kept; labels that arrive before their file wait for it.
    if (Index("path") is >= 0 and var pi && original[pi] is { Type: "text", Value: { } originalPath })
    {
      if (!references.TryGetValue("path", out var fileRef) || fileRef.Table != "file" || fileRef.Id != original[pi] || !Guid.TryParse(fileRef.StoreId, out _)) throw new CloudFailure("invalid_request");
      var mapped = state.Versions.Values.Where(x => x.StoreId == fileRef.StoreId && x.Key == "file/" + originalPath && !string.IsNullOrEmpty(x.Projection)).Select(x => x.Projection).LastOrDefault()
        ?? state.FileOrigins.FirstOrDefault(f => f.Value.StoreId == fileRef.StoreId && f.Value.Key == "file/" + originalPath).Key;
      if (mapped is null) { v.Waiting = "waiting_for_file"; return; }
      values[pi] = DeckMemoryCell.Text(mapped);
    }
    var keys = t.Keys.Select(k => values[Index(k)]).ToArray();
    DeckMemoryRow? existing = t.Name is "notes" or "topics" or "files" or "handoffs" && Index("path") is >= 0 and var path
      ? memory.Rows(t.Name).FirstOrDefault(r => r.Cells[path] == values[path])
      : memory.Rows(t.Name).FirstOrDefault(r => t.Keys.Select(k => r.Cells[Index(k)]).SequenceEqual(keys));
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
        var local = state.Versions.Values.LastOrDefault(x => x.Key == v.Key && x.Projection == encodedExisting && x != v) ?? PublishLocal(t, existing);
        if (CloudMemoryRevision.Winner(Revision(v), Revision(local)).Version != v.Id)
        {
          v.Projection = "";
          List(v, t.Name, v.Body!, "another device's value; yours is newer");
          return;
        }
        List(local, t.Name, Encoding.UTF8.GetString(CloudMemoryFormat.RowBody(t, existing.Cells)), "this PC's value; the other device's is newer");
        mayUpdate = true;
      }
      if (mayUpdate && tombstone)
      {
        memory.RemoveRow(t.Name, existingKeys);
        state.Removals[t.Name + "\n" + CloudMemoryFormat.NativeKey(t, existing.Cells)] = v.Id;
        state.Settings.Remove(CloudMemoryFormat.NativeKey(t, existing.Cells));
        v.Projection = "";
        return;
      }
      if (mayUpdate) { memory.PutRow(placed, existingKeys); Keep(v, t, placed); return; }
      // Rows that keep both (diary, board, history, questions, rewinds): the other version gets its own row.
      if (t.IntegerKey)
      {
        values[Index("id")] = DeckMemoryCell.Integer(memory.AllocateInteger(t.Name));
        if (t.Name == "diary" && values[Index("external_id")] is { Type: "text", Value: { } ext }) values[Index("external_id")] = DeckMemoryCell.Text(ext + ":cloud-" + v.Hash[..16]);
      }
      else if (t.Name == "board" && values[Index("id")] is { Type: "text", Value: { } id }) values[Index("id")] = DeckMemoryCell.Text(id + ":" + v.Hash);
      else { v.Projection = ""; List(v, t.Name, v.Body!, "kept as another version"); return; }
      placed = new DeckMemoryRow(t.Name, values);
      memory.PutRow(placed, null);
      Keep(v, t, placed);
      return;
    }
    // No local row: a removal this PC recorded is decided against the incoming version by the same rule.
    if (DeckMemoryCloudSchema.LastWriterTables.Contains(t.Name) && state.Removals.TryGetValue(t.Name + "\n" + CloudMemoryFormat.NativeKey(t, values), out var removed) && removed != v.Id
      && Find(v.Key, removed) is { } removal && CloudMemoryRevision.Winner(Revision(v), Revision(removal)).Version != v.Id)
    { v.Projection = ""; List(v, t.Name, v.Body!, "removed on another device later"); return; }
    if (tombstone) { state.Removals[t.Name + "\n" + CloudMemoryFormat.NativeKey(t, values)] = v.Id; v.Projection = ""; return; }
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
    if (t.Name == "settings") state.Settings.Add(CloudMemoryFormat.NativeKey(t, placed.Cells));
  }

  /// Gives a never-published local value its version now and queues it for the next send.
  private Version PublishLocal(DeckMemoryTable t, DeckMemoryRow existing)
  {
    var resource = Logical(t, existing);
    foreach (var op in Export(resource, () => localNow())) state.Pending.Add(Encoding.UTF8.GetString(CloudCanonical.Encode(op.ToJson())));
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

/// The memory store used until Windows has its own Deck Memory (and by the tests): everything in memory.
public sealed class InMemoryDeckMemoryStore(string storeId) : IDeckMemoryCloudStore
{
  private readonly Dictionary<string, List<DeckMemoryRow>> tables = new(StringComparer.Ordinal);
  private readonly SortedDictionary<string, byte[]> files = new(StringComparer.Ordinal);
  private readonly Dictionary<string, long> sequences = new(StringComparer.Ordinal);
  public string StoreId { get; } = storeId;
  public IReadOnlyList<DeckMemoryRow> Rows(string table) => tables.TryGetValue(table, out var list) ? list.ToArray() : [];
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
  public void RemoveRow(string table, IReadOnlyList<DeckMemoryCell> keys)
  {
    var t = DeckMemoryCloudSchema.Table(table);
    if (tables.TryGetValue(table, out var list)) list.RemoveAll(r => t.Keys.Select(k => r.Cells[t.Index(k)]).SequenceEqual(keys));
  }
  public long AllocateInteger(string table) => sequences[table] = sequences.GetValueOrDefault(table) + 1;
  public IReadOnlyDictionary<string, byte[]> Files() => new Dictionary<string, byte[]>(files, StringComparer.Ordinal);
  public void WriteFile(string path, byte[] bytes) { if (!DeckMemoryCloudSchema.SafePath(path)) throw new CloudFailure("invalid_request"); files[path] = bytes.ToArray(); }
}
