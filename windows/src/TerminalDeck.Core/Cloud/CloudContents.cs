namespace TerminalDeck.Core.Cloud;

// Lane U1 (15 Nov), the Mac's BackendCloudContents.swift + BackendCloudFiles.swift: "what is in your Cloud", as rows.
// One row per thing, by name and date; a row's "On" is empty in its normal state and says only "Not on this PC" or
// "Only on this PC". The Bin is one line per removal, with the device's NAME. The screens (lane U2) draw exactly this:
// no id, path, key or fingerprint ever reaches a row's visible text (`Id` and `Folder` route; `Name`, dates and the
// words in `CloudContentsWords` are what is shown).
//
// Every kind comes from ONE small provider (`ICloudContentsSource`). A kind with no provider has no place and no rows,
// so a kind joined later (saved passwords, project secret files, records v2) is registered, never rewritten in.

/// The places, in the order the page lists them (DESIGN-WINDOWS-CLOUD.md 2). "Code" is drawn by the screens only (it
/// opens the GitHub page); it has no rows here.
public enum CloudContentsKind { Memory, Projects, Agents, InstructionFiles, Tasks, Settings, Artifacts, CloudFolder, Sessions, Passwords }

/// A row's one state. `InSync` is the normal state: its "On" column is EMPTY.
public enum CloudItemState { InSync, NotOnThisPc, OnlyOnThisPc }

/// One place on the left: its title and how many items it holds. `CanBin*` say which bin actions the top bar offers for
/// rows of this place (none for a kind whose delete rule is not open, none for tasks' and agents' "Cloud").
public sealed record CloudContentsPlace(CloudContentsKind Kind, string Title, int Count, bool CanBinCloud, bool CanBinEverywhere);

/// One thing in his Cloud. `Id` routes (never shown). `Folder` is the folders it sits in inside its kind, by name
/// (empty = top of its kind). `Detail` is the secondary text after the name or at the right (a task's state, a
/// setting's value); nil for every other kind.
public sealed record CloudContentsRow(string Id, CloudContentsKind Kind, string Name, IReadOnlyList<string> Folder, long ChangedAt, string? ChangedBy,
  long? Bytes, CloudItemState State, string? Detail = null, bool CanOpen = true, bool IsSecret = false)
{
  /// The "On" column: empty for an item in its normal state.
  public string OnText => CloudContentsWords.On(State);
}

/// One folder inside a kind ("Deck Dev", "Lead"), with how many things it holds below it.
public sealed record CloudContentsFolderRow(CloudContentsKind Kind, IReadOnlyList<string> Path, string Name, int Items);

/// What one folder of a kind lists: folders first, then items.
public sealed record CloudContentsListing(IReadOnlyList<CloudContentsFolderRow> Folders, IReadOnlyList<CloudContentsRow> Items);

/// One read of his Cloud: the places (only kinds with a provider) and every row of them.
public sealed record CloudContentsSnapshot(IReadOnlyList<CloudContentsPlace> Places, IReadOnlyList<CloudContentsRow> Rows, int BinCount)
{
  /// What one folder of a kind lists, filtered by the search words (name or folder).
  public CloudContentsListing List(CloudContentsKind kind, IReadOnlyList<string> folder, string search = "") => CloudContents.Listing(Rows, kind, folder, search);
}

/// One line of the Bin: one removal (a group, across kinds when one press removed several). `Id` routes; `What` is the
/// name or "12 notes in Deck Dev"; `Device` is the device's NAME.
public sealed record CloudBinLine(string Id, IReadOnlyList<CloudContentsKind> Kinds, string What, long At, string Device, bool ByAi, int Count,
  CloudBinEra Era = CloudBinEra.Current)
{
  /// "Removed on MacBook Pro", "Removed by an AI on MacBook Pro", "Removed on MacBook Pro (older version)", "Before the new rule".
  public string Title => Era switch
  {
    CloudBinEra.BeforeNewRule => CloudDeleteWords.BeforeNewRule,
    CloudBinEra.OlderVersion => CloudDeleteWords.RemovedOlderVersion(Device),
    _ => ByAi ? CloudDeleteWords.RemovedByAi(Device) : CloudDeleteWords.Removed(Device)
  };
}

