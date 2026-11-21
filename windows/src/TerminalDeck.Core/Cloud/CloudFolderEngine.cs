using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Lane F: the file engine of one file kind over this PC's PRIVATE copy, ported from the Mac's BackendCloudBrainFiles
// (+ ...Import.swift) in its lean mode, the mode only the Cloud folder and artifacts use. It never sees his folder:
// the owner (CloudFolderOwner) moves files between his folder and this copy by the rules. What it does:
// - Reconcile: a changed file in the copy becomes a new version in the journal (retained by fingerprint first); a file
//   gone from a complete, reliable walk of the copy becomes a removal (`archive`) on top of the version it had.
// - Records: each version as `td-memory-part-1` parts of 32 KiB (`file/<source>/<path>`), a removal as a
//   `td-file-archive-1` marker; byte for byte the Mac's (deterministic from the journal row).
// - Arrivals: each part checked against its own identity, staged, the whole file assembled and its fingerprint proven
//   before anything is placed; placed into the copy only as a new file, or over the unchanged version it was made on
//   ("newer_version"); anything else is kept beside (`kept_both`), never written over.
// State: `<state>\engine\state.json` (one atomic file), `retained\<sha256>`, `parts\<op id>`. Saved by the owner.

public sealed class CloudFolderEngine
{
  public sealed class FileRow
  {
    public string Hash { get; set; } = ""; public long Bytes { get; set; } public long Mtime { get; set; } public string StoreId { get; set; } = "";
    public string Key { get; set; } = ""; public string Version { get; set; } = ""; public List<string> Parents { get; set; } = []; public long CreatedAt { get; set; }
    public string RawHash { get; set; } = ""; public long RawBytes { get; set; } public string OriginDevice { get; set; } = ""; public bool Imported { get; set; }
    public bool Archived { get; set; } public bool Pending { get; set; }
  }
  public sealed class JournalRow
  {
    public long Seq { get; set; } public string Kind { get; set; } = "put"; public string Path { get; set; } = ""; public string StoreId { get; set; } = "";
    public string Key { get; set; } = ""; public string Version { get; set; } = ""; public List<string> Parents { get; set; } = []; public long CreatedAt { get; set; }
    public string RawHash { get; set; } = ""; public long RawBytes { get; set; }
  }
  public sealed class Resource
  {
    public long Rowid { get; set; } public string Kind { get; set; } = "put"; public string Relative { get; set; } = ""; public string RawHash { get; set; } = "";
    public long RawBytes { get; set; } public List<string> Parents { get; set; } = []; public string OriginDevice { get; set; } = ""; public long CreatedAt { get; set; }
    public string Version { get; set; } = ""; public string Status { get; set; } = ""; public string? Reason { get; set; } public string? FirstOp { get; set; }
  }
  public sealed class PartRow
  {
    public string OpHash { get; set; } = ""; public string Kind { get; set; } = "put"; public string Identity { get; set; } = ""; public int Index { get; set; }
    public int Count { get; set; } public long Bytes { get; set; } public string ResourceHash { get; set; } = ""; public bool Body { get; set; }
  }
  private sealed class State
  {
    public string StoreId { get; set; } = "";
    public long NextSeq { get; set; } = 1;
    public long NextRowid { get; set; } = 1;
    public long SweptRowid { get; set; }
    /// The journal position every record up to which was handed to the sync engine (the Mac's pump cursor).
    public long Cursor { get; set; }
    /// Records of the first row after `Cursor` already handed over (a large file goes in batches).
    public int CursorPart { get; set; }
    public Dictionary<string, FileRow> Files { get; set; } = [];
    public List<JournalRow> Journal { get; set; } = [];
    public Dictionary<string, Resource> Resources { get; set; } = [];
    public Dictionary<string, PartRow> Parts { get; set; } = [];
  }

  /// One incoming record, checked (the Mac's BackendCloudBrainFilesPart).
  public sealed record Part(CloudOperation Op, string OpHash, bool Archive, string StoreId, string Key, string Version, int Index, int Count, long Bytes,
    string ResourceHash, IReadOnlyList<string> Parents, byte[] Body, string Relative)
  {
    public string Identity => StoreId + "\n" + Key + "\n" + Version;
  }
  /// One version of one path as this engine holds it.
  public sealed record VersionInfo(string Version, IReadOnlyList<string> Parents, long CreatedAt, string RawHash, string OriginDevice);
  /// Where an arriving file goes: written into the copy, or kept unread (`ArchiveOnly`).
  public sealed record Placement(bool Write, string? Reason);

