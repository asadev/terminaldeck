using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// AI instruction files travelling on Windows (7C-3, inventory row I09, domain `brain/files/i09`): a project's CLAUDE.md,
// AGENTS.md, GEMINI.md and its `.claude/agents|skills|commands`, `.agents/skills`, `.codex/skills`, `.gemini/skills`
// text files, by the Mac's own list (CloudBootFilesFormat). Record shapes, ids and the rules are the Mac's
// (td-mac-next BackendCloudBootFiles*.swift). The rules kept here on purpose:
// - Places: ONLY a project's folder on this PC, given by the project list (`projectFolders`, 7C-2). The Mac does not
//   sync the AI tools' own home folders (~/.claude, ~/.codex, ~/.gemini) in this version (NativeCloudBoot.swift), so
//   Windows does not either: a home record that arrives is kept and waits, and nothing is written into a home folder.
//   A project with no folder on this PC waits too ("no chosen folder"); a folder is never guessed. Agent instruction
//   text is not a boot file: it travels with the agents (I10, 7C-2).
// - Never sent and never written: settings, hooks, MCP, permission and sign-in files, hidden names, links, anything
//   that is not text or is larger than 1 MB. An arriving record naming one is refused before a byte is kept.
// - First copy (rule J): nothing is sent before the whole feed was read once. A file this PC never agreed on with the
//   Cloud is a first saved copy and loses: where the Cloud already holds that path, the Cloud's text is used here and
//   this PC's text is kept and listed; it is never sent over the account's version.
// - One rule: two different texts of one file, the newer (the version's own time, clamped to [agreed time, now]) is
//   used on every device; the other text is kept (outside the folder, never sent) and listed. A file is written only
//   if it still holds exactly the bytes just read; otherwise nothing is written and it is tried again later.
// - A file that can run a command or grant tools (CloudBootFilesFormat.RunReasons) waits: Windows has no Accept step yet.
// - Removals do NOT travel to or from Windows yet, and sync never deletes anything in a person's folder.

/// One line the Cloud page can show: a file written here from another device, a text kept, or a file that waits.
public sealed record CloudBootFilesLine(string Kind, string Place, string Path, string Device, string Why, string? Kept, long At);

public sealed class CloudBootFilesAdapter : ICloudSyncAdapter
{
  public const string WaitingFolder = "no-folder", WaitingHome = "home", WaitingAccept = "needs-accept", RefusedFolder = "home-folder";
  private readonly ICloudLedgerSlot slot;
  private readonly string retained;
  private readonly ICloudMemoryKeeper keeper;
  private readonly string deviceId;
  private readonly Func<long> localNow;
  private readonly Func<IReadOnlyDictionary<string, string>>? projectFolders;
  private readonly IReadOnlyList<string> guarded;
  private readonly bool autoAccept;
  private IReadOnlyDictionary<string, string>? foldersNow;
  private State state;
  private bool dirty;

  /// `projectFolders`: project id (the id every device shares) → this PC's folder for that project's instruction files,
  /// null or missing = the project's files wait. `userProfile`: the folder whose AI homes a project folder may never be
  /// (or hold); `stateFolder`: this adapter's own folder, never inside a project folder.
  public CloudBootFilesAdapter(ICloudLedgerSlot slot, string retainedFolder, string deviceId, Func<IReadOnlyDictionary<string, string>>? projectFolders = null,
    Func<long>? localNow = null, ICloudMemoryKeeper? keeper = null, string? userProfile = null, string? stateFolder = null, bool autoAccept = false)
  {
    CloudBytes.TransportId(deviceId);
    this.slot = slot; retained = retainedFolder; this.deviceId = deviceId; this.projectFolders = projectFolders; this.autoAccept = autoAccept;
    this.localNow = localNow ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.keeper = keeper ?? new CloudMemoryKeptInMemory();
    var profile = userProfile ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var list = new List<string>();
    if (profile.Length > 0) list.AddRange(new[] { "", ".claude", ".codex", ".gemini", ".agents" }.Select(h => h.Length == 0 ? profile : Path.Combine(profile, h)));
    if (stateFolder is not null) list.Add(stateFolder);
    list.Add(retainedFolder);
    guarded = list;
    state = slot.Read() is { } bytes ? JsonSerializer.Deserialize<State>(bytes) ?? new State() : new State();
    if (!Guid.TryParse(state.StoreId, out _)) state.StoreId = Guid.NewGuid().ToString("D");
  }

