using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The Macs' one rule for memory removals and moves, on a Windows PC (CloudMemoryOneRule.cs). Everything runs through
// the real engine, transport and signed packs against the fixture service (CloudFakeService), never the live Cloud.
// The two "Macs" are this same adapter over in-memory stores with the one rule on (it follows the Mac's rules); one test
// also feeds the PC a removal made exactly as the Mac makes it. The PC uses the real file-backed store and the real
// safety-copy folder in a scratch folder.
public sealed class CloudMemoryOneRuleTests : IDisposable
{
  private const string Subject = CloudFakeService.Subject;
  private const string MacA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", MacB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e", Pc = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string StoreA = "2b7e1516-28ae-4d2a-a6d2-abf7158809cf", StoreB = "9c1d2e3f-4a5b-4c6d-9e7f-8a9b0c1d2e3f";
  private const long Minutes = 60_000;
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-1r-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private sealed class Peer
  {
    public required IDeckMemoryCloudStore Memory;
    public required CloudMemoryAdapter Adapter;
    public required CloudSyncEngine Engine;
    public required CloudMemoryKeptInMemory Kept;
    public Task Sync() => Engine.SyncAsync(default);
  }
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private readonly Dictionary<string, CloudTestDevice> devices = [];
  private readonly Dictionary<string, (CloudMemorySlot State, CloudMemorySlot Ledger, CloudMemorySlot Adapter)> slots = [];
  /// The account's devices that keep memory, as the account lists them.
  private readonly List<string> account = [MacA, MacB];

  private Peer Make(string id, IDeckMemoryCloudStore memory, bool oneRule = true, ICloudMemorySafety? safety = null)
  {
    if (!devices.TryGetValue(id, out var device)) { device = devices[id] = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk; }
    if (!slots.TryGetValue(id, out var s)) s = slots[id] = (new CloudMemorySlot(), new CloudMemorySlot(), new CloudMemorySlot());
    var kept = new CloudMemoryKeptInMemory();
    var ports = oneRule ? new CloudMemoryOneRulePorts(() => account.ToArray(), safety ?? new CloudMemorySafetyInMemory(memory)) : null;
    var adapter = new CloudMemoryAdapter(memory, s.Adapter, id, localNow: () => service.Now, keeper: kept, oneRule: ports);
    var store = new CloudSyncStore(s.State, s.Ledger, Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [adapter], null, () => service.Now);
    return new Peer { Memory = memory, Adapter = adapter, Engine = engine, Kept = kept };
  }
  private string PcFolder => Path.Combine(scratch, "account");
  private Peer MakePc(bool oneRule = true) => Make(Pc, FileDeckMemoryStore.At(Path.Combine(PcFolder, "memory")), oneRule, new CloudMemorySafetyFolder(PcFolder));
  private string PcFile(string path) => Path.Combine(new[] { PcFolder, "memory", "files" }.Concat(path.Split('/')).ToArray());