/// An opened item for the reading pane. A saved password or secret file carries its name and date only, never a value.
public sealed record CloudOpenedItem(string Name, long ChangedAt, string? Text, byte[]? Bytes, string? MediaType, string? WhereLine, bool IsSecret = false);

/// What an action did: how many rows it did and, when it could not do all of them, one plain line to show.
public sealed record CloudContentsResult(int Done, string? Line = null);

/// One kind's provider. Rows are read from the kind's owner; removals go through its `ICloudDeleteOwning` (null = the
/// kind offers no bin action, no bring back and no Bin lines).
public interface ICloudContentsSource
{
  CloudContentsKind Kind { get; }
  Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel);
  Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel);
  ICloudDeleteOwning? Removals { get; }
  /// Tasks and agents are always removed everywhere: no "Cloud" bin for them.
  bool OffersCloudOnly => true;
  CloudDeleteItem DeleteItem(CloudContentsRow row);
}

public static class CloudContentsWords
{
  public const string OpenButton = "Manage files", WindowTitle = "Your Cloud", Bin = "Bin", Open = "Open", NothingYet = "Nothing of this kind is in your Cloud yet.",
    SignedOut = "Sign in to see what is in your Cloud.", BinEmpty = "The Bin is empty.", BinEmptiesAfter = "Items in the Bin are deleted for good after 30 days.";
  public static string On(CloudItemState state) => state switch
  {
    CloudItemState.NotOnThisPc => CloudDeleteWords.NotOnThisPc,
    CloudItemState.OnlyOnThisPc => CloudDeleteWords.OnlyOnThisPc,
    _ => ""
  };
  public static string Title(CloudContentsKind kind) => kind switch
  {
    CloudContentsKind.Memory => "Memory",
    CloudContentsKind.Projects => "Projects",
    CloudContentsKind.Agents => "Agents",
    CloudContentsKind.InstructionFiles => "Instruction files",
    CloudContentsKind.Tasks => "Tasks",
    CloudContentsKind.Settings => "Settings",
    CloudContentsKind.Artifacts => "Artifacts",
    CloudContentsKind.CloudFolder => "Cloud folder",
    CloudContentsKind.Sessions => "Sessions and chats",
    _ => "Saved passwords"
  };
  public static string Items(int count) => count == 1 ? "1 item" : count + " items";
  /// The thing a kind holds, for a Bin line ("12 notes").
  public static string Noun(CloudContentsKind kind, int count)
  {
    var (one, many) = kind switch
    {
      CloudContentsKind.Memory => ("note", "notes"),
      CloudContentsKind.Projects => ("project", "projects"),
      CloudContentsKind.Agents => ("agent", "agents"),
      CloudContentsKind.InstructionFiles => ("instruction file", "instruction files"),
      CloudContentsKind.Tasks => ("task", "tasks"),
      CloudContentsKind.Settings => ("setting", "settings"),
      CloudContentsKind.Artifacts => ("artifact", "artifacts"),
      CloudContentsKind.CloudFolder => ("file", "files"),
      CloudContentsKind.Sessions => ("chat", "chats"),
      _ => ("saved password", "saved passwords")
    };
    return count == 1 ? one : many;
  }
}