  /// One signed-in account on this PC: `<account>\sync\bootfiles.json` (this bookkeeping), `<account>\bootfiles\retained`
  /// (the Cloud's texts by fingerprint), `<account>\kept\instructions` (texts not in use). Never inside a project folder.
  public static CloudBootFilesAdapter ForAccount(string accountFolder, string deviceId, Func<IReadOnlyDictionary<string, string>>? projectFolders = null) =>
    new(new CloudFileSlot(Path.Combine(accountFolder, "sync", "bootfiles.json")), Path.Combine(accountFolder, "bootfiles", "retained"), deviceId, projectFolders,
      keeper: new CloudMemoryKeptFolder(Path.Combine(accountFolder, "kept", "instructions")), stateFolder: accountFolder);

  public IReadOnlyCollection<string> Domains => [CloudBootFilesFormat.Domain];

  // ---- Durable bookkeeping (one atomic file, saved once per pack) ----

  private sealed class Head
  {
    public string Version { get; set; } = ""; public string StoreId { get; set; } = ""; public string Key { get; set; } = ""; public string Hash { get; set; } = "";
    public List<string> Parents { get; set; } = []; public long CreatedAt { get; set; } public string Device { get; set; } = "";
  }
  private sealed class PathState
  {
    /// The fingerprint this PC's file and the Cloud last agreed on (null: never).
    public string? Base { get; set; }
    /// The version in use for this path (this PC's own, or the one that arrived and was written).
    public Head? Head { get; set; }
    public string? Stamp { get; set; }
    /// The one rule: this PC's edit is newer than a version made apart from it; it is recorded beside that one.
    public List<string>? NextParents { get; set; }
    /// The Cloud already holds a version of this path.
    public bool CloudHeld { get; set; }
    public List<long> Newer { get; set; } = [];
  }
  private sealed class Arrived
  {
    public long Seq { get; set; } public string StoreId { get; set; } = ""; public string Key { get; set; } = ""; public string Version { get; set; } = "";
    public string Hash { get; set; } = ""; public string SourceId { get; set; } = ""; public string Relative { get; set; } = "";
    public List<string> Parents { get; set; } = []; public long CreatedAt { get; set; } public string Device { get; set; } = "";
    public int Count { get; set; } public long Bytes { get; set; } public Dictionary<int, string> Parts { get; set; } = [];
    public bool Done { get; set; } public bool Settled { get; set; } public string? Waiting { get; set; }
  }
  private sealed class Known { public string Hash { get; set; } = ""; public List<string> Parents { get; set; } = []; }
  private sealed class Line
  {
    public string Kind { get; set; } = ""; public string SourceId { get; set; } = ""; public string Relative { get; set; } = ""; public string Device { get; set; } = "";
    public string Why { get; set; } = ""; public string? Kept { get; set; } public long At { get; set; }
  }
  private sealed class State
  {
    public string StoreId { get; set; } = "";
    /// The whole feed was read once: before that nothing of this PC is captured (its first copy waits for the Cloud's).
    public bool FeedRead { get; set; }
    public long Seq { get; set; }
    public Dictionary<string, PathState> Paths { get; set; } = [];
    public Dictionary<string, Arrived> Versions { get; set; } = [];
    public Dictionary<string, Known> Known { get; set; } = [];
    public HashSet<string> Applied { get; set; } = [];
    public List<Line> Lines { get; set; } = [];
  }
  private void Save() { slot.Write(JsonSerializer.SerializeToUtf8Bytes(state)); dirty = false; }
  private static string Pk(string sourceId, string relative) => sourceId + "\n" + relative;
  private PathState PathOf(string pk) => state.Paths.TryGetValue(pk, out var ps) ? ps : state.Paths[pk] = new PathState();

  public Task SettleAsync(CancellationToken ct)
  {
    foldersNow = null;
    if (dirty) Save();
    return Task.CompletedTask;
  }
  public bool FeedRead()
  {
    if (state.FeedRead) return false;
    state.FeedRead = true;
    Save();
    return true;
  }

  // ---- What the page shows ----