  private static DeckMemoryRow Note(string id, string path)
  {
    var t = DeckMemoryCloudSchema.Table("notes");
    var cells = Enumerable.Repeat(DeckMemoryCell.Null, t.Columns.Count).ToArray();
    cells[t.Index("id")] = DeckMemoryCell.Text(id); cells[t.Index("path")] = DeckMemoryCell.Text(path);
    cells[t.Index("title")] = DeckMemoryCell.Text("Note " + id); cells[t.Index("type")] = DeckMemoryCell.Text("note"); cells[t.Index("owner")] = DeckMemoryCell.Text("hoot");
    return new("notes", cells);
  }
  private static void Seed(InMemoryDeckMemoryStore memory, string prefix, int notes)
  {
    for (var i = 0; i < notes; i++)
    {
      var path = $"hoot/notes/{prefix}-{i}.md";
      memory.WriteFile(path, Encoding.UTF8.GetBytes($"# {prefix} {i}\n\nText of note {i} from {prefix}.\n"));
      memory.PutRow(Note(prefix + "-" + i, path), null);
    }
  }
  private static string? Text(IDeckMemoryCloudStore memory, string path) => memory.ReadFile(path) is { } b ? Encoding.UTF8.GetString(b) : null;
  private static string? Understands(IDeckMemoryCloudStore memory, string device) =>
    memory.Find("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(CloudMemoryOneRule.UnderstandsKey(device))])?.Cells[2].Value;

  /// Two Macs (the one rule on) with their memory in the account, level with each other: 200 notes, limit 10.
  private async Task<(Peer A, Peer B, InMemoryDeckMemoryStore MemA, InMemoryDeckMemoryStore MemB)> TwoMacs()
  {
    var memA = new InMemoryDeckMemoryStore(StoreA); var memB = new InMemoryDeckMemoryStore(StoreB);
    Seed(memA, "a", 120); Seed(memB, "b", 80);
    var a = Make(MacA, memA); var b = Make(MacB, memB);
    await a.Sync(); await b.Sync(); await a.Sync();
    Assert.Equal(200, memA.ListFiles().Count);
    Assert.Equal(200, memB.ListFiles().Count);
    return (a, b, memA, memB);
  }
  /// The PC joins and every device has heard every other one say it understands.
  private async Task<Peer> PcJoins(Peer a, Peer b)
  {
    account.Add(Pc);
    var pc = MakePc();
    await pc.Sync(); await a.Sync(); await b.Sync(); await pc.Sync();
    return pc;
  }

  [Fact]
  public async Task Until_the_PC_says_it_understands_the_Macs_hold_their_removals_then_the_PC_applies_them()
  {
    var (a, b, memA, memB) = await TwoMacs();
    // A PC on the earlier Windows build (no one rule) joins the account: it never says it understands.
    account.Add(Pc);
    var old = MakePc(oneRule: false);
    await old.Sync(); await a.Sync(); await b.Sync();
    Assert.Null(Understands(memA, Pc));
    Assert.StartsWith("v2:", Understands(memA, MacB));

    // Mac A removes a note: nothing is sent while one device of the account does not understand removals.
    memA.DeleteFile("hoot/notes/a-5.md");
    await a.Sync(); await b.Sync(); await old.Sync();
    Assert.NotNull(Text(memB, "hoot/notes/a-5.md"));
    Assert.NotNull(Text(old.Memory, "hoot/notes/a-5.md"));

    // The PC is updated (same disk): it says it understands, exactly as a Mac does (owner "", "v2:<service ms>").
    var pc = MakePc();
    await pc.Sync();
    Assert.StartsWith("v2:", Understands(pc.Memory, Pc));
    await a.Sync(); await b.Sync();
    Assert.Equal(Understands(pc.Memory, Pc), Understands(memA, Pc));

    // Now Mac A's removal travels; the PC applies it: its whole memory copied first, the note's text kept, then gone.
    await a.Sync(); await pc.Sync(); await b.Sync();
    Assert.Null(Text(pc.Memory, "hoot/notes/a-5.md"));
    Assert.Null(Text(memB, "hoot/notes/a-5.md"));
    Assert.False(File.Exists(PcFile("hoot/notes/a-5.md")));
    var safety = Assert.Single(Directory.GetDirectories(Path.Combine(PcFolder, "memory-safety")));
    Assert.True(File.Exists(Path.Combine(safety, "files", "hoot", "notes", "a-5.md")));
    Assert.Equal("# a 5\n\nText of note 5 from a.\n", Encoding.UTF8.GetString(Assert.Single(pc.Kept.Kept).Bytes));
    Assert.Equal(CloudMemoryAdapter.RemovedWhy, Assert.Single(pc.Adapter.OtherVersions).Why);
    // Nothing else changed anywhere, and nothing bounces back.
    Assert.Equal(199, pc.Memory.ListFiles().Count);
    Assert.Equal(199, memA.ListFiles().Count);
    var sent = service.Segments;
    await pc.Sync(); await a.Sync(); await b.Sync();
    Assert.Equal(sent, service.Segments);
  }

  [Fact]
  public async Task A_removal_made_by_a_Mac_in_its_own_format_is_applied_on_the_PC_only_after_a_safety_copy()
  {
    var (a, b, _, _) = await TwoMacs();
    var pc = await PcJoins(a, b);
    var text = Text(pc.Memory, "hoot/notes/a-5.md")!;
    // Exactly what a Mac sends (DeckMemoryRemoval.text): a new version of the file, on top of the one in use.
    const string key = "file/hoot/notes/a-5.md";
    var parent = CloudMemoryFormat.Uuid(StoreA + ":" + key + "\n" + CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes(text)));
    var marker = Encoding.UTF8.GetBytes("---\nid: n-20261114-ab12cd\ntype: removed\nstatus: removed\ntd_removed: 1763000000000\ntd_removed_by: " + MacA
      + "\n---\n# Removed: a-5\n\nThis was removed from your Macs on 2026-11-14. Terminal Deck keeps the earlier text for 30 days; update Terminal Deck on this Mac to see it in the Bin.\n");
    var hash = CloudMemoryFormat.Hash(marker);
    var removal = CloudMemoryFormat.Operation(new(StoreA, "I01", key, CloudMemoryFormat.Uuid(parent + "\n" + hash), hash, marker.Length, 0, 1, [parent],
      Convert.ToBase64String(marker), service.Now + 1, false), MacA, [], service.Now);

    // The safety copy cannot be made (a full disk): the note is held, never removed.
    var failing = new CloudMemorySafetyInMemory(pc.Memory) { Fails = true };
    var careful = new CloudMemoryAdapter(pc.Memory, slots[Pc].Adapter, Pc, localNow: () => service.Now, keeper: pc.Kept,
      oneRule: new CloudMemoryOneRulePorts(() => account.ToArray(), failing));
    await careful.ApplyAsync(removal, new CloudImportOrigin(MacA, 999, null, false), default);
    await careful.SettleAsync(default);
    // This adapter finds no usable safety copy and cannot make one: the removal waits, the note stays.
    Assert.Equal(text, Text(pc.Memory, "hoot/notes/a-5.md"));
    Assert.Equal(1, careful.HeldRemovals);
    failing.Fails = false;
    Assert.Equal(1, careful.ConfirmHeldRemovals());
    Assert.Null(Text(pc.Memory, "hoot/notes/a-5.md"));
    Assert.Single(failing.Made);
    Assert.Equal(text, Encoding.UTF8.GetString(failing.Made[0]["hoot/notes/a-5.md"]));
    Assert.Equal(text, Encoding.UTF8.GetString(Assert.Single(pc.Kept.Kept).Bytes));
  }