  public static readonly IReadOnlySet<string> PartKeys = CloudBootFilesFormat.PartKeys;
  public static readonly IReadOnlySet<string> MarkerKeys = CloudBootFilesFormat.MarkerKeys;

  private readonly string root, copy, deviceId, row, sourceId, domain;
  private readonly Func<long> now;
  private readonly CloudFileSlot slot;
  private readonly Func<string, long?> modifiedAt;
  private State state;
  private readonly Dictionary<string, List<string>> nextParents = new(StringComparer.Ordinal);

  public CloudFolderEngine(string stateRoot, string copyRoot, string deviceId, string inventoryRow, string sourceId, Func<long> now)
  {
    root = stateRoot; copy = copyRoot; this.deviceId = deviceId.ToLowerInvariant(); row = inventoryRow; this.sourceId = sourceId; this.now = now;
    domain = CloudFolderFormat.DomainOf(inventoryRow);
    slot = new CloudFileSlot(Path.Combine(stateRoot, "state.json"));
    state = slot.Read() is { } bytes ? JsonSerializer.Deserialize<State>(bytes) ?? new State() : new State();
    if (!CloudDeleteText.IsUuid(state.StoreId)) state.StoreId = Guid.NewGuid().ToString("D");
    // The one rule: a version's time is when HIS file was changed (the copy carries the folder file's time).
    modifiedAt = relative => CloudFolderDisk.Modified(copy, relative);
  }

  public void Save() => slot.Write(JsonSerializer.SerializeToUtf8Bytes(state));
  public string Domain => domain;
  private string Retained(string hash) => Path.Combine(root, "retained", hash);
  private string PartFile(string opId) => Path.Combine(root, "parts", opId);
  private static string Pk(string relative) => relative;

  // ---- Versions ----

  public VersionInfo? CurrentVersion(string relative) =>
    state.Files.TryGetValue(Pk(relative), out var f) && !f.Archived ? new(f.Version, f.Parents.ToArray(), f.CreatedAt, f.RawHash, f.OriginDevice) : null;
  public void SetNextParents(string relative, IReadOnlyList<string> parents) => nextParents[relative] = parents.ToList();
  /// The newest arrived version of a path with these bytes.
  public VersionInfo? ArrivedVersion(string relative, string rawHash) =>
    state.Resources.Values.Where(r => r.Relative == relative && r.RawHash == rawHash && r.Kind == "put").OrderByDescending(r => r.CreatedAt)
      .Select(r => new VersionInfo(r.Version, r.Parents.ToArray(), r.CreatedAt, r.RawHash, r.OriginDevice)).FirstOrDefault();
  /// Has this path ever held these bytes, in this PC's own journal or in what arrived?
  public bool KnownVersion(string relative, string rawHash) =>
    state.Journal.Any(j => j.Path == relative && j.RawHash == rawHash) || state.Resources.Values.Any(r => r.Relative == relative && r.RawHash == rawHash);
  /// The latest stamp among these versions of a path (own journal and arrived), or null.
  public long? LatestTime(string relative, IEnumerable<string> versions)
  {
    long? latest = null;
    foreach (var version in versions.Distinct())
    {
      foreach (var j in state.Journal.Where(j => j.Path == relative && j.Version == version)) latest = Math.Max(latest ?? j.CreatedAt, j.CreatedAt);
      foreach (var r in state.Resources.Values.Where(r => r.Relative == relative && r.Version == version)) latest = Math.Max(latest ?? r.CreatedAt, r.CreatedAt);
    }
    return latest;
  }
  public byte[]? RetainedBytes(string rawHash)
  {
    if (!CloudBin.IsSha(rawHash)) return null;
    try { var data = File.ReadAllBytes(Retained(rawHash)); return CloudMemoryFormat.Hash(data) == rawHash ? data : null; }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
  }
  private void Retain(byte[] bytes, string hash)
  {
    var target = Retained(hash);
    if (File.Exists(target))
    {
      if (CloudMemoryFormat.Hash(File.ReadAllBytes(target)) != hash) throw new CloudFailure("checksum_mismatch");
      return;
    }
    new CloudFileSlot(target).Write(bytes);
  }

