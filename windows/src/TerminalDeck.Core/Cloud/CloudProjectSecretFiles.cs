using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// The project secret files store (the Mac's BackendProjectSecretFilesStore, td-mac-next2): a saved-passwords source
// (`project-files`, domain `project`) with its own sealed Bin under the delete rule. Every rule of the Mac is kept, with
// every fault found on 15 Nov built in from the start:
// - a file is placed only in ITS project's folder: the project by id, and a record that names a folder only in a folder
//   of that name (R1); two folders of one name are never "the first one" (F5); an empty, missing, home or whole-disk
//   folder takes nothing (F7, decision 11);
// - his own edit is never overwritten: a newer version replaces only what is still the last agreed version AND was made
//   on top of it; anything else is "different on <device>, yours kept" (and a case twin is never overwritten);
// - a removal follows the delete rule: by hand = "Not on this PC" (never travels); an AI session or the app = the sealed
//   Bin + a travelling removal, only while every computer announced the delete rule; an arriving removal removes only
//   the exact removed bytes, never a later edit, never through a link; every failure is a final "not applied".
// - a project removed from the list is never evidence of anything: its folder is "not on this PC", nothing is marked.

public sealed record CloudProjectSecretFilesProject(string Id, string Name, IReadOnlyList<string> Folders);

/// What a delete tool can name: one tracked project secret file by name with its folder (never bytes, never a Bin row).
public sealed record CloudProjectSecretFileTarget(CloudDeleteItem Item, string Folder);

/// A delete that cannot be honoured right now, with the plain reason for the page.
public sealed class CloudProjectSecretFilesWaiting(string reason) : Exception(reason) { public string Reason { get; } = reason; }

public sealed class CloudProjectSecretFilesStore : ICloudSecretsDeletingStore, ICloudDeleteOwning
{
  public const string ItemKind = "project-secret-files";
  private sealed class Entry
  {
    public string ProjectId { get; set; } = "";
    public string Folder { get; set; } = "";
    public string Path { get; set; } = "";
    /// The last version this PC and Cloud agreed on (sent from here, or placed from another device).
    public string Mark { get; set; } = "";
    public string? Base { get; set; }
    public long At { get; set; }
    public string From { get; set; } = "";
    public int Mode { get; set; } = CloudProjectSecretFilesRules.OwnerOnlyMode;
    public int Bytes { get; set; }
    /// Set when a version from another device was different from his own here: his stays.
    public string? DiffersFrom { get; set; }
    public long? DiffersAt { get; set; }
    public long? ArrivedAt { get; set; }
    public long? LastSeenAt { get; set; }
  }
  private sealed class Waiting
  {
    public string ProjectId { get; set; } = "";
    public string Path { get; set; } = "";
    public string From { get; set; } = "";
    public long At { get; set; }
    public string Why { get; set; } = "";
    /// The record, sealed with this device's own holding key (AES-GCM combined, base64).
    public string Sealed { get; set; } = "";
  }
  private sealed class Ledger
  {
    public Dictionary<string, Entry> Files { get; set; } = new(StringComparer.Ordinal);
    public Dictionary<string, Waiting> Waiting { get; set; } = new(StringComparer.Ordinal);
  }
  private enum Placed { Applied, Same, KeptBoth, Wait, Refused }
  private enum RootState { Ok, Wait, Unusable }
  private sealed record ArrivalRoot(RootState State, string? Path, string Why, string RemovalWhy = "");

  private readonly string stateRoot, home;
  private readonly Func<IReadOnlyList<CloudProjectSecretFilesProject>> projects;
  private readonly Func<string> deviceName;
  private readonly Func<CloudProjectSecretFilesGate> gate;
  private readonly Func<long> now;
  private readonly Action requireWriter;
  private readonly long walkReuse;
  private readonly Func<bool> deleteGate;
  private readonly Func<long?> deleteStamp;
  private readonly Func<string> deleteDevice;
  private readonly Func<string, string?> deleteMacName;
  private readonly CloudDeleteWitnessSlot witness;
  private readonly Dictionary<string, (long At, IReadOnlyList<CloudProjectSecretFilesDisk.Walked> Found)> walks = new(StringComparer.OrdinalIgnoreCase);
  private Dictionary<string, List<CloudProjectSecretFilesStatus.File>> heldBack = new(StringComparer.Ordinal);
  private readonly Dictionary<string, (string ProjectId, CloudProjectSecretFilesStatus.File File)> refused = new(StringComparer.Ordinal);
  private readonly Dictionary<string, long> gone = new(StringComparer.Ordinal), lastSeen = new(StringComparer.Ordinal);
  private readonly SemaphoreSlim turn = new(1, 1);
  private CloudSecretsStoreKeys? keys;
  private Ledger ledger = new();
  private string? ledgerSlot;
  private int refusedCount;
  private CloudProjectSecretFilesGate gateState = CloudProjectSecretFilesGate.Open;
  private string myName = "another device";
  private long? lookedAt;
  internal CloudSecretsKeeper Keeper { get; }

  public string SourceId => CloudProjectSecretFilesRules.SourceId;
  public string InventoryRow => CloudProjectSecretFilesRules.InventoryRow;
  public string Domain => CloudSecretsDomains.Project;

  /// `stateRoot`: this account's own folder for the ledger, the sealed waiting arrivals, the sealed Bin and the stricter
  /// setting. `gate`: every computer announced `projectsecrets`. `requireWriter`: the app's writer check (throws when
  /// this copy may not write his folders). `home`: his user folder. `deleteGate`: every computer announced the delete
  /// rule. `deleteStamp`: the service clock (null while unknown). `deleteDevice`: this PC's device id.
  public CloudProjectSecretFilesStore(string stateRoot, Func<IReadOnlyList<CloudProjectSecretFilesProject>> projects, Func<string> deviceName,
    Func<CloudProjectSecretFilesGate> gate, Action? requireWriter = null, string? home = null, long walkReuse = 60_000, Func<bool>? deleteGate = null,
    Func<long?>? deleteStamp = null, Func<string>? deleteDevice = null, Func<string, string?>? deleteMacName = null, CloudDeleteWitnessSlot? witness = null,
    Func<long>? now = null)
  {
    this.stateRoot = stateRoot; this.projects = projects; this.deviceName = deviceName; this.gate = gate;
    this.requireWriter = requireWriter ?? (() => { }); this.home = home ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    this.walkReuse = walkReuse; this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.deleteGate = deleteGate ?? (() => false); this.deleteStamp = deleteStamp ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.deleteDevice = deleteDevice ?? (() => ""); this.deleteMacName = deleteMacName ?? (_ => null); this.witness = witness ?? CloudDeleteWitnessSlot.Shared;
    Keeper = new(Path.Combine(stateRoot, "sealed-bin"), CloudProjectSecretFilesRules.SourceId);
  }

  private async Task<IDisposable> EnterAsync() { await turn.WaitAsync(); return new Done(turn); }
  private sealed class Done(SemaphoreSlim s) : IDisposable { public void Dispose() => s.Release(); }
  private CloudSecretsStoreKeys Keys => keys ?? throw new CloudFailure("secrets_locked");

  // ---- keys and the local ledger ----