/// The contents reader and its actions. The page's actions belong to the person ONLY (never an AI tool).
/// The Mac's BackendCloudContents builder + BackendCloudDeletePage (scopes, marks, Bin merge) on Windows: rows come from
/// each kind's provider, the delete rule's marks give "Not on this PC" / "Only on this PC", an item in the Bin is not a
/// row, and a mark whose item is gone from the list still gets its named row so "Bring back" stays reachable.
public sealed class CloudContents
{
  private readonly Func<bool> deleteRuleOpen;
  private readonly Func<CloudDeleteActor> person;
  private readonly object gate = new();
  private readonly Dictionary<CloudContentsKind, ICloudContentsSource> sources = [];
  /// The Bin as last read: each line's groups, by the provider that owns them.
  private Dictionary<string, List<(ICloudContentsSource Source, CloudBinGroup Group)>> binParts = new(StringComparer.Ordinal);
  /// Which provider a marked row (an item no longer listed) belongs to, and its delete item.
  private Dictionary<string, (ICloudContentsSource Source, CloudDeleteItem Item)> markedRows = new(StringComparer.Ordinal);

  /// The folder a removal's items share, by NAME (memory: the project a note sat in): "12 notes in Website". A place
  /// with no name here is never shown (a place is a route, never words).
  public Func<string, string?>? PlaceNames { get; set; }

  /// One plain line per provider that could not be read (fixed words and the kind's title only; never a name or a path).
  public Action<string>? Log { get; set; }
  // Retained manager views and confirmation callbacks recheck the live offer.
  // Default true preserves callers against old services and paywall-off.
  public Func<bool> AccessAllowed { get; set; } = static () => true;
  private CloudContentsResult AccessRefused => new(0, CloudSubscriptionPageText.Subscribe);

  public CloudContents(Func<bool> deleteRuleOpen, Func<CloudDeleteActor> person)
  {
    this.deleteRuleOpen = deleteRuleOpen;
    this.person = person;
  }

  /// Adds (or replaces) the provider of one kind.
  public void Register(ICloudContentsSource source) { lock (gate) sources[source.Kind] = source; }

  /// The provider of one kind, or null (the shelf reads texts and files through it).
  public ICloudContentsSource? Source(CloudContentsKind kind) { lock (gate) return sources.GetValueOrDefault(kind); }

  public IReadOnlyList<ICloudContentsSource> Sources() { lock (gate) return sources.OrderBy(s => s.Key).Select(s => s.Value).ToArray(); }

  private static string Key(CloudDeleteItem item) => item.Kind + "|" + item.Id;

  /// The bin buttons a place offers (BackendCloudDeletePage.scopes): none without an owner that can delete now; saved
  /// passwords none while the delete rule is closed; "Cloud" only while it is open and never for tasks, agents or chats.
  public static (bool Cloud, bool Everywhere) Scopes(CloudContentsKind kind, bool offersCloudOnly, bool gateOpen, bool canDelete)
  {
    if (!canDelete) return (false, false);
    if (!gateOpen && kind == CloudContentsKind.Passwords) return (false, false);
    var cloud = gateOpen && offersCloudOnly && kind is not (CloudContentsKind.Tasks or CloudContentsKind.Agents or CloudContentsKind.Sessions);
    return (cloud, true);
  }

