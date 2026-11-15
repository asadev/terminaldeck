using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane U1: "what is in your Cloud" and the Core part of the Bin page, case for case the Mac's CloudContentsTests.swift /
// CloudBinPageTests.swift (BackendCloudDeletePage: scopes, marks, Bin merge) with fake owners. Names and dates only: no
// row's visible text is an id or a path.
public sealed class CloudContentsTests
{
  private sealed class Owner : ICloudDeleteOwning
  {
    public List<CloudNotHereItem> Marks = [];
    public List<CloudBinGroup> Bin = [];
    public bool CanDelete = true;
    public bool Throws;
    public readonly List<string> Calls = [];
    public Task<CloudBinGroup> DeleteItemsAsync(IReadOnlyList<CloudDeleteItem> items, CloudDeleteScope scope, CloudDeleteActor by)
    {
      Calls.Add("delete " + scope + " " + string.Join(",", items.Select(i => i.Id)) + " " + by.Group);
      if (Throws) throw new CloudFailure("unavailable");
      return Task.FromResult(new CloudBinGroup(by.Group, by.By, by.MacName, null, null, by.At, items));
    }
    public Task<IReadOnlyList<CloudDeleteItem>> BringBackAsync(IReadOnlyList<CloudDeleteItem> items, CloudBringBackDestination to)
    {
      Calls.Add("back " + to + " " + string.Join(",", items.Select(i => i.Id)));
      return Task.FromResult(items);
    }
    public Task<IReadOnlyList<CloudNotHereItem>> NotHereAsync() => Task.FromResult<IReadOnlyList<CloudNotHereItem>>(Marks);
    public Task<IReadOnlyList<CloudBinGroup>> BinGroupsAsync() => Task.FromResult<IReadOnlyList<CloudBinGroup>>(Bin);
    public Task<IReadOnlyList<CloudDeleteItem>> PutBackGroupAsync(string group)
    {
      Calls.Add("putback " + group);
      return Task.FromResult(Bin.Where(g => g.Id == group).SelectMany(g => g.Items).ToList() as IReadOnlyList<CloudDeleteItem>);
    }
    public Task DeleteForGoodAsync(IReadOnlyList<CloudDeleteItem> items) { Calls.Add("forgood " + string.Join(",", items.Select(i => i.Id))); return Task.CompletedTask; }
    public Task<bool> CanDeleteEverywhereAsync() => Task.FromResult(CanDelete);
  }