  /// A removal that ARRIVED was applied here by its owner: the row takes the removal's version and is marked removed.
  public bool AdoptRemoval(string relative, string version, IReadOnlyList<string> parents, long createdAt, string originDevice)
  {
    if (!state.Files.TryGetValue(relative, out var f) || f.Archived) return false;
    f.Archived = true; f.Version = version; f.Parents = parents.ToList(); f.CreatedAt = createdAt; f.Imported = true; f.OriginDevice = originDevice.ToLowerInvariant();
    return true;
  }
  /// The owner put an ARRIVED version into the copy itself: the row takes it as an import (no echo, no upload).
  public bool AdoptArrival(string relative, string version, IReadOnlyList<string> parents, long createdAt, string rawHash, long rawBytes, string originDevice)
  {
    var held = CloudFolderDisk.Read(copy, relative);
    if (!held.IsFile || CloudMemoryFormat.Hash(held.Bytes!) != rawHash || !state.Files.TryGetValue(relative, out var f)) return false;
    var stamp = CloudFolderDisk.StampOf(copy, relative);
    f.Hash = rawHash; f.Bytes = stamp?.Bytes ?? rawBytes; f.Mtime = MtimeOf(relative); f.Version = version; f.Parents = parents.ToList(); f.CreatedAt = createdAt;
    f.RawHash = rawHash; f.RawBytes = rawBytes; f.OriginDevice = originDevice.ToLowerInvariant(); f.Imported = true; f.Archived = false; f.Pending = false;
    return true;
  }
  /// This PC's current version sent again on top of itself, same bytes and time (another device decides it again).
  public bool Resend(string relative)
  {
    if (!state.Files.TryGetValue(relative, out var f) || f.Archived || f.Pending) return false;
    var version = Guid.NewGuid().ToString("D");
    var old = f.Version;
    Journal("put", relative, f.StoreId, f.Key, version, [old], f.CreatedAt, f.RawHash, f.RawBytes);
    f.Version = version; f.Parents = [old]; f.Imported = false; f.OriginDevice = deviceId;
    return true;
  }

  // ---- Local capture ----