  /// Every place with a provider and every row of them. One failing provider leaves its place empty; the rest list.
  public async Task<CloudContentsSnapshot> ReadAsync(CancellationToken cancel = default)
  {
    var open = SafeGate();
    var places = new List<CloudContentsPlace>();
    var rows = new List<CloudContentsRow>();
    var marked = new Dictionary<string, (ICloudContentsSource, CloudDeleteItem)>(StringComparer.Ordinal);
    var groups = new List<(ICloudContentsSource Source, CloudBinGroup Group)>();
    foreach (var source in Sources())
    {
      cancel.ThrowIfCancellationRequested();
      IReadOnlyList<CloudContentsRow> listed;
      try { listed = await source.RowsAsync(cancel); }
      catch (OperationCanceledException) { throw; }
      catch (Exception e) { Say(source.Kind, "could not be listed", e); listed = []; }
      IReadOnlyList<CloudNotHereItem> marks = [];
      IReadOnlyList<CloudBinGroup> binned = [];
      var canDelete = false;
      if (source.Removals is { } removals)
      {
        try { marks = await removals.NotHereAsync(); } catch (Exception e) { Say(source.Kind, "marks could not be read", e); }
        try { binned = await removals.BinGroupsAsync(); } catch (Exception e) { Say(source.Kind, "Bin could not be read", e); }
        try { canDelete = await removals.CanDeleteEverywhereAsync(); } catch (Exception e) { Say(source.Kind, "could not say whether it can delete", e); }
      }
      foreach (var g in binned) groups.Add((source, g));
      var made = Apply(source, listed, marks, binned, marked);
      rows.AddRange(made);
      var (cloud, everywhere) = Scopes(source.Kind, source.OffersCloudOnly, open, canDelete && source.Removals is not null);
      places.Add(new CloudContentsPlace(source.Kind, CloudContentsWords.Title(source.Kind), made.Count, cloud, everywhere));
    }
    var lines = Lines(groups, PlaceNames, out var parts);
    lock (gate) { binParts = parts; markedRows = marked; }
    return new CloudContentsSnapshot(places, rows, lines.Count);
  }

  /// BackendCloudDeletePage.applying: a marked row carries its mark; a binned row is not listed; a mark without its row
  /// gets a named row ("This PC", the time of the mark).
  private static List<CloudContentsRow> Apply(ICloudContentsSource source, IReadOnlyList<CloudContentsRow> listed, IReadOnlyList<CloudNotHereItem> marks,
    IReadOnlyList<CloudBinGroup> groups, Dictionary<string, (ICloudContentsSource, CloudDeleteItem)> marked)
  {
    var byKey = new Dictionary<string, CloudNotHereItem>(StringComparer.Ordinal);
    foreach (var m in marks) byKey[Key(m.Item)] = m;
    var binned = groups.SelectMany(g => g.Items).Select(Key).ToHashSet(StringComparer.Ordinal);
    var found = new HashSet<string>(StringComparer.Ordinal);
    var made = new List<CloudContentsRow>();
    var ids = new HashSet<string>(StringComparer.Ordinal);
    foreach (var row in listed)
    {
      if (row.Kind != source.Kind || !ids.Add(row.Id)) continue;
      var shown = row;
      if (source.Removals is not null)
      {
        CloudDeleteItem item;
        try { item = source.DeleteItem(row); } catch { made.Add(row); continue; }
        var key = Key(item);
        found.Add(key);
        if (byKey.TryGetValue(key, out var mark)) shown = row with { State = mark.Mark == CloudLocalMark.NotOnThisPc ? CloudItemState.NotOnThisPc : CloudItemState.OnlyOnThisPc };
        else if (binned.Contains(key)) continue;
      }
      made.Add(shown);
    }
    foreach (var mark in marks)
    {
      var key = Key(mark.Item);
      if (found.Contains(key)) continue;
      var id = "marked|" + key;
      if (!ids.Add(id)) continue;
      marked[id] = (source, mark.Item);
      made.Add(new CloudContentsRow(id, source.Kind, CloudShelfWords.Plain(mark.Item.Name) ?? CloudContentsWords.Title(source.Kind), [], mark.At,
        CloudDeleteWords.ThisPc, null, mark.Mark == CloudLocalMark.NotOnThisPc ? CloudItemState.NotOnThisPc : CloudItemState.OnlyOnThisPc, CanOpen: false));
    }
    return made;
  }

  private bool SafeGate()
  {
    try { return deleteRuleOpen(); } catch { return false; }
  }

  private void Say(CloudContentsKind kind, string what, Exception e) =>
    Log?.Invoke("cloud contents: " + CloudContentsWords.Title(kind) + " " + what + " (" + (e is CloudFailure f ? f.Code : e.GetType().Name) + ")");

