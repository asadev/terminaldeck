using System.Globalization;

namespace TerminalDeck.Core.Cloud;

// AI instruction files under the 15 Nov delete rule on Windows, ported from the Mac (td-mac-next2
// BackendCloudBootFilesDeleteRule.swift; the about-records of BackendCloudFolderRules.swift). The same rule as memory:
// - A file this PC agreed with the Cloud, found gone at two looks 3 s apart: an AI the witness saw = Everywhere (an
//   `archive` record, with its about-record while every computer announced the rule); anyone else = "Not on this PC".
//   A project folder that is missing or empty at once is never anyone's delete.
// - An arriving removal applies over exactly the version this PC uses (an edit made on top wins), into the Bin first.
//   Its about-record (same verified signer, same place) says who and which scope; without one, a device that announced
//   the rule is read the safe way ("Cloud": the file stays, "Only on this PC") and an older build's is Everywhere.
// - The person's and an AI tool's "Cloud"/"Everywhere" go through ICloudDeleteOwning; the Bin is the page's only.

/// What the instruction-files adapter needs for the delete rule (safe defaults like memory's).
public sealed record CloudBootFilesDeleteOptions(CloudBin Bin, ICloudLedgerSlot State, CloudAnnounce? Announce = null, Func<string, string?>? DeviceName = null,
  string ThisDeviceName = CloudDeleteWords.ThisPc, CloudDeleteWitnessSlot? Witness = null, long RunStartedAt = 0);

public sealed partial class CloudBootFilesAdapter
{
  public const string BinKind = "boot";
  private const long GoneLook = 3_000;
  private CloudBootFilesDeleteOptions del = null!;
  private CloudDeleteState marks = null!;

  private void InitDelete(CloudBootFilesDeleteOptions? options)
  {
    del = options ?? new CloudBootFilesDeleteOptions(new CloudBin(Path.Combine(retained, "..", "bin")), new CloudMemorySlotInMemory());
    marks = new CloudDeleteState(del.State);
  }
  public CloudDeleteState DeleteMarks => marks;
  private bool GateOpen() => del.Announce?.DeleteRuleIsOpen() == true;
  private string DeviceName(string device) =>
    device.Equals(deviceId, StringComparison.OrdinalIgnoreCase) ? del.ThisDeviceName : del.DeviceName?.Invoke(device.ToLowerInvariant()) ?? CloudDeleteWords.AnotherDevice;
  /// The item a page shows: the file's name, the project as its place; `Id` routes (source id + relative path).
  public static CloudDeleteItem Item(string sourceId, string relative) =>
    new(Pk(sourceId, relative), BinKind, relative.Split('/')[^1], PlaceName(sourceId));
  private static (string SourceId, string Relative)? Route(string id)
  {
    var cut = id.IndexOf('\n');
    if (cut <= 0) return null;
    var (sourceId, relative) = (id[..cut], id[(cut + 1)..]);
    return CloudBootFilesFormat.ParseSourceId(sourceId) is { Kind: CloudBootFilesPlaceKind.Project } && CloudBootFilesFormat.Refusal(CloudBootFilesPlaceKind.Project, relative) is null
      ? (sourceId, relative) : null;
  }
  private string? ProjectOf(string sourceId) =>
    CloudBootFilesFormat.ParseSourceId(sourceId) is { } place ? Folders().Keys.FirstOrDefault(p => CloudBootFilesFormat.Token(p) == place.Token) : null;

  // ---- Sending a removal ----