  private long MtimeOf(string relative)
  {
    try { return File.GetLastWriteTimeUtc(CloudFolderDisk.Full(copy, relative)).Ticks; }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return 0; }
  }
  private static readonly string[] LockEndings = [".lock", ".pid", ".sock", ".socket"];
  /// The copy's files (never through a link; the owner's temporary names and lock files left out).
  private (List<string> Files, bool Reliable) WalkCopy()
  {
    var files = new List<string>();
    if (!CloudFolderDisk.IsPlainFolder(copy)) return (files, false);
    var reliable = true;
    var pending = new Stack<(string, string)>();
    pending.Push((copy, ""));
    while (pending.Count > 0)
    {
      var (folder, prefix) = pending.Pop();
      FileSystemInfo[] children;
      try { children = new DirectoryInfo(folder).EnumerateFileSystemInfos().ToArray(); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { reliable = false; continue; }
      foreach (var child in children)
      {
        var relative = prefix.Length == 0 ? child.Name : prefix + "/" + child.Name;
        if ((child.Attributes & FileAttributes.ReparsePoint) != 0) continue;
        if ((child.Attributes & FileAttributes.Directory) != 0) { pending.Push((child.FullName, relative)); continue; }
        var lower = child.Name.ToLowerInvariant();
        if (lower.StartsWith(".td-cloud-", StringComparison.Ordinal) || lower == ".ds_store" || LockEndings.Any(e => lower.EndsWith(e, StringComparison.Ordinal))) continue;
        files.Add(relative);
      }
    }
    files.Sort(StringComparer.Ordinal);
    return (files, reliable);
  }

  /// Bounded reconciliation of the copy against stored fingerprints. True in `Remaining` when the limit cut it short.
  public (int Journaled, int Archived, bool Remaining) Reconcile(IReadOnlyCollection<string>? paths = null, int limit = 512)
  {
    if (limit <= 0) throw new CloudFailure("invalid_request");
    int journaled = 0, archived = 0;
    var remaining = false;
    var (files, reliable) = WalkCopy();
    var present = files.ToHashSet(StringComparer.Ordinal);
    foreach (var relative in files)
    {
      if (paths is not null && !paths.Contains(relative)) continue;
      if (journaled >= limit) { remaining = true; break; }
      if (Capture(relative)) journaled++;
    }
    if (!remaining && reliable)
      foreach (var (relative, f) in state.Files.Where(f => !f.Value.Archived && !f.Value.Pending).ToArray())
      {
        if (present.Contains(relative) || paths is not null && !paths.Contains(relative)) continue;
        if (File.Exists(CloudFolderDisk.Full(copy, relative))) continue;
        var version = Guid.NewGuid().ToString("D");
        var at = now();
        Journal("archive", relative, f.StoreId, f.Key, version, [f.Version], at, f.RawHash, 0);
        f.Archived = true; f.Parents = [f.Version]; f.Version = version; f.CreatedAt = at; f.Imported = false; f.OriginDevice = deviceId;
        archived++;
      }
    return (journaled, archived, remaining);
  }
  /// Reconcile until nothing remains.
  public void ReconcileAll(IReadOnlyCollection<string>? paths = null) { while (Reconcile(paths, 4096).Remaining) { } }

  private void Journal(string kind, string relative, string storeId, string key, string version, List<string> parents, long at, string rawHash, long rawBytes) =>
    state.Journal.Add(new JournalRow { Seq = state.NextSeq++, Kind = kind, Path = relative, StoreId = storeId, Key = key, Version = version, Parents = parents,
      CreatedAt = at, RawHash = rawHash, RawBytes = rawBytes });

  private bool Capture(string relative)
  {
    var stamp = CloudFolderDisk.StampOf(copy, relative);
    if (stamp is null) return false;
    var mtime = MtimeOf(relative);
    state.Files.TryGetValue(relative, out var previous);
    var read = CloudFolderDisk.Read(copy, relative);
    if (!read.IsFile) return false;
    var hash = CloudMemoryFormat.Hash(read.Bytes!);
    if (previous is { Pending: true })
    {
      // An import is still being placed here. Its own bytes are not a local edit.
      if (hash == previous.Hash) { previous.Pending = false; previous.Bytes = stamp.Bytes; previous.Mtime = mtime; }
      return false;
    }
    if (previous is { Archived: false } && previous.Bytes == stamp.Bytes && previous.Mtime == mtime) return false;
    if (previous is { Archived: false } && previous.Hash == hash) { previous.Bytes = stamp.Bytes; previous.Mtime = mtime; return false; }
    Retain(read.Bytes!, hash);
    var version = Guid.NewGuid().ToString("D");
    var at = now();
    if (modifiedAt(relative) is { } modified) at = CloudBootFilesFormat.Clamp(modified, previous?.CreatedAt, at);
    // The one rule: a version recorded beside the one this copy holds (both made apart) names that one's parents.
    var parents = nextParents.Remove(relative, out var beside) ? beside : previous is null ? [] : [previous.Version];
    var store = previous?.StoreId ?? state.StoreId;
    var key = previous?.Key ?? "file/" + sourceId + "/" + relative;
    Journal("put", relative, store, key, version, parents, at, hash, read.Bytes!.LongLength);
    state.Files[relative] = new FileRow
    {
      Hash = hash, Bytes = stamp.Bytes, Mtime = mtime, StoreId = store, Key = key, Version = version, Parents = parents, CreatedAt = at, RawHash = hash,
      RawBytes = read.Bytes!.LongLength, OriginDevice = deviceId
    };
    return true;
  }

  // ---- Records ----

  public IReadOnlyList<JournalRow> JournalAfter(long seq) => state.Journal.Where(j => j.Seq > seq).OrderBy(j => j.Seq).ToArray();
  public long Cursor { get => state.Cursor; set => state.Cursor = value; }
  public int CursorPart { get => state.CursorPart; set => state.CursorPart = value; }
  public long LastSeq => state.Journal.Count == 0 ? 0 : state.Journal[^1].Seq;
  /// Bytes recorded and not yet handed to the sync (read once per look, never per hand-over).
  public long UnsentBytes() =>
    Math.Max(0, state.Journal.Where(j => j.Seq > state.Cursor).Sum(j => j.RawBytes) - (long)state.CursorPart * CloudMemoryFormat.PartBytes);

  /// Every record of one journal row, deterministic: the same row always gives the same records.
  public IReadOnlyList<CloudOperation> Operations(JournalRow r)
  {
    var source = "files/" + row + "/" + sourceId;
    if (r.Kind == "archive")
    {
      var marker = CloudJson.Obj(("format", CloudJson.From(CloudBootFilesFormat.ArchiveFormat)), ("storeId", CloudJson.From(r.StoreId)), ("inventoryRow", CloudJson.From(row)),
        ("key", CloudJson.From(r.Key)), ("version", CloudJson.From(r.Version)), ("resourceHash", CloudJson.From(r.RawHash)),
        ("parents", CloudJson.Arr(r.Parents.Select(p => CloudJson.From(p)))));
      var revision = CloudMemoryFormat.OperationId(r.Version + "\narchive");
      return [new CloudOperation(1, revision, deviceId, domain, CloudMemoryFormat.Uuid(r.StoreId + "\n" + r.Key + "\narchive"), revision,
        r.Parents.Select(p => CloudMemoryFormat.OperationId(p + "\narchive")).ToArray(), "archive", null, null, new CloudSourceReference(source, r.Key, null, r.RawHash),
        r.CreatedAt, marker, CloudOperation.PayloadHashOf(marker))];
    }
    var data = RetainedBytes(r.RawHash) ?? throw new CloudFailure("checksum_mismatch");
    if (data.LongLength != r.RawBytes) throw new CloudFailure("checksum_mismatch");
    var count = CloudMemoryFormat.PartCount(data.Length);
    var operations = new List<CloudOperation>(count);
    for (var index = 0; index < count; index++)
    {
      var offset = index * CloudMemoryFormat.PartBytes;
      operations.Add(PartOperation(r, source, data.Length, index, count, data.AsSpan(offset, Math.Min(CloudMemoryFormat.PartBytes, data.Length - offset))));
    }
    return operations;
  }
  private CloudOperation PartOperation(JournalRow r, string source, int length, int index, int count, ReadOnlySpan<byte> slice)
  {
    var offset = index * CloudMemoryFormat.PartBytes;
    var payload = new CloudMemoryPart(r.StoreId, row, r.Key, r.Version, r.RawHash, length, index, count, r.Parents, Convert.ToBase64String(slice)).ToJson();
    var suffix = "\n" + index.ToString(CultureInfo.InvariantCulture);
    var opId = CloudMemoryFormat.OperationId(r.Version + suffix);
    return new CloudOperation(1, opId, deviceId, domain, CloudMemoryFormat.Uuid(r.StoreId + "\n" + r.Key + suffix), opId,
      r.Parents.Select(p => CloudMemoryFormat.OperationId(p + suffix)).ToArray(), "put", null, null, new CloudSourceReference(source, r.Key, offset, r.RawHash),
      r.CreatedAt, payload, CloudOperation.PayloadHashOf(payload));
  }

  /// Records `from` to `from + count` of one row, the very records `Operations(r)` makes, reading only their bytes: a
  /// large file is handed over in batches without being read whole for each batch. The whole file's fingerprint is
  /// checked when its first record is made (streamed, never held in memory).
  public IReadOnlyList<CloudOperation> Operations(JournalRow r, int from, int count)
  {
    if (r.Kind == "archive") return from == 0 && count > 0 ? Operations(r) : [];
    var total = CloudMemoryFormat.PartCount(r.RawBytes);
    if (from < 0 || count <= 0 || from >= total) return [];
    count = Math.Min(count, total - from);
    if (!IsHash(r.RawHash) || r.RawBytes > int.MaxValue) throw new CloudFailure("checksum_mismatch");
    var source = "files/" + row + "/" + sourceId;
    var length = (int)r.RawBytes;
    try
    {
      using var file = new FileStream(Retained(r.RawHash), FileMode.Open, FileAccess.Read, FileShare.Read);
      if (file.Length != r.RawBytes) throw new CloudFailure("checksum_mismatch");
      if (from == 0)
      {
        if (Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(file)) != r.RawHash) throw new CloudFailure("checksum_mismatch");
      }
      var operations = new List<CloudOperation>(count);
      var buffer = new byte[CloudMemoryFormat.PartBytes];
      for (var index = from; index < from + count; index++)
      {
        var offset = (long)index * CloudMemoryFormat.PartBytes;
        var size = (int)Math.Min(CloudMemoryFormat.PartBytes, length - offset);
        file.Position = offset;
        file.ReadExactly(buffer, 0, size);
        operations.Add(PartOperation(r, source, length, index, total, buffer.AsSpan(0, size)));
      }
      return operations;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new CloudFailure("checksum_mismatch"); }
  }

  // ---- Arrivals ----

  private static bool LinksValid(CloudOperation op, string version, IReadOnlyList<string> parents, string suffix)
  {
    foreach (var make in new Func<string, string>[] { CloudMemoryFormat.OperationId, CloudMemoryFormat.Uuid })
      if (op.Revision == make(version + suffix)) return op.Parents.SequenceEqual(parents.Select(p => make(p + suffix)));
    return false;
  }
  private static bool IsHash(string text) => CloudBin.IsSha(text);

  /// Every field checked against the operation's identity before anything is staged (the Mac's `check` + `resolve`).
  /// `invalid_request` for anything that does not hold together.
  public Part Check(CloudOperation op)
  {
    static CloudFailure Refused() => new("invalid_request");
    if (op.V != 1 || op.Domain != domain || op.OpId != op.Revision || !CloudDeleteText.IsUuid(op.OriginDevice) || !CloudDeleteText.IsUuid(op.OpId)) throw Refused();
    if (CloudOperation.PayloadHashOf(op.Payload) != op.PayloadHash || op.Payload is not CloudJson.Object o) throw Refused();
    if (CloudCanonical.Encode(op.Payload).Length > 65_536) throw Refused();
    string Text(string k) => o[k]?.AsString ?? throw Refused();
    var archive = op.Kind switch { "put" => false, "archive" => true, _ => throw new CloudFailure("invalid_request") };
    if (o.Members.Any(m => !(archive ? MarkerKeys : PartKeys).Contains(m.Key)) || o.Members.Select(m => m.Key).Distinct().Count() != o.Members.Count) throw Refused();
    if (o["parents"] is not CloudJson.Array list) throw Refused();
    var parents = list.Items.Select(x => x.AsString ?? throw Refused()).ToArray();
    string storeId = Text("storeId"), key = Text("key"), version = Text("version"), hash = Text("resourceHash");
    if (Text("inventoryRow") != row) throw Refused();
    long size = 0; int index = 0, count = 1; byte[] body = [];
    if (!archive)
    {
      if (Text("format") != CloudBootFilesFormat.PartFormat) throw Refused();
      var bytesText = Text("bytes");
      if (!long.TryParse(bytesText, NumberStyles.None, CultureInfo.InvariantCulture, out size) || size.ToString(CultureInfo.InvariantCulture) != bytesText) throw Refused();
      var indexValue = o["index"]?.AsInteger ?? throw Refused();
      var countValue = o["count"]?.AsInteger ?? throw Refused();
      if (indexValue is < 0 or > int.MaxValue || countValue is < 1 or > int.MaxValue) throw Refused();
      index = (int)indexValue; count = (int)countValue;
      try { body = Convert.FromBase64String(Text("data")); } catch (FormatException) { throw Refused(); }
      if (count != CloudMemoryFormat.PartCount(size) || index >= count
        || body.Length != (int)Math.Min(CloudMemoryFormat.PartBytes, Math.Max(0, size - (long)index * CloudMemoryFormat.PartBytes))) throw Refused();
      if (op.EntityId != CloudMemoryFormat.Uuid(storeId + "\n" + key + "\n" + index.ToString(CultureInfo.InvariantCulture))
        || !LinksValid(op, version, parents, "\n" + index.ToString(CultureInfo.InvariantCulture))) throw Refused();
    }
    else
    {
      if (Text("format") != CloudBootFilesFormat.ArchiveFormat) throw Refused();
      if (op.EntityId != CloudMemoryFormat.Uuid(storeId + "\n" + key + "\narchive") || !LinksValid(op, version, parents, "\narchive")) throw Refused();
    }
    if (!CloudDeleteText.IsUuid(storeId) || !CloudDeleteText.IsUuid(version) || parents.Any(p => !CloudDeleteText.IsUuid(p)) || parents.Distinct().Count() != parents.Length
      || !IsHash(hash) || op.Source.RecordId != key) throw Refused();
    var prefix = "file/" + sourceId + "/";
    if (!key.StartsWith(prefix, StringComparison.Ordinal)) throw Refused();
    var relative = key[prefix.Length..];
    if (relative.Length == 0 || relative.Length > 1024 || relative.StartsWith('/') || relative.Contains('\0') || relative.Contains('\\')
      || relative.Split('/').Any(p => p.Length == 0 || p is "." or "..")) throw Refused();
    var opHash = CloudBytes.Sha256Hex(CloudCanonical.Encode(op.ToJson()));
    return new Part(op, opHash, archive, storeId, key, version, index, count, size, hash, parents, body, relative);
  }

  /// Durable staging: a part survives restart; the same id with different bytes is `id_reused`.
  public void Stage(Part p)
  {
    if (state.Parts.TryGetValue(p.Op.OpId, out var old))
    {
      if (old.OpHash != p.OpHash) throw new CloudFailure("id_reused");
      return;
    }
    if (!p.Archive) new CloudFileSlot(PartFile(p.Op.OpId)).Write(p.Body);
    state.Parts[p.Op.OpId] = new PartRow { OpHash = p.OpHash, Kind = p.Archive ? "archive" : "put", Identity = p.Identity, Index = p.Index, Count = p.Count,
      Bytes = p.Bytes, ResourceHash = p.ResourceHash, Body = !p.Archive };
  }

  public Resource? ResourceOf(string identity) => state.Resources.GetValueOrDefault(identity);

  /// Takes one checked part: when its file is complete (or it is a removal), assembled, proven and placed through
  /// `projection`. Answers the resource's status, or null while parts are still missing. Placing twice changes nothing.
  public string? Apply(Part p, Func<string, byte[], Placement> projection)
  {
    Stage(p);
    if (state.Resources.TryGetValue(p.Identity, out var done) && done.Status != "waiting") return done.Status;
    if (p.Archive)
    {
      // A removal elsewhere is history here; the owner applies it over its exact version.
      Record(p, "archived", "archive_marker_kept");
      return "archived";
    }
    var rows = state.Parts.Where(x => x.Value.Identity == p.Identity && x.Value.Kind == "put").ToArray();
    if (rows.Any(x => x.Value.Count != p.Count || x.Value.Bytes != p.Bytes || x.Value.ResourceHash != p.ResourceHash)) throw new CloudFailure("invalid_request");
    if (rows.Length != p.Count || !rows.Select(x => x.Value.Index).OrderBy(i => i).SequenceEqual(Enumerable.Range(0, p.Count))) return null;
    if (RetainedBytes(p.ResourceHash) is null)
    {
      using var buffer = new MemoryStream();
      foreach (var (opId, _) in rows.OrderBy(x => x.Value.Index))
      {
        try { buffer.Write(File.ReadAllBytes(PartFile(opId))); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new CloudFailure("checksum_mismatch"); }
      }
      var whole = buffer.ToArray();
      if (whole.LongLength != p.Bytes || CloudMemoryFormat.Hash(whole) != p.ResourceHash) throw new CloudFailure("invalid_request");
      Retain(whole, p.ResourceHash);
    }
    var status = Place(p, projection);
    // Lean: the file is assembled (retained) and placed; its part bodies are not needed again. The rows stay (with
    // their fingerprint), so the same record sent again is still known and still checked.
    if (status != "waiting")
      foreach (var (opId, part) in rows)
      {
        part.Body = false;
        try { File.Delete(PartFile(opId)); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
      }
    return status;
  }

  private void Record(Part p, string status, string? reason)
  {
    if (!state.Resources.TryGetValue(p.Identity, out var r)) state.Resources[p.Identity] = r = new Resource { Rowid = state.NextRowid++ };
    r.Kind = p.Archive ? "archive" : "put"; r.Relative = p.Relative; r.RawHash = p.ResourceHash; r.RawBytes = p.Bytes; r.Parents = p.Parents.ToList();
    r.OriginDevice = p.Op.OriginDevice; r.CreatedAt = p.Op.CreatedAt; r.Version = p.Version; r.Status = status; r.Reason = reason; r.FirstOp ??= p.Op.OpId;
  }

  private string Place(Part p, Func<string, byte[], Placement> projection)
  {
    var raw = RetainedBytes(p.ResourceHash) ?? throw new CloudFailure("checksum_mismatch");
    var placement = projection(p.Relative, raw);
    if (!placement.Write) { Record(p, "archived", placement.Reason); return "archived"; }
    void Remember(bool pending)
    {
      state.Files[p.Relative] = new FileRow
      {
        Hash = p.ResourceHash, Bytes = raw.LongLength, Mtime = 0, StoreId = p.StoreId, Key = p.Key, Version = p.Version, Parents = p.Parents.ToList(),
        CreatedAt = p.Op.CreatedAt, RawHash = p.ResourceHash, RawBytes = p.Bytes, OriginDevice = p.Op.OriginDevice.ToLowerInvariant(), Imported = true, Pending = pending
      };
    }
    try
    {
      var there = CloudFolderDisk.Read(copy, p.Relative);
      if (there.Kind != CloudFolderDisk.Kind.Absent || Directory.Exists(CloudFolderDisk.Full(copy, p.Relative)))
      {
        var existing = there.IsFile ? CloudMemoryFormat.Hash(there.Bytes!) : null;
        if (existing == p.ResourceHash) { Remember(false); Record(p, "already_present", null); return "already_present"; }
        // A sequential newer version over an unchanged older import: the replaced bytes are retained first.
        if (existing is not null && state.Files.TryGetValue(p.Relative, out var f) && f.Hash == existing && !f.Pending && p.Parents.Contains(f.Version))
        {
          Retain(there.Bytes!, existing);
          Remember(true);
          CloudFolderDisk.Write(copy, p.Relative, raw, existing);
          Remember(false);
          Record(p, "applied", "newer_version");
          return "applied";
        }
        // Different bytes stay; the incoming version is kept beside them (retained by fingerprint).
        Record(p, "kept_both", "existing_file_kept");
        return "kept_both";
      }
      Remember(true);
      CloudFolderDisk.Write(copy, p.Relative, raw, null);
      Remember(false);
      Record(p, "applied", null);
      return "applied";
    }
    catch (CloudFailure failure)
    {
      // Windows (a path this disk cannot take now, a file in use): nothing is written; it waits and is tried again
      // at the next look (`Reproject`), never dropped and never a stop of the whole feed.
      if (state.Files.TryGetValue(p.Relative, out var f) && f.Pending && f.Version == p.Version) state.Files.Remove(p.Relative);
      Record(p, "waiting", failure.Code);
      return "waiting";
    }
  }

  /// Places again what waited (parts are kept until then). Answers the relatives that were placed.
  public IReadOnlyList<string> Reproject(Func<string, byte[], Placement> projection)
  {
    var placed = new List<string>();
    foreach (var (identity, r) in state.Resources.Where(x => x.Value.Status == "waiting").ToArray())
    {
      var fields = identity.Split('\n');
      if (r.FirstOp is null || fields.Length != 3) continue;
      var part = new Part(new CloudOperation(1, r.FirstOp, r.OriginDevice, domain, "", r.FirstOp, [], "put", null, null, new CloudSourceReference("", fields[1]), r.CreatedAt,
        CloudJson.Obj(), ""), "", false, fields[0], fields[1], fields[2], 0, 1, r.RawBytes, r.RawHash, r.Parents, [], r.Relative);
      if (Place(part, projection) != "waiting") placed.Add(r.Relative);
    }
    return placed;
  }

  // ---- Cost ----

  /// Drops retained copies nothing needs any more: not a current file's, not one still to be handed to the sync engine,
  /// not one that arrived since the previous sweep (or waits). Answers how many went.
  public int SweepRetained()
  {
    var keep = state.Files.Values.Where(f => !f.Archived).Select(f => f.RawHash).ToHashSet(StringComparer.Ordinal);
    keep.UnionWith(state.Journal.Where(j => j.Seq > state.Cursor).Select(j => j.RawHash));
    keep.UnionWith(state.Resources.Values.Where(r => r.Rowid > state.SweptRowid || r.Status == "waiting").Select(r => r.RawHash));
    var dropped = 0;
    var folder = Path.Combine(root, "retained");
    if (Directory.Exists(folder))
      foreach (var file in Directory.EnumerateFiles(folder))
      {
        var name = Path.GetFileName(file);
        if (!IsHash(name) || keep.Contains(name)) continue;
        try { File.Delete(file); dropped++; } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
      }
    state.SweptRowid = state.Resources.Count == 0 ? 0 : state.Resources.Values.Max(r => r.Rowid);
    return dropped;
  }
  /// Tests: bytes of part bodies still held.
  public long StoredPartBytes()
  {
    var folder = Path.Combine(root, "parts");
    return Directory.Exists(folder) ? Directory.EnumerateFiles(folder).Sum(f => new FileInfo(f).Length) : 0;
  }
}
