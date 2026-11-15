using System.Globalization;
using System.Text;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Deck Memory files under the 15 Nov delete rule on Windows, ported from the Mac (td-mac-next2 DeckMemoryStoreOneRule.swift
// `DeckMemoryRemoval`, cloudApplyRemoval, cloudJournalRemoval, the CloudDeleteOwning extension; DeckMemoryStoreCloudSource.swift
// cloudForgetRemovedFiles; DeckMemoryStoreCloudMerge.swift cloudMemoryReappeared, cloudDeleteRuleArrival, cloudAgainstRemoval):
// - A captured file found gone at two looks 3 s apart: the witness decides. An AI inside a Terminal Deck session =
//   Everywhere (into the Bin, a removal marker travels). Anyone else, or cannot know = "Not on this PC": a local mark,
//   nothing sent, and nothing that arrives is placed there again by itself. A whole memory folder gone at once (an
//   unplugged disk looks the same) is never anyone's delete: nothing is marked.
// - A file reappearing at a "Not on this PC" place (J-7): the Cloud's newest bytes = mark cleared, nothing sent; bytes of
//   an earlier version = mark cleared and the Cloud's newest placed (or its removal applied); other bytes = his new
//   version, sent on top of the newest.
// - An arriving removal marker applies over exactly the version it removed (an edit made on top wins: ancestry, never
//   dates): the file goes into this PC's Bin first. "Cloud" scope: the file stays, marked "Only on this PC", never sent
//   again by itself. No new-rule fields (an older build): Everywhere, Bin label "(older version)". Unreadable fields:
//   kept as history, the file is left alone.
// - The person's "Cloud"/"Everywhere" (and an AI tool's Everywhere) through ICloudDeleteOwning: the intent and the Bin
//   copy are written BEFORE the file goes; the marker is sent by the next capture. The new fields travel only while
//   every computer of the account announced the rule; until then "Cloud" is refused and Everywhere goes in the old form.

/// What the memory adapter needs for the delete rule. Every member has a safe default: no Bin folder = an in-memory one,
/// no gate = closed, no witness = by hand, no names = "Another of your devices".
public sealed record CloudMemoryDeleteOptions(CloudBin Bin, ICloudLedgerSlot State, ICloudLedgerSlot Requests, string RetainedFolder,
  Func<string, string?>? FullPath = null, CloudAnnounce? Announce = null, Func<string, string?>? DeviceName = null, string ThisDeviceName = CloudDeleteWords.ThisPc,
  CloudDeleteWitnessSlot? Witness = null, long RunStartedAt = 0);

/// The marker a removal travels as (the Mac's DeckMemoryRemoval): a small memory file whose front matter carries
/// `td_removed: <ms>`, the removing device, the AI flag and the six delete-rule fields.
public sealed record CloudMemoryRemoval(long At, string By, string? MovedTo, bool ByAi, IReadOnlyDictionary<string, string> Travel)
{
  public static CloudMemoryRemoval? Parse(byte[] bytes)
  {
    if (!CloudMemoryFormat.IsRemovalMarker(bytes)) return null;
    var front = Front(Encoding.UTF8.GetString(bytes));
    if (!long.TryParse(Value(front, "td_removed"), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var at)) return null;
    var travel = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var key in CloudDeleteTravel.Fields) if (Value(front, key) is { } v) travel[key] = v;
    return new(at, Value(front, "td_removed_by") ?? "", Value(front, "td_moved_to"), Value(front, "td_removed_by_ai") == "1", travel);
  }
  private static List<string> Front(string text)
  {
    var lines = text.Split('\n');
    var end = Array.FindIndex(lines, 1, l => l.Trim() == "---");
    return end < 0 ? [] : lines[1..end].ToList();
  }
  private static string? Value(List<string> front, string key)
  {
    foreach (var line in front)
    {
      var colon = line.IndexOf(':');
      if (colon <= 0 || line[0] is ' ' or '\t' || line[..colon].Trim() != key) continue;
      var value = line[(colon + 1)..].Trim();
      if (value.Length >= 2 && (value[0] == '"' && value[^1] == '"' || value[0] == '\'' && value[^1] == '\'')) value = value[1..^1];
      return value.Length == 0 ? null : value;
    }
    return null;
  }

  /// A complete memory file (the Mac's DeckMemoryRemoval.text): an older build that places it indexes it as a note.
  public string Text(string id, string name)
  {
    var day = DateTimeOffset.FromUnixTimeMilliseconds(At).ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    var body = "# Removed: " + name + "\n\n" + (MovedTo is null ? "This was removed from your devices on " : "This moved to another place in memory on ") + day
      + ". Terminal Deck keeps the earlier text for 30 days; update Terminal Deck on this Mac to see it in the Bin.\n";
    var front = new List<string>();
    void Set(string key, string? value)
    {
      var clean = value?.Replace('\r', ' ').Replace('\n', ' ').Trim();
      if (!string.IsNullOrEmpty(clean)) front.Add(key + ": " + clean);
    }
    Set("id", id); Set("type", "removed"); Set("status", "removed"); Set("td_removed", At.ToString(CultureInfo.InvariantCulture)); Set("td_removed_by", By);
    Set("td_moved_to", MovedTo); Set("td_removed_by_ai", ByAi ? "1" : null);
    foreach (var (k, v) in Travel.OrderBy(t => t.Key, StringComparer.Ordinal)) Set(k, v);
    return "---\n" + string.Join("\n", front) + "\n---\n" + body;
  }
}

