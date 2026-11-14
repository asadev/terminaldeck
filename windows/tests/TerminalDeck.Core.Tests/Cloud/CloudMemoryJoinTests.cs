using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// 7C-1 safety: a Windows PC joins an account where two Macs already keep their memory. Everything runs through the real
// engine, transport and signed packs against the fixture service (CloudFakeService), never the live Cloud. The two
// "Macs" are this same memory adapter over in-memory stores (it follows the Mac's rules); the PC uses the real
// file-backed store in a scratch folder, and is restarted from disk.
public sealed class CloudMemoryJoinTests : IDisposable
{
  private const string Subject = CloudFakeService.Subject;
  private const string MacA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", MacB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e", Pc = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string StoreA = "2b7e1516-28ae-4d2a-a6d2-abf7158809cf", StoreB = "9c1d2e3f-4a5b-4c6d-9e7f-8a9b0c1d2e3f";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-7c1-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private sealed class Peer
  {
    public required IDeckMemoryCloudStore Memory;
    public required CloudMemoryAdapter Adapter;
    public required CloudSyncEngine Engine;
    public required CloudMemoryKeptInMemory Kept;
  }
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private readonly Dictionary<string, CloudTestDevice> devices = [];
  private readonly Dictionary<string, (CloudMemorySlot State, CloudMemorySlot Ledger, CloudMemorySlot Adapter)> slots = [];

  private Peer Make(string id, IDeckMemoryCloudStore memory)
  {
    if (!devices.TryGetValue(id, out var device)) { device = devices[id] = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk; }
    if (!slots.TryGetValue(id, out var s)) s = slots[id] = (new CloudMemorySlot(), new CloudMemorySlot(), new CloudMemorySlot());
    var kept = new CloudMemoryKeptInMemory();
    var adapter = new CloudMemoryAdapter(memory, s.Adapter, id, localNow: () => service.Now, keeper: kept);
    var store = new CloudSyncStore(s.State, s.Ledger, Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [adapter], null, () => service.Now);
    return new Peer { Memory = memory, Adapter = adapter, Engine = engine, Kept = kept };
  }
  private Peer MakePc() => Make(Pc, FileDeckMemoryStore.At(Path.Combine(scratch, "memory")));

  private static DeckMemoryRow Setting(string key, string value) =>
    new("settings", [DeckMemoryCell.Text("hoot"), DeckMemoryCell.Text(key), DeckMemoryCell.Text(value), DeckMemoryCell.Real(1)]);
  private static DeckMemoryRow Note(string id, string path)
  {
    var t = DeckMemoryCloudSchema.Table("notes");
    var cells = Enumerable.Repeat(DeckMemoryCell.Null, t.Columns.Count).ToArray();
    cells[t.Index("id")] = DeckMemoryCell.Text(id); cells[t.Index("path")] = DeckMemoryCell.Text(path);
    cells[t.Index("title")] = DeckMemoryCell.Text("Note " + id); cells[t.Index("type")] = DeckMemoryCell.Text("note"); cells[t.Index("owner")] = DeckMemoryCell.Text("hoot");
    return new("notes", cells);
  }
  private static DeckMemoryRow Diary(long id, string text)
  {
    var t = DeckMemoryCloudSchema.Table("diary");
    var cells = Enumerable.Repeat(DeckMemoryCell.Null, t.Columns.Count).ToArray();
    cells[t.Index("id")] = DeckMemoryCell.Integer(id); cells[t.Index("owner")] = DeckMemoryCell.Text("hoot"); cells[t.Index("text")] = DeckMemoryCell.Text(text);
    return new("diary", cells);
  }
  private static void Seed(InMemoryDeckMemoryStore memory, string prefix, int notes)
  {
    for (var i = 0; i < notes; i++)
    {
      var path = $"hoot/notes/{prefix}-{i}.md";
      memory.WriteFile(path, Encoding.UTF8.GetBytes($"# {prefix} {i}\n\nText of note {i} from {prefix}.\n"));
      memory.PutRow(Note(prefix + "-" + i, path), null);
    }
    for (var i = 1; i <= 20; i++) memory.PutRow(Diary(i, prefix + " diary " + i), null);
  }
  private static string Text(IDeckMemoryCloudStore memory, string path) => Encoding.UTF8.GetString(memory.ReadFile(path) ?? []);
  private static string? Value(IDeckMemoryCloudStore memory, string key) => memory.Rows("settings").FirstOrDefault(r => r.Cells[1].Value == key)?.Cells[2].Value;
  private static SortedDictionary<string, string> Snapshot(IDeckMemoryCloudStore memory) =>
    new(memory.ListFiles().ToDictionary(f => f.Path, f => Text(memory, f.Path), StringComparer.Ordinal), StringComparer.Ordinal);

