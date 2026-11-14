using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// The per-account bookkeeping of the lean records (the Mac's CloudBrainAgentsStore.swift, design v2 D8): every version
// of every record (small nodes), the contents of the current heads and of this PC's own versions not yet handed to the
// engine, what this PC last STORED for each record (its image) and the fields it holds back, and the listed other
// versions. One small file per record under `<account folder>\records\<domain>\`, read once at start and indexed in
// memory; only the records that changed are written, once per pack (Flush), never the whole state per record.

public sealed class CloudRecordTooFarAhead(string opId) : Exception("This record is dated more than a day ahead of the Cloud's clock.")
{
  public string OpId { get; } = opId;
}

public sealed record CloudRecordKey(string Domain, string Entity)
{
  public static CloudRecordKey Of(string domain, string entity)
  {
    if (domain.Length is 0 or > 128 || !char.IsAsciiLetterOrDigit(domain[0]) || domain.Any(c => !(c is >= 'a' and <= 'z' or >= '0' and <= '9' or '/' or '_' or '-'))
      || entity.Length == 0 || Encoding.UTF8.GetByteCount(entity) > 256 || entity.Contains('\0')) throw new CloudFailure("invalid_request");
    return new(domain, entity);
  }
}

public sealed record CloudRecordOtherVersion(CloudRecordKey Key, CloudMergeConflict Conflict);

public sealed class CloudRecordStore
{
  /// A version dated more than this far ahead of this PC's service clock is refused.
  public const long MaximumAhead = 86_400_000;

  private sealed class PayloadRow { public string Version { get; set; } = ""; public bool Head { get; set; } public bool Unhanded { get; set; } }
  private sealed class NodeRow { public string Op { get; set; } = ""; public List<string> Parents { get; set; } = []; public string Device { get; set; } = ""; public long Time { get; set; } public bool Baseline { get; set; } }
  private sealed class OtherRow { public string Field { get; set; } = ""; public string Revision { get; set; } = ""; public string Value { get; set; } = ""; public string Device { get; set; } = ""; public long Time { get; set; } }
  private sealed class Row
  {
    public string Domain { get; set; } = ""; public string Entity { get; set; } = "";
    public List<NodeRow> Nodes { get; set; } = [];
    public Dictionary<string, PayloadRow> Payloads { get; set; } = [];
    public List<string> Heads { get; set; } = [];
    public bool Stored { get; set; }
    public string? Image { get; set; }
    public List<string> Held { get; set; } = [];
    public List<OtherRow> Others { get; set; } = [];
  }
  private sealed class Meta { public bool Joining { get; set; } = true; public bool FeedRead { get; set; } public List<string> Joined { get; set; } = []; }

  private readonly string folder;
  private readonly Dictionary<CloudRecordKey, Row> rows = [];
  private readonly Dictionary<string, CloudRecordKey> opIndex = new(StringComparer.Ordinal);
  private readonly HashSet<CloudRecordKey> dirty = [];
  private readonly HashSet<string> domains = new(StringComparer.Ordinal);
  private Meta meta;
  private bool metaDirty;
  private readonly object gate = new();
  public string Folder => folder;
  /// The service-corrected clock (ms). The adapter sets it from the engine's `stampNow` at each capture.
  public Func<long> Clock { get; set; }

  /// `folder`: this account's own `records` folder (`cloud\accounts\<account>\records`).
  public CloudRecordStore(string folder, Func<long>? clock = null)
  {
    this.folder = folder;
    Clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    var metaFile = Path.Combine(folder, "store.json");
    meta = File.Exists(metaFile) ? JsonSerializer.Deserialize<Meta>(File.ReadAllBytes(metaFile)) ?? new Meta() : new Meta();
    if (!Directory.Exists(folder)) return;
    foreach (var file in Directory.EnumerateDirectories(folder).SelectMany(d => Directory.EnumerateFiles(d, "*.json")))
    {
      Row? row;
      try { row = JsonSerializer.Deserialize<Row>(File.ReadAllBytes(file)); }
      catch (JsonException) { continue; }
      if (row is null || row.Domain.Length == 0) continue;
      var key = new CloudRecordKey(row.Domain, row.Entity);
      rows[key] = row;
      foreach (var node in row.Nodes) opIndex[node.Op] = key;
    }
  }