  [Fact]
  public async Task A_note_changed_on_the_PC_after_the_removal_was_made_stays_and_comes_back_on_the_Macs()
  {
    var (a, b, memA, memB) = await TwoMacs();
    var pc = await PcJoins(a, b);
    // Mac A removes a note; meanwhile the person edits the same note on the PC.
    memA.DeleteFile("hoot/notes/a-8.md");
    await a.Sync();
    pc.Memory.WriteFile("hoot/notes/a-8.md", Encoding.UTF8.GetBytes("# a 8\n\nHis newer words, written on the PC.\n"));
    await pc.Sync();
    // His text stays on the PC; it was not what the removal was made from.
    Assert.Equal("# a 8\n\nHis newer words, written on the PC.\n", Text(pc.Memory, "hoot/notes/a-8.md"));
    Assert.Contains(pc.Adapter.OtherVersions, o => o.Why == CloudMemoryAdapter.EditKeptWhy);
    // And it comes back on both Macs (an edit the removal was not made on top of beats it everywhere).
    await a.Sync(); await b.Sync();
    Assert.Equal("# a 8\n\nHis newer words, written on the PC.\n", Text(memA, "hoot/notes/a-8.md"));
    Assert.Equal("# a 8\n\nHis newer words, written on the PC.\n", Text(memB, "hoot/notes/a-8.md"));
    Assert.Equal(200, pc.Memory.ListFiles().Count);
  }