  /// Two Macs with their memory already in the account and level with each other.
  private async Task<(Peer A, Peer B, InMemoryDeckMemoryStore MemA, InMemoryDeckMemoryStore MemB)> TwoMacs()
  {
    var memA = new InMemoryDeckMemoryStore(StoreA); var memB = new InMemoryDeckMemoryStore(StoreB);
    Seed(memA, "a", 120); Seed(memB, "b", 80);
    memA.PutRow(Setting("tidy.hour", "3"), null);
    var a = Make(MacA, memA); var b = Make(MacB, memB);
    await a.Engine.SyncAsync(default);
    await b.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    Assert.Equal(200, memA.ListFiles().Count);
    Assert.Equal(200, memB.ListFiles().Count);
    return (a, b, memA, memB);
  }

  [Fact]
  public async Task A_fresh_PC_receives_everything_sends_nothing_and_changes_nothing_on_the_Macs()
  {
    var (a, b, memA, memB) = await TwoMacs();
    var macFiles = Snapshot(memA);
    var sent = service.Segments;

    var pc = MakePc();
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    // Empty memory is "nothing yet": the PC sent no record at all.
    Assert.Equal(sent, service.Segments);
    Assert.Equal(CloudSyncPhase.Level, pc.Engine.State().Phase);
    // Everything arrived once, byte for byte, with its labels; no second copy of anything.
    Assert.Equal(macFiles, Snapshot(pc.Memory));
    Assert.Equal(200, pc.Memory.Rows("notes").Count);
    Assert.Equal(200, pc.Memory.Rows("notes").Select(r => r.Cells[1].Value).Distinct().Count());
    Assert.Equal(40, pc.Memory.Rows("diary").Count);
    Assert.Equal("3", Value(pc.Memory, "tidy.hour"));
    Assert.Empty(pc.Adapter.OtherVersions);
    Assert.Equal(0, pc.Adapter.WaitingCount);

    // The Macs see nothing new: same files, same labels, nothing listed.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(macFiles, Snapshot(memA));
    Assert.Equal(macFiles, Snapshot(memB));
    Assert.Equal(200, memA.Rows("notes").Count);
    Assert.Empty(a.Adapter.OtherVersions); Assert.Empty(b.Adapter.OtherVersions);

    // The PC restarts from its own disk: still nothing to send, nothing lost.
    var again = MakePc();
    await again.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(macFiles, Snapshot(again.Memory));
    Assert.Equal(200, again.Memory.Rows("notes").Count);
  }

  [Fact]
  public async Task A_PC_that_had_its_own_text_never_overwrites_the_Macs_its_text_is_kept_and_listed()
  {
    var (a, b, memA, memB) = await TwoMacs();
    var macFiles = Snapshot(memA);
    // The PC had a different text at a path the Macs use, and its own value of a shared setting, before it joined.
    var disk = FileDeckMemoryStore.At(Path.Combine(scratch, "memory"));
    disk.WriteFile("hoot/notes/a-1.md", Encoding.UTF8.GetBytes("the PC's old text"));
    disk.PutRow(Setting("tidy.hour", "7"), null);
    disk.Flush();

    var pc = MakePc();
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    // The Cloud's text and value are used on the PC; the PC's own are kept and listed (rule J: a joiner's first copy loses).
    Assert.Equal(macFiles, Snapshot(pc.Memory));
    Assert.Equal("3", Value(pc.Memory, "tidy.hour"));
    Assert.Equal("the PC's old text", Encoding.UTF8.GetString(Assert.Single(pc.Kept.Kept).Bytes));
    Assert.Equal(2, pc.Adapter.OtherVersions.Count);

    // The PC's own copies travel as baselines: the Macs keep theirs in use, no second live file appears.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(macFiles, Snapshot(memA));
    Assert.Equal(macFiles, Snapshot(memB));
    Assert.Equal("3", Value(memA, "tidy.hour"));
    Assert.Equal("3", Value(memB, "tidy.hour"));
    Assert.Equal(200, memA.Rows("notes").Count);
    Assert.Equal("the PC's old text", Encoding.UTF8.GetString(Assert.Single(a.Kept.Kept).Bytes));

    // And everyone is level afterwards: another round sends nothing.
    var sent = service.Segments;
    await pc.Engine.SyncAsync(default); await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
  }