  public void UseKeys(CloudSecretsStoreKeys? next)
  {
    keys = next;
    Keeper.Use(next);
    if (next is null) { ledgerSlot = null; ledger = new(); walks.Clear(); gone.Clear(); lastSeen.Clear(); heldBack = new(StringComparer.Ordinal); refused.Clear(); return; }
    var slot = next.Shared("ledger\n"u8)[..24];
    if (slot == ledgerSlot) return;
    ledgerSlot = slot;
    ledger = ReadLedger(LedgerPath(slot)) ?? new();
  }
  private string LedgerPath(string slot) => Path.Combine(stateRoot, "files-" + slot + ".json");
  private static Ledger? ReadLedger(string path)
  {
    try
    {
      var info = new FileInfo(path);
      if (!info.Exists || info.LinkTarget is not null || info.Length > CloudProjectSecretFilesRules.LedgerBytes) return null;
      var read = JsonSerializer.Deserialize<Ledger>(File.ReadAllBytes(path));
      if (read is null) return null;
      return new() { Files = new(read.Files, StringComparer.Ordinal), Waiting = new(read.Waiting, StringComparer.Ordinal) };
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or ArgumentException) { return null; }
  }
  private void SaveLedger()
  {
    if (ledgerSlot is not { } slot) return;
    try { new CloudFileSlot(LedgerPath(slot)).Write(JsonSerializer.SerializeToUtf8Bytes(ledger)); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
  }

  // ---- the stricter setting (his press only; default off) ----

  public static bool KeepsOnThisPc(string stateRoot)
  {
    try
    {
      var path = Path.Combine(stateRoot, "setting.json");
      return File.Exists(path) && CloudJson.Parse(File.ReadAllBytes(path)) is CloudJson.Object o && o["keepOnThisPc"] is CloudJson.Bool { Value: true };
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or CloudFailure) { return false; }
  }
  /// Saved, then read back: succeeds only when the setting on disk now says `on` (F9: never silently).
  public static void SaveKeepOnThisPc(bool on, string stateRoot)
  {
    new CloudFileSlot(Path.Combine(stateRoot, "setting.json")).Write(CloudCanonical.Encode(CloudJson.Obj(("keepOnThisPc", CloudJson.From(on)))));
    if (KeepsOnThisPc(stateRoot) != on) throw new CloudFailure("unavailable");
  }
  public bool KeepOnThisPc() => KeepsOnThisPc(stateRoot);
  public void SetKeepOnThisPc(bool on) => SaveKeepOnThisPc(on, stateRoot);
  /// His names for the projects, by id (the sealed shelf lists "<project>: <file>").
  public IReadOnlyDictionary<string, string> ProjectNames() => projects().GroupBy(p => p.Id).ToDictionary(g => g.Key, g => g.First().Name, StringComparer.Ordinal);

  // ---- names and fingerprints ----

  private static string RecordId(CloudSecretsStoreKeys keys, string projectId, string folder, string path) =>
    "file/" + projectId + "/" + keys.Shared(Encoding.UTF8.GetBytes("id\n" + projectId + "\n" + folder + "\n" + path));
  private static string Mark(CloudSecretsStoreKeys keys, byte[] bytes) => keys.Shared([.. "content\n"u8, .. bytes]);
  private static string? MarkOf(CloudSecretRecord? record) => record?.Payload is CloudJson.Object o ? o["mark"]?.AsString : null;
  public static string PlainName(string raw)
  {
    var flat = new string(raw.Select(c => char.IsControl(c) || char.GetUnicodeCategory(c) == UnicodeCategory.Format ? ' ' : c).ToArray()).Trim();
    return flat.Length == 0 ? "another device" : flat.Length > 60 ? flat[..60] : flat;
  }

  // ---- capture ----

  public async Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync()
  {
    var k = Keys;
    Keeper.Ready();
    using var _ = await EnterAsync();
    Keeper.Expire(deleteStamp());
    var list = projects().Where(p => CloudProjectSecretFilesRules.ValidProjectId(p.Id)).ToArray();
    var keep = KeepOnThisPc();
    if (!keep) { await NoticeMissingAsync(list, k); PlaceWaiting(list, k); }
    lookedAt = now();
    // R3: nothing can be sent, so the kept scan (it holds contents) is not kept either.
    if (keep) { heldBack = new(StringComparer.Ordinal); walks.Clear(); return []; }
    gateState = gate();
    if (gateState != CloudProjectSecretFilesGate.Open) { walks.Clear(); return []; }
    var name = PlainName(deviceName());
    myName = name;
    var records = new List<CloudSecretRecord>();
    var seen = new HashSet<string>(StringComparer.Ordinal);
    var held = new Dictionary<string, List<CloudProjectSecretFilesStatus.File>>(StringComparer.Ordinal);
    var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var changed = false;
    // One project's trouble (a clash, a forbidden folder, a file that cannot be sealed) never stops the others.
    foreach (var project in list.OrderBy(p => p.Id, StringComparer.Ordinal))
    {
      int count = 0, bytes = 0;
      var names = project.Folders.Select(FolderName).ToArray();
      for (var index = 0; index < project.Folders.Count; index++)
      {
        // One folder names none (each device has its own folder name for it); with several, the folder's own name.
        var folder = project.Folders.Count == 1 ? "" : names[index];
        void HoldBack(string path, int size, long? at, string state) =>
          (held.TryGetValue(project.Id, out var l) ? l : held[project.Id] = []).Add(new(folder, path, size, at, null, state, false));
        if (folder.Length > 0 && !CloudProjectSecretFilesRules.CleanFolderName(folder)) continue;
        // Two folders with one name: their records would share names, and no device could tell them apart.
        if (folder.Length > 0 && names.Count(n => string.Equals(n, folder, StringComparison.OrdinalIgnoreCase)) > 1)
        { HoldBack(folder + "/", 0, null, CloudProjectSecretFilesWords.SameName(folder)); continue; }
        var (kind, real) = CloudProjectSecretFilesRules.RealRoot(project.Folders[index], home);
        if (kind == CloudProjectSecretFilesRules.RootKind.Missing) continue;
        if (kind == CloudProjectSecretFilesRules.RootKind.Forbidden) { HoldBack(names[index] + "/", 0, null, CloudProjectSecretFilesWords.WholeFolder); continue; }
        var root = real!;
        roots.Add(root);
        foreach (var found in Walked(root))
        {
          if (found.Stays) { HoldBack(found.Path, found.Size, found.At, CloudProjectSecretFilesWords.StaysHere); continue; }
          if (found.Size > CloudProjectSecretFilesRules.FileBytes || found.Data.Length > CloudProjectSecretFilesRules.FileBytes)
          { HoldBack(found.Path, found.Size, found.At, CloudProjectSecretFilesWords.TooLarge); continue; }
          if (count >= CloudProjectSecretFilesRules.ProjectFiles || bytes + found.Data.Length > CloudProjectSecretFilesRules.ProjectBytes || records.Count >= CloudProjectSecretFilesRules.AllFiles)
          { HoldBack(found.Path, found.Size, found.At, CloudProjectSecretFilesWords.TooMany); continue; }
          var id = RecordId(k, project.Id, folder, found.Path);
          // Never two records with one name (the adapter would refuse the whole batch).
          if (seen.Contains(id)) continue;
          var current = Mark(k, found.Data);
          gone.Remove(id); lastSeen[id] = now();
          if (Keeper.Mark(id) is { } localMark)
          {
            if (localMark.Mark == CloudLocalMark.OnlyOnThisPc) continue;
            var newest = Keeper.Newest(id);
            var newestValue = TryDecoded(newest);
            if (newest is not null && newestValue is { } nv && Keeper.IsDeleted(id))
            {
              if (current == nv.Value.Mark)
              {
                if (Keeper.IsUnplaced(id))
                {
                  // Decision 10: the removal reached this PC while this project folder was not here. The same bytes in
                  // the folder now are that removed file: into the Bin (its sealed copy exists). Refused: tried again.
                  if (RemoveFile(newest, list)) { Keeper.PlacedUnplaced(id); ledger.Files.Remove(id); changed = true; }
                  continue;
                }
                // Decision 10: removed here, and the same bytes are back: he put it back himself. His new version.
                Keeper.Restored(id, keepHandMark: false);
                Keeper.MarkDeliberate(id);
                ledger.Files[id] = new() { ProjectId = project.Id, Folder = folder, Path = found.Path, Mark = current, Base = nv.Value.Base, At = nv.Value.At,
                  From = nv.Value.From, Bytes = found.Data.Length };
                changed = true;
              }
              else Keeper.Restored(id, keepHandMark: false);
            }
            else if (newest is not null && newestValue is { } nw)
            {
              if (current == nw.Value.Mark)
              {
                Keeper.Restored(id, keepHandMark: false);
                Place(nw.Value, nw.Bytes, id, k, list, keep: false);
                continue;
              }
              if (Keeper.FileMarks(id).Contains(current))
              {
                // J-7: a branch switch brought old bytes back. Keep them sealed, write the Cloud's newest FIRST and
                // clear the mark only after; a failed write keeps the mark and the next look tries again.
                var before = new CloudProjectSecretFileValue(1, project.Id, folder, found.Path, CloudProjectSecretFilesRules.OwnerOnlyMode,
                  Convert.ToBase64String(found.Data), current, null, found.At, name);
                try { Keeper.KeepSafety(before.Record(id), now()); } catch (Exception e) when (e is CloudFailure or IOException) { continue; }
                try { CloudProjectSecretFilesDisk.Write(root, found.Path, nw.Bytes, found.Data, nw.Value.At); }
                catch (CloudProjectSecretFilesDisk.Refused) { continue; }
                walks.Remove(root);
                Keeper.Restored(id, keepHandMark: false);
                Place(nw.Value, nw.Bytes, id, k, list, keep: false);
                continue;
              }
              Keeper.Restored(id, keepHandMark: false);
            }
            else Keeper.Restored(id, keepHandMark: false);
          }
          ledger.Files.TryGetValue(id, out var known);
          if (known?.Mark != current)
          {
            // A new version made here, on top of the last agreed one.
            known = new() { ProjectId = project.Id, Folder = folder, Path = found.Path, Mark = current, Base = MarkOf(Keeper.Newest(id)) ?? known?.Mark,
              At = found.At, From = name, Bytes = found.Data.Length };
            ledger.Files[id] = known; changed = true;
          }
          var agreed = known!;
          var value = new CloudProjectSecretFileValue(1, project.Id, folder, found.Path, agreed.Mode, Convert.ToBase64String(found.Data), agreed.Mark,
            agreed.Base, agreed.At, agreed.From);
          var record = value.Record(id);
          if (CloudCanonical.Encode(record.Payload).Length > CloudSecretsLogicalAdapter.MaximumRecordPayloadBytes)
          { HoldBack(found.Path, found.Size, found.At, CloudProjectSecretFilesWords.TooLarge); continue; }
          count++; bytes += found.Data.Length;
          Keeper.Remember(record);
          seen.Add(id); records.Add(record);
        }
      }
    }
    // A folder no project uses any more is forgotten (with its bytes).
    foreach (var stale in walks.Keys.Where(r => !roots.Contains(r)).ToArray()) walks.Remove(stale);
    heldBack = held;
    if (changed) SaveLedger();
    return records;
  }
  private static string FolderName(string registered) => Path.GetFileName(registered.TrimEnd('\\', '/'));

  /// The kept scan of one folder when it is recent enough, else a new one (F10).
  private IReadOnlyList<CloudProjectSecretFilesDisk.Walked> Walked(string root)
  {
    var at = now();
    if (walks.TryGetValue(root, out var kept) && at >= kept.At && at - kept.At < walkReuse) return kept.Found;
    var found = CloudProjectSecretFilesDisk.Walk(root, at);
    walks[root] = (at, found);
    return found;
  }

  // ---- what a record must be ----

  public Task ValidateAsync(CloudSecretRecord record) { _ = Decoded(record); return Task.CompletedTask; }

  private sealed record Pair(CloudProjectSecretFileValue Value, byte[] Bytes);
  private Pair? TryDecoded(CloudSecretRecord? record)
  {
    if (record is null) return null;
    try { return Decoded(record); } catch (CloudFailure) { return null; }
  }
  /// Anything else is refused whole. A file that runs programs passes here and is refused, counted and named at merge
  /// (one bad file never stops a batch).
  private Pair Decoded(CloudSecretRecord record)
  {
    var k = Keys;
    var value = CloudProjectSecretFileValue.Decode(record);
    var bytes = value.Bytes();
    if (value.V != 1 || !CloudProjectSecretFilesRules.ValidProjectId(value.ProjectId)
      || value.Folder.Length > 0 && !CloudProjectSecretFilesRules.CleanFolderName(value.Folder) || value.Mode is < 0 or > 511 || value.At < 0
      || value.From.Length == 0 || Encoding.UTF8.GetByteCount(value.From) > 80
      || value.From.Any(c => char.IsControl(c) || char.GetUnicodeCategory(c) == UnicodeCategory.Format)
      || bytes is null || bytes.Length > CloudProjectSecretFilesRules.FileBytes
      || CloudProjectSecretFilesRules.Judge(value.Path, bytes) == CloudProjectSecretFilesRules.Verdict.Never
      || value.Mark != Mark(k, bytes) || value.Base is { Length: not 64 }
      || record.RecordId != RecordId(k, value.ProjectId, value.Folder, value.Path)) throw new CloudFailure("invalid_request");
    return new(value, bytes);
  }

  // ---- arrival ----

  public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
  {
    using var _ = await EnterAsync();
    return MergeCore(record);
  }
  private CloudApplyStatus MergeCore(CloudSecretRecord record)
  {
    var (value, bytes) = Decoded(record);
    var k = Keys;
    requireWriter();
    myName = PlainName(deviceName());
    // Checked again here, on this PC's own rule: a file that runs programs is never created or replaced.
    if (!CloudProjectSecretFilesRules.Travels(value.Path, bytes))
    {
      Refuse(value, record.RecordId, CloudProjectSecretFilesWords.RefusedPrograms);
      return CloudApplyStatus.AlreadyPresent;
    }
    var list = projects();
    if (Keeper.Mark(record.RecordId) is { } localMark)
    {
      if (localMark.Mark == CloudLocalMark.NotOnThisPc && !Keeper.IsDeleted(record.RecordId))
      {
        Keeper.Remember(record);
        ledger.Files[record.RecordId] = new() { ProjectId = value.ProjectId, Folder = value.Folder, Path = value.Path, Mark = value.Mark, Base = value.Base,
          At = value.At, From = value.From, Mode = value.Mode, Bytes = bytes.Length, ArrivedAt = now(), LastSeenAt = ledger.Files.GetValueOrDefault(record.RecordId)?.LastSeenAt };
        SaveLedger();
        return CloudApplyStatus.AlreadyPresent;
      }
      if (Keeper.HasVersion(record)) return CloudApplyStatus.AlreadyPresent;
      // A new put on top of a travelling removal brings the item back into sync.
      Keeper.Restored(record.RecordId);
    }
    Keeper.Remember(record);
    var (outcome, why) = Place(value, bytes, record.RecordId, k, list, KeepOnThisPc());
    switch (outcome)
    {
      case Placed.Wait:
        if (!Hold(record, value, why, k)) Refuse(value, record.RecordId, CloudProjectSecretFilesWords.RefusedWaitingFull);
        SaveLedger();
        return CloudApplyStatus.AlreadyPresent;
      case Placed.Refused:
        Refuse(value, record.RecordId, why);
        ledger.Waiting.Remove(record.RecordId);
        SaveLedger();
        return CloudApplyStatus.AlreadyPresent;
      default:
        ledger.Waiting.Remove(record.RecordId);
        refused.Remove(record.RecordId);
        SaveLedger();
        return outcome == Placed.Applied ? CloudApplyStatus.Applied : outcome == Placed.KeptBoth ? CloudApplyStatus.KeptBoth : CloudApplyStatus.AlreadyPresent;
    }
  }

  public Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
  {
    if (outcome != CloudApplyStatus.Applied) return Task.FromResult(true);
    var (value, bytes) = Decoded(record);
    var root = Arrival(value.ProjectId, value.Folder, projects());
    if (root.State != RootState.Ok) return Task.FromResult(false);
    return Task.FromResult(CloudProjectSecretFilesDisk.Read(root.Path!, value.Path).Bytes is { } held && held.AsSpan().SequenceEqual(bytes));
  }

  /// The project's folder on this PC for a record: its only folder, else the ONE folder with that name (never "the first"
  /// of two with one name), resolved once to its real folder. A record from a one-folder project waits on a device where
  /// that project has several. `allowEmpty`: his own press (Put back, Bring back, the bin buttons) may use an empty folder.
  private ArrivalRoot Arrival(string projectId, string folder, IReadOnlyList<CloudProjectSecretFilesProject> list, bool allowEmpty = false)
  {
    var project = list.FirstOrDefault(p => p.Id == projectId);
    if (project is null || project.Folders.Count == 0) return new(RootState.Wait, null, CloudProjectSecretFilesWords.WaitingFolder);
    string chosen;
    if (project.Folders.Count == 1)
    {
      // R1: a record that names a folder lands only in a folder of that name, never in another one.
      if (folder.Length > 0 && !string.Equals(FolderName(project.Folders[0]), folder, StringComparison.OrdinalIgnoreCase))
        return new(RootState.Wait, null, CloudProjectSecretFilesWords.WaitingFolder);
      chosen = project.Folders[0];
    }
    else
    {
      if (folder.Length == 0) return new(RootState.Wait, null, CloudProjectSecretFilesWords.WaitingFolder);
      var matches = project.Folders.Where(f => string.Equals(FolderName(f), folder, StringComparison.OrdinalIgnoreCase)).ToArray();
      if (matches.Length > 1) return new(RootState.Unusable, null, CloudProjectSecretFilesWords.WaitingSameName(folder), CloudProjectSecretFilesWords.NotRemovedSameName(folder));
      if (matches.Length == 0) return new(RootState.Wait, null, CloudProjectSecretFilesWords.WaitingFolder);
      chosen = matches[0];
    }
    var (kind, real) = CloudProjectSecretFilesRules.RealRoot(chosen, home);
    return kind switch
    {
      CloudProjectSecretFilesRules.RootKind.Ok => allowEmpty || !CloudProjectSecretFilesDisk.EmptyFolder(real!) ? new(RootState.Ok, real, "")
        : new(RootState.Wait, null, CloudProjectSecretFilesWords.WaitingFolder),
      CloudProjectSecretFilesRules.RootKind.Missing => new(RootState.Wait, null, CloudProjectSecretFilesWords.WaitingFolder),
      _ => new(RootState.Unusable, null, CloudProjectSecretFilesWords.WaitingWholeFolder, CloudProjectSecretFilesWords.NotRemovedWholeFolder)
    };
  }

  /// F4: the caps hold on arrival too, counted over what this PC knows is on its disk now, plus this one.
  private bool WithinCaps(CloudProjectSecretFileValue value, int size, string id, IReadOnlyList<CloudProjectSecretFilesProject> list)
  {
    var roots = new Dictionary<string, string?>(StringComparer.Ordinal);
    int projectCount = 0, projectBytes = 0, all = 0;
    foreach (var (other, entry) in ledger.Files)
    {
      if (other == id) continue;
      var key = entry.ProjectId + "\n" + entry.Folder;
      if (!roots.TryGetValue(key, out var root))
      {
        var found = Arrival(entry.ProjectId, entry.Folder, list);
        roots[key] = root = found.State == RootState.Ok ? found.Path : null;
      }
      if (root is null) continue;
      var read = CloudProjectSecretFilesDisk.Read(root, entry.Path, int.MaxValue);
      if (read.Bytes is not { } present) continue;
      all++;
      if (entry.ProjectId == value.ProjectId) { projectCount++; projectBytes += present.Length; }
    }
    return projectCount < CloudProjectSecretFilesRules.ProjectFiles && projectBytes + size <= CloudProjectSecretFilesRules.ProjectBytes && all < CloudProjectSecretFilesRules.AllFiles;
  }

  private (Placed Outcome, string Why) Place(CloudProjectSecretFileValue value, byte[] bytes, string id, CloudSecretsStoreKeys k,
    IReadOnlyList<CloudProjectSecretFilesProject> list, bool keep)
  {
    if (keep) return (Placed.Wait, CloudProjectSecretFilesWords.WaitingSetting);
    var arrival = Arrival(value.ProjectId, value.Folder, list);
    if (arrival.State != RootState.Ok) return (Placed.Wait, arrival.Why);
    var root = arrival.Path!;
    if (Keeper.Mark(id) is not null) return (Placed.Same, "");
    // A removal applied here drops the item from this list (decision 1). A listed file that is absent was removed
    // outside the app: the next look marks it "Not on this PC"; only that mark keeps arrivals away.
    ledger.Files.TryGetValue(id, out var entry);
    void Agreed() => ledger.Files[id] = new() { ProjectId = value.ProjectId, Folder = value.Folder, Path = value.Path, Mark = value.Mark, Base = value.Base,
      At = value.At, From = value.From, Bytes = bytes.Length, ArrivedAt = now() };
    var read = CloudProjectSecretFilesDisk.Read(root, value.Path);
    // A twin (the same name in another letter case) is never overwritten: his stays.
    if (read.Blocked == "twin") return (Differs(value, id, null, k), "");
    if (read.Blocked is not null) return (Placed.Wait, CloudProjectSecretFilesWords.WaitingBlocked);
    if (read.Bytes is not { } local)
    {
      // A known file is between absent looks, or removed by hand. Never let an arrival undo that: keep the newest sealed
      // until the look records the mark or he explicitly brings it back.
      if (entry is not null) return (Placed.Wait, CloudDeleteWords.NotOnThisPc);
      if (!WithinCaps(value, bytes.Length, id, list)) return (Placed.Refused, CloudProjectSecretFilesWords.RefusedCaps);
      try { CloudProjectSecretFilesDisk.Write(root, value.Path, bytes, null, value.At); }
      catch (Exception e) when (e is CloudProjectSecretFilesDisk.Refused or IOException or UnauthorizedAccessException) { return (Placed.Wait, CloudProjectSecretFilesWords.WaitingBlocked); }
      walks.Remove(root);
      Agreed(); return (Placed.Applied, "");
    }
    var localMark = Mark(k, local);
    if (localMark == value.Mark) { if (entry?.Mark != value.Mark) Agreed(); return (Placed.Same, ""); }
    // Made on top of exactly what is here, and what is here is the last agreed version: the newer one wins.
    if (entry is not null && entry.Mark == localMark && value.Base == localMark)
    {
      if (!WithinCaps(value, bytes.Length, id, list)) return (Placed.Refused, CloudProjectSecretFilesWords.RefusedCaps);
      try
      {
        var before = new CloudProjectSecretFileValue(1, entry.ProjectId, entry.Folder, entry.Path, CloudProjectSecretFilesRules.OwnerOnlyMode,
          Convert.ToBase64String(local), localMark, entry.Base, entry.At, entry.From);
        Keeper.KeepSafety(before.Record(id), now());
        CloudProjectSecretFilesDisk.Write(root, value.Path, bytes, local, value.At);
      }
      catch (Exception e) when (e is CloudProjectSecretFilesDisk.Refused or CloudFailure or IOException or UnauthorizedAccessException) { return (Differs(value, id, local, k), ""); }
      walks.Remove(root);
      Agreed(); return (Placed.Applied, "");
    }
    return (Differs(value, id, local, k), "");
  }

  /// His own text wins: nothing here changes. The other version stays sealed in the kept-conflicts store (the adapter
  /// keeps it) and on the other device; the line says so.
  private Placed Differs(CloudProjectSecretFileValue value, string id, byte[]? local, CloudSecretsStoreKeys k)
  {
    if (!ledger.Files.TryGetValue(id, out var entry))
      ledger.Files[id] = entry = new() { ProjectId = value.ProjectId, Folder = value.Folder, Path = value.Path, Mark = local is null ? "" : Mark(k, local),
        At = now(), From = myName, Bytes = local?.Length ?? 0 };
    entry.DiffersFrom = value.From; entry.DiffersAt = value.At;
    return Placed.KeptBoth;
  }

  /// Kept sealed with this PC's own key until it can be placed; false when the waiting list is full.
  private bool Hold(CloudSecretRecord record, CloudProjectSecretFileValue value, string why, CloudSecretsStoreKeys k)
  {
    string text;
    try { text = Convert.ToBase64String(CloudSecretsLocalSeal.Seal(record.Canonical(), k.Local)); } catch (Exception) { return false; }
    int count = 0, project = 0, size = 0;
    foreach (var (other, waiting) in ledger.Waiting)
    {
      if (other == record.RecordId) continue;
      count++; size += waiting.Sealed.Length;
      if (waiting.ProjectId == value.ProjectId) project++;
    }
    if (count >= CloudProjectSecretFilesRules.AllFiles || project >= CloudProjectSecretFilesRules.ProjectFiles || size + text.Length > CloudProjectSecretFilesRules.WaitingBytes) return false;
    ledger.Waiting[record.RecordId] = new() { ProjectId = value.ProjectId, Path = value.Path, From = value.From, At = value.At, Why = why, Sealed = text };
    return true;
  }

  /// Counted, and named in the status (at most AllFiles names; the count keeps going).
  private void Refuse(CloudProjectSecretFileValue value, string id, string why)
  {
    refusedCount++;
    if (!refused.ContainsKey(id) && refused.Count >= CloudProjectSecretFilesRules.AllFiles) return;
    refused[id] = (value.ProjectId, new(value.Folder, value.Path, 0, value.At, value.From, why, false));
  }

  /// Arrivals that waited (no folder yet, the stricter setting, a link in the way) are placed when they can be.
  private void PlaceWaiting(IReadOnlyList<CloudProjectSecretFilesProject> list, CloudSecretsStoreKeys k)
  {
    if (ledger.Waiting.Count == 0) return;
    try { requireWriter(); } catch (Exception) { return; }
    var changed = false;
    foreach (var (id, waiting) in ledger.Waiting.OrderBy(w => w.Key, StringComparer.Ordinal).ToArray())
    {
      Pair? pair = null;
      try
      {
        var record = CloudSecretRecord.FromJson(CloudJson.Parse(CloudSecretsLocalSeal.Open(Convert.FromBase64String(waiting.Sealed), k.Local)));
        if (record.RecordId == id) pair = Decoded(record);
      }
      catch (Exception) { pair = null; }
      if (pair is null || !CloudProjectSecretFilesRules.Travels(pair.Value.Path, pair.Bytes)) { ledger.Waiting.Remove(id); changed = true; continue; }
      var (outcome, why) = Place(pair.Value, pair.Bytes, id, k, list, keep: false);
      switch (outcome)
      {
        case Placed.Wait: if (why != waiting.Why) { waiting.Why = why; changed = true; } break;
        case Placed.Refused: Refuse(pair.Value, id, why); ledger.Waiting.Remove(id); changed = true; break;
        default: ledger.Waiting.Remove(id); changed = true; break;
      }
    }
    if (changed) SaveLedger();
  }

  // ---- the delete rule (the Bin calls below belong to the person's own presses only) ----

  /// The Code page and tools: one project secret file by its visible name. No bytes, no Bin entry.
  public CloudDeleteItem? DeleteItem(string projectId, string folder, string path)
  {
    var id = RecordId(Keys, projectId, folder, path);
    if (Keeper.IsDeleted(id)) return null;
    return Keeper.Newest(id) is { } newest ? Item(newest) : null;
  }
  /// Every tracked project secret file by name with its folder; never bytes, never a Bin entry.
  public IReadOnlyList<CloudProjectSecretFileTarget> DeleteListing()
  {
    _ = Keys;
    var output = new List<CloudProjectSecretFileTarget>();
    foreach (var entry in ledger.Files.Values.OrderBy(e => e.ProjectId, StringComparer.Ordinal).ThenBy(e => e.Path, StringComparer.Ordinal))
    {
      CloudDeleteItem? item = null;
      try { item = DeleteItem(entry.ProjectId, entry.Folder, entry.Path); } catch (CloudFailure) { }
      if (item is not null) output.Add(new(item, entry.Folder));
    }
    return output;
  }
  private CloudDeleteItem Item(CloudSecretRecord record) => new(record.RecordId, ItemKind, Decoded(record).Value.Path, Decoded(record).Value.ProjectId);
  /// Decision 7: whether "Everywhere" (and "Cloud") can be honoured right now; pages hide both buttons when false.
  public Task<bool> CanDeleteEverywhereAsync()
  {
    if (keys is null) return Task.FromResult(false);
    try { Keeper.Ready(); } catch (CloudFailure) { return Task.FromResult(false); }
    return Task.FromResult(deleteGate());
  }
  public string? BinNotice => Keeper.Notice;

  /// Removes exactly the record's bytes from its project folder here. True: gone (or already absent).
  private bool RemoveFile(CloudSecretRecord record, IReadOnlyList<CloudProjectSecretFilesProject> list)
  {
    var (value, bytes) = Decoded(record);
    var root = Arrival(value.ProjectId, value.Folder, list, allowEmpty: true);
    if (root.State != RootState.Ok) return false;
    requireWriter();
    switch (CloudProjectSecretFilesDisk.UnlinkExactly(root.Path!, value.Path, bytes))
    {
      case CloudProjectSecretFilesDisk.Unlinked.Removed: walks.Remove(root.Path!); return true;
      case CloudProjectSecretFilesDisk.Unlinked.Absent: return true;
      default: return false;
    }
  }

  private async Task NoticeMissingAsync(IReadOnlyList<CloudProjectSecretFilesProject> list, CloudSecretsStoreKeys k)
  {
    var open = deleteGate();
    foreach (var (id, entry) in ledger.Files.ToArray())
    {
      // A missing, unreadable or EMPTY root is never evidence of anything (rule 7, decision 11): no mark, no removal.
      if (Keeper.Mark(id) is not null) continue;
      var root = Arrival(entry.ProjectId, entry.Folder, list);
      if (root.State != RootState.Ok) continue;
      var read = CloudProjectSecretFilesDisk.Read(root.Path!, entry.Path, int.MaxValue);
      if (read.Bytes is not null) { gone.Remove(id); lastSeen[id] = now(); entry.LastSeenAt = now(); continue; }
      if (read.Blocked is not null) continue;
      var at = now();
      if (!gone.TryGetValue(id, out var first)) { gone[id] = at; continue; }
      if (at < first || at - first < 3_000) continue;
      gone.Remove(id);
      ledger.Waiting.Remove(id);
      if (Keeper.Intent(id) is { } intent && Keeper.Newest(id) is { } pending)
      {
        // An app delete of this very action (an intent is written last and cleared first, decision 2).
        var actor = new CloudDeleteActor(intent.By, intent.Mac, myName, intent.Session, intent.Agent, intent.At, intent.Group);
        try
        {
          var removal = Keeper.Prepare(pending, Item(pending), intent.Scope, actor, open, deleteStamp());
          Keeper.Finish(removal);
          if (intent.Scope == CloudDeleteScope.Everywhere) ledger.Files.Remove(id);
        }
        catch (Exception e) when (e is CloudFailure or CloudDeleteRuleException or IOException) { try { Keeper.PutMark(id, CloudLocalMark.NotOnThisPc, at); } catch (Exception) { } }
        continue;
      }
      var seenAt = lastSeen.TryGetValue(id, out var s) ? s : entry.LastSeenAt ?? entry.At;
      var answer = await witness.WhoAsync(Path.Combine(root.Path!, entry.Path.Replace('/', Path.DirectorySeparatorChar)),
        DateTimeOffset.FromUnixTimeMilliseconds(seenAt), DateTimeOffset.FromUnixTimeMilliseconds(at));
      if (keys is null) throw new CloudFailure("secrets_locked");
      var device = deleteDevice();
      // Without the gate, this device's id, the service clock or a proper command group it cannot be an attributed
      // Everywhere removal: it stays by hand (a mark), the safe side.
      if (open && answer.Kind == CloudDeleteWitnessAnswer.Kinds.Ai && answer.Group is { } group && CloudDeleteText.IsUuid(group) && device.Length > 0
        && Keeper.Newest(id) is { } newest && deleteStamp() is { } stamp)
      {
        var actor = new CloudDeleteActor(CloudDeleteBy.Ai, device, PlainName(deviceName()), answer.Session, answer.Agent, stamp, group);
        try
        {
          var removal = Keeper.Prepare(newest, Item(newest), CloudDeleteScope.Everywhere, actor, true, stamp);
          Keeper.Finish(removal);
          ledger.Files.Remove(id);
        }
        catch (Exception e) when (e is CloudFailure or CloudDeleteRuleException or IOException) { try { Keeper.PutMark(id, CloudLocalMark.NotOnThisPc, at); } catch (Exception) { } }
      }
      else Keeper.PutMark(id, CloudLocalMark.NotOnThisPc, at);
    }
    SaveLedger();
  }

  /// Decision 6: null (the old form) for every ordinary upload, also while the gate is open.
  public Task<string?> VersionForUploadAsync(CloudSecretRecord record)
  {
    Keeper.Ready();
    return Task.FromResult(deleteGate() ? Keeper.UploadVersion(record) : null);
  }
  public async Task<CloudApplyStatus> MergeVersionedAsync(CloudSecretRecord record, string version, string? removalGroup)
  {
    Keeper.Ready();
    if (!CloudDeleteText.IsUuid(version)) throw new CloudFailure("invalid_request");
    using var _ = await EnterAsync();
    if (Keeper.EarlierVersion(record.RecordId, version)) return CloudApplyStatus.AlreadyPresent;
    if (Keeper.NewVersion(record.RecordId, version) && Keeper.Mark(record.RecordId) is { } mark
      && (mark.Mark == CloudLocalMark.OnlyOnThisPc || Keeper.IsDeleted(record.RecordId))) Keeper.Restored(record.RecordId);
    if (removalGroup is { } g && Keeper.Reintroduces(record.RecordId, g)) Keeper.Restored(record.RecordId);
    var outcome = MergeCore(record);
    if (outcome != CloudApplyStatus.KeptBoth) Keeper.AdoptVersion(record, version);
    return outcome;
  }
  public Task<string?> RepublicationAsync(string recordId)
  {
    Keeper.Ready();
    return Task.FromResult(deleteGate() ? Keeper.Republication(recordId) : null);
  }
  public Task<IReadOnlyList<CloudSecretRemoval>> CaptureRemovalsAsync() =>
    Task.FromResult(deleteGate() ? Keeper.Pending() : (IReadOnlyList<CloudSecretRemoval>)[]);
  public Task ValidateRemovalAsync(CloudSecretRemoval removal)
  {
    Keeper.Ready();
    if (removal.SourceId != SourceId || removal.Domain != Domain || !(removal.Version.Length == 64 || CloudDeleteText.IsUuid(removal.Version))
      || !removal.RecordId.StartsWith("file/", StringComparison.Ordinal) || removal.At <= 0 || removal.At > CloudSecretsKeeper.LatestAt) throw new CloudFailure("invalid_request");
    CloudDeleteIntent? intent;
    try { intent = CloudDeleteTravel.Read(removal.Fields, removal.RecordId, removal.Mac, removal.At).Intent; }
    catch (CloudDeleteRuleException) { throw new CloudFailure("invalid_request"); }
    if (intent is null) throw new CloudFailure("invalid_request");
    Keeper.Validate(removal);
    if (removal.Removed is { } removed) _ = Decoded(removed);
    return Task.CompletedTask;
  }
  public async Task<CloudApplyStatus> MergeRemovalAsync(CloudSecretRemoval removal)
  {
    using var _ = await EnterAsync();
    await ValidateRemovalAsync(removal);
    if (Keeper.Superseded(removal)) return CloudApplyStatus.AlreadyPresent;
    var k = Keys;
    var intent = CloudDeleteTravel.Read(removal.Fields, removal.RecordId, removal.Mac, removal.At).Intent!;
    var list = projects();
    var known = Keeper.Newest(removal.RecordId);
    if ((known ?? removal.Removed) is not { } record || !Keeper.Matches(record, removal)) return CloudApplyStatus.KeptBoth;
    var (value, bytes) = Decoded(record);
    // Only over exactly the removed version: a different file here (a later edit) wins; a link or unsafe folder on the
    // way is never followed. Both close the removal as not applied, without stalling the feed.
    var root = Arrival(value.ProjectId, value.Folder, list);
    var unplaced = false;
    switch (root.State)
    {
      case RootState.Unusable:
        // Decision 11: a folder that is here but cannot be used is named, and the removal is not recorded as done.
        Refuse(value, removal.RecordId, root.RemovalWhy);
        return CloudApplyStatus.KeptBoth;
      case RootState.Wait:
        // The project folder is not on this PC (or empty): nothing to unlink. Kept in the sealed Bin and marked.
        unplaced = intent.Scope == CloudDeleteScope.Everywhere;
        break;
      default:
        var read = CloudProjectSecretFilesDisk.Read(root.Path!, value.Path);
        if (read.Bytes is { } local && Mark(k, local) != value.Mark || read.Blocked is not null) return CloudApplyStatus.KeptBoth;
        break;
    }
    if (known is null)
    {
      // Decision 5: a copy that never was on this PC is checked like any arriving file. It stays sealed in the Bin (never
      // written by itself; Put back checks it again), it is named when it may never be written here, and a full Bin
      // refuses it.
      if (!Keeper.RoomForCarried(record)) return CloudApplyStatus.KeptBoth;
      if (!CloudProjectSecretFilesRules.Travels(value.Path, bytes)) Refuse(value, removal.RecordId, CloudProjectSecretFilesWords.PutBackPrograms);
    }
    Keeper.Remember(record);
    var undo = Keeper.UndoFor(record.RecordId);
    if (Keeper.Mark(record.RecordId) is { Mark: CloudLocalMark.NotOnThisPc } && !Keeper.IsDeleted(record.RecordId)) Keeper.KeepHandMark(record.RecordId);
    var actor = new CloudDeleteActor(intent.By, intent.Mac, deleteMacName(intent.Mac) ?? "another device", intent.Session, intent.Agent, intent.At, intent.Group);
    try { Keeper.Prepare(record, Item(record), intent.Scope, actor, travel: false, binnedAt: deleteStamp()); }
    catch (Exception) { try { Keeper.Cancel(undo); } catch (Exception) { } throw; }
    if (intent.Scope == CloudDeleteScope.Everywhere && root.State == RootState.Ok)
    {
      // The sealed keeper copy exists; the file goes only if it is still exactly that version.
      bool removed;
      try { removed = RemoveFile(record, list); } catch (Exception) { removed = false; }
      if (!removed) { try { Keeper.Cancel(undo); } catch (Exception) { } return CloudApplyStatus.KeptBoth; }
    }
    Keeper.Finish(removal, unplaced);
    // Decision 1: the item leaves this PC's list of known files, so a put back or a newer version arriving later is
    // placed like any arrival, never held as "Not on this PC".
    if (intent.Scope == CloudDeleteScope.Everywhere) ledger.Files.Remove(removal.RecordId);
    ledger.Waiting.Remove(removal.RecordId); SaveLedger();
    return CloudApplyStatus.Applied;
  }
  public Task<bool> VerifyRemovalAsync(CloudSecretRemoval removal, CloudApplyStatus outcome)
  {
    if (outcome != CloudApplyStatus.Applied) return Task.FromResult(true);
    if (Keeper.Mark(removal.RecordId) is null) return Task.FromResult(false);
    if (removal.Fields.GetValueOrDefault(CloudDeleteTravel.Scope) == "cloud" || Keeper.Newest(removal.RecordId) is not { } record) return Task.FromResult(true);
    var value = Decoded(record).Value;
    // No project folder here: nothing could be on disk; the sealed Bin entry and the mark are the result.
    var root = Arrival(value.ProjectId, value.Folder, projects());
    if (root.State != RootState.Ok) return Task.FromResult(true);
    return Task.FromResult(CloudProjectSecretFilesDisk.Read(root.Path!, value.Path).IsAbsent);
  }

  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    using var _ = await EnterAsync();
    Keeper.Ready(); requireWriter();
    // Decision 7: while an older device exists, neither "Everywhere" nor "Cloud" can be honoured for these files.
    if (!deleteGate()) throw new CloudProjectSecretFilesWaiting(CloudDeleteWords.CloudNeedsUpdatedDevices);
    var list = projects();
    var done = new List<CloudDeleteItem>();
    foreach (var wanted in items)
    {
      if (wanted.Kind != ItemKind || Keeper.IsDeleted(wanted.Id) || Keeper.Newest(wanted.Id) is not { } previous) throw new CloudFailure("invalid_request");
      var record = previous;
      var value = Decoded(previous).Value;
      var k = Keys;
      var root = Arrival(value.ProjectId, value.Folder, list, allowEmpty: true);
      if (root.State == RootState.Unusable) throw new CloudProjectSecretFilesWaiting(root.RemovalWhy);
      if (root.State == RootState.Ok && CloudProjectSecretFilesDisk.Read(root.Path!, value.Path).Bytes is { } here)
      {
        // Delete exactly this PC's current bytes, even when the last look predates an edit.
        var same = value.Mark == Mark(k, here);
        record = new CloudProjectSecretFileValue(1, value.ProjectId, value.Folder, value.Path, CloudProjectSecretFilesRules.OwnerOnlyMode, Convert.ToBase64String(here),
          Mark(k, here), same ? value.Base : value.Mark, same ? value.At : by.At, same ? value.From : by.MacName).Record(wanted.Id);
      }
      Keeper.Remember(record);
      var undo = Keeper.UndoFor(wanted.Id);
      var removal = Keeper.Prepare(record, Item(record), scope, by, true, deleteStamp());
      // Its project folder not on this PC: nothing to unlink here; the removal still travels.
      if (scope == CloudDeleteScope.Everywhere && root.State == RootState.Ok)
      {
        bool removed;
        try { removed = RemoveFile(record, list); } catch (Exception) { try { Keeper.Cancel(undo); } catch (Exception) { } throw new CloudFailure("unavailable"); }
        if (!removed) { try { Keeper.Cancel(undo); } catch (Exception) { } throw new CloudFailure("version_changed"); }
      }
      Keeper.Finish(removal);
      if (scope == CloudDeleteScope.Everywhere) ledger.Files.Remove(wanted.Id);
      ledger.Waiting.Remove(wanted.Id);
      SaveLedger();
      done.Add(Item(record));
    }
    return new(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, done);
  }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>(Keeper.Marks()
    .Where(m => !Keeper.IsDeleted(m.Place) && Keeper.Newest(m.Place) is not null).Select(m => new CloudNotHereItem(Item(Keeper.Newest(m.Place)!), m.Mark, m.At)).ToArray());
  /// Decision 5: a file comes out of this PC's keeping only under the SAME rules as any arriving secret file.
  private bool MayWrite(CloudProjectSecretFileValue value, byte[] bytes, string id, IReadOnlyList<CloudProjectSecretFilesProject> list)
  {
    if (bytes.Length > CloudProjectSecretFilesRules.FileBytes || !CloudProjectSecretFilesRules.Travels(value.Path, bytes))
    { Refuse(value, id, CloudProjectSecretFilesWords.PutBackPrograms); return false; }
    if (!WithinCaps(value, bytes.Length, id, list)) { Refuse(value, id, CloudProjectSecretFilesWords.PutBackCaps); return false; }
    return true;
  }
  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    using var _ = await EnterAsync();
    var k = Keys;
    var list = projects();
    var done = new List<CloudDeleteItem>();
    foreach (var wanted in items)
    {
      if (Keeper.IsDeleted(wanted.Id)) throw new CloudFailure("invalid_request");
      if (TryDecoded(Keeper.Newest(wanted.Id)) is not { } pair) continue;
      var record = Keeper.Newest(wanted.Id)!;
      var root = Arrival(pair.Value.ProjectId, pair.Value.Folder, list, allowEmpty: true);
      if (root.State != RootState.Ok) throw new CloudFailure("unavailable");
      var read = CloudProjectSecretFilesDisk.Read(root.Path!, pair.Value.Path);
      if (to == CloudBringBackDestination.ThisPc)
      {
        requireWriter();
        if (read.Blocked is not null) throw new CloudFailure("unsafe_configuration");
        if (read.Bytes is { } local) { if (!local.AsSpan().SequenceEqual(pair.Bytes)) throw new CloudFailure("version_changed"); }
        else
        {
          if (!MayWrite(pair.Value, pair.Bytes, wanted.Id, list)) continue;
          try { CloudProjectSecretFilesDisk.Write(root.Path!, pair.Value.Path, pair.Bytes, null, pair.Value.At); }
          catch (CloudProjectSecretFilesDisk.Refused) { throw new CloudFailure("version_changed"); }
        }
        walks.Remove(root.Path!);
        Keeper.Restored(wanted.Id, keepHandMark: false);
      }
      else
      {
        // Put in Cloud again captures THIS PC's bytes on the next look, in the versioned form.
        if (read.Bytes is null) throw new CloudFailure("unavailable");
        Keeper.Restored(wanted.Id, keepHandMark: false);
        Keeper.MarkDeliberate(wanted.Id);
      }
      Place(pair.Value, pair.Bytes, wanted.Id, k, list, keep: false);
      SaveLedger();
      done.Add(Item(record));
    }
    return done;
  }
  /// The Bin ages by the service clock only, never by this PC's own clock.
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => Task.FromResult(Keeper.Groups(deleteStamp()));
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
  {
    using var _ = await EnterAsync();
    var k = Keys;
    var list = projects();
    var done = new List<CloudDeleteItem>();
    foreach (var entry in Keeper.Entries(deleteStamp()).Where(e => e.Actor.Group == group).ToArray())
    {
      // An entry that cannot be read is skipped (decision 8); it never stops the rest.
      if (TryDecoded(entry.Record) is not { } pair) continue;
      var root = Arrival(pair.Value.ProjectId, pair.Value.Folder, list, allowEmpty: true);
      if (root.State != RootState.Ok) continue;
      requireWriter();
      var read = CloudProjectSecretFilesDisk.Read(root.Path!, pair.Value.Path);
      if (read.Blocked is not null) continue;
      if (read.Bytes is { } local) { if (!local.AsSpan().SequenceEqual(pair.Bytes)) continue; }
      else
      {
        if (!MayWrite(pair.Value, pair.Bytes, entry.Item.Id, list)) continue;
        try { CloudProjectSecretFilesDisk.Write(root.Path!, pair.Value.Path, pair.Bytes, null, pair.Value.At); } catch (CloudProjectSecretFilesDisk.Refused) { continue; }
      }
      walks.Remove(root.Path!);
      Keeper.Remember(entry.Record);
      Keeper.Restored(entry.Item.Id, keepHandMark: false);
      // Decision 1/6: his deliberate Put back travels in the versioned form and is written on his other devices.
      Keeper.MarkDeliberate(entry.Item.Id);
      Keeper.PutBackDone(group, entry.Item.Id);
      Place(pair.Value, pair.Bytes, entry.Item.Id, k, list, keep: false);
      SaveLedger();
      done.Add(entry.Item);
    }
    return done;
  }
  public async Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    using var _ = await EnterAsync();
    requireWriter(); Keeper.ForgetBin(items);
  }

  // ---- status (names, sizes, dates, plain words) ----

  public CloudProjectSecretFilesStatus? Status()
  {
    if (keys is null) return null;
    var list = projects();
    var keep = KeepOnThisPc();
    var waitingWhy = CloudProjectSecretFilesWords.Waiting(gateState);
    var status = new CloudProjectSecretFilesStatus
    {
      KeepOnThisPc = keep, WaitingForDevices = gateState != CloudProjectSecretFilesGate.Open, WaitingWhy = keep ? null : waitingWhy,
      LookedAt = lookedAt, RefusedArrivals = refusedCount, BinNotice = Keeper.Notice
    };
    var mine = PlainName(deviceName());
    foreach (var project in list.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase))
    {
      var files = new List<CloudProjectSecretFilesStatus.File>();
      foreach (var (id, entry) in ledger.Files.Where(f => f.Value.ProjectId == project.Id))
      {
        if (Keeper.IsDeleted(id)) continue;
        string state; bool travels;
        CloudDeleteMark? localMark = null;
        try { localMark = Keeper.Mark(id); } catch (CloudFailure) { }
        if (localMark is not null) { state = CloudDeleteText.Title(localMark.Mark); travels = false; }
        else if (entry.DiffersFrom is { } other) { state = CloudProjectSecretFilesWords.Differs(other); travels = false; }
        else if (keep) { state = CloudProjectSecretFilesWords.KeptHere; travels = false; }
        else if (waitingWhy is not null) { state = waitingWhy; travels = false; }
        else if (entry.ArrivedAt is not null && entry.From != mine) { state = CloudProjectSecretFilesWords.Arrived(entry.From); travels = true; }
        else { state = CloudProjectSecretFilesWords.Travels; travels = true; }
        files.Add(new(entry.Folder, entry.Path, entry.Bytes, entry.At, entry.From, state, travels));
      }
      foreach (var waiting in ledger.Waiting.Values.Where(w => w.ProjectId == project.Id))
        files.Add(new("", waiting.Path, 0, waiting.At, waiting.From, waiting.Why, false));
      files.AddRange(refused.Values.Where(r => r.ProjectId == project.Id).Select(r => r.File));
      if (heldBack.TryGetValue(project.Id, out var held)) files.AddRange(held);
      if (files.Count == 0) continue;
      status.Projects.Add(new(project.Id, project.Name, files.OrderBy(f => f.Path, StringComparer.Ordinal).ToArray()));
    }
    return status;
  }
}

/// The one live store, for the Code page, the Cloud page's switch and the read tool. Set when saved passwords are
/// wired; cleared at sign-out.
public sealed class CloudProjectSecretFilesHolder
{
  public static CloudProjectSecretFilesHolder Shared { get; } = new();
  private readonly object gate = new();
  private CloudProjectSecretFilesStore? held;
  private string? root;
  public CloudProjectSecretFilesStore? Store { get { lock (gate) return held; } set { lock (gate) held = value; } }
  /// Where the stricter setting lives on this PC (known even before saved passwords open).
  public string? StateRoot { get { lock (gate) return root; } set { lock (gate) root = value; } }
}