  [Fact]
  public async Task A_removal_and_a_move_made_on_the_PC_travel_to_the_Macs()
  {
    var (a, b, memA, memB) = await TwoMacs();
    var pc = await PcJoins(a, b);
    // A move (the same text at a new place) and a plain removal, made on the PC.
    var text = File.ReadAllBytes(PcFile("hoot/notes/a-7.md"));
    File.Delete(PcFile("hoot/notes/a-7.md"));
    pc.Memory.WriteFile("hoot/archive-notes/a-7.md", text);
    File.Delete(PcFile("hoot/notes/b-3.md"));
    await pc.Sync(); await a.Sync(); await b.Sync();

    foreach (var mac in new[] { memA, memB })
    {
      Assert.Null(Text(mac, "hoot/notes/a-7.md"));
      Assert.Equal(Encoding.UTF8.GetString(text), Text(mac, "hoot/archive-notes/a-7.md"));
      Assert.Null(Text(mac, "hoot/notes/b-3.md"));
      Assert.Equal(199, mac.ListFiles().Count);
    }
    // Both last texts are kept on each Mac; only the removal is listed (a moved text is in use at its new place).
    foreach (var mac in new[] { a, b })
    {
      Assert.Equal(new[] { "a-7", "b-3" }, mac.Kept.Kept.Select(k => Path.GetFileNameWithoutExtension(k.Path)).Order().ToArray());
      Assert.EndsWith("b-3.md", Assert.Single(mac.Adapter.OtherVersions, o => o.Why == CloudMemoryAdapter.RemovedWhy).Value);
    }
    // Nothing bounces back.
    var sent = service.Segments;
    await pc.Sync(); await a.Sync(); await b.Sync();
    Assert.Equal(sent, service.Segments);
  }

  [Fact]
  public async Task The_PC_sends_at_most_the_limit_in_15_minutes_and_nothing_when_too_many_go_at_once()
  {
    var (a, b, memA, memB) = await TwoMacs();
    var pc = await PcJoins(a, b);
    // 200 notes: the limit is 10. Twelve gone at once is "too many": nothing is sent until the person confirms.
    for (var i = 0; i < 12; i++) File.Delete(PcFile($"hoot/notes/a-{i}.md"));
    await pc.Sync();
    Assert.Equal(12, pc.Adapter.MissingNotSent);
    await a.Sync();
    Assert.Equal(200, memA.ListFiles().Count);
    pc.Adapter.ConfirmMissing();
    await pc.Sync();
    Assert.Equal(0, pc.Adapter.MissingNotSent);
    // Mac A applies ten in its 15 minutes and holds the other two for its own answer (a confirmed label never lets
    // a removal past the receiver's own brake).
    await a.Sync();
    Assert.Equal(190, memA.ListFiles().Count);
    Assert.Equal(2, a.Adapter.HeldRemovals);

    // A fresh window: eight go, then five more in the same 15 minutes: two of those wait for the brake.
    service.Now += 16 * Minutes;
    for (var i = 20; i < 28; i++) File.Delete(PcFile($"hoot/notes/a-{i}.md"));
    await pc.Sync();
    Assert.Equal(0, pc.Adapter.MissingNotSent);
    for (var i = 30; i < 35; i++) File.Delete(PcFile($"hoot/notes/a-{i}.md"));
    await pc.Sync();
    Assert.Equal(3, pc.Adapter.MissingNotSent);
    service.Now += 15 * Minutes;
    await pc.Sync();
    Assert.Equal(0, pc.Adapter.MissingNotSent);
    // Mac B, reading all 25 at once, applies ten and holds the rest until its own answer.
    await b.Sync();
    Assert.Equal(190, memB.ListFiles().Count);
    Assert.Equal(15, b.Adapter.HeldRemovals);
    Assert.Equal(15, b.Adapter.ConfirmHeldRemovals());
    Assert.Equal(200 - 25, memB.ListFiles().Count);
    Assert.Equal(200 - 25, pc.Memory.ListFiles().Count);
  }

