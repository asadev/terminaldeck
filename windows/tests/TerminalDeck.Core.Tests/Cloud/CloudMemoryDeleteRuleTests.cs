using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The 15 Nov delete rule for Deck Memory files on Windows, case for case from the Mac's MemoryDeleteRuleTests.swift and
// MemoryDeleteRuleReviewTests.swift (td-mac-next2). Two devices are this adapter over in-memory stores; records move
// between them by capture and apply, as the engine moves them. Cases the Mac has for parts Windows does not have (the
// one-time migration of the Mac's old memory database, moves the Mac's archive and seat folding record, Deck Memory's
// own card/playbook tools) are not here; see the lane's result file.
public sealed class CloudMemoryDeleteRuleTests : IDisposable
{
  private const string A = "e3c75f30-363e-4323-a592-cf07fe14c4a6", B = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string StoreA = "2b7e1516-28ae-4d2a-a6d2-abf7158809cf", StoreB = "9c1d2e3f-4a5b-4c6d-9e7f-8a9b0c1d2e3f";
  private const string Group = "dd1c167a-86a7-4503-93ed-7c537acbfc09";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-memory-delete-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private long now = 1_900_000_000_000;
  private ulong seq;
  private readonly Dictionary<string, string> names = new() { [A] = "Mac mini", [B] = "Office PC" };