  public async Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel = default)
  {
    if (!AccessAllowed() || !row.CanOpen || Source(row.Kind) is not { } source) return null;
    try { var result = await source.OpenAsync(row, cancel); return AccessAllowed() ? result : null; }
    catch (OperationCanceledException) { throw; }
    catch (Exception e) { Say(row.Kind, "could not open an item", e); return null; }
  }

  /// Bin "Cloud": out of his Cloud and his other devices, kept on this PC ("Only on this PC").
  public Task<CloudContentsResult> RemoveFromCloudAsync(IReadOnlyList<CloudContentsRow> rows) => RemoveAsync(rows, CloudDeleteScope.Cloud);

  /// Bin "Everywhere": into the Bin on every device.
  public Task<CloudContentsResult> RemoveEverywhereAsync(IReadOnlyList<CloudContentsRow> rows) => RemoveAsync(rows, CloudDeleteScope.Everywhere);

  private async Task<CloudContentsResult> RemoveAsync(IReadOnlyList<CloudContentsRow> rows, CloudDeleteScope scope)
  {
    if (!AccessAllowed()) return AccessRefused;
    var open = SafeGate();
    var actor = person();
    var done = 0;
    var failed = 0;
    foreach (var (source, items) in Route(rows.Where(r => r.State == CloudItemState.InSync)))
    {
      bool canDelete;
      try { canDelete = await source.Removals!.CanDeleteEverywhereAsync(); } catch { canDelete = false; }
      if (!AccessAllowed()) return new(done, CloudSubscriptionPageText.Subscribe);
      var (cloud, everywhere) = Scopes(source.Kind, source.OffersCloudOnly, open, canDelete);
      if (scope == CloudDeleteScope.Cloud ? !cloud : !everywhere) { failed += items.Count; continue; }
      try { done += (await source.Removals!.DeleteItemsAsync(items, scope, actor)).Count; }
      catch (Exception e) { Say(source.Kind, "could not remove", e); failed += items.Count; }
    }
    return Result(done, failed + rows.Count(r => r.State != CloudItemState.InSync));
  }

  /// "Bring back" for rows "Not on this PC".
  public Task<CloudContentsResult> BringBackAsync(IReadOnlyList<CloudContentsRow> rows) =>
    BackAsync(rows, CloudItemState.NotOnThisPc, CloudBringBackDestination.ThisPc);

  /// "Put in Cloud again" for rows "Only on this PC".
  public Task<CloudContentsResult> PutInCloudAgainAsync(IReadOnlyList<CloudContentsRow> rows) =>
    BackAsync(rows, CloudItemState.OnlyOnThisPc, CloudBringBackDestination.Cloud);

  private async Task<CloudContentsResult> BackAsync(IReadOnlyList<CloudContentsRow> rows, CloudItemState state, CloudBringBackDestination to)
  {
    if (!AccessAllowed()) return AccessRefused;
    var done = 0;
    var failed = rows.Count(r => r.State != state);
    foreach (var (source, items) in Route(rows.Where(r => r.State == state)))
    {
      if (!AccessAllowed()) return new(done, CloudSubscriptionPageText.Subscribe);
      try { done += (await source.Removals!.BringBackAsync(items, to)).Count; }
      catch (Exception e) { Say(source.Kind, to == CloudBringBackDestination.ThisPc ? "could not bring back" : "could not put in Cloud again", e); failed += items.Count; }
    }
    return Result(done, failed);
  }

  /// The rows' delete items by provider (rows of a kind without removals are left out).
  private List<(ICloudContentsSource Source, IReadOnlyList<CloudDeleteItem> Items)> Route(IEnumerable<CloudContentsRow> rows)
  {
    Dictionary<string, (ICloudContentsSource Source, CloudDeleteItem Item)> marked;
    lock (gate) marked = markedRows;
    var made = new Dictionary<CloudContentsKind, (ICloudContentsSource Source, List<CloudDeleteItem> Items)>();
    foreach (var row in rows)
    {
      ICloudContentsSource? source;
      CloudDeleteItem item;
      if (marked.TryGetValue(row.Id, out var m)) (source, item) = (m.Source, m.Item);
      else
      {
        source = Source(row.Kind);
        if (source?.Removals is null) continue;
        try { item = source.DeleteItem(row); } catch { continue; }
      }
      if (source.Removals is null) continue;
      if (!made.TryGetValue(row.Kind, out var list)) made[row.Kind] = list = (source, []);
      if (!list.Items.Any(i => Key(i) == Key(item))) list.Items.Add(item);
    }
    return made.OrderBy(m => m.Key).Select(m => (m.Value.Source, (IReadOnlyList<CloudDeleteItem>)m.Value.Items)).ToList();
  }

  private static CloudContentsResult Result(int done, int failed) =>
    new(done, failed == 0 ? null : failed == 1 ? "1 item could not be changed." : failed + " items could not be changed.");

  /// The Bin, newest removal first: one line per removal (a group across kinds is one line).
  public async Task<IReadOnlyList<CloudBinLine>> BinAsync(CancellationToken cancel = default)
  {
    var groups = new List<(ICloudContentsSource, CloudBinGroup)>();
    foreach (var source in Sources())
    {
      cancel.ThrowIfCancellationRequested();
      if (source.Removals is not { } removals) continue;
      try { foreach (var g in await removals.BinGroupsAsync()) groups.Add((source, g)); }
      catch (Exception e) { Say(source.Kind, "Bin could not be read", e); }
    }
    var lines = Lines(groups, PlaceNames, out var parts);
    lock (gate) binParts = parts;
    return lines;
  }

  private static List<CloudBinLine> Lines(IEnumerable<(ICloudContentsSource Source, CloudBinGroup Group)> groups, Func<string, string?>? placeNames,
    out Dictionary<string, List<(ICloudContentsSource, CloudBinGroup)>> parts)
  {
    parts = new(StringComparer.Ordinal);
    foreach (var (source, group) in groups)
    {
      if (group.Items.Count == 0) continue;
      if (!parts.TryGetValue(group.Id, out var list)) parts[group.Id] = list = [];
      list.Add((source, group));
    }
    var lines = new List<CloudBinLine>();
    foreach (var (id, list) in parts)
    {
      var first = list.OrderByDescending(p => p.Item2.At).First().Item2;
      var items = new List<(CloudContentsKind Kind, CloudDeleteItem Item)>();
      var seen = new HashSet<string>(StringComparer.Ordinal);
      foreach (var (source, group) in list)
        foreach (var item in group.Items)
          if (seen.Add(Key(item))) items.Add((source.Kind, item));
      var kinds = items.Select(i => i.Kind).Distinct().OrderBy(k => k).ToArray();
      lines.Add(new CloudBinLine(id, kinds, What(items, placeNames), list.Max(p => p.Item2.At), CloudShelfWords.Plain(first.MacName) ?? CloudDeleteWords.AnotherDevice,
        first.By == CloudDeleteBy.Ai, items.Count, first.Era));
    }
    return lines.OrderByDescending(l => l.At).ThenBy(l => l.Id, StringComparer.Ordinal).ToList();
  }

  /// What a removal was: its name, or "12 notes", or "12 items" for several kinds; "… in Website" when every item sat
  /// in the same named place.
  internal static string What(IReadOnlyList<(CloudContentsKind Kind, CloudDeleteItem Item)> items, Func<string, string?>? placeNames = null)
  {
    if (items.Count == 1) return CloudShelfWords.Plain(items[0].Item.Name) ?? CloudContentsWords.Noun(items[0].Kind, 1);
    var kinds = items.Select(i => i.Kind).Distinct().ToArray();
    var what = kinds.Length == 1 ? items.Count + " " + CloudContentsWords.Noun(kinds[0], items.Count) : CloudContentsWords.Items(items.Count);
    var places = items.Select(i => i.Item.Place).Distinct(StringComparer.Ordinal).ToArray();
    string? name = null;
    if (places is [{ Length: > 0 } place] && placeNames is not null)
      try { name = CloudShelfWords.Plain(placeNames(place)); } catch (Exception e) when (e is not OutOfMemoryException) { name = null; }
    return name is null ? what : what + " in " + name;
  }

  /// "Put back all" for the selected lines.
  public async Task<CloudContentsResult> PutBackAllAsync(IReadOnlyList<CloudBinLine> lines)
  {
    if (!AccessAllowed()) return AccessRefused;
    var done = 0;
    var failed = 0;
    foreach (var line in lines)
      foreach (var (source, group) in await PartsAsync(line))
      {
        if (!AccessAllowed()) return new(done, CloudSubscriptionPageText.Subscribe);
        try { done += (await source.Removals!.PutBackGroupAsync(group.Id)).Count; }
        catch (Exception e) { Say(source.Kind, "could not put back", e); failed += group.Items.Count; }
      }
    return Result(done, failed);
  }

  /// "Delete for good" (right-click only).
  public async Task<CloudContentsResult> DeleteForGoodAsync(IReadOnlyList<CloudBinLine> lines)
  {
    if (!AccessAllowed()) return AccessRefused;
    var done = 0;
    var failed = 0;
    foreach (var line in lines)
      foreach (var (source, group) in await PartsAsync(line))
      {
        if (!AccessAllowed()) return new(done, CloudSubscriptionPageText.Subscribe);
        try { await source.Removals!.DeleteForGoodAsync(group.Items); done += group.Items.Count; }
        catch (Exception e) { Say(source.Kind, "could not delete for good", e); failed += group.Items.Count; }
      }
    return Result(done, failed);
  }

  private async Task<IReadOnlyList<(ICloudContentsSource, CloudBinGroup)>> PartsAsync(CloudBinLine line)
  {
    lock (gate) if (binParts.TryGetValue(line.Id, out var known)) return known.ToArray();
    await BinAsync();
    lock (gate) return binParts.TryGetValue(line.Id, out var fresh) ? fresh.ToArray() : [];
  }

  /// What one folder of a kind lists: folders first (with how many things each holds), then items. With search words:
  /// every item below the folder whose name or folder holds them, and no folders.
  public static CloudContentsListing Listing(IReadOnlyList<CloudContentsRow> rows, CloudContentsKind kind, IReadOnlyList<string> folder, string search)
  {
    static bool Under(CloudContentsRow r, IReadOnlyList<string> f) => r.Folder.Count >= f.Count && f.Select((p, i) => string.Equals(r.Folder[i], p, StringComparison.Ordinal)).All(b => b);
    var mine = rows.Where(r => r.Kind == kind && Under(r, folder)).ToArray();
    var words = (search ?? "").Trim();
    if (words.Length > 0)
    {
      var found = mine.Where(r => r.Name.Contains(words, StringComparison.OrdinalIgnoreCase) || r.Folder.Any(p => p.Contains(words, StringComparison.OrdinalIgnoreCase)));
      return new CloudContentsListing([], Order(found));
    }
    var folders = mine.Where(r => r.Folder.Count > folder.Count).GroupBy(r => r.Folder[folder.Count], StringComparer.Ordinal)
      .Select(g => new CloudContentsFolderRow(kind, [.. folder, g.Key], g.Key, g.Count()))
      .OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase).ThenBy(f => f.Name, StringComparer.Ordinal).ToArray();
    return new CloudContentsListing(folders, Order(mine.Where(r => r.Folder.Count == folder.Count)));
  }

  private static IReadOnlyList<CloudContentsRow> Order(IEnumerable<CloudContentsRow> rows) =>
    rows.OrderBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase).ThenByDescending(r => r.ChangedAt).ThenBy(r => r.Id, StringComparer.Ordinal).ToArray();
}