  [Fact]
  public async Task Removals_arriving_past_the_brake_wait_on_the_PC_for_the_persons_answer()
  {
    var (a, b, memA, _) = await TwoMacs();
    var pc = await PcJoins(a, b);
    for (var i = 0; i < 15; i++) memA.DeleteFile($"hoot/notes/b-{i}.md");
    a.Adapter.ConfirmMissing();
    await a.Sync(); await pc.Sync();
    // Ten applied, five held untouched.
    Assert.Equal(185, pc.Memory.ListFiles().Count);
    Assert.Equal(5, pc.Adapter.HeldRemovals);
    Assert.NotNull(Text(pc.Memory, "hoot/notes/b-9.md"));
    // His answer "they are gone".
    Assert.Equal(5, pc.Adapter.ConfirmHeldRemovals());
    Assert.Equal(185 - 5, pc.Memory.ListFiles().Count);
    Assert.Equal(0, pc.Adapter.HeldRemovals);
  }

  [Fact]
  public async Task Keep_them_puts_the_held_notes_back_on_the_Mac_that_removed_them()
  {
    var (a, b, memA, _) = await TwoMacs();
    var pc = await PcJoins(a, b);
    for (var i = 0; i < 15; i++) memA.DeleteFile($"hoot/notes/b-{i}.md");
    a.Adapter.ConfirmMissing();
    await a.Sync(); await pc.Sync();
    Assert.Equal(5, pc.Adapter.HeldRemovals);
    Assert.Equal(5, pc.Adapter.KeepHeldRemovals());
    await pc.Sync(); await a.Sync();
    Assert.Equal(185 + 5, memA.ListFiles().Count);
    Assert.Equal(185 + 5, pc.Memory.ListFiles().Count);
  }

  [Fact]
  public async Task A_joining_PC_never_removes_anything_anywhere()
  {
    var (a, b, memA, memB) = await TwoMacs();
    // Before the PC joins, Mac A removed a note (both Macs understand): the Cloud holds its text, then its removal.
    memA.DeleteFile("hoot/notes/a-3.md");
    await a.Sync(); await b.Sync();
    Assert.Null(Text(memB, "hoot/notes/a-3.md"));
    var before = (A: memA.ListFiles().Select(f => f.Path).ToArray(), B: memB.ListFiles().Select(f => f.Path).ToArray());

    // The PC joins: it receives the account as it is and sends nothing but "I understand".
    var pc = await PcJoins(a, b);
    Assert.Null(Text(pc.Memory, "hoot/notes/a-3.md"));
    Assert.Equal(199, pc.Memory.ListFiles().Count);
    Assert.Equal(before.A, memA.ListFiles().Select(f => f.Path).ToArray());
    Assert.Equal(before.B, memB.ListFiles().Select(f => f.Path).ToArray());
    Assert.StartsWith("v2:", Understands(memA, Pc));

    // The PC's memory folder is emptied (a reinstall, a wiped disk): "everything gone at once" is never sent.
    Directory.Delete(Path.Combine(PcFolder, "memory", "files"), recursive: true);
    await pc.Sync(); await pc.Sync();
    Assert.Equal(199, pc.Adapter.MissingNotSent);
    await a.Sync(); await b.Sync();
    Assert.Equal(before.A, memA.ListFiles().Select(f => f.Path).ToArray());
    Assert.Equal(before.B, memB.ListFiles().Select(f => f.Path).ToArray());
  }

  [Fact]
  public async Task An_untouched_app_default_never_replaces_his_own_text_on_any_device()
  {
    // The shipped Hoot playbook, byte for byte the Mac's (349 characters, SHA-256 93ba59bf..., read on 14 Nov).
    var shipped = Encoding.UTF8.GetBytes(CloudMemoryDefaults.Playbook);
    Assert.Equal(349, shipped.Length);
    Assert.StartsWith("93ba59bf", CloudMemoryFormat.Hash(shipped));
    const string his = "# Playbook\nRead notes before working.\n| Job | AI |\n|---|---|\n| release | claude |\n";

    // Mac B (a fresh install) sends the default first; Mac A, with his own text, joins two minutes later. By the
    // Cloud's order alone the default would win on A (A's first copy is a baseline that loses).
    var memA = new InMemoryDeckMemoryStore(StoreA); var memB = new InMemoryDeckMemoryStore(StoreB);
    memB.WriteFile("hoot/playbook.md", shipped);
    memA.WriteFile("hoot/playbook.md", Encoding.UTF8.GetBytes(his));
    var b = Make(MacB, memB); var a = Make(MacA, memA);
    await b.Sync();
    service.Now += 2 * Minutes;
    await a.Sync(); await b.Sync();
    Assert.Equal(his, Text(memA, "hoot/playbook.md"));
    Assert.Equal(his, Text(memB, "hoot/playbook.md"));

    // The PC joins: the default arrives first, his text after it; his text is the one in use.
    account.Add(Pc);
    var pc = MakePc();
    await pc.Sync(); await pc.Sync();
    Assert.Equal(his, Text(pc.Memory, "hoot/playbook.md"));
    // And nothing the PC sends brings the default back anywhere.
    await a.Sync(); await b.Sync();
    Assert.Equal(his, Text(memA, "hoot/playbook.md"));
    Assert.Equal(his, Text(memB, "hoot/playbook.md"));
  }