  /// The `archive` record (the Mac's file engine) and, while the gate is open, its about-record first.
  private List<CloudOperation> RemovalRecords(string pk, PathState ps, CloudDeleteIntent intent, string sourceId, string relative, long createdAt)
  {
    var head = ps.Head!;
    List<string> parents = [head.Version];
    var version = CloudMemoryFormat.Uuid(head.StoreId + "\n" + head.Key + "\n" + string.Join(",", parents) + "\narchive\n" + createdAt.ToString(CultureInfo.InvariantCulture));
    var payload = CloudJson.Obj(("format", CloudJson.From(CloudBootFilesFormat.ArchiveFormat)), ("storeId", CloudJson.From(head.StoreId)),
      ("inventoryRow", CloudJson.From(CloudBootFilesFormat.InventoryRow)), ("key", CloudJson.From(head.Key)), ("version", CloudJson.From(version)),
      ("resourceHash", CloudJson.From(head.Hash)), ("parents", CloudJson.Arr(parents.Select(p => CloudJson.From(p)))));
    var opId = CloudMemoryFormat.OperationId(version + "\narchive");
    var archive = new CloudOperation(1, opId, deviceId, CloudBootFilesFormat.Domain, CloudMemoryFormat.Uuid(head.StoreId + "\n" + head.Key + "\narchive"), opId,
      parents.Select(p => CloudMemoryFormat.OperationId(p + "\narchive")).ToArray(), "archive", ProjectOf(sourceId), CloudBootFilesFormat.ProjectRoot,
      new CloudSourceReference("files/" + CloudBootFilesFormat.InventoryRow + "/" + sourceId, head.Key, null, head.Hash), createdAt, payload, CloudOperation.PayloadHashOf(payload));
    var records = new List<CloudOperation>();
    if (GateOpen()) records.Add(CloudFileDeleteRecords.Operation(archive, intent));
    records.Add(archive);
    foreach (var r in records) state.Applied.Add(r.OpId);
    state.Known[pk + "\n" + version] = new Known { Hash = head.Hash, Parents = parents };
    ps.Head = new Head { Version = version, StoreId = head.StoreId, Key = head.Key, Hash = "", Parents = parents, CreatedAt = createdAt, Device = deviceId, Removal = true };
    ps.Base = null; ps.Stamp = null; ps.NextParents = null;
    return records;
  }

  private void BinPut(string pk, string sourceId, string relative, byte[] bytes, CloudDeleteIntent intent, CloudBinEra era, string device)
  {
    var item = Item(sourceId, relative);
    var group = new CloudBinGroup(intent.Group, intent.By, DeviceName(intent.Mac), intent.Session, intent.Agent, intent.At, [item], era);
    del.Bin.Put(BinKind, pk, item.Name, item.Place, pk, intent.At, device, bytes, shown: true, localNow(), group);
  }

  // ---- Capture side ----