public sealed partial class CloudMemoryAdapter
{
  public const string BinKind = "memory";
  private const long GoneLook = 3_000;
  private CloudMemoryDeleteOptions del = null!;
  private CloudDeleteState marks = null!;
  private DeleteRequests requests = null!;

  private sealed class DeleteRequests
  {
    /// "Put in Cloud again" (an Only-on-this-PC file the person sends again on top of the removal).
    public HashSet<string> PutInCloud { get; set; } = [];
  }
  private void SaveRequests() => del.Requests.Write(JsonSerializer.SerializeToUtf8Bytes(requests));

  private void InitDelete(CloudMemoryDeleteOptions? options)
  {
    del = options ?? new CloudMemoryDeleteOptions(new CloudBin(Path.Combine(Path.GetTempPath(), "td-memory-bin-" + memory.StoreId)), new CloudMemorySlotInMemory(),
      new CloudMemorySlotInMemory(), Path.Combine(Path.GetTempPath(), "td-memory-retained-" + memory.StoreId));
    marks = new CloudDeleteState(del.State);
    requests = del.Requests.Read() is { } bytes ? JsonSerializer.Deserialize<DeleteRequests>(bytes) ?? new DeleteRequests() : new DeleteRequests();
  }

  /// The account's announcements (the delete-rule gate), set once by the composition after the memory store exists.
  public void UseAnnounce(CloudAnnounce announce) => del = del with { Announce = announce };
  /// The delete rule's local marks (for the page: "Not on this PC", "Only on this PC").
  public CloudDeleteState DeleteMarks => marks;
  public CloudBin Bin => del.Bin;
  private bool GateOpen() => del.Announce?.DeleteRuleIsOpen() == true;
  private string DeviceName(string device) =>
    device.Equals(deviceId, StringComparison.OrdinalIgnoreCase) ? del.ThisDeviceName : del.DeviceName?.Invoke(device.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice;
  private static string ItemKey(string path) => "memory:" + path;
  private static string BinDevice(string device, bool byAi) => byAi ? device + "#ai" : device;

  // ---- Bytes of every file version, by fingerprint (the Mac's versions folder): what a gone file last was ----

  private string RetainedPath(string hash) => Path.Combine(del.RetainedFolder, hash);
  private void Retain(byte[] bytes, string hash)
  {
    var path = RetainedPath(hash);
    if (!File.Exists(path)) new CloudFileSlot(path).Write(bytes);
  }
  private byte[]? Retained(string? hash)
  {
    if (hash is null || !CloudBin.IsSha(hash)) return null;
    var path = RetainedPath(hash);
    try { return File.Exists(path) && File.ReadAllBytes(path) is var b && CloudMemoryFormat.Hash(b) == hash ? b : null; } catch (IOException) { return null; }
  }

  // ---- Names ----

  private static string NameOf(string path)
  {
    var last = path.Split('/')[^1];
    return last.EndsWith(".md", StringComparison.OrdinalIgnoreCase) ? last[..^3] : last;
  }
  private static string? PlaceOf(string path)
  {
    var parts = path.Split('/');
    return parts.Length >= 3 && parts[0] == "projects" ? parts[1] : null;
  }
  public static CloudDeleteItem Item(string path) => new(path, BinKind, NameOf(path), PlaceOf(path));

  // ---- Heads ----

  private (string StoreId, string Key) KeyOf(string path)
  {
    var origin = state.FileOrigins.GetValueOrDefault(path);
    return (origin?.StoreId ?? memory.StoreId, origin?.Key ?? "file/" + path);
  }
  private bool IsRemoval(Version v) => state.RemovalHashes.Contains(v.Hash);
  /// The Cloud's newest complete version of a resource (the same answer on every device).
  private Version? Newest(string key, string? excluding = null)
  {
    Version? best = null;
    foreach (var v in VersionsOf(key).Where(v => v.Done && v.Id != excluding))
      best = best is null ? v : CloudMemoryRevision.Winner(Revision(best), Revision(v)).Version == best.Id ? best : v;
    return best;
  }
  private void Adopt(string path, Version v)
  {
    state.FileOrigins[path] = new Origin { StoreId = v.StoreId, Key = v.Key, Version = v.Id };
    state.Heads[v.StoreId + ":" + v.Key] = new Head { Hash = v.Hash, Version = v.Id, Parents = v.Parents.ToList(), Base = v.Id };
  }

  // ---- Capture side: gone files, marks, intents ----

  /// "Put in Cloud again": this PC's bytes become a new version on top of the removal (before the files are read).
  private void PutInCloudRequests()
  {
    foreach (var path in requests.PutInCloud.ToArray())
    {
      var (storeId, key) = KeyOf(path);
      if (memory.ReadFile(path) is not null && Newest(key) is { } newest)
      {
        state.Heads[storeId + ":" + key] = new Head { Hash = newest.Hash, Version = newest.Id, Parents = newest.Parents.ToList(), Base = newest.Id };
        state.FileOrigins[path] = new Origin { StoreId = newest.StoreId, Key = newest.Key, Version = newest.Id };
        state.FileStamps.Remove(path);
        marks.ClearMark(path);
      }
      requests.PutInCloud.Remove(path);
      SaveRequests();
    }
  }

  /// Runs inside capture, after the whole feed was read once. Returns the removal records to send now.
  private async Task<List<CloudOperation>> DeleteRulePassAsync(IReadOnlyList<DeckMemoryFileInfo> listed, Func<long> stampNow, CancellationToken ct)
  {
    var operations = new List<CloudOperation>();
    var here = listed.Select(f => f.Path).ToHashSet(StringComparer.Ordinal);
    var now = localNow();
    // Explicit deletes (page or tool): the intent was written before the file went.
    foreach (var place in marks.IntentPlaces())
    {
      ct.ThrowIfCancellationRequested();
      if (marks.Intent(place) is not { } intent) continue;
      operations.AddRange(JournalRemoval(place, intent, stampNow));
    }
    foreach (var path in here) { state.GoneAt.Remove(path); state.GoneSeen.Remove(path); }
    // Every place this PC captured or placed a file at.
    var known = state.FileStamps.Keys.Concat(state.FileOrigins.Keys).Distinct().Where(p => !here.Contains(p) && DeckMemoryCloudSchema.FileRow(p) is { } r && rows.Contains(r))
      .OrderBy(p => p, StringComparer.Ordinal).ToArray();
    // Rule 7: a whole memory folder missing at once is "not on this PC", never a delete by anyone.
    if (listed.Count == 0 && known.Length > 0) return operations;
    foreach (var path in known)
    {
      ct.ThrowIfCancellationRequested();
      var (storeId, key) = KeyOf(path);
      var head = state.Heads.GetValueOrDefault(storeId + ":" + key);
      if (marks.Mark(path) is not null || head is null || state.RemovalHashes.Contains(head.Hash)) { state.FileStamps.Remove(path); state.GoneAt.Remove(path); continue; }
      if (!state.GoneAt.TryGetValue(path, out var first) || now < first)
      {
        state.GoneAt[path] = now;
        // The last moment this PC saw it: its last full look (it was there, or it would have been noticed gone then).
        if (state.LastLook > 0 && state.LastLook <= now) state.GoneSeen[path] = state.LastLook; else state.GoneSeen.Remove(path);
        continue;
      }
      if (now - first < GoneLook) continue;
      var last = Math.Min(state.GoneSeen.GetValueOrDefault(path, first - GoneLook), first);
      CloudDeleteWitnessAnswer answer;
      if (last < del.RunStartedAt || del.FullPath?.Invoke(path) is not { } full) answer = CloudDeleteWitnessAnswer.CannotKnow;
      else answer = await (del.Witness ?? CloudDeleteWitnessSlot.Shared).WhoAsync(full, DateTimeOffset.FromUnixTimeMilliseconds(last), DateTimeOffset.FromUnixTimeMilliseconds(first));
      state.GoneAt.Remove(path); state.GoneSeen.Remove(path);
      if (answer.Kind == CloudDeleteWitnessAnswer.Kinds.Ai && answer.Group is { } group && CloudDeleteText.IsUuid(group) && Retained(head.Hash) is { } bytes)
      {
        var at = stampNow();
        var intent = new CloudDeleteIntent(path, CloudDeleteScope.Everywhere, CloudDeleteBy.Ai, deviceId, answer.Session, answer.Agent, at, group);
        BinPut(path, bytes, intent, CloudBinEra.Current, deviceId);
        operations.AddRange(JournalRemoval(path, intent, stampNow));
      }
      else marks.PutMark(new CloudDeleteMark(path, CloudLocalMark.NotOnThisPc, now));
      state.FileStamps.Remove(path);
    }
    state.LastLook = now;
    return operations;
  }

  private void BinPut(string path, byte[] bytes, CloudDeleteIntent intent, CloudBinEra era, string device)
  {
    var item = Item(path);
    var group = new CloudBinGroup(intent.Group, intent.By, DeviceName(intent.Mac), intent.Session, intent.Agent, intent.At, [item], era);
    del.Bin.Put(BinKind, ItemKey(path), item.Name, item.Place, path, intent.At, BinDevice(device, intent.By == CloudDeleteBy.Ai), bytes, shown: true, localNow(), group);
  }

  /// The removal as a new version of the resource whose bytes are a marker (cloudJournalRemoval). The intent is
  /// cleared when the capture commits.
  private IEnumerable<CloudOperation> JournalRemoval(string path, CloudDeleteIntent intent, Func<long> stampNow)
  {
    var (storeId, key) = KeyOf(path);
    var row = DeckMemoryCloudSchema.FileRow(key[5..]);
    var head = state.Heads.GetValueOrDefault(storeId + ":" + key);
    if (row is null || !rows.Contains(row) || head is null || state.RemovalHashes.Contains(head.Hash)) { clearedIntents.Add(path); return []; }
    var travel = new Dictionary<string, string>(StringComparer.Ordinal);
    if (GateOpen()) CloudDeleteTravel.Write(intent, travel);
    var removal = new CloudMemoryRemoval(intent.At, intent.Mac, null, intent.By == CloudDeleteBy.Ai, travel);
    var id = "n-" + DateTimeOffset.FromUnixTimeMilliseconds(intent.At).ToLocalTime().ToString("yyyyMMdd", CultureInfo.InvariantCulture) + "-" + intent.Group[..6];
    var data = Encoding.UTF8.GetBytes(removal.Text(id, NameOf(path)));
    var hash = CloudMemoryFormat.Hash(data);
    state.RemovalHashes.Add(hash);
    clearedIntents.Add(path);
    state.FileStamps.Remove(path);
    var operations = Export(new Resource(row, storeId, key, data, hash, state.FileOrigins.GetValueOrDefault(path)?.Version, null, path), stampNow).ToList();
    // The marker is this place's head now; it is never a placed file.
    if (state.Heads.GetValueOrDefault(storeId + ":" + key) is { } made && Find(key, made.Version) is { } version) version.Projection = "";
    return operations;
  }
  private readonly List<string> clearedIntents = [];
  private void CommitDeletePass()
  {
    foreach (var path in clearedIntents) marks.ClearIntent(path);
    clearedIntents.Clear();
  }

  /// A file present at a marked place. True = consumed (never captured); false = his new version, capture it.
  private bool Reappeared(string path, byte[] bytes, string hash)
  {
    if (marks.Mark(path) is not { } mark) return false;
    if (mark.Mark == CloudLocalMark.OnlyOnThisPc) return true;
    var (_, key) = KeyOf(path);
    if (Newest(key) is not { } newest) return true;
    var newestBytes = newest.Hash == hash ? bytes : Retained(newest.Hash);
    if (newestBytes is null) return true;
    if (hash == newest.Hash) { Adopt(path, newest); marks.ClearMark(path); return true; }
    if (VersionsOf(key).Any(v => v.Hash == hash) || state.KnownHashes.Contains(path + "\n" + hash))
    {
      marks.ClearMark(path);
      if (IsRemoval(newest)) ApplyRemovalTo(path, newest, CloudMemoryRemoval.Parse(newestBytes)!, bytes);
      else { memory.WriteFile(path, newestBytes); Adopt(path, newest); }
      return true;
    }
    // His own new text descends from what the Cloud has now; the Cloud's text is kept.
    if (!IsRemoval(newest)) keeper.Keep(path, newestBytes, newest.Device, localNow());
    Adopt(path, newest);
    marks.ClearMark(path);
    return false;
  }

  // ---- Apply side ----

  /// An arriving version at a marked place, or over a removal held here. Null = place it as usual.
  private bool? DeleteRuleArrival(Version v, string path, byte[] bytes, CloudMemoryRemoval? marker)
  {
    state.KnownHashes.Add(path + "\n" + v.Hash);
    if (marks.Mark(path) is { } mark)
    {
      if (mark.Mark == CloudLocalMark.OnlyOnThisPc && marker is null && Newest(v.Key, v.Id) is { } head && IsRemoval(head)
        && (v.Parents.Contains(head.Id) || Revision(v).Ancestors.Contains(head.Id)))
      {
        // "Put in Cloud again" on another device: this PC's differing text is kept, the Cloud's version placed.
        if (memory.ReadFile(path) is { } local && CloudMemoryFormat.Hash(local) != v.Hash) keeper.Keep(path, local, "this PC", localNow());
        marks.ClearMark(path);
        memory.WriteFile(path, bytes);
        Claim(path, v, onlyIfUnowned: false);
        return true;
      }
      // Decision 10: "Not on this PC" and the Cloud's newest is now an Everywhere removal: nothing is left to bring back.
      if (mark.Mark == CloudLocalMark.NotOnThisPc && marker is not null && Newest(v.Key)?.Id == v.Id && ScopeOf(marker, path) == CloudDeleteScope.Everywhere)
      {
        marks.ClearMark(path);
        Adopt(path, v);
        v.Projection = "";
        return true;
      }
      v.Projection = "";
      return true;
    }
    if (marker is not null) return null;
    // Not here because this PC holds a removal as the head: placed only when it is newer than the removal.
    if (memory.ReadFile(path) is null && state.Heads.GetValueOrDefault(KeyOf(path).StoreId + ":" + KeyOf(path).Key) is { } held
      && state.RemovalHashes.Contains(held.Hash) && held.Version != v.Id)
    {
      var removalWins = !v.Parents.Contains(held.Version) && Find(v.Key, held.Version) is { } removal && Revision(removal).Ancestors.Contains(v.Id);
      if (removalWins) { v.Projection = ""; return true; }
      del.Bin.Take(ItemKey(path), localNow());
    }
    return null;
  }
  private static CloudDeleteScope? ScopeOf(CloudMemoryRemoval marker, string path)
  {
    try { return CloudDeleteTravel.Read(marker.Travel, path, marker.By, marker.At).Intent?.Scope ?? CloudDeleteScope.Everywhere; }
    catch (CloudDeleteRuleException) { return null; }
  }

  /// An arrived removal marker for `path` (cloudApplyRemoval). Applied only over exactly the version it removed.
  private void ApplyRemoval(Version v, string path, CloudMemoryRemoval marker)
  {
    v.Projection = "";
    state.RemovalHashes.Add(v.Hash);
    if (marker.MovedTo is not null && (!DeckMemoryCloudSchema.SafePath(marker.MovedTo) || DeckMemoryCloudSchema.FileRow(marker.MovedTo) is null)) return;
    try { _ = CloudDeleteTravel.Read(marker.Travel, path, marker.By, marker.At); } catch (CloudDeleteRuleException) { return; }
    var local = memory.ReadFile(path);
    if (local is null) { Adopt(path, v); return; }
    var current = CloudMemoryFormat.Hash(local);
    var mine = LocalVersion(path, local, current);
    var ancestors = Revision(v).Ancestors;
    var wins = mine is not null && (marker.MovedTo is not null ? v.Parents.Contains(mine.Id) : v.Parents.Contains(mine.Id) || ancestors.Contains(mine.Id));
    if (!wins) return;
    ApplyRemovalTo(path, v, marker, local);
  }
  private void ApplyRemovalTo(string path, Version v, CloudMemoryRemoval marker, byte[] local)
  {
    var travel = CloudDeleteTravel.Read(marker.Travel, path, marker.By, marker.At);
    var era = travel.IsOlderVersion ? CloudBinEra.OlderVersion : CloudBinEra.Current;
    var day = DateTimeOffset.FromUnixTimeMilliseconds(marker.At).ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    var intent = travel.Intent ?? new CloudDeleteIntent(path, CloudDeleteScope.Everywhere, marker.ByAi ? CloudDeleteBy.Ai : CloudDeleteBy.Person, marker.By, null, null,
      marker.At, CloudMemoryFormat.Uuid("older-removal:" + marker.By + ":" + day));
    var device = marker.By.Length > 0 ? marker.By : v.Device;
    if (marker.MovedTo is null) BinPut(path, local, intent with { Mac = device }, era, device);
    else del.Bin.Put(BinKind, ItemKey(path), NameOf(path), PlaceOf(path), path, marker.At, BinDevice(device, intent.By == CloudDeleteBy.Ai), local, shown: true, localNow());
    Adopt(path, v);
    state.FileStamps.Remove(path);
    if (intent.Scope == CloudDeleteScope.Cloud) { marks.PutMark(new CloudDeleteMark(path, CloudLocalMark.OnlyOnThisPc, intent.At)); return; }
    memory.RemoveFile(path, CloudMemoryFormat.Hash(local));
  }

  // ---- The person's page and the AI tools (ICloudDeleteOwning) ----

  private readonly SemaphoreSlim turn = new(1, 1);

  public async Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
  {
    if (!CloudDeleteText.IsUuid(by.Group) || items.Count == 0 || items.Select(i => i.Id).Distinct().Count() != items.Count) throw new CloudFailure("invalid_request");
    if (scope == CloudDeleteScope.Cloud && !GateOpen()) throw new InvalidOperationException(CloudDeleteWords.CloudNeedsUpdatedDevices);
    await turn.WaitAsync();
    try
    {
      var removed = new List<CloudDeleteItem>();
      foreach (var item in items)
      {
        var path = item.Id;
        if (!DeckMemoryCloudSchema.SafePath(path) || DeckMemoryCloudSchema.FileRow(path) is not { } row || !rows.Contains(row)) continue;
        var (storeId, key) = KeyOf(path);
        var bytes = memory.ReadFile(path);
        if (bytes is null || CloudMemoryFormat.IsRemovalMarker(bytes)) continue;
        if (!state.Heads.ContainsKey(storeId + ":" + key) && scope == CloudDeleteScope.Cloud) continue;
        var intent = by.Intent(path, scope);
        // The intent and the Bin copy first; then the file (Everywhere) or the mark (Cloud).
        marks.PutIntent(intent);
        BinPut(path, bytes, intent, CloudBinEra.Current, by.Mac);
        Retain(bytes, CloudMemoryFormat.Hash(bytes));
        if (scope == CloudDeleteScope.Everywhere) memory.RemoveFile(path, CloudMemoryFormat.Hash(bytes));
        else marks.PutMark(new CloudDeleteMark(path, CloudLocalMark.OnlyOnThisPc, intent.At));
        removed.Add(Item(path));
      }
      if (removed.Count == 0) throw new CloudFailure("unavailable");
      return new CloudBinGroup(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, removed);
    }
    finally { turn.Release(); }
  }

  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    await turn.WaitAsync();
    try
    {
      var back = new List<CloudDeleteItem>();
      foreach (var item in items)
      {
        var path = item.Id;
        if (marks.Mark(path) is not { } mark) continue;
        if (to == CloudBringBackDestination.Cloud)
        {
          if (mark.Mark != CloudLocalMark.OnlyOnThisPc || memory.ReadFile(path) is null) continue;
          requests.PutInCloud.Add(path); SaveRequests();
        }
        else
        {
          if (mark.Mark != CloudLocalMark.NotOnThisPc || Newest(KeyOf(path).Key) is not { } newest || IsRemoval(newest) || Retained(newest.Hash) is not { } bytes) continue;
          // The capture finds the Cloud's newest bytes at the marked place and adopts them (J-7), nothing is sent.
          memory.WriteFile(path, bytes);
        }
        back.Add(item);
      }
      return back;
    }
    finally { turn.Release(); }
  }

  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() =>
    Task.FromResult<IReadOnlyList<CloudNotHereItem>>(marks.Marks().Select(m => new CloudNotHereItem(Item(m.Place), m.Mark, m.At)).ToArray());

  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() =>
    Task.FromResult(del.Bin.Groups(BinKind, b => Item(b.Path), d => del.DeviceName?.Invoke(d)));