  // ---- join mode (rule J) and the first full feed read ----

  /// True while captures without a stored image count as baseline even before the Cloud's heads arrive: a PC that has not
  /// yet finished its first sync with this account.
  public bool Joining { get { lock (gate) return meta.Joining; } }
  public bool FeedReadDone { get { lock (gate) return meta.FeedRead; } }
  /// Every domain that uses this store registers itself; the join ends only once each has committed a capture.
  public void Register(string domain) { lock (gate) domains.Add(domain); }
  public bool MarkFeedRead()
  {
    lock (gate)
    {
      if (meta.FeedRead) return false;
      meta.FeedRead = true; metaDirty = true;
      return true;
    }
  }
  public void Committed(string domain)
  {
    lock (gate)
    {
      if (!meta.Joining) return;
      if (!meta.Joined.Contains(domain)) { meta.Joined.Add(domain); metaDirty = true; }
      if (domains.All(meta.Joined.Contains)) { meta.Joining = false; metaDirty = true; }
    }
  }

  // ---- persistence ----

  private string FileOf(CloudRecordKey key) =>
    Path.Combine(folder, key.Domain.Replace('/', '_'), CloudBytes.Sha256Hex(Encoding.UTF8.GetBytes(key.Entity))[..32] + ".json");
  /// Writes every record changed since the last flush, and the join marks: once per pack.
  public void Flush()
  {
    lock (gate)
    {
      foreach (var key in dirty)
        if (rows.TryGetValue(key, out var row)) new CloudFileSlot(FileOf(key)).Write(JsonSerializer.SerializeToUtf8Bytes(row));
      dirty.Clear();
      if (metaDirty) { new CloudFileSlot(Path.Combine(folder, "store.json")).Write(JsonSerializer.SerializeToUtf8Bytes(meta)); metaDirty = false; }
    }
  }
  private Row RowOf(CloudRecordKey key, bool create)
  {
    if (rows.TryGetValue(key, out var row)) return row;
    row = new Row { Domain = key.Domain, Entity = key.Entity };
    if (create) rows[key] = row;
    return row;
  }

  // ---- reads ----

  private static CloudMergeGraph Graph(Row row) => new(row.Nodes.Select(n => new CloudMergeNode(n.Op, n.Parents, n.Device, n.Time, n.Baseline)));
  private static Dictionary<string, CloudMergeVersion> HeadPayloads(Row row) =>
    row.Payloads.Where(p => p.Value.Head).ToDictionary(p => p.Key, p => CloudMergeVersion.Parse(CloudJson.Parse(p.Value.Version)), StringComparer.Ordinal);
  private static (CloudMergeGraph Graph, CloudMergeView? View) LoadView(Row row, CloudMergeTable table)
  {
    var graph = Graph(row);
    var heads = graph.Heads;
    if (heads.Count == 0) return (graph, null);
    return (graph, CloudRecordMerge.View(heads, HeadPayloads(row), graph, table));
  }
  public CloudMergeGraph GraphOf(CloudRecordKey key) { lock (gate) return Graph(RowOf(key, false)); }
  public bool Holds(CloudRecordKey key) { lock (gate) return rows.TryGetValue(key, out var row) && row.Nodes.Count > 0; }
  /// Throws CloudMergeHistoryIncomplete while a version it needs has not arrived.
  public CloudMergeView? View(CloudRecordKey key, CloudMergeTable table) { lock (gate) return LoadView(RowOf(key, false), table).View; }
  public (bool Stored, CloudJson.Object? Value) Image(CloudRecordKey key)
  {
    lock (gate)
    {
      var row = RowOf(key, false);
      return (row.Stored, row.Image is null ? null : CloudJson.Parse(row.Image) as CloudJson.Object);
    }
  }
  public IReadOnlySet<string> Held(CloudRecordKey key) { lock (gate) return RowOf(key, false).Held.ToHashSet(StringComparer.Ordinal); }
  public void SetHeld(CloudRecordKey key, IEnumerable<string> fields)
  {
    lock (gate)
    {
      var row = RowOf(key, true);
      var next = fields.Distinct(StringComparer.Ordinal).OrderBy(f => f, StringComparer.Ordinal).ToList();
      if (row.Held.SequenceEqual(next)) return;
      row.Held = next; dirty.Add(key);
    }
  }