  [Fact]
  public async Task A_removal_from_a_Mac_leaves_the_PCs_copy_and_the_PC_never_sends_one()
  {
    var (_, _, memA, _) = await TwoMacs();
    var pc = MakePc();
    await pc.Engine.SyncAsync(default);
    var text = Text(pc.Memory, "hoot/notes/a-5.md");
    Assert.NotEmpty(text);

    // The Mac's one rule: a removal is a new version of the file (on top of the one in use) whose text is a marker.
    const string key = "file/hoot/notes/a-5.md";
    var parent = CloudMemoryFormat.Uuid(StoreA + ":" + key + "\n" + CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes(text)));
    var marker = Encoding.UTF8.GetBytes("---\nid: a-5\ntype: removed\nstatus: removed\ntd_removed: 1763000000000\ntd_removed_by: " + MacA + "\n---\n# Removed: a-5\n");
    var hash = CloudMemoryFormat.Hash(marker);
    var removal = CloudMemoryFormat.Operation(new(StoreA, "I01", key, CloudMemoryFormat.Uuid(parent + "\n" + hash), hash, marker.Length, 0, 1, [parent],
      Convert.ToBase64String(marker), service.Now + 1, false), MacA, [], service.Now);
    await pc.Adapter.ApplyAsync(removal, new CloudImportOrigin(MacA, 999, null, false), default);
    await pc.Adapter.SettleAsync(default);
    Assert.Equal(text, Text(pc.Memory, "hoot/notes/a-5.md"));
    Assert.Equal(CloudMemoryAdapter.KeptRemovalWhy, Assert.Single(pc.Adapter.OtherVersions).Why);

    // A label row the PC still holds and a file gone from the PC's folder never travel as removals.
    var sent = service.Segments;
    File.Delete(Path.Combine(scratch, "memory", "files", "hoot", "notes", "a-6.md"));
    await pc.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.NotEmpty(Text(memA, "hoot/notes/a-6.md"));
  }

  [Fact]
  public async Task What_never_travels_stays_on_the_PC()
  {
    var disk = FileDeckMemoryStore.At(Path.Combine(scratch, "memory"));
    foreach (var path in new[] { "CLAUDE.md", "START-HERE.md", "archive/backups/memory-1.db", "memory.db" }) disk.WriteFile(path, [1, 2, 3]);
    disk.WriteFile("hoot/notes/gone.md", Encoding.UTF8.GetBytes("---\ntd_removed: 5\n---\n"));
    Directory.CreateDirectory(Path.Combine(scratch, "memory", "files", ".git"));
    File.WriteAllText(Path.Combine(scratch, "memory", "files", ".git", "config"), "secret");
    disk.WriteFile("hoot/notes/kept.md", Encoding.UTF8.GetBytes("an ordinary note"));
    disk.PutRow(Setting("helper.last-run", "123"), null);
    disk.PutRow(Setting("onerule.understands." + Pc, "1"), null);
    disk.PutRow(new("meta", [DeckMemoryCell.Text("embedding.model"), DeckMemoryCell.Text("m")]), null);
    var board = DeckMemoryCloudSchema.Table("board");
    disk.PutRow(new("board", Enumerable.Range(0, board.Columns.Count).Select(i => i == 0 ? DeckMemoryCell.Text("seat") : DeckMemoryCell.Null).ToArray()), null);
    disk.PutRow(new("settings", [DeckMemoryCell.Text("hoot"), DeckMemoryCell.Text("tidy.on"), DeckMemoryCell.Null, DeckMemoryCell.Real(1)]), null);
    disk.Flush();

    var adapter = new CloudMemoryAdapter(disk, new CloudMemorySlot(), Pc);
    adapter.FeedRead();
    var capture = await adapter.CaptureAsync(() => 1, default);
    // Only the ordinary note goes (a PC may add memory); the help files, database files, hidden folder, removal
    // marker, local settings, meta, the board and a removal never do.
    var sent = capture.Operations.Select(o => ((CloudJson.Object)o.Payload)["key"]!.AsString).ToArray();
    Assert.Equal(["file/hoot/notes/kept.md"], sent);
  }

  [Fact]
  public void The_PCs_memory_store_keeps_rows_and_names_across_a_restart()
  {
    var folder = Path.Combine(scratch, "store");
    var store = FileDeckMemoryStore.At(folder);
    store.PutRow(Setting("tidy.on", "1"), null);
    Assert.Equal(1, store.AllocateInteger("diary"));
    store.PutRow(Diary(1, "one"), null);
    store.WriteFile("hoot/notes/n.md", [65]);
    store.Flush();
    var again = FileDeckMemoryStore.At(folder);
    Assert.Equal(store.StoreId, again.StoreId);
    Assert.Equal("1", Value(again, "tidy.on"));
    Assert.Equal(2, again.AllocateInteger("diary"));
    Assert.Equal(new byte[] { 65 }, again.ReadFile("hoot/notes/n.md"));
    Assert.NotNull(again.FindWhere("diary", "text", DeckMemoryCell.Text("one")));
    Assert.Equal("a_b_.md", FileDeckMemoryStore.WindowsName("a:b?.md"));
    Assert.Equal("x/_CON.md", FileDeckMemoryStore.WindowsName("x/CON.md"));
    Assert.Equal("dots._/n.md", FileDeckMemoryStore.WindowsName("dots./n.md"));
    Assert.Equal("hoot/notes/plain.md", FileDeckMemoryStore.WindowsName("hoot/notes/plain.md"));
  }
}