  public IReadOnlyList<CloudBootFilesLine> Lines =>
    state.Lines.Select(l => new CloudBootFilesLine(l.Kind, PlaceName(l.SourceId), l.Relative, l.Device, l.Why, l.Kept, l.At))
      .Concat(state.Versions.Values.Where(v => v.Done && !v.Settled && v.Waiting is not null).OrderBy(v => v.Seq)
        .Select(v => new CloudBootFilesLine("waiting", PlaceName(v.SourceId), v.Relative, v.Device, WaitingWhy(v.Waiting!), null, v.CreatedAt))).ToArray();
  public int WaitingCount => state.Versions.Values.Count(v => v.Done && !v.Settled && v.Waiting is not null);
  private static string PlaceName(string sourceId) =>
    CloudBootFilesFormat.ParseSourceId(sourceId) is { } p ? (CloudBootFilesFormat.Untoken(p.Token) ?? p.Token) : sourceId;
  private static string WaitingWhy(string code) => code switch
  {
    WaitingFolder => "waiting for this project's folder on this PC",
    WaitingHome => "AI account instruction files do not sync in this version",
    WaitingAccept => "this file can run a command or grant tools; it waits (accepting it is not on Windows yet)",
    RefusedFolder => "the project's folder is the home folder or holds an AI account's folder; nothing is written there",
    _ => "not written yet: " + code
  };
  private void AddLine(string kind, Arrived a, string why, string? kept) =>
    state.Lines.Add(new Line { Kind = kind, SourceId = a.SourceId, Relative = a.Relative, Device = a.Device, Why = why, Kept = kept, At = localNow() });

  // ---- Places ----

  private IReadOnlyDictionary<string, string> Folders() => foldersNow ??= projectFolders?.Invoke() ?? new Dictionary<string, string>();