  private sealed class Source(CloudContentsKind kind, Owner? owner, params (string Path, string Name)[] items) : ICloudContentsSource
  {
    public bool Fail;
    public bool CloudOnly = true;
    public CloudContentsKind Kind => kind;
    public ICloudDeleteOwning? Removals => owner;
    public bool OffersCloudOnly => CloudOnly;
    public Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel)
    {
      if (Fail) throw new CloudFailure("unavailable");
      return Task.FromResult<IReadOnlyList<CloudContentsRow>>(items.Select(i => new CloudContentsRow(Raw + "||" + i.Path, kind, i.Name,
        i.Path.Split('/')[..^1], 100, null, 10, CloudItemState.InSync)).ToArray());
    }
    private string Raw => CloudShelf.Raw(kind);
    public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel) =>
      Task.FromResult<CloudOpenedItem?>(new(row.Name, row.ChangedAt, "text of " + row.Name, null, "text/plain", null));
    public CloudDeleteItem DeleteItem(CloudContentsRow row) => new(row.Id[(Raw.Length + 2)..], Raw, row.Name, null);
  }

  private static readonly string Group = "00000000-0000-4000-8000-000000000001";
  private static CloudDeleteActor Person() => new(CloudDeleteBy.Person, "11111111-1111-4111-8111-111111111111", "Office PC", null, null, 50, Group);
  private static CloudDeleteItem Item(string kind, string id, string name) => new(id, kind, name, null);

  [Fact]
  public async Task Rows_MarksGiveTheStates_BinnedRowsAreGone_AMarkWithoutItsRowStaysReachable()
  {
    var owner = new Owner();
    owner.Marks.Add(new(Item("memory", "notes/a.md", "A"), CloudLocalMark.NotOnThisPc, 7));
    owner.Marks.Add(new(Item("memory", "notes/b.md", "B"), CloudLocalMark.OnlyOnThisPc, 8));
    owner.Marks.Add(new(Item("memory", "gone.md", "Gone note"), CloudLocalMark.NotOnThisPc, 9));
    owner.Bin.Add(new("g1", CloudDeleteBy.Person, "MacBook Pro", null, null, 30, [Item("memory", "notes/c.md", "C")]));
    var contents = new CloudContents(() => true, Person);
    contents.Register(new Source(CloudContentsKind.Memory, owner, ("notes/a.md", "A"), ("notes/b.md", "B"), ("notes/c.md", "C"), ("notes/d.md", "D")));
    var snap = await contents.ReadAsync();
    var rows = snap.Rows.ToDictionary(r => r.Name);
    Assert.Equal(CloudItemState.NotOnThisPc, rows["A"].State);
    Assert.Equal("Not on this PC", rows["A"].OnText);
    Assert.Equal(CloudItemState.OnlyOnThisPc, rows["B"].State);
    Assert.Equal("Only on this PC", rows["B"].OnText);
    Assert.False(rows.ContainsKey("C"));
    Assert.Equal("", rows["D"].OnText);
    Assert.Equal(CloudItemState.NotOnThisPc, rows["Gone note"].State);
    Assert.Equal("This PC", rows["Gone note"].ChangedBy);
    Assert.Equal(4, snap.Places.Single().Count);
    Assert.Equal(1, snap.BinCount);

    // Bring back works for the row whose item is no longer listed too.
    var back = await contents.BringBackAsync([rows["A"], rows["Gone note"], rows["D"]]);
    Assert.Equal(2, back.Done);
    Assert.Equal("1 item could not be changed.", back.Line);
    Assert.Contains("back ThisPc notes/a.md,gone.md", owner.Calls);
    await contents.PutInCloudAgainAsync([rows["B"]]);
    Assert.Contains("back Cloud notes/b.md", owner.Calls);
  }

  [Fact]
  public async Task Places_BinButtonsFollowTheDeleteRule()
  {
    var open = false;
    var contents = new CloudContents(() => open, Person);
    contents.Register(new Source(CloudContentsKind.Memory, new Owner(), ("a.md", "A")));
    contents.Register(new Source(CloudContentsKind.Passwords, new Owner(), ("p", "P")));
    contents.Register(new Source(CloudContentsKind.Sessions, new Owner(), ("s", "S")) { CloudOnly = false });
    contents.Register(new Source(CloudContentsKind.Tasks, new Owner(), ("t", "T")));
    contents.Register(new Source(CloudContentsKind.Settings, null, ("x", "X")));
    contents.Register(new Source(CloudContentsKind.Artifacts, new Owner { CanDelete = false }, ("y", "Y")));
    var closed = (await contents.ReadAsync()).Places.ToDictionary(p => p.Kind);
    Assert.Equal((false, true), (closed[CloudContentsKind.Memory].CanBinCloud, closed[CloudContentsKind.Memory].CanBinEverywhere));
    Assert.Equal((false, false), (closed[CloudContentsKind.Passwords].CanBinCloud, closed[CloudContentsKind.Passwords].CanBinEverywhere));
    Assert.Equal((false, false), (closed[CloudContentsKind.Settings].CanBinCloud, closed[CloudContentsKind.Settings].CanBinEverywhere));
    Assert.Equal((false, false), (closed[CloudContentsKind.Artifacts].CanBinCloud, closed[CloudContentsKind.Artifacts].CanBinEverywhere));
    open = true;
    var opened = (await contents.ReadAsync()).Places.ToDictionary(p => p.Kind);
    Assert.Equal((true, true), (opened[CloudContentsKind.Memory].CanBinCloud, opened[CloudContentsKind.Memory].CanBinEverywhere));
    Assert.Equal((true, true), (opened[CloudContentsKind.Passwords].CanBinCloud, opened[CloudContentsKind.Passwords].CanBinEverywhere));
    Assert.Equal((false, true), (opened[CloudContentsKind.Sessions].CanBinCloud, opened[CloudContentsKind.Sessions].CanBinEverywhere));
    Assert.Equal((false, true), (opened[CloudContentsKind.Tasks].CanBinCloud, opened[CloudContentsKind.Tasks].CanBinEverywhere));
    // Places in the page's order, only kinds with a provider.
    Assert.Equal([CloudContentsKind.Memory, CloudContentsKind.Tasks, CloudContentsKind.Settings, CloudContentsKind.Artifacts, CloudContentsKind.Sessions, CloudContentsKind.Passwords],
      (await contents.ReadAsync()).Places.Select(p => p.Kind));
  }

  [Fact]
  public async Task Remove_OneGroupForOnePress_CloudRefusedWhileTheRuleIsClosed()
  {
    var open = false;
    var memory = new Owner();
    var folder = new Owner();
    var contents = new CloudContents(() => open, Person);
    contents.Register(new Source(CloudContentsKind.Memory, memory, ("a.md", "A")));
    contents.Register(new Source(CloudContentsKind.CloudFolder, folder, ("f.txt", "f.txt")));
    var rows = (await contents.ReadAsync()).Rows;
    var refused = await contents.RemoveFromCloudAsync(rows);
    Assert.Equal(0, refused.Done);
    Assert.Empty(memory.Calls);
    var done = await contents.RemoveEverywhereAsync(rows);
    Assert.Equal(2, done.Done);
    Assert.Null(done.Line);
    Assert.Equal("delete Everywhere a.md " + Group, memory.Calls.Single());
    Assert.Equal("delete Everywhere f.txt " + Group, folder.Calls.Single());
    open = true;
    Assert.Equal(1, (await contents.RemoveFromCloudAsync([rows[0]])).Done);
    memory.Throws = true;
    Assert.Equal("1 item could not be changed.", (await contents.RemoveEverywhereAsync([rows[0]])).Line);
  }

  [Fact]
  public async Task Bin_ARemovalOfSeveralThingsNamesWhereTheyWere()
  {
    var memory = new Owner();
    CloudDeleteItem Note(int i, string? place) => new("projects/" + (place ?? "x") + "/notes/n" + i + ".md", "memory", "Note " + i, place);
    memory.Bin.Add(new("g1", CloudDeleteBy.Person, "Studio Mac", null, null, 300, [.. Enumerable.Range(1, 12).Select(i => Note(i, "p-website"))]));
    memory.Bin.Add(new("g2", CloudDeleteBy.Person, "Studio Mac", null, null, 200, [Note(1, "p-website"), Note(2, "p-mobile")]));
    memory.Bin.Add(new("g3", CloudDeleteBy.Person, "Studio Mac", null, null, 100, [Note(3, "p-unknown"), Note(4, "p-unknown")]));
    var contents = new CloudContents(() => true, Person) { PlaceNames = id => id switch { "p-website" => "Website", "p-mobile" => "Mobile app", _ => null } };
    contents.Register(new Source(CloudContentsKind.Memory, memory));
    var lines = await contents.BinAsync();
    Assert.Equal("12 notes in Website", lines.Single(l => l.Id == "g1").What);
    Assert.Equal("2 notes", lines.Single(l => l.Id == "g2").What);     // two places: no "in"
    Assert.Equal("2 notes", lines.Single(l => l.Id == "g3").What);     // a place without a name is never shown
  }

  [Fact]
  public async Task Bin_OneLinePerRemovalWithTheDevicesName_PutBackAllAndDeleteForGoodReachEveryOwner()
  {
    var memory = new Owner();
    var folder = new Owner();
    memory.Bin.Add(new("g1", CloudDeleteBy.Ai, "Mac mini", "Session", null, 100, [Item("memory", "a.md", "A"), Item("memory", "b.md", "B")]));
    folder.Bin.Add(new("g1", CloudDeleteBy.Ai, "Mac mini", "Session", null, 100, [Item("cloudFolder", "f.txt", "f.txt")]));
    memory.Bin.Add(new("g2", CloudDeleteBy.Person, "MacBook Pro", null, null, 200, [Item("memory", "c.md", "Plan")]));
    memory.Bin.Add(new("g3", CloudDeleteBy.Person, "Mac mini", null, null, 50, [Item("memory", "d.md", "D"), Item("memory", "e.md", "E")], CloudBinEra.BeforeNewRule));
    var contents = new CloudContents(() => true, Person);
    contents.Register(new Source(CloudContentsKind.Memory, memory));
    contents.Register(new Source(CloudContentsKind.CloudFolder, folder));
    var lines = await contents.BinAsync();
    Assert.Equal(["g2", "g1", "g3"], lines.Select(l => l.Id));
    Assert.Equal("Plan", lines[0].What);
    Assert.Equal("Removed on MacBook Pro", lines[0].Title);
    Assert.Equal("3 items", lines[1].What);
    Assert.Equal("Removed by an AI on Mac mini", lines[1].Title);
    Assert.Equal([CloudContentsKind.Memory, CloudContentsKind.CloudFolder], lines[1].Kinds);
    Assert.Equal("2 notes", lines[2].What);
    Assert.Equal("Before the new rule", lines[2].Title);
    Assert.Equal(3, (await contents.PutBackAllAsync([lines[1]])).Done);
    Assert.Contains("putback g1", memory.Calls);
    Assert.Contains("putback g1", folder.Calls);
    await contents.DeleteForGoodAsync([lines[0]]);
    Assert.Contains("forgood c.md", memory.Calls);
    Assert.DoesNotContain(folder.Calls, c => c.StartsWith("forgood", StringComparison.Ordinal));
  }

  [Fact]
  public async Task OneFailingProviderLeavesItsPlaceEmpty_TheRestList_AndItIsLogged()
  {
    var lines = new List<string>();
    var contents = new CloudContents(() => true, Person) { Log = lines.Add };
    contents.Register(new Source(CloudContentsKind.Memory, null, ("a.md", "A")) { Fail = true });
    contents.Register(new Source(CloudContentsKind.Artifacts, null, ("x.html", "Report")));
    var snap = await contents.ReadAsync();
    Assert.Equal(0, snap.Places.Single(p => p.Kind == CloudContentsKind.Memory).Count);
    Assert.Equal("Report", snap.Rows.Single().Name);
    Assert.Equal("cloud contents: Memory could not be listed (unavailable)", lines.Single());
  }

  [Fact]
  public async Task Listing_FoldersFirstWithCounts_SearchFindsBelow_OpenReads()
  {
    var contents = new CloudContents(() => true, Person);
    contents.Register(new Source(CloudContentsKind.CloudFolder, null, ("Deck Dev/Lead/one.md", "one.md"), ("Deck Dev/two.md", "two.md"), ("Pictures/cat.png", "cat.png"),
      ("top.txt", "top.txt")));
    var snap = await contents.ReadAsync();
    var top = snap.List(CloudContentsKind.CloudFolder, []);
    Assert.Equal(["Deck Dev", "Pictures"], top.Folders.Select(f => f.Name));
    Assert.Equal([2, 1], top.Folders.Select(f => f.Items));
    Assert.Equal(["top.txt"], top.Items.Select(i => i.Name));
    var deck = snap.List(CloudContentsKind.CloudFolder, ["Deck Dev"]);
    Assert.Equal(["Lead"], deck.Folders.Select(f => f.Name));
    Assert.Equal(["Deck Dev", "Lead"], deck.Folders[0].Path);
    Assert.Equal(["two.md"], deck.Items.Select(i => i.Name));
    var found = snap.List(CloudContentsKind.CloudFolder, [], "lead");
    Assert.Empty(found.Folders);
    Assert.Equal(["one.md"], found.Items.Select(i => i.Name));
    Assert.Equal("text of top.txt", (await contents.OpenAsync(top.Items[0]))!.Text);
  }

  // ---- The real providers that need no service ----

  private sealed class MemoryStore : IDeckMemoryCloudStore
  {
    public readonly Dictionary<string, byte[]> Files = new(StringComparer.Ordinal);
    public string StoreId => "11111111-1111-4111-8111-111111111111";
    public IReadOnlyList<DeckMemoryRow> Rows(string table) => [];
    public DeckMemoryRow? Find(string table, IReadOnlyList<DeckMemoryCell> keys) => null;
    public DeckMemoryRow? FindWhere(string table, string column, DeckMemoryCell value) => null;
    public void PutRow(DeckMemoryRow row, IReadOnlyList<DeckMemoryCell>? replacing) { }
    public long AllocateInteger(string table) => 1;
    public IReadOnlyList<DeckMemoryFileInfo> ListFiles() => Files.Select(f => new DeckMemoryFileInfo(f.Key, f.Value.Length, new DateTime(2026, 11, 15, 0, 0, 0, DateTimeKind.Utc).Ticks)).ToArray();
    public byte[]? ReadFile(string path) => Files.GetValueOrDefault(path);
    public void WriteFile(string path, byte[] bytes) => Files[path] = bytes;
    public void RemoveFile(string path, string expectedHash) => Files.Remove(path);
    public void Flush() { }
  }

  [Fact]
  public async Task MemoryProvider_NotesByTitle_NeverArchiveOrHelpFiles()
  {
    var store = new MemoryStore();
    store.Files["projects/p1/roles/decker/notes/2026-11-02-open-items-abc123.md"] = Encoding.UTF8.GetBytes("---\nkind: note\n---\n# Open items\n\nbody");
    store.Files["team/decker/2026-11-02-app-domain-retired-dtvjwi.md"] = Encoding.UTF8.GetBytes("no heading");
    store.Files["archive/versions/x.md"] = [1];
    store.Files["CLAUDE.md"] = [1];
    store.Files["imported/MEMORY.md"] = [1];
    var source = new CloudMemoryContentsSource(store, null, () => new Dictionary<string, string> { ["p1"] = "Terminal Deck" });
    var rows = await source.RowsAsync(default);
    Assert.Equal(["App domain retired", "Open items"], rows.Select(r => r.Name).Order());
    var open = rows.Single(r => r.Name == "Open items");
    Assert.Equal(["Terminal Deck", "decker"], open.Folder);
    Assert.Equal(new DateTimeOffset(2026, 11, 15, 0, 0, 0, TimeSpan.Zero).ToUnixTimeMilliseconds(), open.ChangedAt);
    Assert.Equal("# Open items\n\nbody", await source.TextAsync(open, default));
    Assert.Equal("projects/p1/roles/decker/notes/2026-11-02-open-items-abc123.md", source.DeleteItem(open).Id);
    Assert.Equal("memory", source.DeleteItem(open).Kind);
  }

  [Fact]
  public async Task SettingsProvider_NamesPagesAndValues_NoBin()
  {
    var settings = new List<CloudSetting>
    {
      new("setting:general.copyOnSelect", CloudJson.From(false), _ => true, () => CloudJson.From(true), _ => { }),
      new("setting:appearance.terminalFontSize", CloudJson.From(13), _ => true, () => CloudJson.From(14), _ => { }),
    };
    var source = new CloudSettingsContentsSource(() => settings);
    var rows = await source.RowsAsync(default);
    Assert.Equal(("Copy on select", "General", "On"), (rows[0].Name, rows[0].Folder.Single(), rows[0].Detail));
    Assert.Equal(("Terminal font size", "Appearance", "14"), (rows[1].Name, rows[1].Folder.Single(), rows[1].Detail));
    Assert.Null(source.Removals);
  }

  [Fact]
  public async Task NoRowShowsAnIdOrAPath()
  {
    var contents = new CloudContents(() => true, Person);
    var owner = new Owner();
    owner.Marks.Add(new(Item("memory", "notes/0123456789abcdef0123.md", "0123456789abcdef0123"), CloudLocalMark.NotOnThisPc, 1));
    contents.Register(new Source(CloudContentsKind.Memory, owner, ("x/a.md", "A")));
    var snap = await contents.ReadAsync();
    foreach (var row in snap.Rows)
    {
      Assert.False(CloudShelfWords.LooksLikeCode(row.Name));
      Assert.DoesNotContain('/', row.Name);
    }
  }

  private sealed class Records(Dictionary<string, CloudJson.Object> held) : ICloudRecordOwner
  {
    public IReadOnlyDictionary<string, CloudJson.Object> CloudRecords() => held;
    public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud) => throw new NotSupportedException();
    public void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting) => throw new NotSupportedException();
    public void CloudImported(IReadOnlyList<string> entities) { }
  }

  [Fact]
  public async Task RecordsProvider_TasksWithStateInTheirProject_TheirText_EverywhereOnly()
  {
    var owner = new Records(new()
    {
      ["task:1"] = (CloudJson.Object)CloudJson.Parse("{\"title\":\"Ship it\",\"crmStatus\":\"To do\",\"instructions\":\"Do the thing\",\"projectRef\":{\"projectId\":\"p1\"},\"updatedAt\":77}"),
      ["task-system:x"] = (CloudJson.Object)CloudJson.Parse("{\"name\":\"Board\"}"),
    });
    var source = new CloudRecordsContentsSource(CloudContentsKind.Tasks, owner, new Owner(), () => new Dictionary<string, string> { ["p1"] = "Garden" });
    var row = (await source.RowsAsync(default)).Single();
    Assert.Equal(("Ship it", "To do", 77L), (row.Name, row.Detail, row.ChangedAt));
    Assert.Equal(["Garden"], row.Folder);
    Assert.Equal(new CloudDeleteItem("task:1", "task", "Ship it"), source.DeleteItem(row));
    Assert.Equal("Do the thing", await source.TextAsync(row, default));
    var contents = CloudContentsReader.Make(() => true, Person, tasks: null);
    contents.Register(source);
    var place = (await contents.ReadAsync()).Places.Single();
    Assert.Equal((false, true), (place.CanBinCloud, place.CanBinEverywhere));
  }

  [Fact]
  public async Task Reader_RegistersOnlyWhatExists_PasswordsWithoutStoresHaveNoButtons()
  {
    var contents = CloudContentsReader.Make(() => true, Person, settings: () => [], passwordStores: () => []);
    var places = (await contents.ReadAsync()).Places;
    Assert.Equal([CloudContentsKind.Settings, CloudContentsKind.Passwords], places.Select(p => p.Kind));
    Assert.False(places[1].CanBinEverywhere);
    Assert.Equal("The Bin is empty.", CloudContentsWords.BinEmpty);
  }
}
