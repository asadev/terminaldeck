using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Lane F (15 Nov): the Cloud folder (`%USERPROFILE%\Terminal Deck Cloud`, row I24) and, run a second time over the
// app's own store, his artifacts (row I23), ported one to one from the Mac's BackendCloudFolder.swift.
//
// The engine is NEVER given his folder: it works on this PC's private copy (`<state>\copy`; NTFS has no clones, so it
// is a plain copy, bounded by the folder's own 1 GB cap and the disk floor). Everything between his folder and the copy
// goes through this owner, one file at a time, by three fingerprints: the file in the folder, the copy, and the bytes
// both last agreed on (`Base`).
//
//     folder --(rules; quiet 3 s; at most once a minute per busy file; removals: explicit intent or witnessed AI only)--> copy --engine--> Cloud
//     Cloud --engine (refusals first)--> copy --(the one rule; older bytes kept 30 days; removals to the Bin)--> folder
//
// The safety law, for his files:
// - Nothing in the folder is overwritten or removed by sync without a way back: replaced bytes go to the 30-day keeper
//   and removed files to its Bin BEFORE the folder is touched, and a safety copy of the folder is made before the first
//   such change on this PC.
// - Two different files with one name: the newer is used, the other is kept as a version he can open.
// - By-hand disappearance is local only ("Not on this PC"). Explicit and witnessed AI removals travel, with no question.
//   Arriving removals apply over the exact version removed, after keeper and safety copies.
// - A PC that joins sends nothing of its own until it has read the Cloud (`MarkCloudRead`), and the whole kind sends
//   nothing until every computer of the account announced it understands it (`everyDeviceUnderstands`).
public sealed class CloudFolderOwner : ICloudSyncAdapter, ICloudDeleteOwning
{
  public const string EngineRefusal = "Refused: the record does not match its own description.";
  public const string NotCarried = "Refused: this file does not travel in the Cloud folder.";
  public const string DiskLowRefusal = "Waiting: this PC has less than 2 GB free. It is tried again later.";

  public CloudFileKind Profile { get; }
  /// His folder on this PC (for artifacts: the app's own store of them).
  public string Folder { get; }
  public string DeviceId { get; }
  public string StateRoot { get; }
  private readonly CloudBin keeper;
  private readonly Func<long> now;
  private readonly Func<long?> freeDisk;
  private readonly Action<string> log;
  private Func<bool> everyDeviceUnderstands;
  private Func<IReadOnlyList<string>> whoWaits = () => [];
  private Func<long?> roomLeft = () => null;
  private Func<string, string?> deviceName = _ => null;
  private Func<bool> deleteRuleOpen = () => false;
  private Func<string, bool> deleteRuleAnnounced = _ => true;
  private Func<long?> serviceNow = () => null;
  private CloudDeleteWitnessSlot witness = CloudDeleteWitnessSlot.Shared;
  private CloudDayBudget? dayBudget;
  private bool roomLow;
  private readonly SemaphoreSlim busy = new(1, 1);
  private CloudFolderEngine? built;
  private CloudDeleteState? deleteStateMade;
  private readonly CloudFileSlot slot;
  private readonly OwnerState state;
  private bool dirty = true;
  private long lastFullLook;
  private bool hurry;
  private FileSystemWatcher? watcher;
  private Timer? looper;

  /// Something of this PC is ready to be sent (the wiring asks the sync for a round).
  public event Action? Changed;
  /// Tests only: runs between reading a file's bytes and reading its size and time again (a writer still at work).
  public Action<string>? AfterReadForTests { get; set; }
  /// Tests only: a named point of a removal where a crash is simulated by throwing.
  public Action<string>? CrashPointForTests { get; set; }

  private sealed class BaseRow { public string Hash { get; set; } = ""; public long Bytes { get; set; } public long Modified { get; set; } }
  private sealed class SeenRow { public long Bytes { get; set; } public long Modified { get; set; } public long ChangedAt { get; set; } public long SentAt { get; set; } public int Streak { get; set; } }
  private sealed class LineRow { public string Device { get; set; } = ""; public long KeptUntil { get; set; } public long At { get; set; } }
  private sealed class DayRow { public long Day { get; set; } public int Count { get; set; } }
  private sealed class OwnerState
  {
    public Dictionary<string, BaseRow> Base { get; set; } = [];
    public Dictionary<string, SeenRow> Seen { get; set; } = [];
    public Dictionary<string, long> Gone { get; set; } = [];
    public Dictionary<string, LineRow> Lines { get; set; } = [];
    public Dictionary<string, string> Control { get; set; } = [];
    public HashSet<string> Arrived { get; set; } = [];
    public Dictionary<string, long> Presence { get; set; } = [];
    public Dictionary<string, DayRow> DayCount { get; set; } = [];
    public CloudFileDeleteBook Delete { get; set; } = new();
  }