  /// "Put back all": every item of the group back at its place (this PC's text there now is kept); the capture sends
  /// each as a new version on top of its removal, so it is back on every device.
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
  {
    var held = (await BinGroupsAsync()).FirstOrDefault(g => g.Id == group);
    if (held is null) return [];
    await turn.WaitAsync();
    try
    {
      var back = new List<CloudDeleteItem>();
      foreach (var item in held.Items)
      {
        var path = item.Id;
        if (del.Bin.Get(ItemKey(path)) is not { } binned || del.Bin.Content(binned.Kind, binned.Sha256) is not { } bytes) continue;
        if (marks.Mark(path) is { Mark: CloudLocalMark.OnlyOnThisPc })
        {
          requests.PutInCloud.Add(path); SaveRequests();
        }
        else
        {
          if (memory.ReadFile(path) is { } current && CloudMemoryFormat.Hash(current) != binned.Sha256) keeper.Keep(path, current, "this PC", localNow());
          memory.WriteFile(path, bytes);
          marks.ClearMark(path);
        }
        del.Bin.Take(ItemKey(path), localNow());
        back.Add(item);
      }
      return back;
    }
    finally { turn.Release(); }
  }

  public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    foreach (var item in items) del.Bin.DeleteForGood(ItemKey(item.Id));
    return Task.CompletedTask;
  }
}

/// A slot kept in memory (tests, and the default when no folder is given).
public sealed class CloudMemorySlotInMemory : ICloudLedgerSlot
{
  private byte[]? bytes;
  public byte[]? Read() => bytes?.ToArray();
  public void Write(byte[] value) => bytes = value.ToArray();
}