  // ---- other versions ----

  private static void RefreshOthers(Row row, CloudMergeTable table)
  {
    CloudMergeView? view;
    try { view = LoadView(row, table).View; } catch (CloudMergeHistoryIncomplete) { return; }
    row.Others = (view?.Conflicts ?? Array.Empty<CloudMergeConflict>()).Select(c => new OtherRow { Field = c.Field, Revision = c.Revision, Value = CloudRecordJson.Encode(c.Value), Device = c.Device, Time = c.Time }).ToList();
  }
  public int OtherVersionCount(string domain) { lock (gate) return rows.Values.Where(r => r.Domain == domain).Sum(r => r.Others.Count); }
  public IReadOnlyList<CloudRecordOtherVersion> OtherVersions(string domain, int limit = 200)
  {
    lock (gate)
      return rows.Values.Where(r => r.Domain == domain).OrderBy(r => r.Entity, StringComparer.Ordinal)
        .SelectMany(r => r.Others.OrderBy(o => o.Field, StringComparer.Ordinal).ThenBy(o => o.Revision, StringComparer.Ordinal)
          .Select(o => new CloudRecordOtherVersion(new(r.Domain, r.Entity), new(o.Field, o.Revision, CloudJson.Parse(o.Value), o.Device, o.Time))))
        .Take(limit).ToArray();
  }

  // ---- writes ----

  /// Retains received versions. A version already known is skipped; a version that arrives after one of its children
  /// keeps only its node; a version dated more than a day ahead of the service clock is refused before anything is kept.
  public void Receive(CloudRecordKey key, IReadOnlyList<CloudMergeRevision> revisions, CloudMergeTable table)
  {
    var limit = Clock() + MaximumAhead;
    if (revisions.FirstOrDefault(r => r.Time > limit) is { } ahead) throw new CloudRecordTooFarAhead(ahead.OpId);
    lock (gate)
    {
      var row = RowOf(key, true);
      foreach (var revision in revisions) Insert(key, row, revision, own: false);
      RefreshOthers(row, table);
      dirty.Add(key);
    }
  }
  private void Insert(CloudRecordKey key, Row row, CloudMergeRevision revision, bool own)
  {
    if (opIndex.ContainsKey(revision.OpId)) return;
    row.Nodes.Add(new NodeRow { Op = revision.OpId, Parents = revision.Parents.ToList(), Device = revision.Node.Device, Time = revision.Time, Baseline = revision.Node.Baseline });
    opIndex[revision.OpId] = key;
    var isHead = !row.Nodes.Any(n => n.Parents.Contains(revision.OpId));
    if (isHead || own) row.Payloads[revision.OpId] = new PayloadRow { Version = CloudRecordJson.Encode(revision.Version.Payload()), Head = isHead, Unhanded = own };
    foreach (var parent in revision.Parents)
      if (row.Payloads.TryGetValue(parent, out var p))
      {
        p.Head = false;
        // Only the heads' contents are kept, plus this PC's own versions until the engine has them.
        if (!p.Unhanded) row.Payloads.Remove(parent);
      }
  }