  private sealed class Witness(CloudDeleteWitnessAnswer answer) : ICloudDeleteWitness
  {
    public readonly List<(string Path, DateTimeOffset Seen, DateTimeOffset Gone)> Calls = [];
    public CloudDeleteWitnessAnswer Answer = answer;
    public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt)
    { Calls.Add((removedPath, lastSeen, seenGoneAt)); return Task.FromResult(Answer); }
  }

  private sealed class Device
  {
    public required InMemoryDeckMemoryStore Memory;
    public required CloudMemoryAdapter Adapter;
    public required string Id;
    public required Witness Witness;
    public required CloudMemoryKeptInMemory Kept;
    public required CloudMemorySlot Slot, State, Requests;
    public required CloudBin Bin;
  }

  private bool gateOpen;
  private Device Make(string id, string store, InMemoryDeckMemoryStore? memory = null, Device? reopen = null, long runStartedAt = 0)
  {
    memory ??= reopen?.Memory ?? new InMemoryDeckMemoryStore(store);
    var witness = reopen?.Witness ?? new Witness(CloudDeleteWitnessAnswer.CannotKnow);
    var slot = reopen?.Slot ?? new CloudMemorySlot();
    var state = reopen?.State ?? new CloudMemorySlot();
    var requests = reopen?.Requests ?? new CloudMemorySlot();
    var bin = reopen?.Bin ?? new CloudBin(Path.Combine(scratch, id, "bin"));
    var witnesses = new CloudDeleteWitnessSlot();
    witnesses.InstallOnce(witness);
    var announce = new CloudAnnounce(memory, () => id, () => now, () => [A, B], new CloudMemorySlot());
    var kept = new CloudMemoryKeptInMemory();
    var options = new CloudMemoryDeleteOptions(bin, state, requests, Path.Combine(scratch, id, "retained"), p => Path.Combine(scratch, id, "files", p),
      gateOpen ? announce : null, d => names.GetValueOrDefault(d), names[id], witnesses, runStartedAt);
    var adapter = new CloudMemoryAdapter(memory, slot, id, localNow: () => now, keeper: kept, delete: options);
    adapter.FeedRead();
    return new Device { Memory = memory, Adapter = adapter, Id = id, Witness = witness, Kept = kept, Slot = slot, State = state, Requests = requests, Bin = bin };
  }
  private void OpenGate(params Device[] devices)
  {
    gateOpen = true;
    foreach (var d in devices)
      foreach (var id in new[] { A, B })
        d.Memory.PutRow(new("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(CloudDeleteGate.Key(id)), DeckMemoryCell.Text(CloudDeleteGate.Value(now)), DeckMemoryCell.Real(1)]), null);
  }

  private async Task<IReadOnlyList<CloudOperation>> Capture(Device d)
  {
    var capture = await d.Adapter.CaptureAsync(() => now, default);
    capture.Commit();
    return capture.Operations;
  }
  private async Task Deliver(IEnumerable<CloudOperation> ops, Device to, string from)
  {
    foreach (var op in ops) await to.Adapter.ApplyAsync(op, new CloudImportOrigin(from, ++seq, now, false), default);
    await to.Adapter.SettleAsync(default);
  }
  private async Task<IReadOnlyList<CloudOperation>> Sync(Device from, Device to)
  {
    var ops = await Capture(from);
    await Deliver(ops.Where(o => !o.Domain.EndsWith("i05", StringComparison.Ordinal)), to, from.Id);
    return ops;
  }
  private static byte[] T(string text) => Encoding.UTF8.GetBytes(text);
  private static string? Text(Device d, string path) => d.Memory.ReadFile(path) is { } b ? Encoding.UTF8.GetString(b) : null;
  private static CloudMemoryRemoval? MarkerIn(IEnumerable<CloudOperation> ops) =>
    ops.Where(o => o.Domain == "brain/memory/i01").Select(o => CloudMemoryRemoval.Parse(Convert.FromBase64String(((CloudJson.Object)o.Payload)["data"]!.AsString!))).FirstOrDefault(m => m is not null);
  private static IEnumerable<CloudOperation> Files(IEnumerable<CloudOperation> ops) => ops.Where(o => o.Domain == "brain/memory/i01");

  /// Two devices holding the same note (written on A, placed on B).
  private async Task<(Device A, Device B)> Shared(string path = "hoot/notes/plan.md", string text = "# Plan\n")
  {
    var a = Make(A, StoreA);
    var b = Make(B, StoreB);
    a.Memory.WriteFile(path, T(text));
    await Sync(a, b);
    Assert.Equal(text, Text(b, path));
    await Capture(b);
    return (a, b);
  }
  private async Task GoneTwoLooks(Device d)
  {
    await Capture(d);
    now += 4_000;
    await Capture(d);
  }

  [Fact]
  public async Task Two_looks_are_required_before_the_unknown_witness_can_mark_a_file()
  {
    var (_, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Capture(b);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    Assert.Empty(await Capture(b));
    Assert.Empty(await b.Adapter.NotHereAsync());
    now += 1_000;
    Assert.Empty(await Capture(b));
    Assert.Empty(await b.Adapter.NotHereAsync());
    now += 3_000;
    Assert.Empty(await Capture(b));
    var mark = Assert.Single(await b.Adapter.NotHereAsync());
    Assert.Equal((CloudLocalMark.NotOnThisPc, "plan"), (mark.Mark, mark.Item.Name));
  }

  [Fact]
  public async Task A_thousand_files_gone_by_hand_mean_a_thousand_marks_and_nothing_sent()
  {
    var a = Make(A, StoreA);
    var b = Make(B, StoreB);
    for (var i = 0; i < 1000; i++) a.Memory.WriteFile($"hoot/notes/n{i}.md", T("note " + i));
    a.Memory.WriteFile("hoot/keep.md", T("stays"));
    await Sync(a, b);
    await Capture(b);
    for (var i = 0; i < 1000; i++) b.Memory.RemoveFile($"hoot/notes/n{i}.md", CloudMemoryFormat.Hash(T("note " + i)));
    await Capture(b);
    now += 4_000;
    Assert.Empty(await Capture(b));
    Assert.Equal(1000, (await b.Adapter.NotHereAsync()).Count);
    Assert.DoesNotContain(b.Witness.Calls, c => c.Path.Length == 0);
    Assert.Equal("note 7", Text(a, "hoot/notes/n7.md"));
  }

  [Fact]
  public async Task A_missing_root_is_neither_marked_nor_sent()
  {
    var (_, b) = await Shared();
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    Assert.Empty(await b.Adapter.NotHereAsync());
    Assert.Empty(b.Witness.Calls);
  }

  [Fact]
  public async Task Affirmative_AI_witness_deletes_everywhere_with_one_attributed_group()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    b.Witness.Answer = CloudDeleteWitnessAnswer.Ai("Night work", "Integrations", DateTimeOffset.FromUnixTimeMilliseconds(now), Group);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await Capture(b);
    now += 4_000;
    var sent = await Capture(b);
    var marker = MarkerIn(sent);
    Assert.NotNull(marker);
    Assert.True(marker!.ByAi);
    Assert.Equal(B, marker.By);
    var binB = Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal((Group, "Removed by an AI on Office PC", "Night work", "Integrations"), (binB.Id, binB.Title, binB.Session, binB.Agent));
    await Deliver(sent, a, B);
    Assert.Null(Text(a, "hoot/notes/plan.md"));
    var binA = Assert.Single(await a.Adapter.BinGroupsAsync());
    Assert.Equal("plan", Assert.Single(binA.Items).Name);
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task The_witness_is_asked_about_the_narrowest_honest_window()
  {
    var (_, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Capture(b);
    var lastLook = now;
    now += 10_000;
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await Capture(b);
    var firstGone = now;
    now += 4_000;
    await Capture(b);
    var call = Assert.Single(b.Witness.Calls);
    Assert.EndsWith(Path.Combine("files", "hoot/notes/plan.md"), call.Path);
    Assert.Equal((lastLook, firstGone), (call.Seen.ToUnixTimeMilliseconds(), call.Gone.ToUnixTimeMilliseconds()));
  }

  [Fact]
  public async Task A_file_gone_while_the_app_was_not_running_counts_as_by_hand_without_asking()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Capture(b);
    // The app restarts later; the file went while it was not running.
    now += 60_000;
    var again = Make(B, StoreB, reopen: b, runStartedAt: now);
    again.Witness.Answer = CloudDeleteWitnessAnswer.Ai("Night work", null, DateTimeOffset.FromUnixTimeMilliseconds(now), Group);
    again.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await Capture(again);
    now += 4_000;
    Assert.Empty(Files(await Capture(again)));
    Assert.Empty(again.Witness.Calls);
    Assert.Equal(CloudLocalMark.NotOnThisPc, Assert.Single(await again.Adapter.NotHereAsync()).Mark);
    Assert.Equal("# Plan\n", Text(a, "hoot/notes/plan.md"));
  }

  [Fact]
  public async Task A_stale_witness_cannot_delete_a_file_that_has_returned()
  {
    var (_, b) = await Shared();
    b.Witness.Answer = CloudDeleteWitnessAnswer.Ai("Night work", null, DateTimeOffset.FromUnixTimeMilliseconds(now), Group);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Capture(b);
    b.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\n"));
    now += 4_000;
    Assert.Null(MarkerIn(await Capture(b)));
    Assert.Empty(b.Witness.Calls);
    Assert.Equal("# Plan\n", Text(b, "hoot/notes/plan.md"));
  }

  [Fact]
  public async Task A_local_absence_survives_new_Cloud_versions_and_a_reopen()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\nedited on the Mac\n"));
    now += 1_000;
    await Sync(a, b);
    Assert.Null(Text(b, "hoot/notes/plan.md"));
    var reopened = Make(B, StoreB, reopen: b);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\nedited twice\n"));
    now += 1_000;
    await Sync(a, reopened);
    Assert.Null(Text(reopened, "hoot/notes/plan.md"));
    Assert.Single(await reopened.Adapter.NotHereAsync());
    Assert.Empty(Files(await Capture(reopened)));
  }

  [Fact]
  public async Task A_bring_back_places_the_Clouds_newest_and_sends_nothing()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan v2\n"));
    now += 1_000;
    await Sync(a, b);
    var item = Assert.Single(await b.Adapter.NotHereAsync()).Item;
    Assert.Single(await b.Adapter.BringBackAsync([item], CloudBringBackDestination.ThisPc));
    Assert.Equal("# Plan v2\n", Text(b, "hoot/notes/plan.md"));
    Assert.Empty(Files(await Capture(b)));
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task Reappearing_newest_bytes_clear_the_mark_without_sending()
  {
    var (_, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Capture(b);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    b.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\n"));
    Assert.Empty(Files(await Capture(b)));
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task Reappearing_earlier_bytes_do_not_roll_back_a_newer_Cloud_edit()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan newer\n"));
    now += 1_000;
    await Sync(a, b);
    // A branch switch puts the old bytes back.
    b.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\n"));
    Assert.Empty(Files(await Capture(b)));
    Assert.Equal("# Plan newer\n", Text(b, "hoot/notes/plan.md"));
    Assert.Empty(await b.Adapter.NotHereAsync());
    Assert.Equal("# Plan newer\n", Text(a, "hoot/notes/plan.md"));
  }

  [Fact]
  public async Task Reappearing_new_bytes_are_his_new_version_on_top_of_the_newest_Cloud_version()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan newer\n"));
    now += 1_000;
    await Sync(a, b);
    b.Memory.WriteFile("hoot/notes/plan.md", T("# His new text\n"));
    now += 1_000;
    var sent = await Sync(b, a);
    Assert.NotEmpty(Files(sent));
    Assert.Equal("# His new text\n", Text(a, "hoot/notes/plan.md"));
    Assert.Empty(await b.Adapter.NotHereAsync());
    // The Cloud's text he wrote over is kept on this PC.
    Assert.Contains(b.Kept.Kept, k => Encoding.UTF8.GetString(k.Bytes) == "# Plan newer\n");
  }

  [Fact]
  public async Task Cloud_scope_keeps_both_copies_and_an_explicit_return_publishes_the_local_text()
  {
    var a = Make(A, StoreA);
    var b = Make(B, StoreB);
    OpenGate(a, b);
    a = Make(A, StoreA, reopen: a);
    b = Make(B, StoreB, reopen: b);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\n"));
    a.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(a, b);
    await Capture(b);
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    var group = await a.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudDeleteScope.Cloud, actor);
    Assert.Equal("Removed on Mac mini", group.Title);
    var sent = await Sync(a, b);
    var marker = MarkerIn(sent)!;
    Assert.Equal("cloud", marker.Travel[CloudDeleteTravel.Scope]);
    Assert.Equal("# Plan\n", Text(a, "hoot/notes/plan.md"));
    Assert.Equal("# Plan\n", Text(b, "hoot/notes/plan.md"));
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, Assert.Single(await a.Adapter.NotHereAsync()).Mark);
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, Assert.Single(await b.Adapter.NotHereAsync()).Mark);
    // Never captured again by itself, even after an edit here.
    b.Memory.WriteFile("hoot/notes/plan.md", T("# Plan, only here\n"));
    now += 1_000;
    Assert.Empty(Files(await Capture(b)));
    // "Put in Cloud again" on the Mac: its text goes on top of the removal; the PC keeps its own text and takes it.
    Assert.Single(await a.Adapter.BringBackAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudBringBackDestination.Cloud));
    now += 1_000;
    await Sync(a, b);
    Assert.Equal("# Plan\n", Text(b, "hoot/notes/plan.md"));
    Assert.Empty(await a.Adapter.NotHereAsync());
    Assert.Empty(await b.Adapter.NotHereAsync());
    Assert.Contains(b.Kept.Kept, k => Encoding.UTF8.GetString(k.Bytes) == "# Plan, only here\n");
  }

  [Fact]
  public async Task A_closed_gate_refuses_Cloud_scope_and_sends_a_compatible_everywhere()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, B, "Office PC", null, null, now, Group);
    await Assert.ThrowsAsync<InvalidOperationException>(() => b.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudDeleteScope.Cloud, actor));
    Assert.Equal("# Plan\n", Text(b, "hoot/notes/plan.md"));
    await b.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudDeleteScope.Everywhere, actor);
    Assert.Null(Text(b, "hoot/notes/plan.md"));
    var sent = await Sync(b, a);
    var marker = MarkerIn(sent)!;
    Assert.Empty(marker.Travel);
    Assert.Null(Text(a, "hoot/notes/plan.md"));
    Assert.Equal(CloudBinEra.OlderVersion, Assert.Single(await a.Adapter.BinGroupsAsync()).Era);
    Assert.Empty(Files(await Capture(b)));
  }

  [Fact]
  public async Task An_open_gate_sends_the_six_fields_and_the_other_device_groups_by_them()
  {
    var a0 = Make(A, StoreA);
    var b0 = Make(B, StoreB);
    OpenGate(a0, b0);
    var a = Make(A, StoreA, reopen: a0);
    var b = Make(B, StoreB, reopen: b0);
    a.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\n"));
    a.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(a, b);
    await Capture(b);
    var actor = new CloudDeleteActor(CloudDeleteBy.Ai, B, "Office PC", "Night work", "Integrations", now, Group);
    await b.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudDeleteScope.Everywhere, actor);
    var marker = MarkerIn(await Sync(b, a))!;
    Assert.Equal(("1", "everywhere", "ai", Group), (marker.Travel[CloudDeleteTravel.Rule], marker.Travel[CloudDeleteTravel.Scope], marker.Travel[CloudDeleteTravel.By], marker.Travel[CloudDeleteTravel.Group]));
    Assert.Null(Text(a, "hoot/notes/plan.md"));
    var group = Assert.Single(await a.Adapter.BinGroupsAsync());
    Assert.Equal((Group, "Removed by an AI on Office PC", "Night work"), (group.Id, group.Title, group.Session));
  }

  [Fact]
  public async Task An_edit_made_on_top_wins_over_a_removal_of_the_earlier_version()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/plan.md", T("# Plan\nedited on the PC\n"));
    now += 1_000;
    await Capture(b);
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    a.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await a.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudDeleteScope.Everywhere, actor);
    await Sync(a, b);
    Assert.Equal("# Plan\nedited on the PC\n", Text(b, "hoot/notes/plan.md"));
    Assert.Empty(await b.Adapter.BinGroupsAsync());
  }

  [Fact]
  public async Task A_malformed_new_marker_never_falls_back_to_an_everywhere_delete()
  {
    var (a, b) = await Shared();
    const string key = "file/hoot/notes/plan.md";
    var parent = CloudMemoryFormat.Uuid(StoreA + ":" + key + "\n" + CloudMemoryFormat.Hash(T("# Plan\n")));
    foreach (var bad in new[] { "td_delete_rule: 2\ntd_scope: everywhere\ntd_by: person\ntd_group: " + Group, "td_delete_rule: 1\ntd_scope: sideways\ntd_by: person\ntd_group: " + Group,
      "td_delete_rule: 1\ntd_scope: everywhere\ntd_by: person\ntd_group: not-a-uuid" })
    {
      var marker = T("---\ntd_removed: 1900000000000\ntd_removed_by: " + A + "\n" + bad + "\n---\n# Removed: plan\n");
      var hash = CloudMemoryFormat.Hash(marker);
      var op = CloudMemoryFormat.Operation(new(StoreA, "I01", key, CloudMemoryFormat.Uuid(parent + "\n" + hash), hash, marker.Length, 0, 1, [parent],
        Convert.ToBase64String(marker), now, false), A, [], now);
      await Deliver([op], b, A);
      Assert.Equal("# Plan\n", Text(b, "hoot/notes/plan.md"));
    }
    Assert.Empty(await b.Adapter.BinGroupsAsync());
    _ = a;
  }

  [Fact]
  public async Task A_Not_on_this_PC_mark_goes_when_another_device_removes_the_place_everywhere()
  {
    var (a, b) = await Shared();
    b.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(b, a);
    b.Memory.RemoveFile("hoot/notes/plan.md", CloudMemoryFormat.Hash(T("# Plan\n")));
    await GoneTwoLooks(b);
    Assert.Single(await b.Adapter.NotHereAsync());
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await a.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")], CloudDeleteScope.Everywhere, actor);
    await Sync(a, b);
    Assert.Empty(await b.Adapter.NotHereAsync());
  }

  [Fact]
  public async Task Put_back_all_restores_the_group_and_sends_it_on_top_of_the_removal()
  {
    var (a, b) = await Shared();
    a.Memory.WriteFile("hoot/notes/second.md", T("# Second\n"));
    a.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(a, b);
    await Capture(b);
    var actor = new CloudDeleteActor(CloudDeleteBy.Ai, A, "Mac mini", "Night work", null, now, Group);
    var group = await a.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md"), CloudMemoryAdapter.Item("hoot/notes/second.md")], CloudDeleteScope.Everywhere, actor);
    Assert.Equal(2, group.Count);
    now += 1_000;
    await Sync(a, b);
    Assert.Null(Text(b, "hoot/notes/second.md"));
    var held = Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal(2, held.Count);
    var back = await b.Adapter.PutBackGroupAsync(held.Id);
    Assert.Equal(2, back.Count);
    Assert.Empty(await b.Adapter.BinGroupsAsync());
    now += 1_000;
    await Sync(b, a);
    Assert.Equal("# Plan\n", Text(a, "hoot/notes/plan.md"));
    Assert.Equal("# Second\n", Text(a, "hoot/notes/second.md"));
    Assert.Equal("# Plan\n", Text(b, "hoot/notes/plan.md"));
  }

  [Fact]
  public async Task Bin_groups_resolve_device_names_and_delete_for_good_takes_only_the_chosen_rows()
  {
    var (a, b) = await Shared();
    a.Memory.WriteFile("hoot/notes/second.md", T("# Second\n"));
    a.Memory.WriteFile("hoot/notes/other.md", T("keeps the root"));
    await Sync(a, b);
    await Capture(b);
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, A, "Mac mini", null, null, now, Group);
    await a.Adapter.DeleteItemsAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md"), CloudMemoryAdapter.Item("hoot/notes/second.md")], CloudDeleteScope.Everywhere, actor);
    await Sync(a, b);
    var group = Assert.Single(await b.Adapter.BinGroupsAsync());
    Assert.Equal("Removed on Mac mini (older version)", group.Title);
    await b.Adapter.DeleteForGoodAsync([CloudMemoryAdapter.Item("hoot/notes/plan.md")]);
    Assert.Equal("second", Assert.Single(Assert.Single(await b.Adapter.BinGroupsAsync()).Items).Name);
  }
}
