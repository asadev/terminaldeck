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
// - Removals and moves of memory FILES (the Macs' one rule, CloudMemoryOneRule.cs), only when the one rule is wired
//   (`oneRule`; the app always wires it): this PC says it understands them (`onerule.understands.<this PC>`), applies
//   one that arrives (the note's text goes into this PC's safety copy and its kept texts first; a note changed on this
//   PC after the removal was made stays), and sends one made here only while every device of the account understands
//   them, under the shared 15-minute brake. A file this PC never held is never removed anywhere. Without `oneRule`
//   nothing is announced, applied or sent (7C-1). A removed shared SETTING still leaves this PC's value and is listed.

/// One row of a memory table, cells in the table's column order (DeckMemoryCloudSchema).
public sealed record DeckMemoryRow(string Table, IReadOnlyList<DeckMemoryCell> Cells)
{
  public bool Same(DeckMemoryRow other) => Table == other.Table && Cells.SequenceEqual(other.Cells);
}

/// A file in the memory folder: '/'-separated relative path, size and last write time (ticks, any fixed origin).
public sealed record DeckMemoryFileInfo(string Path, long Length, long ModifiedTicks);

/// What a Deck Memory store gives Cloud. There is no way to remove a row through it; a file is removed only by the one
/// rule's apply, only when it still holds exactly the text that was kept first. Every write here comes from Cloud's
/// apply and is recognised as such by content.
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
  /// Removes the file only when its bytes still hash to `expectedHash` (an edit a moment ago is never removed).
  bool RemoveFile(string path, string expectedHash);
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
  public const string RemovedWhy = "removed on another device; its last text is kept on this PC";
  public const string EditKeptWhy = "removed or moved on another device, but this PC's text is not the one it was made from; this PC's text stays and goes back to your other devices";
  public const string OlderThanRemovalWhy = "an older text of a note that was removed since; kept on this PC, not used";
  private readonly CloudMemoryOneRulePorts? oneRule;
  private Func<long>? serviceNow;
  private bool announcedThisRun, incomingConfirmed;
  private bool? sendingForced;
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
    Func<string, string, string?>? projects = null, Func<long>? localNow = null, ICloudMemoryKeeper? keeper = null, CloudMemoryOneRulePorts? oneRule = null)
  {
    this.oneRule = oneRule;
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
  /// Removals from another device held here, not applied, until the person answers (more than the brake allows).
  public int HeldRemovals => state.Held.Count;
  /// Notes gone from this PC's memory folder that were NOT sent as removals because too many went at once.
  public int MissingNotSent => state.MissingWaiting;

  /// The memory store for one signed-in account on this PC: `<account folder>/memory` (notes and tables),
  /// `<account folder>/sync/memory.json` (this adapter's bookkeeping), `<account folder>/kept/memory` (kept texts).
  /// Per account, so signing in with another account never sends one account's memory into the other.
  /// The one rule (removals and moves) is on when `accountDevices` is given; its safety copies go to
  /// `<account folder>/memory-safety/<yyyyMMdd-HHmmss>`.
  public static CloudMemoryAdapter ForAccount(string accountFolder, string deviceId, Func<string, string, string?>? projects = null,
    Func<IReadOnlyCollection<string>?>? accountDevices = null) =>
    new(FileDeckMemoryStore.At(Path.Combine(accountFolder, "memory")), new CloudFileSlot(Path.Combine(accountFolder, "sync", "memory.json")), deviceId,
      projects: projects, keeper: new CloudMemoryKeptFolder(Path.Combine(accountFolder, "kept", "memory")),
      oneRule: accountDevices is null ? null : new CloudMemoryOneRulePorts(accountDevices, new CloudMemorySafetyFolder(accountFolder)));

  // ---- Durable bookkeeping (beside the sync store, one atomic file) ----

  private sealed class Head { public string Hash { get; set; } = ""; public string Version { get; set; } = ""; public List<string> Parents { get; set; } = []; public string? Base { get; set; } }
  private sealed class Version
  {
    public string StoreId { get; set; } = ""; public string Key { get; set; } = ""; public string Id { get; set; } = ""; public string Row { get; set; } = "";
    public string Hash { get; set; } = ""; public List<string> Parents { get; set; } = []; public long Stamp { get; set; } public bool Baseline { get; set; }
    public bool Own { get; set; } public string? FirstOp { get; set; } public Dictionary<int, string> PartOps { get; set; } = []; public int Count { get; set; }
    public Dictionary<int, string> Parts { get; set; } = []; public string? Body { get; set; } public string? Projection { get; set; }
    public string? Waiting { get; set; } public bool Done { get; set; } public string Device { get; set; } = "";
    /// 7C-2: the bytes of a file that waits for its project (base64), so it is placed once the project arrives.
    public string? WaitingBytes { get; set; }
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
    // ---- The one rule ----
    /// Removal markers this PC made or received, by their text's hash.
    public Dictionary<string, Removed> Removals { get; set; } = [];
    /// Removals from another device held, untouched, until the person answers.
    public List<HeldRemoval> Held { get; set; } = [];
    /// Gone files that passed the "too many at once" check and wait for the brake (they never count as newly gone again).
    public HashSet<string> Queued { get; set; } = [];
    public int MissingWaiting { get; set; }
    public bool MissingConfirmed { get; set; }
    public long? SentAt { get; set; } public int SentCount { get; set; }
    public long? AppliedAt { get; set; } public int AppliedCount { get; set; }
    public string? SafetyCopy { get; set; } public long SafetyTriedAt { get; set; }
  }
  private sealed class Removed { public string Path { get; set; } = ""; public long At { get; set; } public string By { get; set; } = ""; public string? MovedTo { get; set; } }
  private sealed class HeldRemoval
  {
    public string StoreId { get; set; } = ""; public string Key { get; set; } = ""; public string Version { get; set; } = "";
    public string Path { get; set; } = ""; public string Device { get; set; } = ""; public string Bytes { get; set; } = "";
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
  /// that changed: rows of the enabled tables (shared settings only; `meta` never) and memory-folder files; with the
  /// one rule, also this PC's "understands" setting and the removals and moves of files this PC held (SendRemovals).
  /// Stamped once, here, on the service clock. Deterministic ids: a capture repeated after a crash makes the same records.
  public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    if (!state.FeedRead) return Task.FromResult(CloudCapture.None);
    serviceNow = stampNow;
    if (oneRule is not null) { Announce(stampNow()); PrepareSafetyCopy(stampNow()); }
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
        // "This device understands removal records": only this PC's own, and only while the one rule is on here.
        if (t.Name == "settings" && row.Cells[t.Index("key")].Value is { } key && key.StartsWith(DeckMemoryCloudSchema.SharedSettingPrefix, StringComparison.Ordinal)
          && (oneRule is null || key != CloudMemoryOneRule.UnderstandsKey(deviceId))) continue;
        operations.AddRange(Export(Logical(t, row), stampNow));
      }
    var present = new HashSet<string>(StringComparer.Ordinal);
    foreach (var file in memory.ListFiles().OrderBy(f => f.Path, StringComparer.Ordinal))
    {
      ct.ThrowIfCancellationRequested();
      present.Add(file.Path);
      if (FileResource(file) is { } resource) operations.AddRange(Export(resource, stampNow));
    }
    // The Mac's capture order: new files first, then removals, so a rename's removal names where the text went.
    if (oneRule is not null) operations.AddRange(SendRemovals(present, stampNow));
    var committed = state;
    state = JsonSerializer.Deserialize<State>(before)!;
    var staged = committed;
    return Task.FromResult(new CloudCapture(operations, () => { state = staged; state.Pending.Clear(); memory.Flush(); Save(); }));
  }

  // ---- The one rule: understanding, the switch, the brake, sending (DeckMemoryStoreOneRule.swift) ----

  private long Now() => serviceNow?.Invoke() ?? localNow();
  private static readonly DeckMemoryTable SettingsTable = DeckMemoryCloudSchema.Table("settings");
  private string? SettingValue(string owner, string key) =>
    memory.Find("settings", [DeckMemoryCell.Text(owner), DeckMemoryCell.Text(key)])?.Cells[SettingsTable.Index("value")].Value;

  /// At the first capture of every run and every 12 hours: this PC understands removals and moves of this format, as of
  /// now (service clock). The Mac's own record: a shared memory setting, owner "", value "v2:<ms>".
  private void Announce(long now)
  {
    if (!Guid.TryParse(deviceId, out _) || now <= 0) return;
    var key = CloudMemoryOneRule.UnderstandsKey(deviceId);
    var held = CloudMemoryOneRule.ParseUnderstands(SettingValue("", key));
    if (announcedThisRun && held is { } h && h.Format == CloudMemoryOneRule.Format && h.At <= now && now - h.At < CloudMemoryOneRule.RenewAfter) return;
    var keys = new[] { DeckMemoryCell.Text(""), DeckMemoryCell.Text(key) };
    memory.PutRow(new("settings", [.. keys, DeckMemoryCell.Text(CloudMemoryOneRule.UnderstandsValue(now)), DeckMemoryCell.Real(now / 1000.0)]),
      memory.Find("settings", keys) is null ? null : keys);
    announcedThisRun = true;
  }

  /// The account's list is known, holds this PC, and every device in it said it understands, within the last 3 days.
  private bool EveryDeviceUnderstands(long now)
  {
    if (oneRule?.AccountDevices() is not { Count: > 0 } devices) return false;
    var me = deviceId.ToLowerInvariant();
    if (!devices.Any(d => d.Equals(me, StringComparison.OrdinalIgnoreCase))) return false;
    return devices.All(id => CloudMemoryOneRule.Fresh(SettingValue("", CloudMemoryOneRule.UnderstandsKey(id)), now));
  }
  private bool SafetyReady() => state.SafetyCopy is { } made && oneRule!.Safety.Exists(made);
  /// The safety copy, made as soon as every device understands (before anything is sent) and before the first removal
  /// is applied. A copy that fails keeps sending off and removes nothing; it is tried again an hour later.
  private bool PrepareSafetyCopy(long now, bool forApply = false)
  {
    if (oneRule is null) return false;
    if (SafetyReady()) return true;
    if (!forApply && !EveryDeviceUnderstands(now)) return false;
    // Before sending: tried again an hour after a failure. Before applying a removal: tried every time (else held).
    if (!forApply && state.SafetyTriedAt > 0 && now >= state.SafetyTriedAt && now - state.SafetyTriedAt < 3_600_000) return false;
    state.SafetyTriedAt = now;
    state.SafetyCopy = oneRule.Safety.Make(now);
    dirty = true;
    if (!forApply) Save();
    return state.SafetyCopy is not null;
  }
  /// THE switch for sending removals and moves: every device understands and the safety copy exists.
  private bool Sends(long now) => sendingForced ?? (EveryDeviceUnderstands(now) && SafetyReady());
  /// Tests only: force sending on or off (null = decide by the account).
  public void SetSendingForTests(bool? on) => sendingForced = on;
  private int Total() => Math.Max(1, Math.Max(state.FileStamps.Count, state.FileOrigins.Count));

  /// A file this PC held is gone from its memory folder: its removal (or, when the same text is now at another place,
  /// its move) travels as a new version of the same file whose text is a removal marker. Never for a file this PC
  /// never held, never for one whose newest version here already is a removal, never while the switch is off; at most
  /// the brake's limit per 15 minutes, and none at all when more than that went at once (until the person confirms).
  /// What waits keeps its "last seen" entry, so a later capture sends it.
  private IEnumerable<CloudOperation> SendRemovals(HashSet<string> present, Func<long> stampNow)
  {
    var gone = new List<(string Path, string Row, string StoreId, string Key, Head Head, Origin? Origin, string LastHash)>();
    foreach (var path in state.FileStamps.Keys.Concat(state.FileOrigins.Keys).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray())
    {
      if (present.Contains(path)) { state.Queued.Remove(path); continue; }
      var origin = state.FileOrigins.GetValueOrDefault(path);
      var storeId = origin?.StoreId ?? memory.StoreId;
      var key = origin?.Key ?? "file/" + path;
      var logical = key[5..];
      // Only a file at its own record's place travels (never a second copy, never a name Windows changed for another).
      if (!DeckMemoryCloudSchema.SafePath(logical) || DeckMemoryCloudSchema.AppHelpFiles.Contains(logical)
        || Placement(logical, storeId) is not { } placed || FileDeckMemoryStore.WindowsName(placed) != path) { Forget(path); continue; }
      var row = DeckMemoryCloudSchema.FileRow(logical);
      // Nothing of it ever travelled from or to this PC: nothing to remove anywhere (a joining PC removes nothing).
      if (row is null || !rows.Contains(row) || state.Heads.GetValueOrDefault(storeId + ":" + key) is not { } head) { Forget(path); continue; }
      // Its newest version here is already a removal (one that arrived, or one sent before).
      if (state.Removals.ContainsKey(head.Hash)) { Forget(path); continue; }
      var stamp = state.FileStamps.GetValueOrDefault(path);
      var lastHash = stamp is not null && stamp.LastIndexOf(':') is >= 0 and var c ? stamp[(c + 1)..] : head.Hash;
      gone.Add((path, row, storeId, key, head, origin, lastHash));
    }
    if (gone.Count == 0) { state.MissingWaiting = 0; state.MissingConfirmed = false; return []; }
    var now = stampNow();
    if (!Sends(now)) return [];
    var limit = CloudMemoryOneRule.Limit(Total());
    var confirmed = state.MissingConfirmed;
    var fresh = gone.Count(g => !state.Queued.Contains(g.Path));
    if (!confirmed && fresh > limit) { state.MissingWaiting = fresh; return []; }
    foreach (var g in gone) state.Queued.Add(g.Path);
    var window = CloudMemoryOneRule.Current(state.SentAt, state.SentCount, now);
    var room = confirmed ? int.MaxValue : Math.Max(0, limit - window.Count);
    // Where a text lives on: another file here now holding exactly the same bytes.
    var byHash = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var (p, s) in state.FileStamps.OrderBy(x => x.Key, StringComparer.Ordinal))
      if (present.Contains(p) && s.LastIndexOf(':') is >= 0 and var c2) byHash.TryAdd(s[(c2 + 1)..], p);
    var operations = new List<CloudOperation>();
    var sent = 0;
    foreach (var g in gone)
    {
      if (sent >= room) break;
      string? movedTo = null;
      if (byHash.TryGetValue(g.LastHash, out var there)) movedTo = state.FileOrigins.GetValueOrDefault(there) is { } o ? o.Key[5..] : there;
      var removal = new CloudMemoryRemoval(now, deviceId.ToLowerInvariant(), movedTo, Confirmed: confirmed);
      var name = g.Path.Split('/')[^1] is var last && last.EndsWith(".md", StringComparison.OrdinalIgnoreCase) ? last[..^3] : g.Path.Split('/')[^1];
      var bytes = removal.Text(CloudMemoryRemoval.NoteId(now, g.StoreId + "
" + g.Key + "
" + g.Head.Version), name);
      var hash = CloudMemoryFormat.Hash(bytes);
      operations.AddRange(Export(new Resource(g.Row, g.StoreId, g.Key, bytes, hash, g.Origin?.Version, null, g.Path), stampNow));
      state.Removals[hash] = new Removed { Path = g.Path, At = now, By = removal.By, MovedTo = movedTo };
      var made = state.Heads[g.StoreId + ":" + g.Key];
      if (Find(g.Key, made.Version) is { } marker) marker.Projection = "";
      state.FileOrigins[g.Path] = new Origin { StoreId = g.StoreId, Key = g.Key, Version = made.Version };
      state.FileStamps.Remove(g.Path);
      state.Queued.Remove(g.Path);
      window = (window.At, window.Count + 1);
      sent++;
    }
    state.SentAt = window.At; state.SentCount = window.Count;
    state.MissingWaiting = gone.Count - sent;
    if (state.MissingWaiting == 0) state.MissingConfirmed = false;
    return operations;

    void Forget(string path) { state.FileStamps.Remove(path); state.Queued.Remove(path); }
  }

  /// His answer "they are gone" to the notes missing on this PC that were not sent: the next capture sends them all.
  public void ConfirmMissing() { state.MissingConfirmed = true; Save(); }

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
    if (placed is null) { v.Waiting = "waiting_project_not_matched"; v.WaitingBytes = Convert.ToBase64String(bytes); return; }
    v.Waiting = null; v.WaitingBytes = null;
    // A name Windows cannot hold (a ':' or '?', a reserved name such as CON) is kept under the nearest allowed name;
    // the record keeps its original name, so it travels back unchanged.
    var path = FileDeckMemoryStore.WindowsName(placed);
    var local = memory.ReadFile(path);
    // A removal or a move from another device (the one rule). Without the one rule this PC keeps its copy and lists it.
    if (bytes.Length < CloudMemoryFormat.RemovalMarkerLimit && CloudMemoryFormat.IsRemovalMarker(bytes))
    {
      if (oneRule is not null && CloudMemoryRemoval.Parse(bytes) is { } removal) { ApplyRemoval(v, removal, path, local, bytes); return; }
      v.Projection = "";
      if (local is not null) List(v, "file", path, KeptRemovalWhy);
      return;
    }
    if (local is null)
    {
      // Not here because it was removed: placed only when it is newer than the removal (a put back, or an edit made
      // elsewhere that the removal was not made on top of).
      if (oneRule is not null && !NewerThanRemoval(v, path, bytes)) return;
      memory.WriteFile(path, bytes); Claim(path, v, onlyIfUnowned: false); return;
    }
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
    // His own text beats an untouched app default (the Mac's default rule), only between texts neither built on the other.
    if (mine is not null && !Related(v, mine) && CloudMemoryDefaults.Decide(placed, v.Hash, current, SeatTitle) is { } incomingWins)
    {
      if (incomingWins) UseIncoming(); else KeepIncoming();
      return;
    }
    if (mine is not null && (v.Parents.Contains(mine.Id) || CloudMemoryRevision.Winner(Revision(v), Revision(mine)).Version == v.Id)) { UseIncoming(); return; }
    KeepIncoming();

    void UseIncoming()
    {
      var kept = keeper.Keep(path, local!, "this PC", localNow());
      memory.WriteFile(path, bytes);
      Claim(path, v, onlyIfUnowned: false);
      if (mine is not null) List(mine, "file", kept, "this PC's text; the newer text from another device is in use");
    }
    void KeepIncoming()
    {
      v.Projection = "";
      List(v, "file", keeper.Keep(path, bytes, v.Device, localNow()), "another device's text; this PC's is newer and stays in use");
    }
  }

  private bool Related(Version a, Version b) => a.Parents.Contains(b.Id) || Revision(a).Ancestors.Contains(b.Id) || Revision(b).Ancestors.Contains(a.Id);
  private string? SeatTitle(string owner) => SettingValue(owner, "seat.title");

  // ---- The one rule: an arriving removal or move (cloudApplyRemoval, cloudAgainstRemoval, the held removals) ----

  /// The version of this file whose text is exactly `hash` (the newest such), or null: an edit made here that never
  /// became a version.
  private Version? KnownVersion(string path, string key, string hash)
  {
    var keys = new List<string> { key };
    if (state.FileOrigins.GetValueOrDefault(path) is { } origin && !keys.Contains(origin.Key)) keys.Add(origin.Key);
    if (!keys.Contains("file/" + path)) keys.Add("file/" + path);
    foreach (var k in keys) if (VersionsOf(k).LastOrDefault(x => x.Hash == hash && x.Done) is { } found) return found;
    return null;
  }

  /// Decided by the Cloud's revision order, never a time stamp: a plain removal wins only over a text it was made on
  /// top of; a move only over exactly the version it was made from. A text changed here since (a version the removal
  /// does not descend from, or an edit that is not a version yet) stays, and goes back to the other devices.
  private void ApplyRemoval(Version v, CloudMemoryRemoval removal, string path, byte[]? local, byte[] marker)
  {
    state.Removals[v.Hash] = new Removed { Path = path, At = removal.At, By = removal.By, MovedTo = removal.MovedTo };
    v.Projection = "";
    if (local is null) { TakeRemoval(v, path); return; }
    var current = CloudMemoryFormat.Hash(local);
    var mine = KnownVersion(path, v.Key, current);
    var wins = mine is not null && (v.Parents.Contains(mine.Id) || removal.MovedTo is null && Revision(v).Ancestors.Contains(mine.Id));
    if (!wins) { List(v, "file", path, EditKeptWhy); return; }
    // A move whose text is already in use here at its new place is never held and never counted.
    var identical = IdenticalInUse(removal.MovedTo, v.StoreId, local);
    if (!identical && Hold(v, path, marker, removal)) return;
    // Never removed without a safety copy of the whole memory and this note's last text kept first.
    if (!PrepareSafetyCopy(Now(), forApply: true)) { HoldAnyway(v, path, marker, removal); return; }
    var kept = keeper.Keep(path, local, string.IsNullOrEmpty(removal.By) ? v.Device : removal.By, Now());
    if (!memory.RemoveFile(path, current)) { List(v, "file", path, EditKeptWhy); return; }
    TakeRemoval(v, path);
    if (!identical) List(v, "file", kept, RemovedWhy);
  }
  /// The removal is this file's newest version here: what arrives later is decided against it.
  private void TakeRemoval(Version v, string path)
  {
    state.FileOrigins[path] = new Origin { StoreId = v.StoreId, Key = v.Key, Version = v.Id };
    state.Heads[v.StoreId + ":" + v.Key] = new Head { Hash = v.Hash, Version = v.Id, Parents = v.Parents.ToList(), Base = v.Id };
    state.FileStamps.Remove(path);
    state.Queued.Remove(path);
  }
  /// Is the same text (bytes, or the same words under other labels) in use at the move's new place here?
  private bool IdenticalInUse(string? movedTo, string storeId, byte[] bytes)
  {
    if (movedTo is null || !DeckMemoryCloudSchema.SafePath(movedTo)) return false;
    var body = FrontMatter.Of(Encoding.UTF8.GetString(bytes)).Body;
    foreach (var place in new[] { Placement(movedTo, storeId), movedTo }.OfType<string>().Select(FileDeckMemoryStore.WindowsName).Distinct())
    {
      byte[]? there;
      try { there = memory.ReadFile(place); } catch (CloudFailure) { continue; }
      if (there is null) continue;
      if (there.AsSpan().SequenceEqual(bytes) || FrontMatter.Of(Encoding.UTF8.GetString(there)).Body == body) return true;
    }
    return false;
  }
  /// More removals from other devices than the brake allows in 15 minutes: this one and every later one are held,
  /// untouched, until the person answers on this PC. True = held.
  private bool Hold(Version v, string path, byte[] marker, CloudMemoryRemoval removal)
  {
    if (incomingConfirmed) return false;
    var window = CloudMemoryOneRule.Current(state.AppliedAt, state.AppliedCount, Now());
    if (state.Held.Count == 0 && window.Count < CloudMemoryOneRule.Limit(Total()))
    {
      state.AppliedAt = window.At; state.AppliedCount = window.Count + 1;
      return false;
    }
    HoldAnyway(v, path, marker, removal);
    return true;
  }
  private void HoldAnyway(Version v, string path, byte[] marker, CloudMemoryRemoval removal)
  {
    if (state.Held.Any(h => h.StoreId == v.StoreId && h.Key == v.Key && h.Version == v.Id)) return;
    state.Held.Add(new HeldRemoval { StoreId = v.StoreId, Key = v.Key, Version = v.Id, Path = path, Device = string.IsNullOrEmpty(removal.By) ? v.Device : removal.By, Bytes = Convert.ToBase64String(marker) });
  }

  /// An arrival for a file that is not here. False = it is older history of a removal this PC holds as the file's
  /// newest version (kept, not placed). A put back (made on top of the removal), or an edit the removal was not made on
  /// top of, is placed.
  private bool NewerThanRemoval(Version v, string path, byte[] bytes)
  {
    var heads = new List<(string StoreId, string Key)> { (v.StoreId, v.Key) };
    if (state.FileOrigins.GetValueOrDefault(path) is { } origin && (origin.StoreId != v.StoreId || origin.Key != v.Key)) heads.Add((origin.StoreId, origin.Key));
    foreach (var (storeId, key) in heads)
    {
      if (state.Heads.GetValueOrDefault(storeId + ":" + key) is not { } head || !state.Removals.ContainsKey(head.Hash) || head.Version == v.Id) continue;
      if (v.Parents.Contains(head.Version)) return true;
      if (Find(key, head.Version) is { } removal && Revision(removal).Ancestors.Contains(v.Id))
      {
        v.Projection = "";
        List(v, "file", keeper.Keep(path, bytes, v.Device, localNow()), OlderThanRemovalWhy);
        return false;
      }
      return true;
    }
    return true;
  }

  /// The held removals that are still the newest thing for their note (a newer arrival or a put back made them history).
  private List<(HeldRemoval Held, Version Version)> TakeHeld()
  {
    var out_ = new List<(HeldRemoval, Version)>();
    foreach (var h in state.Held)
    {
      if (Find(h.Key, h.Version) is not { } v) continue;
      if (state.Heads.GetValueOrDefault(h.StoreId + ":" + h.Key) is { } head && head.Version != h.Version
        && Find(h.Key, head.Version) is { } newer && Revision(newer).Ancestors.Contains(h.Version)) continue;
      out_.Add((h, v));
    }
    state.Held.Clear();
    return out_;
  }
  /// His answer "they are gone" for removals held here: each is decided now by the same rule as any arrival (a note
  /// changed on this PC since still stays). Returns how many were looked at.
  public int ConfirmHeldRemovals()
  {
    var held = TakeHeld();
    incomingConfirmed = true;
    try { foreach (var (h, v) in held) ProjectFile(v, Convert.FromBase64String(h.Bytes)); }
    finally { incomingConfirmed = false; }
    memory.Flush(); Save();
    return held.Count;
  }
  /// His other answer, "keep them": each held note stays here and goes out again as a new version made on top of the
  /// removal, so it comes back on the device that removed it too. Returns how many were kept.
  public int KeepHeldRemovals()
  {
    var kept = 0;
    foreach (var (h, v) in TakeHeld())
    {
      if (memory.ReadFile(h.Path) is null) continue;
      if (CloudMemoryRemoval.Parse(Convert.FromBase64String(h.Bytes)) is { } removal)
        state.Removals[v.Hash] = new Removed { Path = h.Path, At = removal.At, By = removal.By, MovedTo = removal.MovedTo };
      TakeRemoval(v, h.Path);
      kept++;
    }
    Save();
    return kept;
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

  /// 7C-2: a project became known on this PC (arrived through Cloud or made here). Project memory that waited for it is
  /// placed now under the same project id: files first, then the labels that waited for them. Saved once.
  public void RetryProjects()
  {
    var placed = false;
    foreach (var v in state.Versions.Values.Where(x => x.Waiting == "waiting_project_not_matched").OrderBy(x => x.Key, StringComparer.Ordinal).ToArray())
    {
      try
      {
        if (v.WaitingBytes is { } held) ProjectFile(v, Convert.FromBase64String(held));
        else if (v.Body is not null) ProjectRow(v);
        placed |= v.Waiting is null;
      }
      catch (CloudFailure) { }
    }
    if (!placed) return;
    try { RetryWaitingRows(); } catch (CloudFailure) { }
    memory.Flush();
    Save();
  }

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
  public bool RemoveFile(string path, string expectedHash)
  {
    if (!files.TryGetValue(path, out var bytes) || CloudMemoryFormat.Hash(bytes) != expectedHash) return false;
    files.Remove(path); written.Remove(path);
    return true;
  }
  /// The person's own removal or move on this device (tests).
  public void DeleteFile(string path) { files.Remove(path); written.Remove(path); }
  public void Flush() { }
}