  /// - `folder`: his Cloud folder (`CloudFolderFormat.DefaultFolder()`; a scratch folder in tests).
  /// - `stateRoot`: this account's Cloud folder state (`<account>\cloud-folder`), never inside `folder`.
  /// - `keeper`: the account's ONE keeper and Bin (`CloudBin.ForAccount`), shared with every other kind's owner.
  /// - `now`: the sync's service clock, falling back to this PC's clock.
  public CloudFolderOwner(string deviceId, string folder, string stateRoot, CloudBin keeper, Func<bool> everyDeviceUnderstands, CloudFileKind? kind = null,
    Func<long?>? freeDisk = null, Func<long>? now = null, Action<string>? log = null)
  {
    if (!CloudDeleteText.IsUuid(deviceId) || !Path.IsPathFullyQualified(folder) || !Path.IsPathFullyQualified(stateRoot)) throw new CloudFailure("invalid_request");
    var mine = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
    var held = Path.TrimEndingDirectorySeparator(Path.GetFullPath(stateRoot));
    if (string.Equals(mine, held, StringComparison.OrdinalIgnoreCase) || held.StartsWith(mine + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
      || mine.StartsWith(held + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new CloudFailure("unsafe_configuration");
    DeviceId = deviceId.ToLowerInvariant(); Folder = mine; StateRoot = held; this.keeper = keeper;
    Profile = kind ?? CloudFileKind.CloudFolder;
    this.everyDeviceUnderstands = everyDeviceUnderstands;
    this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    this.freeDisk = freeDisk ?? (() => CloudFolderDisk.FreeBytes(held));
    this.log = log ?? (_ => { });
    slot = new CloudFileSlot(Path.Combine(held, "folder.json"));
    state = slot.Read() is { } bytes ? JsonSerializer.Deserialize<OwnerState>(bytes) ?? new OwnerState() : new OwnerState();
  }
  public void SetEveryDeviceUnderstands(Func<bool> check) => everyDeviceUnderstands = check;
  public void SetWhoWaits(Func<IReadOnlyList<string>> names) => whoWaits = names;
  public void SetRoomLeft(Func<long?> read) => roomLeft = read;
  public void SetDeviceName(Func<string, string?> read) => deviceName = read;
  public void SetDayBudget(CloudDayBudget? budget) => dayBudget = budget;
  public void SetDeleteRuleGate(Func<bool> gate) => deleteRuleOpen = gate;
  public void SetDeleteRuleAnnounced(Func<string, bool> read) => deleteRuleAnnounced = read;
  public void SetDeleteWitness(CloudDeleteWitnessSlot slot) => witness = slot;
  /// The sync's service clock (null while not known): the daily sweep runs only on it.
  public void SetServiceNow(Func<long?> read) => serviceNow = read;

  // ---- One job at a time ----

  private Task Enter() => busy.WaitAsync();
  private void Leave() => busy.Release();

  // ---- State ----

  private void Save()
  {
    slot.Write(JsonSerializer.SerializeToUtf8Bytes(state));
    built?.Save();
  }
  public string? Control(string key) => state.Control.GetValueOrDefault(key);
  public void SetControl(string key, string? value) { if (value is null) state.Control.Remove(key); else state.Control[key] = value; }
  private BaseRow? Base(string path) => state.Base.GetValueOrDefault(path);
  private void SetBase(string path, string? hash, long bytes = 0, long modified = 0)
  {
    if (hash is null) { state.Base.Remove(path); return; }
    state.Presence[path] = now();
    state.Base[path] = new BaseRow { Hash = hash, Bytes = bytes, Modified = modified };
  }
  private void SetBase(string path, byte[] bytes, long modified) => SetBase(path, CloudMemoryFormat.Hash(bytes), bytes.LongLength, modified);
  public string CopyRoot => Path.Combine(StateRoot, "copy");
  private CloudDeleteState DeleteState() => deleteStateMade ??= new CloudDeleteState(new CloudFileSlot(Path.Combine(StateRoot, "delete-state.json")));
  private CloudFileDeleteBook Book => state.Delete;

  /// The file engine over this PC's private copy. Makes only the copy folder.
  public CloudFolderEngine Core()
  {
    if (built is not null) return built;
    Directory.CreateDirectory(CopyRoot);
    return built = new CloudFolderEngine(Path.Combine(StateRoot, "engine"), CopyRoot, DeviceId, Profile.InventoryRow, Profile.SourceId, now);
  }
  /// The rules are asked again for every arriving path: a refused one is kept unread, never written. A name that differs
  /// only by capitals from a file here is never written over it: the owner keeps it BESIDE it under a plain new name.
  private CloudFolderEngine.Placement Projection(string relative, byte[] bytes)
  {
    if (Profile.Refusal(relative) is not null || bytes.LongLength > Profile.MaximumFileBytes || CloudFolderRules.WindowsCannotHold(relative)) return new(false, "not-carried");
    if (CloudFolderDisk.CaseClash(CopyRoot, relative) || CloudFolderDisk.CaseClash(Folder, relative)) return new(false, "case-clash");
    return new(true, null);
  }

  public string ItemKey(string path) => Profile.KeeperKind + ":" + path;
  private string MineKey(string path) => ItemKey(path) + "|mine";
  public static string Name(string path) => path.Split('/').Last();
  /// The folder inside the Cloud folder, said as names ("Plans › 2026"); null at the top.
  public static string? Place(string path)
  {
    var parts = path.Split('/');
    return parts.Length > 1 ? string.Join(" › ", parts[..^1]) : null;
  }
  private bool FolderPresent() => CloudFolderDisk.IsPlainFolder(Folder);
  private static string Hash(byte[] bytes) => CloudMemoryFormat.Hash(bytes);
  private void Report(Exception error) => log(Profile.Label + ": " + (error is CloudFailure f ? f.Code : error.GetType().Name));

  // ---- Joining the sync ----

  /// Watches his folder (file events, and a look every 2 seconds). Nothing of this PC is recorded until
  /// `MarkCloudRead` and the gate is open.
  public void StartWatching()
  {
    if (looper is not null) return;
    try
    {
      if (FolderPresent())
      {
        watcher = new FileSystemWatcher(Folder) { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size };
        watcher.Changed += (_, _) => dirty = true; watcher.Created += (_, _) => dirty = true; watcher.Deleted += (_, _) => dirty = true; watcher.Renamed += (_, _) => dirty = true;
        watcher.Error += (_, _) => dirty = true;
        watcher.EnableRaisingEvents = true;
      }
    }
    catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException) { watcher = null; }
    looper = new Timer(_ => _ = LookIfDueAsync(), null, TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(2));
  }
  /// Sign-out or a closed gate: nothing is read, sent or written after this returns. Nothing is deleted.
  public void StopWatching()
  {
    looper?.Dispose(); looper = null;
    watcher?.Dispose(); watcher = null;
  }
  /// The first pull has returned: this PC has read the Cloud, so its own files may be recorded now. Kept.
  public void MarkCloudRead() { SetControl("cloudRead", "1"); Save(); }
  public bool HasReadCloud() => Control("cloudRead") == "1";
  /// Sync now: everything waiting goes at once (busy files too).
  public async Task SendNowAsync()
  {
    hurry = true;
    dirty = true;
    await LookIfDueAsync();
    hurry = false;
  }

  public async Task LookIfDueAsync()
  {
    var t = now();
    var pending = state.Seen.Any(s => Base(s.Key) is not { } b || b.Bytes != s.Value.Bytes || b.Modified != s.Value.Modified) || state.Gone.Count > 0;
    // The daily sweep runs once a day.
    var swept = long.TryParse(Control("sweptAt"), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var s) ? s : (long?)null;
    if (swept is null || t - swept < 0 || t - swept >= CloudFolderFormat.Day)
    {
      try { if (await SweepDailyAsync()) { SetControl("sweptAt", t.ToString(CultureInfo.InvariantCulture)); Save(); } }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { Report(e); }
    }
    if (!(dirty || pending || t - lastFullLook >= 300_000)) return;
    dirty = false;
    lastFullLook = t;
    try { await LookAsync(); } catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException or CloudDeleteRuleException) { Report(e); }
  }

  // ---- Folder -> copy (this PC's own changes) ----

  /// One reliable look: record changes, mark by-hand absences and journal intended removals.
  public async Task LookAsync()
  {
    await Enter();
    try { await LookBody(); }
    finally { Save(); Leave(); }
  }

  private async Task LookBody()
  {
    if (!HasReadCloud()) return;
    if (!everyDeviceUnderstands())
    {
      var waiting = whoWaits();
      SetControl("gateWaiting", waiting.Count == 0 ? null : string.Join("\n", waiting));
      return;
    }
    SetControl("gateWaiting", null);
    var engine = Core();
    var journalBefore = engine.LastSeq;
    // An arrived removal half applied before a crash is finished before anything reconciles.
    FinishArrivedRemovals(engine);
    var walk = CloudFolderWalk.Run(Folder);
    var t = now();
    // Each saved intent on its own; nothing here can stop the look.
    RecoverDeleteIntents(engine);
    var hadFiles = state.Base.Count > 0;
    var unavailable = !walk.Present || !walk.Reliable || walk.Files.Count == 0 && hadFiles;
    SetControl("folderMissing", unavailable ? "1" : null);
    if (unavailable)
    {
      // The next reliable root starts a fresh pair of absent looks.
      state.Gone.Clear();
      return;
    }
    // Windows had no Cloud folder before the delete rule: there is no older state to switch over.
    SetControl("deleteRuleMigrated", "1");
    RetryRemovalHeads(engine);
    WithdrawCloudRemovals(engine);
    var full = walk.Bytes > Profile.MaximumFolderBytes;
    SetControl("folderFull", full ? "1" : null);
    SetControl("tooLarge", walk.Skipped.TryGetValue(CloudFolderSkip.TooLarge, out var large) ? large.ToString(CultureInfo.InvariantCulture) : null);
    SetControl("secretNames", walk.SecretNames.Count == 0 ? null : string.Join("\n", walk.SecretNames));
    SetControl("spellingNames", walk.SpellingNames.Count == 0 ? null : string.Join("\n", walk.SpellingNames));
    CheckDisk();
    roomLow = roomLeft() is { } left && left < CloudFolderFormat.RoomFloor;
    SetControl("roomLow", roomLow ? "1" : null);
    _ = DaySent(t);
    var today = t / CloudFolderFormat.Day;
    var busyFiles = 0;
    foreach (var path in walk.Files.Keys.OrderBy(p => p, StringComparer.Ordinal))
    {
      var entry = walk.Files[path];
      state.Presence[path] = t;
      var mark = DeleteState().Mark(path);
      if (mark?.Mark == CloudLocalMark.OnlyOnThisPc) continue;
      if (mark is not null)
      {
        // A file back at a marked place: one path's error never stops the look (the mark stays; tried again).
        try { _ = Settle(path, engine); } catch (CloudFailure e) { Report(e); }
        continue;
      }
      if (Base(path) is { } known && known.Bytes == entry.Bytes && known.Modified == entry.Modified) continue;
      var seen = state.Seen.GetValueOrDefault(path);
      if (seen is null || seen.Bytes != entry.Bytes || seen.Modified != entry.Modified)
      {
        if (seen is null) state.Seen[path] = seen = new SeenRow();
        seen.Bytes = entry.Bytes; seen.Modified = entry.Modified; seen.ChangedAt = t;
        if (!hurry) continue;
      }
      else if (t - seen.ChangedAt < CloudFolderFormat.Quiet && !hurry) continue;
      // A file back at a place whose "Cloud" choice a look cleared is checked once it is still, BEFORE the send limits.
      try { if (CloudChoiceStands(path, null, engine)) continue; }
      catch (CloudFailure e) { Report(e); continue; }
      long sentAt = seen.SentAt; var streak = seen.Streak;
      var gap = streak >= CloudFolderFormat.BusyStreak ? CloudFolderFormat.BusyLongGap : streak >= 1 ? CloudFolderFormat.BusyGap : 0;
      if (!hurry && sentAt > 0 && t - sentAt < gap) continue;
      // Past 1 GB, new and changed files stay here (nothing is removed; one line says so).
      if (full) continue;
      // At most 6 versions of one file a day; then it waits until it has been still an hour.
      var versionsToday = state.DayCount.TryGetValue(path, out var day) && day.Day == today ? day.Count : 0;
      if (versionsToday >= CloudFolderFormat.VersionsPerDay && t - seen.ChangedAt < CloudFolderFormat.StillAfterLimit) { busyFiles++; continue; }
      bool recorded;
      // A path that is a file on one side and a folder on the other is skipped here, never the look.
      try { recorded = Settle(path, engine); } catch (CloudFailure e) when (e.Code == "unsafe_configuration") { continue; }
      if (recorded)
      {
        state.DayCount[path] = day is not null && day.Day == today ? new DayRow { Day = today, Count = day.Count + 1 } : new DayRow { Day = today, Count = 1 };
        // A file that keeps changing: each send within 10 minutes of the last one lengthens the gap.
        var next = sentAt > 0 && t - sentAt < CloudFolderFormat.BusyLongGap ? streak + 1 : 1;
        seen.SentAt = t; seen.Streak = next;
      }
    }
    SetControl("busyFiles", busyFiles > 0 ? busyFiles.ToString(CultureInfo.InvariantCulture) : null);
    foreach (var stale in state.DayCount.Where(d => d.Value.Day < today).Select(d => d.Key).ToArray()) state.DayCount.Remove(stale);
    // Rows of files that stayed still for an hour are dropped (the gap starts afresh).
    foreach (var still in state.Seen.Where(s => s.Value.ChangedAt < t - 3_600_000 && s.Value.SentAt < t - 3_600_000).Select(s => s.Key).ToArray()) state.Seen.Remove(still);
    // "Only on this PC" lives only where this PC has the file: a kept file he later removed by hand leaves no mark.
    foreach (var m in DeleteState().Marks().Where(m => m.Mark == CloudLocalMark.OnlyOnThisPc && !walk.Files.ContainsKey(m.Place) && !walk.ExcludedPaths.Contains(m.Place)))
      if (CloudFolderDisk.Read(Folder, m.Place).Kind == CloudFolderDisk.Kind.Absent)
      {
        DeleteState().ClearMark(m.Place);
        Book.Cleared.Add(m.Place);
      }
    await Removals(walk, engine, t);
    engine.ReconcileAll();
    PlaceArrivals(engine);
    if (engine.LastSeq != journalBefore) Changed?.Invoke();
  }

  // ---- Cost ----

  /// What this PC sent of this kind today (bytes). A new day starts at 0.
  private long DaySent(long t)
  {
    var today = (t / CloudFolderFormat.Day).ToString(CultureInfo.InvariantCulture);
    if (Control("day") != today)
    {
      SetControl("day", today); SetControl("daySent", "0"); SetControl("dayFull", null);
      if (dayBudget is null) return 0;
    }
    if (dayBudget is not null) return dayBudget.Sent(t / CloudFolderFormat.Day);
    return long.TryParse(Control("daySent"), NumberStyles.None, CultureInfo.InvariantCulture, out var sent) ? sent : 0;
  }
  /// May `bytes` more be recorded (and so sent) now? No while the account's room is low or today's budget would pass
  /// 200 MB (then one line says so). Sync now does not pass it.
  private bool MayRecord(long bytes)
  {
    if (roomLow) return false;
    if (DaySent(now()) + bytes > CloudFolderFormat.DailySendBytes) { SetControl("dayFull", "1"); return false; }
    return true;
  }
  private void Spent(long bytes)
  {
    if (dayBudget is not null) { _ = DaySent(now()); dayBudget.Add(bytes, now() / CloudFolderFormat.Day); return; }
    SetControl("daySent", (DaySent(now()) + bytes).ToString(CultureInfo.InvariantCulture));
  }
  /// Below 2 GB free: nothing that arrives is written or kept (one line). True while it is low.
  private bool CheckDisk()
  {
    var low = (freeDisk() ?? long.MaxValue) < CloudFolderFormat.DiskFloor;
    SetControl("diskLow", low ? "1" : null);
    return low;
  }

  /// A place whose "Only on this PC" mark a look cleared (the file was gone). Bytes this place held before get the mark
  /// back and are never uploaded (true); bytes never seen here are his new file (false, the memory goes).
  private bool CloudChoiceStands(string path, string? localHash, CloudFolderEngine engine)
  {
    if (!Book.Cleared.Contains(path) || DeleteState().Mark(path) is not null) return false;
    if (localHash is null)
    {
      if (Profile.Refusal(path) is not null || CloudFolderDisk.CaseClash(Folder, path) || CloudFolderDisk.StampOf(Folder, path) is not { } before) return false;
      var read = CloudFolderDisk.Read(Folder, path);
      if (!read.IsFile || CloudFolderDisk.StampOf(Folder, path) != before || read.Bytes!.LongLength != before.Bytes) return false;
      localHash = Hash(read.Bytes!);
    }
    if (engine.KnownVersion(path, localHash))
    {
      DeleteState().PutMark(new CloudDeleteMark(path, CloudLocalMark.OnlyOnThisPc, now()));
      Book.Cleared.Remove(path);
      return true;
    }
    Book.Cleared.Remove(path);
    return false;
  }

  /// One path, folder to copy. True when the copy changed (the engine is told by the reconcile that follows).
  private bool Settle(string path, CloudFolderEngine engine)
  {
    // Its size and time are read before AND after its bytes; a file still being written waits. A name that differs
    // only by capitals from the file on disk is not that file.
    if (Profile.Refusal(path) is not null || CloudFolderDisk.CaseClash(Folder, path) || CloudFolderDisk.StampOf(Folder, path) is not { } before) return false;
    var read = CloudFolderDisk.Read(Folder, path);
    if (!read.IsFile) return false;
    var local = read.Bytes!;
    AfterReadForTests?.Invoke(path);
    if (CloudFolderDisk.StampOf(Folder, path) != before || local.LongLength != before.Bytes || local.LongLength > Profile.MaximumFileBytes) return false;
    var localHash = Hash(local);
    // His "Cloud" choice survives a branch switch: bytes this place held before come back as "Only on this PC".
    if (CloudChoiceStands(path, localHash, engine)) return false;
    if (DeleteState().Mark(path) is { } mark)
    {
      if (mark.Mark == CloudLocalMark.OnlyOnThisPc) return false;
      // J-7: an old checkout must never publish a rollback over a newer Cloud version. The mark is cleared only AFTER
      // the check and its write succeeded; an error in between leaves it, so the next look decides again.
      if (WasCloudVersion(path, localHash, engine) && CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } newest)
      {
        var hash = Hash(newest.Bytes!);
        if (hash != localHash)
        {
          if (!EnsureSafetyCopy()) return false;
          KeepMine(path, now(), local, now());
          CrashPointForTests?.Invoke("j7:beforeWrite");
          CloudFolderDisk.Write(Folder, path, newest.Bytes!, localHash);
        }
        SetBase(path, hash, newest.Bytes!.LongLength, CloudFolderDisk.Modified(Folder, path) ?? now());
        DeleteState().ClearMark(path);
        return false;
      }
      // Unknown bytes are the person's new version ON TOP of the latest Cloud head, regardless of file dates.
      if (!MayRecord(local.LongLength)) return false;
      string? expecting = null;
      if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } held)
      {
        expecting = Hash(held.Bytes!);
        KeepVersion(ItemKey(path), Name(path), Place(path), now(), DeviceId, held.Bytes!, now());
      }
      CloudFolderDisk.Write(CopyRoot, path, local, expecting);
      Spent(local.LongLength);
      SetBase(path, localHash, local.LongLength, CloudFolderDisk.Modified(Folder, path) ?? now());
      DeleteState().ClearMark(path);
      return true;
    }
    var modified = CloudFolderDisk.Modified(Folder, path) ?? before.Modified;
    var known = Base(path);
    var copy = CloudFolderDisk.Read(CopyRoot, path);
    if (copy.Kind == CloudFolderDisk.Kind.Blocked) return false;
    var copyHash = copy.IsFile ? Hash(copy.Bytes!) : null;
    if (localHash == known?.Hash || localHash == copyHash)
    {
      // Only its time changed, or the copy already holds these bytes: nothing to send.
      SetBase(path, localHash, local.LongLength, modified);
      return false;
    }
    if (copyHash is null || copyHash == known?.Hash)
    {
      if (!MayRecord(local.LongLength)) return false;
      CloudFolderDisk.Write(CopyRoot, path, local, copyHash);
      Spent(local.LongLength);
      CloudFolderDisk.SetModified(CopyRoot, path, modified);
      SetBase(path, localHash, local.LongLength, modified);
      state.Gone.Remove(path);
      // A file back at a place that was in the Bin is in use again (on the other devices too, when it arrives).
      if (copyHash is null) TakeFromBin(ItemKey(path), now());
      return true;
    }
    // Both changed: the copy holds a version from another device not written here yet, the folder an edit not sent yet.
    return BothChanged(path, local, localHash, modified, engine);
  }

  /// The one rule for one path whose folder file and copy both changed since they last agreed. True when the copy changed.
  private bool BothChanged(string path, byte[] local, string localHash, long modified, CloudFolderEngine engine)
  {
    if (CloudFolderDisk.Read(CopyRoot, path) is not { IsFile: true } copy) return false;
    var copyBytes = copy.Bytes!;
    var copyHash = Hash(copyBytes);
    if (engine.CurrentVersion(path) is not { } arrived || arrived.RawHash != copyHash) return false;
    var agreedAt = engine.LatestTime(path, arrived.Parents);
    var t = now();
    var localAt = CloudBootFilesFormat.Clamp(modified, agreedAt, t);
    var pick = CloudBootFilesFormat.Newest(new(localAt, DeviceId, Base(path) is null), new(arrived.CreatedAt, arrived.OriginDevice, arrived.Parents.Count == 0), t);
    var item = ItemKey(path);
    if (pick == CloudBootFilesNewest.Local)
    {
      // His edit here is newer: it is recorded BESIDE the arrived version (same parents). The arrived one is kept 30 days.
      if (!MayRecord(local.LongLength)) return false;
      KeepVersion(item, Name(path), Place(path), arrived.CreatedAt, arrived.OriginDevice, copyBytes, t);
      engine.SetNextParents(path, arrived.Parents);
      CloudFolderDisk.Write(CopyRoot, path, local, copyHash);
      Spent(local.LongLength);
      CloudFolderDisk.SetModified(CopyRoot, path, modified);
      SetBase(path, localHash, local.LongLength, modified);
      return true;
    }
    // The arrived version is newer: his edit is kept 30 days (a version he can open), then the newer one is written.
    if (!EnsureSafetyCopy()) return false;
    var until = KeepMine(path, localAt, local, t);
    CloudFolderDisk.Write(Folder, path, copyBytes, localHash);
    CloudFolderDisk.SetModified(Folder, path, arrived.CreatedAt);
    SetBase(path, copyHash, copyBytes.LongLength, CloudFolderDisk.Modified(Folder, path) ?? arrived.CreatedAt);
    state.Lines[path] = new LineRow { Device = arrived.OriginDevice, KeptUntil = until, At = t };
    return false;
  }

  /// Two reliable looks at a nonempty root. An unknown witness is by hand and never travels.
  private async Task Removals(CloudFolderWalk walk, CloudFolderEngine engine, long t)
  {
    if (!walk.Present || !walk.Reliable || walk.Files.Count == 0) return;
    foreach (var (path, row) in state.Base.ToArray())
    {
      if (walk.Files.ContainsKey(path) || walk.ExcludedPaths.Contains(path)) { state.Gone.Remove(path); continue; }
      if (DeleteState().Mark(path) is not null || CloudFolderDisk.Read(Folder, path).Kind != CloudFolderDisk.Kind.Absent) continue;
      if (!state.Gone.TryGetValue(path, out var since)) { state.Gone[path] = t; continue; }
      if (t - since < CloudFolderFormat.Quiet) continue;
      // Only the witness decides here, never an intent left in the table.
      var lastSeen = Math.Min(state.Presence.TryGetValue(path, out var at) ? at : row.Modified, since);
      var answer = await witness.WhoAsync(CloudFolderDisk.Full(Folder, path), DateTimeOffset.FromUnixTimeMilliseconds(lastSeen), DateTimeOffset.FromUnixTimeMilliseconds(since));
      var travelled = false;
      if (answer.Kind == CloudDeleteWitnessAnswer.Kinds.Ai && answer.Session is { } session && answer.Group is { } group
        && CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } copy && Hash(copy.Bytes!) == row.Hash)
      {
        var intent = new CloudDeleteIntent(path, CloudDeleteScope.Everywhere, CloudDeleteBy.Ai, DeviceId, session, answer.Agent, t, group);
        try { RemoveItem(path, intent, engine, wasHere: false); travelled = true; }
        catch (Exception e) when (e is CloudFailure or CloudDeleteRuleException) { Report(e); }
      }
      // By hand, or a newer Cloud edit arrived while the file was absent, or the AI's removal could not be recorded.
      if (!travelled) DeleteState().PutMark(new CloudDeleteMark(path, CloudLocalMark.NotOnThisPc, t));
      state.Gone.Remove(path);
    }
  }

  // ---- Copy -> folder (what arrived from his other devices) ----

  /// Every path an arrival touched whose copy holds bytes the folder has not agreed on yet is placed by the rules. A path
  /// that could not be placed now stays listed. Nothing is written while the folder is missing or the disk is low.
  private void PlaceArrivals(CloudFolderEngine engine)
  {
    if (state.Arrived.Count == 0 && Control("clashNames") is null) return;
    if (RootUnavailable() || CheckDisk()) return;
    var clashes = new List<string>();
    foreach (var path in state.Arrived.OrderBy(p => p, StringComparer.Ordinal).Take(2000).ToArray())
    {
      if (DeleteState().Mark(path) is not null) continue;
      if (Profile.Refusal(path) is not null || CloudFolderDisk.CaseClash(Folder, path) || CloudFolderDisk.Read(CopyRoot, path) is not { IsFile: true } copy)
      {
        state.Arrived.Remove(path); continue;
      }
      // A name that is a folder here and a file there (or the other way) stays apart, named.
      if (CloudFolderDisk.FileFolderClash(Folder, path)) { clashes.Add(Name(path)); continue; }
      var copyHash = Hash(copy.Bytes!);
      if (copyHash != Base(path)?.Hash)
      {
        try { Arrive(path, copy.Bytes!, copyHash, Base(path), engine); }
        catch (CloudFailure) { continue; }
      }
      // Placed (or his newer edit is now the copy's): done. Otherwise it waits for the next look.
      if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } held && Hash(held.Bytes!) == Base(path)?.Hash) state.Arrived.Remove(path);
    }
    SetControl("clashNames", clashes.Count == 0 ? null : string.Join("\n", clashes));
  }

  private void Arrive(string path, byte[] copyBytes, string copyHash, BaseRow? known, CloudFolderEngine engine)
  {
    var t = now();
    var found = CloudFolderDisk.Read(Folder, path);
    switch (found.Kind)
    {
      case CloudFolderDisk.Kind.Blocked:
        return;
      case CloudFolderDisk.Kind.Absent:
        // A previously agreed file disappeared here: the two-look witness decides before any placement.
        if (known is not null) return;
        CloudFolderDisk.Write(Folder, path, copyBytes, null);
        if (engine.CurrentVersion(path)?.CreatedAt is { } at) CloudFolderDisk.SetModified(Folder, path, at);
        SetBase(path, copyHash, copyBytes.LongLength, CloudFolderDisk.Modified(Folder, path) ?? t);
        state.Gone.Remove(path);
        TakeFromBin(ItemKey(path), t);
        return;
      default:
        var local = found.Bytes!;
        var localHash = Hash(local);
        if (localHash == copyHash) { SetBase(path, copyHash, local.LongLength, CloudFolderDisk.Modified(Folder, path) ?? t); return; }
        if (known is not null && localHash == known.Hash)
        {
          // His file is the version both agreed on: the newer one replaces it; his is kept 30 days (a way back).
          if (!EnsureSafetyCopy()) return;
          // Bytes that never arrived from another device are HIS: kept under his own key for their full 30 days.
          if (engine.ArrivedVersion(path, localHash) is null) KeepMine(path, known.Modified, local, t);
          else KeepVersion(ItemKey(path), Name(path), Place(path), known.Modified, DeviceId, local, t);
          CloudFolderDisk.Write(Folder, path, copyBytes, localHash);
          if (engine.CurrentVersion(path)?.CreatedAt is { } made) CloudFolderDisk.SetModified(Folder, path, made);
          SetBase(path, copyHash, copyBytes.LongLength, CloudFolderDisk.Modified(Folder, path) ?? t);
          return;
        }
        // Both changed (or a file of the same name was here before he joined: rule J, his first copy loses and is kept).
        var modified = CloudFolderDisk.Modified(Folder, path) ?? t;
        if (BothChanged(path, local, localHash, modified, engine)) engine.ReconcileAll([path]);
        return;
    }
  }

  // ---- The Bin, versions, the lines ----

  public Task<string?> WaitingLineAsync() => Task.FromResult<string?>(Control("folderMissing") == "1" ? Profile.Words.FolderMissing : null);
  public CloudFolderAnswer? WaitingAnswer() => Control("folderMissing") == "1" ? new CloudFolderAnswer(true) : null;

  /// Explicit root recreation, never performed by sync. Restores Cloud bytes only on this person's press.
  public async Task MakeFolderAgainAsync()
  {
    await Enter();
    try
    {
      var engine = Core();
      FinishArrivedRemovals(engine);
      Directory.CreateDirectory(Folder);
      SetControl("folderMissing", null);
      foreach (var path in state.Base.Keys) state.Arrived.Add(path);
      foreach (var path in state.Arrived.ToArray())
      {
        if (DeleteState().Mark(path) is not null || CloudFolderDisk.Read(Folder, path).Kind != CloudFolderDisk.Kind.Absent
          || CloudFolderDisk.Read(CopyRoot, path) is not { IsFile: true } copy) continue;
        CloudFolderDisk.Write(Folder, path, copy.Bytes!, null);
        SetBase(path, copy.Bytes!, now());
      }
      RetryRemovalHeads(engine);
    }
    finally { Save(); Leave(); }
  }

  public IReadOnlyList<CloudFolderKept> Bin() =>
    keeper.List(Profile.KeeperKind).Select(b => new CloudFolderKept(b.Path, b.Name, b.Place, b.RemovedAt, b.Device, b.Bytes, b.KeptUntil, b.Sha256)).ToArray();
  /// Every version kept of one file, newest first: the one kept arrival or replaced version, and ALL of his own losing
  /// edits (and files Put back displaced), each for its 30 days.
  public IReadOnlyList<CloudFolderKept> Versions(string path) =>
    keeper.Versions(ItemKey(path)).Concat(keeper.Versions(MineKey(path))).OrderByDescending(k => k.At).ThenBy(k => k.Sha256, StringComparer.Ordinal)
      .Select(k => new CloudFolderKept(path, k.Name, k.Place, k.At, k.Device, k.Bytes, k.KeptUntil, k.Sha256)).ToArray();
  /// A kept version or Bin item as a file he can open (a copy in the app's own folder, named after the file).
  public string? Openable(string path, string sha256)
  {
    if (keeper.Content(Profile.KeeperKind, sha256) is not { } bytes) return null;
    var target = Path.Combine(StateRoot, "opened", sha256[..12], Name(path));
    try
    {
      if (!File.Exists(target) || !File.ReadAllBytes(target).AsSpan().SequenceEqual(bytes)) new CloudFileSlot(target).Write(bytes);
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    return target;
  }
  /// Put back from the Bin: the file is written where it was (a different file there now is kept as a version first)
  /// and the next look sends it, on top of the removal, so it comes back on his other devices too.
  public async Task<bool> PutBackAsync(string path)
  {
    await Enter();
    try
    {
      var item = ItemKey(path);
      var t = now();
      if (keeper.Get(item) is not { } binned || keeper.Content(Profile.KeeperKind, binned.Sha256) is not { } bytes || !FolderPresent()) return false;
      var there = CloudFolderDisk.Read(Folder, path);
      switch (there.Kind)
      {
        case CloudFolderDisk.Kind.Blocked: return false;
        case CloudFolderDisk.Kind.Absent: CloudFolderDisk.Write(Folder, path, bytes, null); break;
        default:
          var hash = Hash(there.Bytes!);
          if (hash != binned.Sha256)
          {
            // The file Put back displaces is his: kept under its own key for its full 30 days.
            KeepMine(path, t, there.Bytes!, t);
            CloudFolderDisk.Write(Folder, path, bytes, hash);
          }
          break;
      }
      DeleteState().ClearMark(path);
      TakeFromBin(item, t);
      dirty = true;
      return true;
    }
    finally { Save(); Leave(); }
  }
  /// One line per replaced file, newest first.
  public IReadOnlyList<CloudFolderReplacedLine> ReplacedLines(IReadOnlyDictionary<string, string> names)
  {
    var t = now();
    return state.Lines.Where(l => l.Value.KeptUntil > t).OrderByDescending(l => l.Value.At)
      .Select(l => new CloudFolderReplacedLine(names.GetValueOrDefault(l.Value.Device.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice, Name(l.Key), Place(l.Key),
        l.Value.KeptUntil, ItemKey(l.Key))).ToArray();
  }
  /// Every file the Cloud page counts, by its path relative to the folder (read only; the AI tools' targets).
  public IReadOnlyList<string> TrackedPaths() => state.Base.Keys.OrderBy(p => p, StringComparer.Ordinal).ToArray();
  /// The Cloud page's numbers: files that travel, and their size (what this PC and the Cloud agree on).
  public (int Files, long Bytes) Counts() => (state.Base.Count, state.Base.Values.Sum(b => b.Bytes));

  /// The daily sweep: kept versions and Bin items older than 30 days, opened copies, safety copies after 30 days, and
  /// the engine's retained copies nothing needs. Only on the service clock: a PC clock that is ahead must never empty the
  /// Bin. False when it did not run.
  public async Task<bool> SweepDailyAsync()
  {
    await Enter();
    try
    {
      if (serviceNow() is null) return false;
      var t = now();
      keeper.Sweep(t);
      foreach (var gone in state.Lines.Where(l => l.Value.KeptUntil <= t).Select(l => l.Key).ToArray()) state.Lines.Remove(gone);
      try { Directory.Delete(Path.Combine(StateRoot, "opened"), recursive: true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
      SweepSafetyCopies(t);
      Core().SweepRetained();
      return true;
    }
    finally { Save(); Leave(); }
  }
  private void SweepSafetyCopies(long t)
  {
    var folder = Path.Combine(StateRoot, "safety");
    if (!Directory.Exists(folder)) return;
    foreach (var made in Directory.EnumerateDirectories(folder))
    {
      var name = Path.GetFileName(made);
      if (name.StartsWith('.') || !DateTime.TryParseExact(name, "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var at)) continue;
      if (t - CloudFolderDisk.Ms(at) <= CloudFolderFormat.SafetyKeptFor) continue;
      try { Directory.Delete(made, recursive: true); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
      if (Control("safetyCopy") == made) SetControl("safetyCopy", null);
    }
  }
  /// A version kept for one file; as on the Mac only the newest arrived version of each file is kept.
  private long KeepVersion(string itemKey, string name, string? place, long at, string device, byte[] content, long t)
  {
    var until = keeper.Keep(Profile.KeeperKind, itemKey, name, place, at, device, content, t);
    keeper.KeepNewestOnly(itemKey);
    return until;
  }
  /// His own work that sync set aside: kept under its own key (`<item>|mine`), only the 30-day sweep removes it.
  private long KeepMine(string path, long at, byte[] content, long t) => keeper.Keep(Profile.KeeperKind, MineKey(path), Name(path), Place(path), at, DeviceId, content, t);
  private void KeepBinnedHistory(string path, string? replacingWith = null)
  {
    if (keeper.Get(ItemKey(path)) is not { } old || old.Sha256 == replacingWith || keeper.Content(Profile.KeeperKind, old.Sha256) is not { } bytes) return;
    keeper.Keep(Profile.KeeperKind, MineKey(path), old.Name, old.Place, old.RemovedAt, old.Device, bytes, now());
  }
  private void TakeFromBin(string itemKey, long t)
  {
    KeepBinnedHistory(itemKey[(Profile.KeeperKind.Length + 1)..]);
    keeper.Take(itemKey, t);
    keeper.KeepNewestOnly(itemKey);
  }

  /// The Cloud page's lines for this kind, one per thing that holds files back or keeps them apart. Empty when nothing does.
  public IReadOnlyList<string> PageLines()
  {
    IReadOnlyList<string> Names(string key) => Control(key) is { } v ? v.Split('\n') : [];
    var lines = new List<string>();
    if (Control("folderMissing") == "1") lines.Add(Profile.KeeperKind == CloudFileKind.CloudFolder.KeeperKind ? "Your Cloud folder is not on this PC" : "Your artifacts folder is not on this PC");
    var words = Profile.Words;
    if (Names("gateWaiting") is { Count: > 0 } waiting) lines.Add(words.Gate(waiting));
    if (Control("roomLow") == "1") lines.Add(words.RoomLow);
    if (Control("folderFull") == "1") lines.Add(words.Full);
    if (Control("dayFull") == "1" && Control("day") == (now() / CloudFolderFormat.Day).ToString(CultureInfo.InvariantCulture)) lines.Add(words.DayFull);
    if (int.TryParse(Control("busyFiles"), out var busyCount) && busyCount > 0) lines.Add(words.Busy(busyCount));
    if (Control("diskLow") == "1") lines.Add(words.DiskLow);
    if (int.TryParse(Control("tooLarge"), out var largeCount) && largeCount > 0) lines.Add(words.TooLarge(largeCount));
    if (Names("secretNames") is { Count: > 0 } secret) lines.Add(words.Secret(secret));
    if (Names("spellingNames") is { Count: > 0 } spelling) lines.Add(words.Spelling(spelling));
    if (Names("clashNames") is { Count: > 0 } clash) lines.Add(words.Clash(clash));
    return lines;
  }
  /// What waits (said plainly) and what is left out on purpose (named).
  public (int Items, long Bytes, IReadOnlyList<string> Gaps, IReadOnlyList<string> Exclusions) Coverage()
  {
    var counted = Counts();
    var large = int.TryParse(Control("tooLarge"), out var l) ? l : 0;
    var gaps = PageLines().Where(line => large == 0 || line != Profile.Words.TooLarge(large)).ToArray();
    var exclusions = Profile.Words.Exclusions.ToList();
    if (large > 0) exclusions.Add(Profile.Words.TooLarge(large));
    return (counted.Files, counted.Bytes, gaps, exclusions);
  }

  // ---- The safety copy ----

  /// Before the FIRST change that replaces or removes a file in his folder on this PC: a copy of every file that travels,
  /// in the app's own folder (`<state>\safety\<date>`). Kept 30 days. A copy that cannot be made stops every replace and
  /// removal (one log line; tried again at the next look); new files still arrive.
  private bool EnsureSafetyCopy()
  {
    if (Control("safetyCopy") is { } made && Directory.Exists(made)) return true;
    var folder = Path.Combine(StateRoot, "safety");
    var target = Path.Combine(folder, DateTimeOffset.FromUnixTimeMilliseconds(now()).UtcDateTime.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture));
    var staging = Path.Combine(folder, ".preparing");
    try
    {
      if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
      Directory.CreateDirectory(staging);
      foreach (var path in CloudFolderWalk.Run(Folder).Files.Keys)
      {
        var to = CloudFolderDisk.Full(staging, path);
        Directory.CreateDirectory(Path.GetDirectoryName(to)!);
        File.Copy(CloudFolderDisk.Full(Folder, path), to);
      }
      Directory.Move(staging, target);
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
    {
      try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); } catch (Exception f) when (f is IOException or UnauthorizedAccessException) { }
      log(Profile.Words.SafetyCopyFailed);
      return false;
    }
    SetControl("safetyCopy", target);
    return true;
  }

  // ---- Adding (the cloud.folder_add tool) ----

  /// Copies a file or folder into the top of the folder under a free name ("Name", "Name 2", ...). Returns the new path.
  /// Never the folder itself, anything inside it, or a folder that holds it.
  public string Add(string source)
  {
    string from;
    try { from = Path.TrimEndingDirectorySeparator(Path.GetFullPath(source)); }
    catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { throw new CloudFailure("invalid_request"); }
    var mine = Folder;
    if (string.Equals(from, mine, StringComparison.OrdinalIgnoreCase) || from.StartsWith(mine + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
      || mine.StartsWith(from + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !(File.Exists(from) || Directory.Exists(from)))
      throw new CloudFailure("invalid_request");
    if (!FolderPresent()) Directory.CreateDirectory(Folder);
    var name = Path.GetFileName(from);
    var dot = name.LastIndexOf('.');
    string stem = dot > 0 ? name[..dot] : name, ext = dot > 0 ? name[dot..] : "";
    for (var number = 1; number <= 99; number++)
    {
      var candidate = number == 1 ? name : stem + " " + number.ToString(CultureInfo.InvariantCulture) + ext;
      var target = Path.Combine(Folder, candidate);
      if (File.Exists(target) || Directory.Exists(target)) continue;
      if (File.Exists(from)) File.Copy(from, target);
      else CopyFolder(from, target);
      dirty = true;
      return target;
    }
    throw new CloudFailure("invalid_request");
  }
  private static void CopyFolder(string from, string to)
  {
    Directory.CreateDirectory(to);
    foreach (var entry in new DirectoryInfo(from).EnumerateFileSystemInfos())
    {
      if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) continue;
      var target = Path.Combine(to, entry.Name);
      if ((entry.Attributes & FileAttributes.Directory) != 0) CopyFolder(entry.FullName, target);
      else File.Copy(entry.FullName, target);
    }
  }

  // ---- A store the app fills itself (artifacts) ----

  /// Writes one file into this owner's folder (the app's artifacts store) inside a job, so it never races an arrival
  /// being placed: a new file only when none is there (`expecting` null), else only over exactly `expecting`.
  public async Task StoreWriteAsync(string relative, byte[] bytes, long? modified, string? expecting)
  {
    await Enter();
    try
    {
      if (Profile.Refusal(relative) is not null || bytes.LongLength > Profile.MaximumFileBytes || CloudFolderDisk.CaseClash(Folder, relative)) throw new CloudFailure("unsafe_configuration");
      if (!FolderPresent() || Control("folderMissing") == "1" || DeleteState().Mark(relative) is not null) throw new CloudFailure("unavailable");
      if (CloudFolderDisk.Read(Folder, relative).Kind == CloudFolderDisk.Kind.Absent && Base(relative) is not null) throw new CloudFailure("unavailable");
      CloudFolderDisk.Write(Folder, relative, bytes, expecting);
      if (modified is { } at) CloudFolderDisk.SetModified(Folder, relative, at);
      dirty = true;
    }
    finally { Leave(); }
  }
  /// The page's remove is explicit Everywhere. Tools pass their AI actor through DeleteItemsAsync instead.
  public async Task StoreRemoveAsync(string relative, string expecting)
  {
    var actor = PersonActor();
    await Enter();
    try
    {
      if (CloudFolderDisk.Read(Folder, relative) is not { IsFile: true } held || Hash(held.Bytes!) != expecting) throw new CloudFailure("version_changed");
      RemoveItem(relative, actor.Intent(relative, CloudDeleteScope.Everywhere), Core());
    }
    finally { Save(); Leave(); }
  }

  // ---- The sync's adapter ----

  public IReadOnlyCollection<string> Domains => [Profile.Domain];
  public bool FeedRead()
  {
    if (HasReadCloud()) return false;
    MarkCloudRead();
    return true;
  }
  public Task SettleAsync(CancellationToken ct) { Save(); return Task.CompletedTask; }

  /// This PC's journal since the last committed capture, each removal preceded by its about-record (or withdrawn).
  public async Task<CloudCapture> CaptureAsync(Func<long> stampNow, CancellationToken ct)
  {
    await LookIfDueAsync();
    await Enter();
    try
    {
      var engine = Core();
      var operations = new List<CloudOperation>();
      var reached = engine.Cursor;
      foreach (var row in engine.JournalAfter(engine.Cursor))
      {
        ct.ThrowIfCancellationRequested();
        IReadOnlyList<CloudOperation> records;
        try { records = TravelOperations(engine.Operations(row)); }
        catch (CloudFailure failure) when (failure.Code is "unavailable" or "checksum_mismatch") { break; }
        operations.AddRange(records);
        reached = row.Seq;
        if (operations.Count >= 1024) break;
      }
      Save();
      return new CloudCapture(operations, () =>
      {
        busy.Wait();
        try { engine.Cursor = Math.Max(engine.Cursor, reached); Save(); }
        finally { busy.Release(); }
      });
    }
    finally { Leave(); }
  }

  /// Refusals before anything is staged: another domain, an unreadable record, a key that is not `file/<source>/<path>`,
  /// a path this kind never carries, a file over the limit.
  public CloudFolderEngine.Part Describe(CloudOperation operation)
  {
    if (operation.Domain != Profile.Domain) throw new CloudFailure("invalid_request");
    var part = Core().Check(operation);
    if (Profile.Refusal(part.Relative) is not null || part.Bytes > Profile.MaximumFileBytes) throw new CloudFailure("invalid_request");
    return part;
  }

  public async Task ApplyAsync(CloudOperation operation, CloudImportOrigin origin, CancellationToken ct)
  {
    await Enter();
    try
    {
      if (CloudFileDeleteRecords.IsAbout(operation))
      {
        // A damaged, newer-format, misplaced or forged about-record is a refusal of that one record; its removal is
        // then applied the safe way.
        if (operation.Domain != Profile.Domain) { Book.Refused.Add(operation.OpId); throw new CloudFailure("invalid_request"); }
        Book.SaveAbout(operation, origin.DeviceId);
        return;
      }
      var item = Describe(operation);
      // Below 2 GB free nothing that arrives is kept; the records wait (tried again at the next round) and the page says
      // why. (Windows has no parking of an incoming record, so the round stops here and resumes by itself.)
      if (CheckDisk()) throw new CloudFailure("unavailable");
      var engine = Core();
      FinishArrivedRemovals(engine);
      CloudDeleteTravelRemoval? travel = null;
      var cloudOnly = false;
      if (item.Archive)
      {
        travel = Book.ArrivedRemoval(operation, item.Relative, origin.DeviceId, deleteRuleAnnounced(origin.DeviceId.ToLowerInvariant()));
        cloudOnly = travel.Intent?.Scope == CloudDeleteScope.Cloud;
      }
      // His unsent edits are recorded first, so an arrival can never pass for a successor of an edit it never saw.
      if (HasReadCloud() && everyDeviceUnderstands())
      {
        if (!cloudOnly) { try { _ = Settle(item.Relative, engine); } catch (CloudFailure e) when (e.Code == "unsafe_configuration") { } }
        engine.ReconcileAll();
      }
      var status = engine.Apply(item, Projection);
      if (!item.Archive)
      {
        // A new version from another device: the place is in the Cloud again, its old "Cloud" choice is forgotten.
        Book.Cleared.Remove(item.Relative);
        // Kept beside under a plain new name; never placed over the other file, never a removal.
        if (!(DeleteState().Mark(item.Relative) is null && KeptBesideByCapitals(item, engine))) state.Arrived.Add(item.Relative);
        if (status is not null)
        {
          if (DeleteState().Mark(item.Relative)?.Mark == CloudLocalMark.OnlyOnThisPc && engine.CurrentVersion(item.Relative)?.Version == item.Version)
          {
            // A new put on top of a Cloud removal reunites every device. This device's differing bytes are kept.
            if (CloudFolderDisk.Read(Folder, item.Relative) is { IsFile: true } local && Hash(local.Bytes!) != item.ResourceHash)
            {
              KeepMine(item.Relative, now(), local.Bytes!, now());
              SetBase(item.Relative, local.Bytes!, now());
            }
            DeleteState().ClearMark(item.Relative);
            TakeFromBin(ItemKey(item.Relative), now());
          }
          KeptBeside(item, engine);
        }
      }
      else
      {
        Book.SaveHead(item.Relative, item.Version, item.Parents, operation.CreatedAt, origin.DeviceId.ToLowerInvariant(),
          travel ?? new CloudDeleteTravelRemoval(CloudFileDeleteRecords.SafeIntent(operation, item.Relative, origin.DeviceId)));
        RetryRemovalHeads(engine);
      }
      PlaceArrivals(engine);
    }
    finally { Save(); Leave(); }
  }

  /// A version the engine kept beside the copy (made apart from the copy's version): the newer of the two goes into the
  /// copy (and from there into his folder); the other is kept 30 days.
  private void KeptBeside(CloudFolderEngine.Part item, CloudFolderEngine engine)
  {
    if (engine.CurrentVersion(item.Relative) is not { } current || current.Version == item.Version || current.RawHash == item.ResourceHash
      || CloudFolderDisk.Read(CopyRoot, item.Relative) is not { IsFile: true } copy || Hash(copy.Bytes!) != current.RawHash
      || engine.RetainedBytes(item.ResourceHash) is not { } arrivedBytes) return;
    // Arrived on top of the copy's version: the engine already wrote it; nothing was kept beside.
    if (item.Parents.Contains(current.Version)) return;
    var t = now();
    var pick = CloudBootFilesFormat.Newest(new(current.CreatedAt, current.OriginDevice, current.Parents.Count == 0),
      new(item.Op.CreatedAt, item.Op.OriginDevice, item.Parents.Count == 0), t);
    var key = ItemKey(item.Relative);
    if (pick == CloudBootFilesNewest.Local)
    {
      KeepVersion(key, Name(item.Relative), Place(item.Relative), item.Op.CreatedAt, item.Op.OriginDevice, arrivedBytes, t);
      return;
    }
    // The arrived one is newer: it becomes the copy's bytes, then reaches his folder. The copy's row ADOPTS the arrived
    // version, so nothing is journaled or uploaded again.
    CloudFolderDisk.Write(CopyRoot, item.Relative, arrivedBytes, current.RawHash);
    CloudFolderDisk.SetModified(CopyRoot, item.Relative, item.Op.CreatedAt);
    engine.AdoptArrival(item.Relative, item.Version, item.Parents, item.Op.CreatedAt, item.ResourceHash, arrivedBytes.LongLength, item.Op.OriginDevice);
    state.Lines[item.Relative] = new LineRow { Device = item.Op.OriginDevice, KeptUntil = t + CloudBin.KeptFor, At = t };
    engine.ReconcileAll([item.Relative]);
  }
  /// A file that arrived under a name that differs only by capitals from one here: written beside it as
  /// "plan (from MacBook Pro).md" (once). True when handled.
  private bool KeptBesideByCapitals(CloudFolderEngine.Part item, CloudFolderEngine engine)
  {
    if (engine.CurrentVersion(item.Relative) is not null || !(CloudFolderDisk.CaseClash(CopyRoot, item.Relative) || CloudFolderDisk.CaseClash(Folder, item.Relative))) return false;
    if (engine.RetainedBytes(item.ResourceHash) is not { } bytes || !FolderPresent()) return true;
    var device = deviceName(item.Op.OriginDevice.ToLowerInvariant()) ?? "another device";
    var slash = item.Relative.LastIndexOf('/');
    var parent = slash < 0 ? "" : item.Relative[..slash];
    var name = Name(item.Relative);
    for (var number = 1; number <= 99; number++)
    {
      var besideName = CloudFolderFormat.BesideName(name, device, number);
      var beside = parent.Length == 0 ? besideName : parent + "/" + besideName;
      if (Profile.Refusal(beside) is not null || CloudFolderRules.WindowsCannotHold(beside)) return true;
      var there = CloudFolderDisk.Read(Folder, beside);
      if (there.IsFile) { if (Hash(there.Bytes!) == item.ResourceHash) return true; continue; }
      if (there.Kind == CloudFolderDisk.Kind.Blocked || CloudFolderDisk.CaseClash(Folder, beside)) continue;
      CloudFolderDisk.Write(Folder, beside, bytes, null);
      dirty = true;
      return true;
    }
    return true;
  }

  // ---- The delete rule ----

  public CloudLocalMark? LocalMark(string path) => DeleteState().Mark(path)?.Mark;
  public CloudDeleteIntent? PendingDeleteIntent(string path) => DeleteState().Intent(path);
  private bool RootUnavailable()
  {
    var walk = CloudFolderWalk.Run(Folder);
    return !walk.Present || !walk.Reliable || walk.Files.Count == 0 && state.Base.Count > 0;
  }
  /// J-7: bytes this place held before (the copy now, this PC's own journal, or what arrived).
  private bool WasCloudVersion(string path, string hash, CloudFolderEngine engine) =>
    CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } copy && Hash(copy.Bytes!) == hash || engine.KnownVersion(path, hash);
  private CloudDeleteItem DeleteItem(string path) => new(path, Profile.KeeperKind, Name(path), path);
  public CloudDeleteActor PersonActor() =>
    new(CloudDeleteBy.Person, DeviceId, deviceName(DeviceId) ?? CloudDeleteWords.ThisPc, null, null, now(), Guid.NewGuid().ToString("D"));
  private CloudBinGroup GroupOf(CloudDeleteIntent intent, string path)
  {
    var name = deviceName(intent.Mac.ToLowerInvariant()) ?? (intent.Mac.ToLowerInvariant() == DeviceId ? CloudDeleteWords.ThisPc : CloudDeleteWords.AnotherDevice);
    return new(intent.Group, intent.By, name, intent.Session, intent.Agent, intent.At, [DeleteItem(path)]);
  }

  /// The gate is read again HERE, at send time, and the queue never waits for it. Closed: an "Everywhere" removal goes
  /// in the old compatible form (no about-record); a "Cloud" removal is withdrawn (not sent; the next look puts the
  /// file back in sync). Nothing new-format ever reaches an older build.
  public IReadOnlyList<CloudOperation> TravelOperations(IReadOnlyList<CloudOperation> operations)
  {
    var result = new List<CloudOperation>();
    foreach (var operation in operations)
    {
      if (operation.Kind == "archive")
      {
        var path = operation.Source.RecordId["file/".Length..][(Profile.SourceId.Length + 1)..];
        var intent = Book.IntentFor(operation, path);
        // Never attach a newer delete's intent to an older journal entry at the same path.
        if (intent is null && Book.Sending.ContainsKey(path)) throw new CloudFailure("unavailable");
        if (intent is not null)
        {
          if (Book.Withdrawn.ContainsKey(operation.OpId)) continue;
          if (deleteRuleOpen()) result.Add(CloudFileDeleteRecords.Operation(operation, intent));
          else if (intent.Scope == CloudDeleteScope.Cloud)
          {
            var parents = operation.Payload is CloudJson.Object o && o["parents"] is CloudJson.Array list ? list.Items.Select(x => x.AsString ?? "").ToList() : [];
            Book.Withdrawn[operation.OpId] = new CloudFileDeleteBook.WithdrawnRow { Place = path, Parents = parents };
            dirty = true;
            continue;
          }
        }
      }
      result.Add(operation);
    }
    return result;
  }
  /// Record the journal's exact removal id before exposing it to the sync.
  private void RememberRemovalMetadata(string path, CloudDeleteIntent _, CloudFolderEngine engine)
  {
    if (Book.Sending.TryGetValue(path, out var row))
    {
      var saved = new CloudDeleteIntent(path, CloudDeleteText.Scope(row.Scope) ?? CloudDeleteScope.Everywhere, CloudDeleteText.By(row.By) ?? CloudDeleteBy.Person,
        row.Mac, row.Session, row.Agent, row.At, row.Group);
      var found = engine.JournalAfter(row.AfterSeq).FirstOrDefault(j => j.Path == path && j.Kind == "archive") ?? throw new CloudFailure("unavailable");
      Book.SaveAbout(CloudFileDeleteRecords.Operation(engine.Operations(found)[0], saved), DeviceId);
    }
    Book.Sending.Remove(path);
    Changed?.Invoke();
  }

  /// The single-item removal. Its intent is written HERE and lives only inside this call: any failure before the engine
  /// has journaled the removal clears it and undoes what was done, so a press that showed an error can never delete
  /// anything afterwards. Only a crash past the Bin step leaves an intent, and only such an intent is resumed.
  /// `wasHere`: his file was in the folder when the act began (false for a removal an AI already made in the folder).
  private void RemoveItem(string path, CloudDeleteIntent intent, CloudFolderEngine engine, bool wasHere = true)
  {
    if (Profile.Refusal(path) is not null || CloudFolderDisk.CaseClash(Folder, path) || CloudFolderDisk.CaseClash(CopyRoot, path) || !HasReadCloud() || !everyDeviceUnderstands())
      throw new CloudFailure("unavailable");
    if (intent.Scope == CloudDeleteScope.Cloud && !deleteRuleOpen()) throw new CloudFailure("invalid_request");
    Book.Cleared.Remove(path);
    DeleteState().PutIntent(intent);
    try
    {
      if (intent.Scope == CloudDeleteScope.Everywhere && CloudFolderDisk.Read(Folder, path) is { IsFile: true } local)
      {
        DeleteState().ClearMark(path);
        var copy = CloudFolderDisk.Read(CopyRoot, path);
        var copyHash = copy.IsFile ? Hash(copy.Bytes!) : null;
        if (Hash(local.Bytes!) != copyHash)
        {
          if (copy.IsFile) KeepVersion(ItemKey(path), Name(path), Place(path), now(), DeviceId, copy.Bytes!, now());
          CloudFolderDisk.Write(CopyRoot, path, local.Bytes!, copyHash);
        }
        engine.ReconcileAll([path]);
      }
      JournalRemoval(path, intent, engine);
    }
    catch (Exception error) when (error is CloudFailure or IOException or UnauthorizedAccessException or CloudDeleteRuleException)
    {
      if (engine.CurrentVersion(path) is null && Book.Binned.ContainsKey(path))
      {
        // The engine journaled the removal after all: it is done; only its bookkeeping is finished.
        FinishJournaled(path, intent, engine);
        return;
      }
      AbandonRemoval(path, intent.Scope, engine, wasHere);
      throw;
    }
  }
  /// Undo an act that never reached the engine's journal. Its own markers are cleared LAST; an undo that fails half-way
  /// stays recorded and the next look's recovery runs it again, never the delete.
  private void AbandonRemoval(string path, CloudDeleteScope scope, CloudFolderEngine engine, bool restoreLocal)
  {
    try
    {
      Book.Undo[path] = new CloudFileDeleteBook.UndoRow { Scope = CloudDeleteText.Raw(scope), Restore = restoreLocal };
      Save();
      if (Book.Binned.TryGetValue(path, out var binned) && engine.CurrentVersion(path) is not null)
      {
        var bytes = keeper.Content(Profile.KeeperKind, binned);
        if (CloudFolderDisk.Read(CopyRoot, path).Kind == CloudFolderDisk.Kind.Absent && bytes is not null) CloudFolderDisk.Write(CopyRoot, path, bytes, null);
        if (scope == CloudDeleteScope.Everywhere && restoreLocal && CloudFolderDisk.Read(Folder, path).Kind == CloudFolderDisk.Kind.Absent && bytes is not null)
          CloudFolderDisk.Write(Folder, path, bytes, null);
        if (CloudFolderDisk.Read(Folder, path).IsFile && keeper.Get(ItemKey(path))?.Sha256 == binned)
        {
          TakeFromBin(ItemKey(path), now());
          Book.Bin.Remove(path);
        }
      }
      DeleteState().ClearIntent(path);
      Book.Binned.Remove(path);
      Book.Sending.Remove(path);
      Book.Undo.Remove(path);
    }
    catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { Report(e); }
  }
  /// One removal of this PC: Bin first, then his file (Everywhere), then the private copy, then the engine journals it.
  private void JournalRemoval(string path, CloudDeleteIntent intent, CloudFolderEngine engine)
  {
    // Pin the format for this act: a gate change meanwhile must never turn Cloud into old Everywhere.
    var modern = deleteRuleOpen();
    if (intent.Scope == CloudDeleteScope.Cloud && !modern) throw new CloudFailure("invalid_request");
    if (engine.CurrentVersion(path) is { } current)
    {
      byte[]? retained = null;
      if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } copy) retained = copy.Bytes;
      else if (keeper.Get(ItemKey(path)) is { } binned && binned.Sha256 == current.RawHash)
      {
        // A crash after the copy went, before the journal: the copy is made again from the Bin to finish.
        retained = keeper.Content(Profile.KeeperKind, binned.Sha256);
        if (retained is not null) CloudFolderDisk.Write(CopyRoot, path, retained, null);
      }
      if (retained is null || Hash(retained) != current.RawHash) throw new CloudFailure("unavailable");
      var local = CloudFolderDisk.Read(Folder, path);
      if (local.Kind == CloudFolderDisk.Kind.Blocked) throw new CloudFailure("unsafe_configuration");
      if (intent.Scope == CloudDeleteScope.Everywhere && local.IsFile && Hash(local.Bytes!) != current.RawHash) throw new CloudFailure("version_changed");
      if (!EnsureSafetyCopy()) throw new CloudFailure("unavailable");
      KeepBinnedHistory(path, Hash(retained));
      var group = GroupOf(intent, path);
      keeper.Put(Profile.KeeperKind, ItemKey(path), Name(path), Place(path), path, intent.At, intent.Mac, retained, Profile.Listed(path), now(), group);
      Book.Bin[path] = CloudFileDeleteBook.Store(group);
      // Past the Bin step: only from here does a crash leave an intent that a restart resumes.
      Book.Binned[path] = current.RawHash;
      Save();
      CrashPointForTests?.Invoke("press:afterBin");
      if (intent.Scope == CloudDeleteScope.Everywhere && local.IsFile) CloudFolderDisk.Remove(Folder, path, Hash(local.Bytes!));
      // Persist attribution first, then bind its exact journal id.
      if (modern)
      {
        engine.ReconcileAll();
        Book.Sending[path] = new CloudFileDeleteBook.SendingRow
        {
          Scope = CloudDeleteText.Raw(intent.Scope), By = CloudDeleteText.Raw(intent.By), Mac = intent.Mac, Session = intent.Session, Agent = intent.Agent,
          At = intent.At, Group = intent.Group, AfterSeq = engine.LastSeq
        };
        Save();
      }
      CloudFolderDisk.Remove(CopyRoot, path, current.RawHash);
      CrashPointForTests?.Invoke("press:afterCopy");
      engine.ReconcileAll([path]);
      if (engine.CurrentVersion(path) is not null) throw new CloudFailure("unavailable");
    }
    else if (!Book.Binned.ContainsKey(path))
    {
      // Nothing in the Cloud to remove: an item that was never in the Cloud is refused.
      throw new CloudFailure("unavailable");
    }
    FinishJournaled(path, intent, engine);
  }
  /// After the engine journaled the removal: bind its about-record, then clear the act. Never an error for the person.
  private void FinishJournaled(string path, CloudDeleteIntent intent, CloudFolderEngine engine)
  {
    try
    {
      RememberRemovalMetadata(path, intent, engine);
      SetBase(path, null);
      // "Only on this PC" only where this PC has the file.
      if (intent.Scope == CloudDeleteScope.Cloud && CloudFolderDisk.Read(Folder, path).IsFile) DeleteState().PutMark(new CloudDeleteMark(path, CloudLocalMark.OnlyOnThisPc, intent.At));
      else DeleteState().ClearMark(path);
      DeleteState().ClearIntent(path);
      Book.Binned.Remove(path);
      state.Gone.Remove(path);
    }
    catch (Exception e) when (e is CloudFailure or CloudDeleteRuleException) { Report(e); }
    dirty = true;
    Save();
  }

  /// One press or tool call: each item on its own, one group. An item that fails is named in the log and the rest go on;
  /// the group lists what was removed. Throws only when nothing could be removed.
  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    await Enter();
    try
    {
      var engine = Core();
      if (items.Count == 0 || items.Select(i => i.Id).Distinct().Count() != items.Count || items.Any(i => Profile.Refusal(i.Id) is not null)) throw new CloudFailure("invalid_request");
      if (scope == CloudDeleteScope.Cloud && !deleteRuleOpen()) throw new CloudFailure("invalid_request");
      FinishArrivedRemovals(engine);
      var removed = new List<CloudDeleteItem>();
      var failed = new List<string>();
      Exception? first = null;
      foreach (var item in items)
      {
        try
        {
          Book.SetRowError(item.Id, null, now());
          RemoveItem(item.Id, by.Intent(item.Id, scope), engine);
          removed.Add(item);
        }
        catch (Exception error) when (error is CloudFailure or IOException or UnauthorizedAccessException or CloudDeleteRuleException)
        {
          first ??= error;
          failed.Add(Name(item.Id));
          // The page reads it per row from `RowErrors()`.
          Book.SetRowError(item.Id, CloudFileDeleteRecords.NotRemovedLine, now());
        }
      }
      if (failed.Count > 0) log(Profile.Label + " delete: " + removed.Count.ToString(CultureInfo.InvariantCulture) + " removed, not removed: " + CloudFolderFormat.Names(failed));
      if (removed.Count == 0 && first is not null) throw first;
      return new CloudBinGroup(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, removed);
    }
    finally { Save(); Leave(); }
  }
  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() =>
    Task.FromResult<IReadOnlyList<CloudNotHereItem>>(DeleteState().Marks().Where(m => Profile.Listed(m.Place)).Select(m => new CloudNotHereItem(DeleteItem(m.Place), m.Mark, m.At)).ToArray());
  /// The one line per row whose delete did not happen, by item id. The line goes when the person acts on that row again.
  public IReadOnlyDictionary<string, string> RowErrors() => Book.RowErrors.ToDictionary(r => r.Key, r => r.Value.Line);

  /// A "Cloud" removal withdrawn at send time: nothing was removed from the Cloud; this PC's copy and engine come back on
  /// top of the version the other devices hold, the mark, Bin entry and intent go, and the file syncs normally again.
  private void WithdrawCloudRemovals(CloudFolderEngine engine)
  {
    foreach (var (operation, row) in Book.Withdrawn.Where(w => !w.Value.Done).ToArray())
    {
      var path = row.Place;
      try
      {
        if (engine.CurrentVersion(path) is null)
        {
          byte[]? bytes = null;
          var here = false;
          if (CloudFolderDisk.Read(Folder, path) is { IsFile: true } local) { bytes = local.Bytes; here = true; }
          else if (keeper.Get(ItemKey(path)) is { } kept) bytes = keeper.Content(Profile.KeeperKind, kept.Sha256);
          if (bytes is not null)
          {
            if (CloudFolderDisk.Read(CopyRoot, path).Kind == CloudFolderDisk.Kind.Absent) CloudFolderDisk.Write(CopyRoot, path, bytes, null);
            engine.SetNextParents(path, row.Parents);
            SetBase(path, bytes, CloudFolderDisk.Modified(Folder, path) ?? now());
            // In the Cloud, not on this PC when he has no file here; otherwise simply in sync.
            if (here) DeleteState().ClearMark(path);
            else DeleteState().PutMark(new CloudDeleteMark(path, CloudLocalMark.NotOnThisPc, now()));
            engine.ReconcileAll([path]);
          }
          if (keeper.Get(ItemKey(path)) is not null) TakeFromBin(ItemKey(path), now());
          Book.Bin.Remove(path);
        }
        DeleteState().ClearIntent(path);
        Book.Binned.Remove(path);
        Book.SetRowError(path, CloudDeleteWords.CloudNeedsUpdatedDevices, now());
        row.Done = true;
        dirty = true;
      }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { Report(e); }
    }
  }
  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    await Enter();
    try
    {
      var engine = Core();
      if (!FolderPresent()) throw new CloudFailure("unavailable");
      FinishArrivedRemovals(engine);
      var restored = new List<CloudDeleteItem>();
      foreach (var item in items)
      {
        var path = item.Id;
        if (Profile.Refusal(path) is not null) throw new CloudFailure("invalid_request");
        Book.SetRowError(path, null, now());
        Book.Cleared.Remove(path);
        if (to == CloudBringBackDestination.Cloud)
        {
          if (CloudFolderDisk.Read(Folder, path) is not { IsFile: true } local) throw new CloudFailure("unavailable");
          // A Cloud-scope removal archived the copy: a fresh capture inherits that removal's version.
          if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } old) CloudFolderDisk.Remove(CopyRoot, path, Hash(old.Bytes!));
          CloudFolderDisk.Write(CopyRoot, path, local.Bytes!, null);
          SetBase(path, local.Bytes!, CloudFolderDisk.Modified(Folder, path) ?? now());
          var before = engine.CurrentVersion(path)?.Version;
          engine.ReconcileAll([path]);
          if (engine.CurrentVersion(path)?.Version == before) engine.Resend(path);
          DeleteState().ClearMark(path);
        }
        else
        {
          if (CloudFolderDisk.Read(CopyRoot, path) is not { IsFile: true } copy) throw new CloudFailure("unavailable");
          var local = CloudFolderDisk.Read(Folder, path);
          string? hash = null;
          if (local.Kind == CloudFolderDisk.Kind.Blocked) throw new CloudFailure("unsafe_configuration");
          if (local.IsFile)
          {
            if (!EnsureSafetyCopy()) throw new CloudFailure("unavailable");
            KeepMine(path, now(), local.Bytes!, now());
            hash = Hash(local.Bytes!);
          }
          CloudFolderDisk.Write(Folder, path, copy.Bytes!, hash);
          DeleteState().ClearMark(path);
          SetBase(path, copy.Bytes!, CloudFolderDisk.Modified(Folder, path) ?? now());
        }
        TakeFromBin(ItemKey(path), now());
        restored.Add(item);
      }
      if (engine.LastSeq > engine.Cursor) Changed?.Invoke();
      return restored;
    }
    finally { Save(); Leave(); }
  }
  /// The group a Bin entry belongs to (its press, or one group per device and day for entries from before the rule).
  private string BinGroupId(CloudFolderKept kept) =>
    Book.Bin.TryGetValue(kept.Path, out var g) ? g.Id : CloudFileDeleteRecords.LegacyGroupId(kept.Device, kept.At, CloudBinEra.BeforeNewRule);
  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync()
  {
    var groups = new List<CloudBinGroup>();
    foreach (var kept in Bin().Where(k => Profile.Listed(k.Path)))
    {
      if (Book.Bin.TryGetValue(kept.Path, out var g)) { groups.Add(CloudFileDeleteBook.Group(g)); continue; }
      var name = deviceName(kept.Device.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice;
      groups.Add(CloudFileDeleteRecords.LegacyGroup(DeleteItem(kept.Path), kept.Device, name, kept.At, CloudBinEra.BeforeNewRule));
    }
    return Task.FromResult(CloudFileDeleteRecords.Merge(groups));
  }
  /// "Put back all": every Bin entry of the group comes back, an artifact's description too; one that fails is named in
  /// the log and the rest go on. Answers what came back.
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
  {
    var restored = new List<CloudDeleteItem>();
    var failed = new List<string>();
    foreach (var kept in Bin())
    {
      if (BinGroupId(kept) != group) continue;
      try
      {
        if (await PutBackAsync(kept.Path)) { if (Profile.Listed(kept.Path)) restored.Add(DeleteItem(kept.Path)); }
        else if (Profile.Listed(kept.Path)) failed.Add(kept.Name);
      }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { if (Profile.Listed(kept.Path)) failed.Add(kept.Name); }
    }
    if (failed.Count > 0) log(Profile.Label + " Put back all: " + restored.Count.ToString(CultureInfo.InvariantCulture) + " back, not back: " + CloudFolderFormat.Names(failed));
    return restored;
  }
  public async Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    await Enter();
    try
    {
      foreach (var item in items)
      {
        if (Profile.Refusal(item.Id) is not null) throw new CloudFailure("invalid_request");
        keeper.DeleteForGood(ItemKey(item.Id));
        Book.Bin.Remove(item.Id);
      }
    }
    finally { Save(); Leave(); }
  }

  // ---- Removals that arrived ----

  /// Every saved arrived removal on its own: one that fails waits for the next look and stops nothing; one that can never
  /// apply is dropped with one log line.
  private void RetryRemovalHeads(CloudFolderEngine engine)
  {
    if (Book.Heads.Count == 0 || RootUnavailable()) return;
    foreach (var head in Book.Heads.Values.Select(CloudFileDeleteBook.HeadOf).ToArray())
    {
      try { ApplyHead(head, engine); }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { Report(e); }
    }
  }
  private void DropHead(CloudFileDeleteRecords.Head head, string why)
  {
    Book.DropHead(head.Place);
    log(Profile.Label + " delete rule: an arrived removal of " + Name(head.Place) + " was dropped (" + why + "); nothing was removed");
  }
  private void ApplyHead(CloudFileDeleteRecords.Head head, CloudFolderEngine engine)
  {
    var path = head.Place;
    if (Profile.Refusal(path) is not null) { DropHead(head, "this file does not travel"); return; }
    if (engine.CurrentVersion(path) is not { } current) { DropHead(head, "it was never in the Cloud on this PC"); return; }
    // An edit made on top of the removed version wins (ancestry, never dates).
    if (!head.Parents.Contains(current.Version)) return;
    CloudDeleteTravelRemoval travel;
    try { travel = head.Travel; } catch (CloudDeleteRuleException) { DropHead(head, "it could not be read"); return; }
    var local = CloudFolderDisk.Read(Folder, path);
    if (local.Kind == CloudFolderDisk.Kind.Blocked) return;
    var cloudScope = travel.Intent?.Scope == CloudDeleteScope.Cloud;
    var binGroup = travel.Intent is { } intent ? GroupOf(intent, path)
      : CloudFileDeleteRecords.LegacyGroup(DeleteItem(path), head.Mac, deviceName(head.Mac.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice, head.At, CloudBinEra.OlderVersion);
    if (cloudScope)
    {
      // Scope Cloud never touches a device's file, including a differing local edit. The Cloud copy goes to the Bin.
      if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } copy)
      {
        if (!EnsureSafetyCopy()) return;
        KeepBinnedHistory(path, Hash(copy.Bytes!));
        keeper.Put(Profile.KeeperKind, ItemKey(path), Name(path), Place(path), path, head.At, head.Mac, copy.Bytes!, Profile.Listed(path), now(), binGroup);
        Book.Bin[path] = CloudFileDeleteBook.Store(binGroup);
      }
      // "Only on this PC" only where this PC has the file; with no file there is nothing to bring back.
      if (local.IsFile) DeleteState().PutMark(new CloudDeleteMark(path, CloudLocalMark.OnlyOnThisPc, head.At));
      else DeleteState().ClearMark(path);
    }
    else
    {
      if (local.IsFile && Hash(local.Bytes!) != current.RawHash) return;
      if (!EnsureSafetyCopy()) return;
      var retained = local.IsFile ? local.Bytes : engine.RetainedBytes(current.RawHash);
      if (retained is null) return;
      KeepBinnedHistory(path, Hash(retained));
      keeper.Put(Profile.KeeperKind, ItemKey(path), Name(path), Place(path), path, head.At, head.Mac, retained, Profile.Listed(path), now(), binGroup);
      Book.Bin[path] = CloudFileDeleteBook.Store(binGroup);
      if (local.IsFile) CloudFolderDisk.Remove(Folder, path, current.RawHash);
      DeleteState().ClearMark(path);
    }
    // The private copy's removal and the engine's "removed" are one step: the marker is read before anything reconciles,
    // so a crash between them never journals a removal of this PC.
    Book.Applying.Add(path);
    Save();
    CrashPointForTests?.Invoke("arrival:beforeCopy");
    if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } held)
    {
      if (Hash(held.Bytes!) != current.RawHash) { Book.Applying.Remove(path); return; }
      CloudFolderDisk.Remove(CopyRoot, path, current.RawHash);
    }
    CrashPointForTests?.Invoke("arrival:afterCopy");
    FinishHead(head, engine);
  }
  private void FinishHead(CloudFileDeleteRecords.Head head, CloudFolderEngine engine)
  {
    engine.AdoptRemoval(head.Place, head.Version, head.Parents, head.At, head.Mac);
    SetBase(head.Place, null);
    state.Gone.Remove(head.Place);
    Book.DropHead(head.Place);
  }
  /// Arrived removals whose private copy was being removed when the app stopped: finished before anything can
  /// reconcile and read the missing copy as this PC's own removal.
  private void FinishArrivedRemovals(CloudFolderEngine engine)
  {
    foreach (var path in Book.Applying.ToArray())
    {
      try
      {
        if (!Book.Heads.TryGetValue(path, out var row)) { Book.Applying.Remove(path); continue; }
        var head = CloudFileDeleteBook.HeadOf(row);
        if (engine.CurrentVersion(path) is not { } current)
        {
          // The engine already holds the removal: only the bookkeeping is left.
          SetBase(path, null);
          Book.DropHead(path);
          continue;
        }
        if (!head.Parents.Contains(current.Version)) { Book.Applying.Remove(path); continue; }
        if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } copy)
        {
          if (Hash(copy.Bytes!) != current.RawHash) { Book.Applying.Remove(path); continue; }
          CloudFolderDisk.Remove(CopyRoot, path, current.RawHash);
        }
        FinishHead(head, engine);
      }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { Report(e); }
    }
  }

  // ---- This PC's own removals after a restart ----

  /// Resumes ONLY removals already past the Bin step. An intent that never reached the Bin is dropped; one whose file or
  /// Cloud version changed since is dropped too (his newer bytes win). Each on its own: none can stop the look.
  private void RecoverDeleteIntents(CloudFolderEngine engine)
  {
    if (!FolderPresent()) return;
    foreach (var path in DeleteState().IntentPlaces())
    {
      var scope = CloudDeleteScope.Cloud;
      try
      {
        if (DeleteState().Intent(path) is not { } intent) continue;
        scope = intent.Scope;
        // An undo that failed half-way is finished, never the delete it undoes.
        if (Book.Undo.TryGetValue(path, out var undo)) { AbandonRemoval(path, CloudDeleteText.Scope(undo.Scope) ?? CloudDeleteScope.Cloud, engine, undo.Restore); continue; }
        if (CloudFolderDisk.Read(Folder, path).Kind == CloudFolderDisk.Kind.Blocked) continue;
        if (Profile.Refusal(path) is not null || !Book.Binned.TryGetValue(path, out var binned))
        {
          DeleteState().ClearIntent(path);
          log(Profile.Label + " delete rule: an unfinished delete of " + Name(path) + " that never reached the Bin was dropped; nothing was removed");
          continue;
        }
        if (engine.CurrentVersion(path) is { } current)
        {
          var changed = current.RawHash != binned;
          if (intent.Scope == CloudDeleteScope.Everywhere && CloudFolderDisk.Read(Folder, path) is { IsFile: true } local && Hash(local.Bytes!) != binned) changed = true;
          if (CloudFolderDisk.Read(CopyRoot, path) is { IsFile: true } copy && Hash(copy.Bytes!) != binned) changed = true;
          if (changed)
          {
            AbandonRemoval(path, intent.Scope, engine, restoreLocal: false);
            log(Profile.Label + " delete rule: an unfinished delete of " + Name(path) + " was dropped because the file changed since; it is kept");
            continue;
          }
        }
        JournalRemoval(path, intent, engine);
      }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException or CloudDeleteRuleException)
      {
        if (engine.CurrentVersion(path) is null) continue;
        AbandonRemoval(path, scope, engine, restoreLocal: false);
        log(Profile.Label + " delete rule: an unfinished delete of " + Name(path) + " could not be finished and was dropped; nothing more was removed");
      }
    }
  }
}