  /// Captures what this PC's owner stores for a record (`local` null = removed here): builds the version over the view
  /// against the stored image and keeps the new image. `baseline` null decides rule J here: baseline only when this PC
  /// never stored the record and either holds Cloud heads for it or is joining.
  public CloudMergeRevision? Capture(CloudRecordKey key, CloudJson.Object? local, CloudMergeTable table, string opId, string device,
    IReadOnlySet<string>? chosen = null, bool restore = false, bool? baseline = null)
  {
    lock (gate)
    {
      var row = RowOf(key, true);
      var (graph, view) = LoadView(row, table);
      var isBaseline = baseline ?? (!row.Stored && (view is not null || meta.Joining));
      var image = row.Image is null ? null : CloudJson.Parse(row.Image) as CloudJson.Object;
      var revision = CloudRecordMerge.Revision(view, isBaseline ? null : image, local, row.Held.ToHashSet(StringComparer.Ordinal), chosen, restore, table, opId, device,
        Clock(), isBaseline, graph);
      if (revision is not null) Insert(key, row, revision, own: true);
      row.Image = local is null ? null : CloudRecordJson.Encode(local); row.Stored = true;
      row.Heads = revision is null ? (view?.Heads ?? Array.Empty<string>()).ToList() : Graph(row).Heads.ToList();
      RefreshOthers(row, table);
      dirty.Add(key);
      return revision;
    }
  }

  /// After the owner wrote the view for these heads: what it stored becomes the image.
  public void Shown(CloudRecordKey key, IReadOnlyList<string> heads, CloudJson.Object? value)
  {
    lock (gate)
    {
      var row = RowOf(key, true);
      row.Heads = heads.ToList(); row.Image = value is null ? null : CloudRecordJson.Encode(value); row.Stored = true;
      dirty.Add(key);
    }
  }

  /// This PC's own versions of one domain not yet handed to the engine, oldest first, each with its record.
  public IReadOnlyList<(CloudRecordKey Key, CloudMergeRevision Revision)> OwnUnhanded(string domain)
  {
    lock (gate)
      return rows.Values.Where(r => r.Domain == domain).SelectMany(r => r.Payloads.Where(p => p.Value.Unhanded).Select(p =>
        {
          var node = r.Nodes.First(n => n.Op == p.Key);
          return (Key: new CloudRecordKey(r.Domain, r.Entity), Revision: new CloudMergeRevision(new CloudMergeNode(node.Op, node.Parents, node.Device, node.Time, node.Baseline),
            CloudMergeVersion.Parse(CloudJson.Parse(p.Value.Version))));
        })).OrderBy(x => x.Revision.Time).ThenBy(x => x.Revision.OpId, StringComparer.Ordinal).ToArray();
  }
  /// The engine holds these now: contents of versions that are no longer heads are dropped.
  public void MarkHanded(IEnumerable<string> ids)
  {
    lock (gate)
      foreach (var id in ids)
      {
        if (!opIndex.TryGetValue(id, out var key) || !rows.TryGetValue(key, out var row) || !row.Payloads.TryGetValue(id, out var p)) continue;
        p.Unhanded = false;
        if (!p.Head) row.Payloads.Remove(id);
        dirty.Add(key);
      }
  }
  /// Records of one domain this PC holds a stored value for.
  public IReadOnlyList<string> StoredEntities(string domain)
  {
    lock (gate) return rows.Values.Where(r => r.Domain == domain && r.Stored && r.Image is not null).Select(r => r.Entity).OrderBy(e => e, StringComparer.Ordinal).ToArray();
  }
  /// Records of one domain with fields this PC deliberately does not show, by record.
  public IReadOnlyDictionary<string, IReadOnlySet<string>> HeldEntities(string domain)
  {
    lock (gate)
      return rows.Values.Where(r => r.Domain == domain && r.Held.Count > 0).OrderBy(r => r.Entity, StringComparer.Ordinal)
        .ToDictionary(r => r.Entity, r => (IReadOnlySet<string>)r.Held.ToHashSet(StringComparer.Ordinal), StringComparer.Ordinal);
  }
}