  [Fact]
  public void The_records_are_the_Macs_own()
  {
    // "Understands": counts only as format 2 or newer, renewed in the last 3 days, never from the future; "1" never.
    const long now = 1_763_000_000_000;
    Assert.Equal("v2:" + now, CloudMemoryOneRule.UnderstandsValue(now));
    Assert.True(CloudMemoryOneRule.Fresh("v2:" + now, now));
    Assert.True(CloudMemoryOneRule.Fresh("v3:" + now, now));
    Assert.False(CloudMemoryOneRule.Fresh("1", now));
    Assert.False(CloudMemoryOneRule.Fresh("v1:" + now, now));
    Assert.False(CloudMemoryOneRule.Fresh("v2:" + (now - 3 * 86_400_000 - 1), now));
    Assert.False(CloudMemoryOneRule.Fresh("v2:" + (now + 3_600_001), now));
    Assert.Equal("onerule.understands." + Pc, CloudMemoryOneRule.UnderstandsKey(Pc.ToUpperInvariant()));
    // The brake: 50 files or 5% of the memory, whichever is smaller, at least 1; a window of 15 minutes.
    Assert.Equal(1, CloudMemoryOneRule.Limit(3));
    Assert.Equal(10, CloudMemoryOneRule.Limit(200));
    Assert.Equal(50, CloudMemoryOneRule.Limit(4_400));
    Assert.Equal((now, 0), CloudMemoryOneRule.Current(now - 15 * Minutes, 7, now));
    Assert.Equal((now - Minutes, 7), CloudMemoryOneRule.Current(now - Minutes, 7, now));
    // A removal marker made on the PC reads back exactly as the Mac reads it (DeckMemoryRemoval.parse).
    var move = new CloudMemoryRemoval(now, Pc, "hoot/archive-notes/a-7.md").Text("n-20261113-abc123", "a-7");
    Assert.True(move.Length < CloudMemoryFormat.RemovalMarkerLimit);
    Assert.True(CloudMemoryFormat.IsRemovalMarker(move));
    Assert.Equal(new CloudMemoryRemoval(now, Pc, "hoot/archive-notes/a-7.md"), CloudMemoryRemoval.Parse(move));
    var front = FrontMatter.Of(Encoding.UTF8.GetString(move)).Values;
    Assert.Equal("removed", front["type"]);
    Assert.Equal("n-20261113-abc123", front["id"]);
    Assert.Null(CloudMemoryRemoval.Parse(Encoding.UTF8.GetBytes("# just a note\n")));
    Assert.Equal(CloudMemoryRemoval.NoteId(now, "x"), CloudMemoryRemoval.NoteId(now, "x"));
    // Defaults: the shipped lead settings (304 characters on his MacBook) and every earlier card count as defaults.
    Assert.Equal(304, CloudMemoryDefaults.Texts("templates/lead/settings.md", _ => null)[0].Length);
    Assert.Equal(3, CloudMemoryDefaults.Texts("templates/agent/card.md", _ => null).Count);
    Assert.Equal(2, CloudMemoryDefaults.Texts("projects/crm/lead/card.md", k => k == "lead:crm" ? "Sales lead" : null).Count);
    Assert.Empty(CloudMemoryDefaults.Texts("hoot/notes/n.md", _ => null));
  }
}