  /// The Mac's S3 rule: a project folder may not be a drive root, the user's own folder, an AI account's folder or a
  /// folder holding one, nor hold this adapter's own folders.
  public bool FolderRefused(string folder)
  {
    string full;
    try
    {
      if (!Path.IsPathFullyQualified(folder)) return true;
      full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
    }
    catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return true; }
    var root = Path.GetPathRoot(full);
    if (root is null || string.Equals(Path.TrimEndingDirectorySeparator(root), full, StringComparison.OrdinalIgnoreCase)) return true;
    foreach (var home in guarded)
    {
      string h;
      try { h = Path.TrimEndingDirectorySeparator(Path.GetFullPath(home)); }
      catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { continue; }
      if (string.Equals(h, full, StringComparison.OrdinalIgnoreCase) || h.StartsWith(full + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return true;
    }
    return false;
  }
  private string? FolderOf(string sourceId, out string why)
  {
    why = WaitingFolder;
    if (CloudBootFilesFormat.ParseSourceId(sourceId) is not { } place) return null;
    if (place.Kind != CloudBootFilesPlaceKind.Project) { why = WaitingHome; return null; }
    foreach (var (projectId, folder) in Folders())
    {
      if (CloudBootFilesFormat.Token(projectId) != place.Token || string.IsNullOrEmpty(folder)) continue;
      if (FolderRefused(folder)) { why = RefusedFolder; return null; }
      return Path.GetFullPath(folder);
    }
    return null;
  }

  // ---- Capture ----

  /// This PC's new and edited instruction files since the last capture, as new versions. Never a removal. Nothing
  /// before the whole feed was read once.
  public Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    foldersNow = null;
    if (!state.FeedRead) return Task.FromResult(CloudCapture.None);
    // Files that waited (for a folder, or for something in the way) are placed first, on the saved state.
    foreach (var waiting in state.Versions.Values.Where(v => v.Done && !v.Settled && v.Waiting is not null and not WaitingHome).OrderBy(v => v.Seq).ToArray())
    {
      ct.ThrowIfCancellationRequested();
      Place(waiting, null);
    }
    if (dirty) Save();
    var before = JsonSerializer.SerializeToUtf8Bytes(state);
    var operations = new List<CloudOperation>();
    foreach (var (projectId, folder) in Folders())
    {
      if (string.IsNullOrEmpty(folder) || FolderRefused(folder)) continue;
      var root = Path.GetFullPath(folder);
      var sourceId = CloudBootFilesFormat.SourceId(CloudBootFilesPlaceKind.Project, projectId);
      if (!CloudBootFilesFormat.ValidSourceId(sourceId)) continue;
      foreach (var entry in CloudBootFilesDisk.Scan(root, CloudBootFilesPlaceKind.Project).Files)
      {
        ct.ThrowIfCancellationRequested();
        var pk = Pk(sourceId, entry.Relative);
        var ps = PathOf(pk);
        var stamp = entry.Length.ToString(System.Globalization.CultureInfo.InvariantCulture) + ":" + entry.ModifiedTicks.ToString(System.Globalization.CultureInfo.InvariantCulture);
        if (ps.Stamp == stamp && ps.Head is not null && ps.Base == ps.Head.Hash) continue;
        if (CloudBootFilesDisk.Read(root, entry.Relative).Bytes is not { } bytes || !CloudBootFilesFormat.IsText(bytes)) continue;
        var hash = CloudMemoryFormat.Hash(bytes);
        ps.Stamp = stamp;
        if (ps.Head?.Hash == hash) { ps.Base = hash; continue; }
        // Rule J: a file never agreed with the Cloud never goes up over a path the Cloud already holds.
        if (ps.Base is null && ps.CloudHeld) continue;
        var parents = new List<string>();
        if (ps.NextParents is { } beside) parents.AddRange(beside);
        else if (ps.Head is { } head) parents.Add(head.Version);
        var storeId = ps.Head?.StoreId ?? state.StoreId;
        var key = ps.Head?.Key ?? "file/" + sourceId + "/" + entry.Relative;
        var now = stampNow();
        var modified = new DateTimeOffset(entry.ModifiedTicks, TimeSpan.Zero).ToUnixTimeMilliseconds();
        var createdAt = CloudBootFilesFormat.Clamp(modified, ps.Head?.CreatedAt, now);
        var version = CloudMemoryFormat.Uuid(storeId + "\n" + key + "\n" + string.Join(",", parents) + "\n" + hash + "\n" + createdAt.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var records = CloudBootFilesFormat.Records(storeId, key, sourceId, version, parents, bytes, deviceId, createdAt, projectId, CloudBootFilesFormat.ProjectRoot);
        ps.Head = new Head { Version = version, StoreId = storeId, Key = key, Hash = hash, Parents = parents, CreatedAt = createdAt, Device = deviceId };
        ps.Base = hash;
        ps.NextParents = null;
        state.Known[pk + "\n" + version] = new Known { Hash = hash, Parents = parents };
        foreach (var record in records) state.Applied.Add(record.OpId);
        operations.AddRange(records);
      }
    }
    var staged = state;
    state = JsonSerializer.Deserialize<State>(before)!;
    return Task.FromResult(new CloudCapture(operations, () => { state = staged; Save(); }));
  }

  // ---- Apply ----

  public Task ApplyAsync(CloudOperation op, CloudImportOrigin origin, CancellationToken ct)
  {
    if (state.Applied.Contains(op.OpId)) return Task.CompletedTask;
    if (op.Domain != CloudBootFilesFormat.Domain) throw new CloudFailure("unsupported_format");
    // Every rule first: a record that is not a boot file is refused before anything is kept or written.
    var item = CloudBootFilesFormat.Describe(op);
    var pk = Pk(item.SourceId, item.Relative);
    // A name that differs only in letter case from one this PC already holds for the same place.
    var folded = item.Relative.ToUpperInvariant();
    foreach (var known in state.Paths.Keys)
      if (known.StartsWith(item.SourceId + "\n", StringComparison.Ordinal) && known != pk && known[(item.SourceId.Length + 1)..].ToUpperInvariant() == folded)
        throw new CloudFailure("invalid_request");
    dirty = true;
    if (item.Archive)
    {
      // A removal on another device is listed; it is never applied here.
      if (state.Paths.ContainsKey(pk))
        state.Lines.Add(new Line { Kind = "removed-elsewhere", SourceId = item.SourceId, Relative = item.Relative, Device = origin.DeviceId,
          Why = "removed on another device; this PC keeps its file (removals do not travel to Windows yet)", At = localNow() });
      state.Applied.Add(op.OpId);
      return Task.CompletedTask;
    }
    var vk = item.StoreId + "\n" + item.Key + "\n" + item.Version;
    if (!state.Versions.TryGetValue(vk, out var a))
      state.Versions[vk] = a = new Arrived
      {
        Seq = ++state.Seq, StoreId = item.StoreId, Key = item.Key, Version = item.Version, Hash = item.Hash, SourceId = item.SourceId, Relative = item.Relative,
        Parents = item.Parents.ToList(), CreatedAt = op.CreatedAt, Device = op.OriginDevice, Count = item.Count, Bytes = item.Bytes
      };
    else if (a.Hash != item.Hash || a.Count != item.Count || !a.Parents.SequenceEqual(item.Parents)) throw new CloudFailure("id_reused");
    if (!a.Done)
    {
      var data = Convert.ToBase64String(item.Data);
      if (a.Parts.TryGetValue(item.Index, out var held) && held != data) throw new CloudFailure("id_reused");
      a.Parts[item.Index] = data;
      if (a.Parts.Count == a.Count)
      {
        var body = a.Parts.OrderBy(p => p.Key).SelectMany(p => Convert.FromBase64String(p.Value)).ToArray();
        if (body.LongLength != a.Bytes || CloudMemoryFormat.Hash(body) != a.Hash || !CloudBootFilesFormat.IsText(body))
        {
          state.Versions.Remove(vk);
          throw new CloudFailure("invalid_request");
        }
        a.Parts.Clear();
        a.Done = true;
        Retain(a.Hash, body);
        state.Known[pk + "\n" + a.Version] = new Known { Hash = a.Hash, Parents = a.Parents.ToList() };
        PathOf(pk).CloudHeld = true;
        Place(a, body);
      }
    }
    state.Applied.Add(op.OpId);
    return Task.CompletedTask;
  }

  private string RetainedPath(string hash) => Path.Combine(retained, hash);
  private void Retain(string hash, byte[] body)
  {
    var path = RetainedPath(hash);
    if (File.Exists(path)) return;
    new CloudFileSlot(path).Write(body);
  }
  private byte[]? Retained(string hash)
  {
    try { return File.ReadAllBytes(RetainedPath(hash)) is var bytes && CloudMemoryFormat.Hash(bytes) == hash ? bytes : null; }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
  }

  /// Places one complete version that arrived: into its project's folder on this PC, or it waits.
  private void Place(Arrived a, byte[]? body)
  {
    dirty = true;
    body ??= Retained(a.Hash);
    if (body is null) { a.Waiting = "unreadable"; return; }
    if (FolderOf(a.SourceId, out var why) is not { } root) { a.Waiting = why; return; }
    Decide(a, root, body);
  }

  private static CloudBootFilesVersionTime Time(Head h) => new(h.CreatedAt, h.Device, h.Parents.Count == 0);
  private static CloudBootFilesVersionTime Time(Arrived a) => new(a.CreatedAt, a.Device, a.Parents.Count == 0);
  private static Head HeadOf(Arrived a) => new() { Version = a.Version, StoreId = a.StoreId, Key = a.Key, Hash = a.Hash, Parents = a.Parents.ToList(), CreatedAt = a.CreatedAt, Device = a.Device };
  private static void Settle(Arrived a) { a.Waiting = null; a.Settled = true; }
  private static void Agree(PathState ps, Arrived a)
  {
    ps.Base = a.Hash;
    if (ps.Head?.Hash != a.Hash) ps.Head = HeadOf(a);
    ps.Stamp = null;
    Settle(a);
  }
  /// True when `ancestor` is an earlier version of `of` (followed through the versions this PC knows).
  private bool IsAncestor(string pk, string ancestor, string of)
  {
    var seen = new HashSet<string>(StringComparer.Ordinal);
    var frontier = new Stack<string>([of]);
    for (var steps = 0; frontier.Count > 0 && steps < 4096; steps++)
      if (state.Known.TryGetValue(pk + "\n" + frontier.Pop(), out var k))
        foreach (var parent in k.Parents)
        {
          if (parent == ancestor) return true;
          if (seen.Add(parent)) frontier.Push(parent);
        }
    return false;
  }
  /// The next version of the text this PC holds: made on top of this PC's version, or of a version with these bytes.
  private bool Descends(string pk, Arrived a, Head head, string localHash) =>
    a.Parents.Contains(head.Version) || a.Parents.Any(p => state.Known.TryGetValue(pk + "\n" + p, out var k) && k.Hash == localHash);

  /// The decision for one path (CloudBootFilesRules.step + the one rule + rule J), then the only write into a folder.
  private void Decide(Arrived a, string root, byte[] body)
  {
    var pk = Pk(a.SourceId, a.Relative);
    var ps = PathOf(pk);
    // An earlier version of what this PC already uses: nothing to do.
    if (ps.Head is { } current && (current.Version == a.Version || IsAncestor(pk, a.Version, current.Version))) { Settle(a); return; }
    var found = CloudBootFilesDisk.Read(root, a.Relative);
    if (found.Blocked is { } blocked) { a.Waiting = "blocked:" + blocked; return; }
    var local = found.Bytes;
    var localHash = local is null ? null : CloudMemoryFormat.Hash(local);
    if (localHash == a.Hash) { Agree(ps, a); return; }
    var mayWrite = autoAccept || CloudBootFilesFormat.RunReasons(a.Relative, body).Count == 0;
    var now = localNow();
    var label = a.SourceId.Replace('/', '-') + "/" + a.Relative;
    if (local is null)
    {
      // Removed here since: it stays removed (removals are not in this slice); the arrived text is kept and listed.
      if (ps.Base is not null) { Settle(a); AddLine("kept-version", a, "removed on this PC; the text from another device is kept, not written", keeper.Keep(label, body, a.Device, now)); return; }
      if (!mayWrite) { a.Waiting = WaitingAccept; return; }
      try { CloudBootFilesDisk.Create(root, a.Relative, body); }
      catch (CloudBootFilesDisk.Stop stop) { a.Waiting = "blocked:" + stop.Reason; return; }
      CloudBootFilesDisk.SetModified(root, a.Relative, Math.Min(a.CreatedAt, now));
      Agree(ps, a);
      AddLine("created", a, "written from another device", null);
      return;
    }
    bool useArrived, next = false;
    if (ps.Base is null) useArrived = true; // Rule J: this PC's text was never agreed with the Cloud; it is a first copy and loses.
    else if (localHash == ps.Base)
    {
      next = ps.Head is null || Descends(pk, a, ps.Head, localHash);
      useArrived = next || CloudBootFilesFormat.Newest(Time(ps.Head!), Time(a), now) == CloudBootFilesNewest.Arrived;
    }
    else
    {
      // Edited here since the last capture: the newer of the two edits is used.
      var localAt = CloudBootFilesFormat.Clamp(CloudBootFilesDisk.ModifiedMs(root, a.Relative) ?? now, ps.Head?.CreatedAt, now);
      useArrived = CloudBootFilesFormat.Newest(new(localAt, deviceId), Time(a), now) == CloudBootFilesNewest.Arrived;
      if (!useArrived) ps.NextParents = a.Parents.ToList();
    }
    if (!useArrived)
    {
      Settle(a);
      AddLine("other-version", a, "another device's text; this PC's is newer and stays in use", keeper.Keep(label, body, a.Device, now));
      return;
    }
    // Two devices replacing each other's text twice within the hour: stop replacing; both stay, listed.
    if (!next && ps.Base is not null && ps.Newer.Count(t => t > now - 3_600_000) >= 2)
    {
      Settle(a);
      AddLine("other-version", a, "this file keeps changing on two devices; both texts are kept", keeper.Keep(label, body, a.Device, now));
      return;
    }
    if (!mayWrite) { a.Waiting = WaitingAccept; return; }
    var kept = keeper.Keep(label, local, "this PC", now);
    try { CloudBootFilesDisk.Replace(root, a.Relative, body, localHash!); }
    catch (CloudBootFilesDisk.Stop stop) { a.Waiting = "blocked:" + stop.Reason; return; }
    CloudBootFilesDisk.SetModified(root, a.Relative, Math.Min(a.CreatedAt, now));
    if (!next && ps.Base is not null) ps.Newer.Add(now);
    var firstCopy = ps.Base is null;
    Agree(ps, a);
    ps.NextParents = null;
    AddLine(next ? "updated" : "replaced", a, next ? "updated from another device" : firstCopy
      ? "this PC's text was never saved to your Cloud; the account's text is in use and this PC's is kept"
      : "this PC's text is kept; the newer text from another device is in use", kept);
  }
}