  /// One place's look: explicit deletes, marked files, files gone by hand or by an AI. Returns records to send.
  private async Task<List<CloudOperation>> DeleteRulePassAsync(string sourceId, string root, CloudBootFilesDisk.Walk walk, Func<long> stampNow, CancellationToken ct)
  {
    var operations = new List<CloudOperation>();
    var here = walk.Files.Select(f => Pk(sourceId, f.Relative)).ToHashSet(StringComparer.Ordinal);
    var now = localNow();
    foreach (var pk in here) { state.GoneAt.Remove(pk); state.GoneSeen.Remove(pk); }
    var known = state.Paths.Where(p => p.Key.StartsWith(sourceId + "\n", StringComparison.Ordinal) && !here.Contains(p.Key) && p.Value.Base is not null
      && p.Value.Head is { Removal: false }).Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal).ToArray();
    // Rule 7: a project folder missing, unreadable or empty at once is "not on this PC", never a delete by anyone.
    if (walk.Gaps.ContainsKey("unreachable") || walk.Gaps.ContainsKey("unreadable") || walk.Files.Count == 0 && known.Length > 0) return operations;
    foreach (var pk in known)
    {
      ct.ThrowIfCancellationRequested();
      var ps = state.Paths[pk];
      var relative = pk[(sourceId.Length + 1)..];
      if (marks.Mark(pk) is not null) continue;
      if (!state.GoneAt.TryGetValue(pk, out var first) || now < first)
      {
        state.GoneAt[pk] = now;
        if (state.LastLook > 0 && state.LastLook <= now) state.GoneSeen[pk] = state.LastLook; else state.GoneSeen.Remove(pk);
        continue;
      }
      if (now - first < GoneLook) continue;
      var last = Math.Min(state.GoneSeen.GetValueOrDefault(pk, first - GoneLook), first);
      state.GoneAt.Remove(pk); state.GoneSeen.Remove(pk);
      var answer = last < del.RunStartedAt ? CloudDeleteWitnessAnswer.CannotKnow
        : await (del.Witness ?? CloudDeleteWitnessSlot.Shared).WhoAsync(Path.Combine(new[] { root }.Concat(relative.Split('/')).ToArray()),
          DateTimeOffset.FromUnixTimeMilliseconds(last), DateTimeOffset.FromUnixTimeMilliseconds(first));
      if (answer.Kind == CloudDeleteWitnessAnswer.Kinds.Ai && answer.Group is { } group && CloudDeleteText.IsUuid(group) && Retained(ps.Head!.Hash) is { } bytes)
      {
        var at = stampNow();
        var intent = new CloudDeleteIntent(pk, CloudDeleteScope.Everywhere, CloudDeleteBy.Ai, deviceId, answer.Session, answer.Agent, at, group);
        BinPut(pk, sourceId, relative, bytes, intent, CloudBinEra.Current, deviceId);
        operations.AddRange(RemovalRecords(pk, ps, intent, sourceId, relative, at));
      }
      else marks.PutMark(new CloudDeleteMark(pk, CloudLocalMark.NotOnThisPc, now));
    }
    return operations;
  }

  /// A file present at a marked place. True = consumed (never captured).
  private bool Reappeared(string pk, string root, string relative, byte[] bytes, string hash)
  {
    if (marks.Mark(pk) is not { } mark) return false;
    if (mark.Mark == CloudLocalMark.OnlyOnThisPc) return true;
    var ps = PathOf(pk);
    if (ps.Head is not { } head) { marks.ClearMark(pk); return false; }
    if (!head.Removal && hash == head.Hash) { ps.Base = hash; marks.ClearMark(pk); return true; }
    if (state.Known.Any(k => k.Key.StartsWith(pk + "\n", StringComparison.Ordinal) && k.Value.Hash == hash))
    {
      marks.ClearMark(pk);
      try
      {
        if (head.Removal) CloudBootFilesDisk.Remove(root, relative, hash);
        else if (Retained(head.Hash) is { } newest) { CloudBootFilesDisk.Replace(root, relative, newest, hash); ps.Base = head.Hash; }
      }
      catch (CloudBootFilesDisk.Stop) { }
      ps.Stamp = null;
      return true;
    }
    // His own new text: on top of the newest the Cloud has; the Cloud's text is kept.
    if (!head.Removal && Retained(head.Hash) is { } cloud) keeper.Keep(PlaceName(pk[..pk.IndexOf('\n')]) + "/" + relative, cloud, head.Device, localNow());
    ps.Base = head.Removal ? "new-after-removal" : head.Hash;
    marks.ClearMark(pk);
    return false;
  }

  /// Explicit deletes waiting for their records (the intent was written before the file went).
  private List<CloudOperation> Intents(Func<long> stampNow)
  {
    var operations = new List<CloudOperation>();
    foreach (var pk in marks.IntentPlaces())
    {
      if (marks.Intent(pk) is not { } intent || Route(pk) is not { } route) { marks.ClearIntent(pk); continue; }
      var ps = PathOf(pk);
      if (ps.Head is { Removal: false }) operations.AddRange(RemovalRecords(pk, ps, intent, route.SourceId, route.Relative, intent.At));
      sentIntents.Add(pk);
    }
    return operations;
  }
  private readonly List<string> sentIntents = [];
  private void CommitDeletePass() { foreach (var pk in sentIntents) marks.ClearIntent(pk); sentIntents.Clear(); }

  // ---- Apply side ----

  /// An about-record: kept with its VERIFIED signer before the removal it speaks for is read; a bad one is refused.
  private void TakeAbout(CloudOperation op, CloudImportOrigin origin)
  {
    var about = CloudFileDeleteRecords.Read(op);
    if (about is null || !string.Equals(about.Mac, origin.DeviceId, StringComparison.OrdinalIgnoreCase)
      || state.Abouts.TryGetValue(about.Operation, out var held) && held != Encode(about))
    { state.RefusedAbouts.Add(op.OpId); return; }
    state.Abouts[about.Operation] = Encode(about);
  }
  private static string Encode(CloudFileDeleteRecords.About about) => System.Text.Encoding.UTF8.GetString(CloudCanonical.Encode(about.ToJson()));
  private static CloudFileDeleteRecords.About? Decode(string? text)
  {
    if (text is null) return null;
    try { return CloudFileDeleteRecords.About.FromJson(CloudJson.Parse(text)); } catch (Exception e) when (e is CloudFailure or CloudDeleteRuleException) { return null; }
  }

  /// An arriving `archive`: applied over exactly the version this PC uses, into the Bin first.
  private void ApplyRemoval(CloudBootFilesIncoming item, CloudImportOrigin origin)
  {
    var pk = Pk(item.SourceId, item.Relative);
    state.Known[pk + "\n" + item.Version] = new Known { Hash = item.Hash, Parents = item.Parents.ToList() };
    var about = Decode(state.Abouts.GetValueOrDefault(item.Operation.OpId));
    var refused = state.RefusedAbouts.Contains(CloudFileDeleteRecords.AboutId(item.Operation.OpId));
    var travel = CloudFileDeleteRecords.ArrivedRemoval(item.Operation, pk, origin.DeviceId, del.Announce?.DeleteRuleAnnounced(origin.DeviceId) ?? true, about, refused);
    state.PendingRemovals[pk] = new PendingRemoval
    {
      Version = item.Version, Parents = item.Parents.ToList(), At = item.Operation.CreatedAt, Mac = origin.DeviceId.ToLowerInvariant(), StoreId = item.StoreId, Key = item.Key,
      Fields = travel.Intent is { } i ? Fields(i) : [], Safe = travel.Intent is not null && about is null
    };
    RetryRemoval(pk);
  }
  private static Dictionary<string, string> Fields(CloudDeleteIntent intent) { var f = new Dictionary<string, string>(); CloudDeleteTravel.Write(intent, f); return f; }

  /// A removal that waits for its project's folder is tried again whenever the places are looked at.
  private void RetryRemovals() { foreach (var pk in state.PendingRemovals.Keys.ToArray()) RetryRemoval(pk); }
  private void RetryRemoval(string pk)
  {
    dirty = true;
    var r = state.PendingRemovals[pk];
    var cut = pk.IndexOf('\n');
    var (sourceId, relative) = (pk[..cut], pk[(cut + 1)..]);
    var ps = PathOf(pk);
    // Never in use on this PC, or an edit was made on top of the removed version: nothing to remove here.
    if (ps.Head is not { Removal: false } current || !r.Parents.Contains(current.Version)) { state.PendingRemovals.Remove(pk); return; }
    if (FolderOf(sourceId, out _) is not { } root) return;
    CloudDeleteTravelRemoval travel;
    try { travel = CloudDeleteTravel.Read(r.Fields, pk, r.Mac, r.At); } catch (CloudDeleteRuleException) { state.PendingRemovals.Remove(pk); return; }
    var cloudOnly = travel.Intent?.Scope == CloudDeleteScope.Cloud;
    var local = CloudBootFilesDisk.Read(root, relative);
    if (local.Blocked is not null) return;
    if (!cloudOnly && local.Bytes is { } held && CloudMemoryFormat.Hash(held) != current.Hash) { state.PendingRemovals.Remove(pk); return; }
    if (Retained(current.Hash) is not { } bytes) return;
    var era = travel.IsOlderVersion ? CloudBinEra.OlderVersion : CloudBinEra.Current;
    var intent = travel.Intent ?? new CloudDeleteIntent(pk, CloudDeleteScope.Everywhere, CloudDeleteBy.Person, r.Mac, null, null, r.At, CloudFileDeleteRecords.LegacyGroupId(r.Mac, r.At, era));
    BinPut(pk, sourceId, relative, bytes, intent, era, r.Mac);
    if (cloudOnly)
    {
      if (local.Bytes is not null) marks.PutMark(new CloudDeleteMark(pk, CloudLocalMark.OnlyOnThisPc, r.At)); else marks.ClearMark(pk);
    }
    else
    {
      if (local.Bytes is not null)
        try { CloudBootFilesDisk.Remove(root, relative, current.Hash); } catch (CloudBootFilesDisk.Stop) { return; }
      marks.ClearMark(pk);
    }
    ps.Head = new Head { Version = r.Version, StoreId = r.StoreId, Key = r.Key, Hash = "", Parents = r.Parents, CreatedAt = r.At, Device = r.Mac, Removal = true };
    ps.Base = null; ps.Stamp = null; ps.NextParents = null;
    state.PendingRemovals.Remove(pk);
  }

  /// An arriving version at a marked place, or after a removal. True = decided here (nothing more to do).
  private bool MarkedArrival(Arrived a, string root, byte[] body)
  {
    var pk = Pk(a.SourceId, a.Relative);
    var ps = PathOf(pk);
    if (marks.Mark(pk) is not { } mark)
    {
      // Newer than a removal this PC holds: back in use, out of the Bin.
      if (ps.Head is { Removal: true } removal && (a.Parents.Contains(removal.Version) || IsAncestor(pk, removal.Version, a.Version))) del.Bin.Take(pk, localNow());
      return false;
    }
    if (mark.Mark == CloudLocalMark.OnlyOnThisPc && ps.Head is { Removal: true } held && (a.Parents.Contains(held.Version) || IsAncestor(pk, held.Version, a.Version)))
    {
      // "Put in Cloud again" on another device: this PC's differing text is kept, the Cloud's version placed.
      var local = CloudBootFilesDisk.Read(root, a.Relative);
      if (local.Bytes is { } mine && CloudMemoryFormat.Hash(mine) != a.Hash) keeper.Keep(PlaceName(a.SourceId) + "/" + a.Relative, mine, "this PC", localNow());
      marks.ClearMark(pk);
      try
      {
        if (local.Bytes is { } b) CloudBootFilesDisk.Replace(root, a.Relative, body, CloudMemoryFormat.Hash(b));
        else CloudBootFilesDisk.Create(root, a.Relative, body);
      }
      catch (CloudBootFilesDisk.Stop stop) { a.Waiting = "blocked:" + stop.Reason; return true; }
      Agree(ps, a);
      return true;
    }
    // Not on this PC / Only on this PC: nothing is placed; the newest the Cloud holds is remembered for "Bring back".
    if (ps.Head is null || a.Parents.Contains(ps.Head.Version) || IsAncestor(pk, ps.Head.Version, a.Version)) ps.Head = HeadOf(a);
    Settle(a);
    return true;
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
      foldersNow = null;
      var removed = new List<CloudDeleteItem>();
      foreach (var item in items)
      {
        if (Route(item.Id) is not { } route || FolderOf(route.SourceId, out _) is not { } root) continue;
        var ps = PathOf(item.Id);
        if (ps.Head is not { Removal: false } || CloudBootFilesDisk.Read(root, route.Relative).Bytes is not { } bytes) continue;
        var intent = by.Intent(item.Id, scope);
        marks.PutIntent(intent);
        BinPut(item.Id, route.SourceId, route.Relative, bytes, intent, CloudBinEra.Current, by.Mac);
        Retain(CloudMemoryFormat.Hash(bytes), bytes);
        if (scope == CloudDeleteScope.Everywhere)
          try { CloudBootFilesDisk.Remove(root, route.Relative, CloudMemoryFormat.Hash(bytes)); }
          catch (CloudBootFilesDisk.Stop) { marks.ClearIntent(item.Id); del.Bin.Take(item.Id, localNow()); continue; }
        else marks.PutMark(new CloudDeleteMark(item.Id, CloudLocalMark.OnlyOnThisPc, intent.At));
        // The version removed is the one on disk now, even an edit not sent yet.
        if (ps.Head.Hash != CloudMemoryFormat.Hash(bytes)) ps.Head.Hash = CloudMemoryFormat.Hash(bytes);
        removed.Add(Item(route.SourceId, route.Relative));
      }
      if (removed.Count == 0) throw new CloudFailure("unavailable");
      Save();
      return new CloudBinGroup(by.Group, by.By, by.MacName, by.Session, by.Agent, by.At, removed);
    }
    finally { turn.Release(); }
  }

  public async Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
  {
    await turn.WaitAsync();
    try
    {
      foldersNow = null;
      var back = new List<CloudDeleteItem>();
      foreach (var item in items)
      {
        if (Route(item.Id) is not { } route || marks.Mark(item.Id) is not { } mark || FolderOf(route.SourceId, out _) is not { } root) continue;
        var ps = PathOf(item.Id);
        if (to == CloudBringBackDestination.Cloud)
        {
          if (mark.Mark != CloudLocalMark.OnlyOnThisPc || CloudBootFilesDisk.Read(root, route.Relative).Bytes is not { } bytes) continue;
          // Captured on top of the removal by the next look.
          _ = bytes;
          ps.Base = "put-in-cloud"; ps.Stamp = null;
        }
        else
        {
          if (mark.Mark != CloudLocalMark.NotOnThisPc || ps.Head is not { Removal: false } head || Retained(head.Hash) is not { } bytes) continue;
          try { CloudBootFilesDisk.Create(root, route.Relative, bytes); } catch (CloudBootFilesDisk.Stop) { continue; }
          ps.Base = head.Hash; ps.Stamp = null;
        }
        marks.ClearMark(item.Id);
        back.Add(item);
      }
      Save();
      return back;
    }
    finally { turn.Release(); }
  }

  public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() =>
    Task.FromResult<IReadOnlyList<CloudNotHereItem>>(marks.Marks().Where(m => Route(m.Place) is not null)
      .Select(m => { var r = Route(m.Place)!.Value; return new CloudNotHereItem(Item(r.SourceId, r.Relative), m.Mark, m.At); }).ToArray());

  public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() =>
    Task.FromResult(del.Bin.Groups(BinKind, b => Route(b.Path) is { } r ? Item(r.SourceId, r.Relative) : null, d => del.DeviceName?.Invoke(d)));

  /// "Put back all": each item back in its project's folder (the text there now is kept); sent on top of its removal.
  public async Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
  {
    var held = (await BinGroupsAsync()).FirstOrDefault(g => g.Id == group);
    if (held is null) return [];
    await turn.WaitAsync();
    try
    {
      foldersNow = null;
      var back = new List<CloudDeleteItem>();
      foreach (var item in held.Items)
      {
        if (Route(item.Id) is not { } route || FolderOf(route.SourceId, out _) is not { } root) continue;
        if (del.Bin.Get(item.Id) is not { } binned || del.Bin.Content(binned.Kind, binned.Sha256) is not { } bytes) continue;
        var local = CloudBootFilesDisk.Read(root, route.Relative);
        try
        {
          if (local.Bytes is { } current)
          {
            if (CloudMemoryFormat.Hash(current) != binned.Sha256)
            {
              keeper.Keep(PlaceName(route.SourceId) + "/" + route.Relative, current, "this PC", localNow());
              CloudBootFilesDisk.Replace(root, route.Relative, bytes, CloudMemoryFormat.Hash(current));
            }
          }
          else CloudBootFilesDisk.Create(root, route.Relative, bytes);
        }
        catch (CloudBootFilesDisk.Stop) { continue; }
        var ps = PathOf(item.Id);
        ps.Base = "put-back"; ps.Stamp = null;
        marks.ClearMark(item.Id);
        del.Bin.Take(item.Id, localNow());
        back.Add(item);
      }
      Save();
      return back;
    }
    finally { turn.Release(); }
  }

  public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items)
  {
    foreach (var item in items) del.Bin.DeleteForGood(item.Id);
    return Task.CompletedTask;
  }
}
