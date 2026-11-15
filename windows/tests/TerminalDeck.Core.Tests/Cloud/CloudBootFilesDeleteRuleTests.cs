using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// AI instruction files under the 15 Nov delete rule, case for case from the Mac's BootFilesDeleteRuleTests.swift
// (td-mac-next2). Two devices are this adapter over their own scratch project folders; records move by capture and
// apply, as the engine moves them. Not here: AI home folders (Windows does not sync them in this version, so their
// case is "a home record waits", already covered by CloudBootFilesJoinTests) and the Mac's one-pack receipt check
// (Windows has no import receipts).
public sealed class CloudBootFilesDeleteRuleTests : IDisposable
{
  private const string A = "e3c75f30-363e-4323-a592-cf07fe14c4a6", B = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string Project = "p1", Group = "dd1c167a-86a7-4503-93ed-7c537acbfc09";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-boot-delete-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }
  private long now = 1_900_000_000_000;
  private ulong seq;
  /// The devices that announced the delete rule (both: the gate is open).
  private HashSet<string> announced = [];
  private bool gateOpen { set => announced = value ? [A, B] : []; }
  private readonly Dictionary<string, string> names = new() { [A] = "Mac mini", [B] = "Office PC" };

  private sealed class Witness : ICloudDeleteWitness
  {
    public CloudDeleteWitnessAnswer Answer = CloudDeleteWitnessAnswer.CannotKnow;
    public int Calls;
    public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt) { Calls++; return Task.FromResult(Answer); }
  }
  private sealed class Device
  {
    public required CloudBootFilesAdapter Adapter;
    public required string Id, Folder;
    public required Witness Witness;
    public required CloudMemoryKeptInMemory Kept;
    public required CloudMemorySlot Slot, State;
    public required CloudBin Bin;
    public required Dictionary<string, string> Folders;
  }
  private Device Make(string id, Device? reopen = null)
  {
    var folder = Path.Combine(scratch, id, "app");
    Directory.CreateDirectory(folder);
    var folders = reopen?.Folders ?? new Dictionary<string, string> { [Project] = folder };
    var witness = reopen?.Witness ?? new Witness();
    var slots = new CloudDeleteWitnessSlot();
    slots.InstallOnce(witness);
    var settings = new InMemoryDeckMemoryStore(Guid.NewGuid().ToString());
    foreach (var d in announced)
      settings.PutRow(new("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(CloudDeleteGate.Key(d)), DeckMemoryCell.Text(CloudDeleteGate.Value(now)), DeckMemoryCell.Real(1)]), null);
    var announce = new CloudAnnounce(settings, () => id, () => now, () => [A, B], new CloudMemorySlot());
    var slot = reopen?.Slot ?? new CloudMemorySlot();
    var state = reopen?.State ?? new CloudMemorySlot();
    var bin = reopen?.Bin ?? new CloudBin(Path.Combine(scratch, id, "bin"));
    var kept = new CloudMemoryKeptInMemory();
    var options = new CloudBootFilesDeleteOptions(bin, state, announce, d => names.GetValueOrDefault(d), names[id], slots);
    var adapter = new CloudBootFilesAdapter(slot, Path.Combine(scratch, id, "state", "retained"), id, () => folders, () => now, kept,
      userProfile: Path.Combine(scratch, "profile"), stateFolder: Path.Combine(scratch, id, "state"), delete: options);
    adapter.FeedRead();
    return new Device { Adapter = adapter, Id = id, Folder = folder, Witness = witness, Kept = kept, Slot = slot, State = state, Bin = bin, Folders = folders };
  }
  private async Task<IReadOnlyList<CloudOperation>> Capture(Device d)
  {
    var capture = await d.Adapter.CaptureAsync(() => now, default);
    capture.Commit();
    return capture.Operations;
  }
  private async Task<IReadOnlyList<CloudOperation>> Sync(Device from, Device to)
  {
    var ops = await Capture(from);
    foreach (var op in ops) await to.Adapter.ApplyAsync(op, new CloudImportOrigin(from.Id, ++seq, now, false), default);
    await to.Adapter.SettleAsync(default);
    return ops;
  }
  private static void Write(Device d, string relative, string text, long at)
  {
    var path = Path.Combine(d.Folder, relative);
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    File.WriteAllText(path, text);
    File.SetLastWriteTimeUtc(path, DateTimeOffset.FromUnixTimeMilliseconds(at).UtcDateTime);
  }
  private static string? Read(Device d, string relative) => File.Exists(Path.Combine(d.Folder, relative)) ? File.ReadAllText(Path.Combine(d.Folder, relative)) : null;
  private static string Id(string relative) => "project/" + CloudBootFilesFormat.Token(Project) + "\n" + relative;
  private static int Archives(IEnumerable<CloudOperation> ops) => ops.Count(o => o.Kind == "archive");
  private static int Abouts(IEnumerable<CloudOperation> ops) => ops.Count(CloudFileDeleteRecords.IsAbout);

  private async Task<(Device A, Device B)> Shared()
  {
    var a = Make(A);
    var b = Make(B);
    Write(a, "CLAUDE.md", "Rules.\n", now - 60_000);
    Write(a, "AGENTS.md", "Agents.\n", now - 60_000);
    await Sync(a, b);
    Assert.Equal("Rules.\n", Read(b, "CLAUDE.md"));
    await Capture(b);
    return (a, b);
  }
  private async Task Looks(Device d) { await Capture(d); now += 4_000; await Capture(d); }

  [Fact]
  public async Task By_hand_is_a_mark_after_two_looks_three_seconds_apart_and_never_sent()
  {
    var (_, b) = await Shared();
    File.Delete(Path.Combine(b.Folder, "CLAUDE.md"));
    Assert.Empty(await Capture(b));
    Assert.Empty(await b.Adapter.NotHereAsync());
    now += 1_000;
    Assert.Empty(await Capture(b));
    now += 3_000;
    Assert.Empty(await Capture(b));
    var mark = Assert.Single(await b.Adapter.NotHereAsync());
    Assert.Equal((CloudLocalMark.NotOnThisPc, "CLAUDE.md"), (mark.Mark, mark.Item.Name));
  }

  [Fact]
  public async Task Hundreds_of_instruction_files_gone_by_hand_have_no_limit_or_question()
  {
    var a = Make(A);
    var b = Make(B);
    for (var i = 0; i < 300; i++) Write(a, $".claude/agents/a{i}.md", "agent " + i, now - 60_000);
    Write(a, "CLAUDE.md", "Rules.\n", now - 60_000);
    await Sync(a, b);
    await Capture(b);
    for (var i = 0; i < 300; i++) File.Delete(Path.Combine(b.Folder, ".claude", "agents", $"a{i}.md"));
    await Looks(b);
    Assert.Equal(300, (await b.Adapter.NotHereAsync()).Count);
    Assert.Equal("agent 7", Read(a, ".claude/agents/a7.md"));
  }

  [Fact]
  public async Task Witnessed_AI_removal_travels_and_applies_into_the_keeper_boot_Bin()
  {
    gateOpen = true;
    var (a, b) = await Shared();
    b.Witness.Answer = CloudDeleteWitnessAnswer.Ai("Night work", "Integrations", DateTimeOffset.FromUnixTimeMilliseconds(now), Group);
    File.Delete(Path.Combine(b.Folder, "CLAUDE.md"));
    await Capture(b);
    now += 4_000;
    var sent = await Sync(b, a);
    Assert.Equal((1, 1), (Archives(sent), Abouts(sent)));
    Assert.Null(Read(a, "CLAUDE.md"));
    var group = Assert.Single(await a.Adapter.BinGroupsAsync());
    Assert.Equal((Group, "Removed by an AI on Office PC", "Night work", "CLAUDE.md"), (group.Id, group.Title, group.Session, Assert.Single(group.Items).Name));
    Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal("Agents.\n", Read(a, "AGENTS.md"));
  }

  [Fact]
  public async Task A_missing_or_empty_project_root_never_calls_the_witness()
  {
    var (_, b) = await Shared();
    File.Delete(Path.Combine(b.Folder, "CLAUDE.md"));
    File.Delete(Path.Combine(b.Folder, "AGENTS.md"));
    await Looks(b);
    Directory.Delete(b.Folder, recursive: true);
    await Looks(b);
    Assert.Equal(0, b.Witness.Calls);
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task Cloud_scope_keeps_both_files_and_only_put_in_Cloud_again_sends_bytes()
  {
    gateOpen = true;
    var (a, b) = await Shared();
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md")], CloudDeleteScope.Cloud, actor);
    var sent = await Sync(a, b);
    Assert.Equal((1, 1), (Archives(sent), Abouts(sent)));
    Assert.Equal("Rules.\n", Read(a, "CLAUDE.md"));
    Assert.Equal("Rules.\n", Read(b, "CLAUDE.md"));
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, Assert.Single(await b.Adapter.NotHereAsync()).Mark);
    Write(b, "CLAUDE.md", "Rules, only here.\n", now);
    now += 1_000;
    Assert.Empty(await Capture(b));
    var item = Assert.Single(await a.Adapter.NotHereAsync()).Item;
    Assert.Single(await a.Adapter.BringBackAsync([item], CloudBringBackDestination.Cloud));
    now += 1_000;
    Assert.NotEmpty(await Sync(a, b));
    Assert.Equal("Rules.\n", Read(b, "CLAUDE.md"));
    Assert.Empty(await b.Adapter.NotHereAsync());
    Assert.Contains(b.Kept.Kept, k => Encoding.UTF8.GetString(k.Bytes) == "Rules, only here.\n");
  }

  [Fact]
  public async Task An_edit_wins_against_an_arriving_removal_regardless_of_dates()
  {
    gateOpen = true;
    var (a, b) = await Shared();
    Write(b, "CLAUDE.md", "Rules, edited on the PC.\n", now - 120_000);
    await Capture(b);
    now += 1_000;
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md")], CloudDeleteScope.Everywhere, actor);
    await Sync(a, b);
    Assert.Equal("Rules, edited on the PC.\n", Read(b, "CLAUDE.md"));
    Assert.Empty(await b.Adapter.BinGroupsAsync());
  }

  [Fact]
  public async Task An_old_format_removal_applies_as_everywhere_with_the_older_version_era()
  {
    // The Mac is an older build: it never announced the rule, so its removal carries no about-record.
    announced = [B];
    var (a, b) = await Shared();
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md")], CloudDeleteScope.Everywhere, actor);
    var sent = await Sync(a, b);
    Assert.Equal((1, 0), (Archives(sent), Abouts(sent)));
    Assert.Null(Read(b, "CLAUDE.md"));
    var group = Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal((CloudBinEra.OlderVersion, "Removed on Mac mini (older version)"), (group.Era, group.Title));
  }

  [Fact]
  public async Task Marks_survive_new_versions_and_a_restart_and_bring_back_uses_the_newest_bytes()
  {
    var (a, b) = await Shared();
    File.Delete(Path.Combine(b.Folder, "CLAUDE.md"));
    await Looks(b);
    Write(a, "CLAUDE.md", "Rules v2.\n", now);
    now += 1_000;
    await Sync(a, b);
    Assert.Null(Read(b, "CLAUDE.md"));
    var again = Make(B, b);
    Assert.Empty(await Capture(again));
    var item = Assert.Single(await again.Adapter.NotHereAsync()).Item;
    Assert.Single(await again.Adapter.BringBackAsync([item], CloudBringBackDestination.ThisPc));
    Assert.Equal("Rules v2.\n", Read(again, "CLAUDE.md"));
    now += 1_000;
    Assert.Empty(await Capture(again));
  }

  [Fact]
  public async Task Reappearing_own_earlier_version_uses_the_newest_without_publishing_a_rollback()
  {
    var (a, b) = await Shared();
    File.Delete(Path.Combine(b.Folder, "CLAUDE.md"));
    await Looks(b);
    Write(a, "CLAUDE.md", "Rules v2.\n", now);
    now += 1_000;
    await Sync(a, b);
    Write(b, "CLAUDE.md", "Rules.\n", now - 500_000);
    Assert.Empty(await Capture(b));
    Assert.Equal("Rules v2.\n", Read(b, "CLAUDE.md"));
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task Reappearing_unknown_bytes_publish_on_top_of_the_newest()
  {
    var (a, b) = await Shared();
    File.Delete(Path.Combine(b.Folder, "CLAUDE.md"));
    await Looks(b);
    Write(a, "CLAUDE.md", "Rules v2.\n", now);
    now += 1_000;
    await Sync(a, b);
    Write(b, "CLAUDE.md", "His own rules.\n", now);
    now += 1_000;
    Assert.NotEmpty(await Sync(b, a));
    Assert.Equal("His own rules.\n", Read(a, "CLAUDE.md"));
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task An_arriving_removal_waits_only_for_its_missing_root_and_applies_when_it_returns()
  {
    gateOpen = true;
    var (a, b) = await Shared();
    var away = Path.Combine(scratch, B, "away");
    Directory.Move(b.Folder, away);
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md")], CloudDeleteScope.Everywhere, actor);
    await Sync(a, b);
    Assert.Empty(await b.Adapter.BinGroupsAsync());
    Directory.Move(away, b.Folder);
    await Capture(b);
    Assert.Null(Read(b, "CLAUDE.md"));
    Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal("Agents.\n", Read(b, "AGENTS.md"));
  }

  [Fact]
  public async Task Put_back_all_and_delete_for_good_use_the_same_keeper_and_never_touch_live_files()
  {
    gateOpen = true;
    var (a, b) = await Shared();
    var actor = new CloudDeleteActor(CloudDeleteBy.Ai, A, "Mac mini", "Night work", null, now, Group);
    await a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md"), new(Id("AGENTS.md"), "boot", "AGENTS.md")], CloudDeleteScope.Everywhere, actor);
    await Sync(a, b);
    Assert.Null(Read(b, "AGENTS.md"));
    var group = Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal(2, group.Count);
    await b.Adapter.DeleteForGoodAsync([group.Items.Single(i => i.Name == "AGENTS.md")]);
    var left = Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal(1, left.Count);
    Assert.Single(await b.Adapter.PutBackGroupAsync(left.Id));
    Assert.Equal("Rules.\n", Read(b, "CLAUDE.md"));
    Assert.Null(Read(b, "AGENTS.md"));
    now += 1_000;
    await Sync(b, a);
    Assert.Equal("Rules.\n", Read(a, "CLAUDE.md"));
  }

  [Fact]
  public async Task A_closed_gate_refuses_Cloud_scope_and_a_removal_without_its_note_from_an_updated_device_keeps_the_file()
  {
    announced = [A];
    var (a, b) = await Shared();
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await Assert.ThrowsAsync<InvalidOperationException>(() => a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md")], CloudDeleteScope.Cloud, actor));
    Assert.Equal("Rules.\n", Read(a, "CLAUDE.md"));
    // Everywhere goes in the old form (no about-record). The Mac announced the rule, so the PC reads it the safe way:
    // the file stays, "Only on this PC", and the removed text is in the Bin.
    await a.Adapter.DeleteItemsAsync([new(Id("CLAUDE.md"), "boot", "CLAUDE.md")], CloudDeleteScope.Everywhere, actor);
    var sent = await Sync(a, b);
    Assert.Equal((1, 0), (Archives(sent), Abouts(sent)));
    Assert.Equal("Rules.\n", Read(b, "CLAUDE.md"));
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, Assert.Single(await b.Adapter.NotHereAsync()).Mark);
  }
}
