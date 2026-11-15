using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane F: the 15 Nov delete rule in the Cloud folder and artifacts, case for case the Mac's CloudFolderDeleteRuleTests.swift
// (+ its CloudArtifactsDeleteRuleTests). Left out on purpose: the four "migration" cases (Windows never had a Cloud folder
// before the rule, so there is no older state to switch over) and the Mac's receipt verification (the Windows sync has no
// receipt step; the same cases check what was placed instead).
public sealed class CloudFolderRuleWitness(CloudDeleteWitnessAnswer answer) : ICloudDeleteWitness
{
  private readonly object gate = new();
  public List<string> Paths { get; } = [];
  public List<(DateTimeOffset LastSeen, DateTimeOffset Gone)> Times { get; } = [];
  public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt)
  {
    lock (gate) { Paths.Add(removedPath); Times.Add((lastSeen, seenGoneAt)); }
    return Task.FromResult(answer);
  }
}

public sealed class CloudFolderDeleteRuleTests
{
  private static CloudDeleteActor Actor(CloudFolderFixture f, CloudDeleteBy by = CloudDeleteBy.Person) =>
    new(by, f.DeviceA, "Mac mini", by == CloudDeleteBy.Ai ? "Night work" : null, by == CloudDeleteBy.Ai ? "Reviewer" : null, f.Clock.Ms, Guid.NewGuid().ToString("D"));
  private static CloudDeleteItem Item(string path) => new(path, "cloudFolder", Path.GetFileName(path), path);
  private static CloudFolderRuleWitness Install(CloudDeleteWitnessAnswer answer, CloudFolderOwner owner)
  {
    var witness = new CloudFolderRuleWitness(answer);
    var slot = new CloudDeleteWitnessSlot();
    Assert.True(slot.InstallOnce(witness));
    owner.SetDeleteWitness(slot);
    return witness;
  }

  [Fact]
  public async Task Hundreds_gone_by_hand_are_marks_with_no_journal_no_bin_and_no_question()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "stays.md", "root is here");
    for (var n = 0; n < 240; n++) f.Write("a", "f" + n + ".md", n.ToString(System.Globalization.CultureInfo.InvariantCulture));
    await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    var witness = Install(CloudDeleteWitnessAnswer.NotAi, a);
    for (var n = 0; n < 240; n++) f.Remove("a", "f" + n + ".md");
    await f.Settle(a);
    Assert.Equal(240, (await a.NotHereAsync()).Count);
    Assert.All(await a.NotHereAsync(), m => Assert.Equal(CloudLocalMark.NotOnThisPc, m.Mark));
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
    Assert.Empty(a.Bin());
    Assert.Null(a.WaitingAnswer());
    Assert.Equal(240, witness.Paths.Count);
    Assert.All(witness.Times, t => Assert.True(t.LastSeen <= t.Gone));
    await a.SendNowAsync(); await a.LookAsync();
    Assert.Equal(240, witness.Paths.Count);
    Assert.Null(f.Text("a", "f0.md"));
  }

  [Fact]
  public async Task An_unknown_witness_is_local_and_the_mark_survives_restart_and_newer_arrivals()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "stay.md", "s"); f.Write("a", "note.md", "one"); await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    f.Remove("a", "note.md"); await f.Settle(a);
    f.Clock.Advance(120_000); f.Write("b", "note.md", "two"); await f.Settle(b);
    await f.Send(b, f.DeviceB, a, fromB);
    var reopened = f.Mac("a", f.DeviceA);
    await f.Settle(reopened); await reopened.SendNowAsync();
    Assert.Null(f.Text("a", "note.md"));
    Assert.Equal(["note.md"], (await reopened.NotHereAsync()).Select(m => m.Item.Id));
    await reopened.BringBackAsync([Item("note.md")], CloudBringBackDestination.ThisPc);
    Assert.Equal("two", f.Text("a", "note.md"));
    Assert.Empty(await reopened.NotHereAsync());
  }

  [Fact]
  public async Task Empty_missing_or_unreadable_root_creates_no_marks_and_sends_nothing()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "one.md", "one"); await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    f.Remove("a", "one.md"); await f.Settle(a);
    Assert.Empty(await a.NotHereAsync());
    Assert.True(a.WaitingAnswer()?.FolderMissing);
    Directory.Delete(f.Folder("a"), recursive: true); await f.Settle(a);
    Assert.Empty(await a.NotHereAsync());
    // A regular file at the root path is reliably unreadable as a folder.
    File.WriteAllText(f.Folder("a"), "not a folder"); await f.Settle(a);
    Assert.Empty(await a.NotHereAsync());
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
  }

  [Fact]
  public async Task First_absent_look_and_editor_rewrite_never_become_a_delete()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "stay.md", "s"); f.Write("a", "note.md", "one"); await f.Settle(a);
    var witness = Install(CloudDeleteWitnessAnswer.NotAi, a);
    f.Remove("a", "note.md"); await a.LookAsync();
    Assert.Empty(await a.NotHereAsync()); Assert.Empty(witness.Paths);
    f.Write("a", "note.md", "one"); f.Clock.Advance(4_000); await a.LookAsync();
    Assert.Empty(await a.NotHereAsync()); Assert.Empty(witness.Paths);
  }

  [Fact]
  public async Task Witnessed_AI_uses_everywhere_and_one_group_for_its_whole_command()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.SetDeleteRuleGate(() => true);
    f.Write("a", "stay.md", "s");
    for (var n = 0; n < 60; n++) f.Write("a", "f" + n + ".md", "file " + n);
    await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    var group = Guid.NewGuid().ToString("D");
    Install(CloudDeleteWitnessAnswer.Ai("Night work", "Reviewer", DateTimeOffset.UtcNow, group), a);
    for (var n = 0; n < 60; n++) f.Remove("a", "f" + n + ".md");
    await f.Settle(a);
    var operations = await f.Send(a, f.DeviceA, b, cursor);
    Assert.Equal(60, operations.Count(op => op.Kind == "archive"));
    Assert.Equal(60, operations.Count(CloudFileDeleteRecords.IsAbout));
    Assert.Equal(60, b.Bin().Count);
    var bin = (await b.BinGroupsAsync()).First();
    Assert.True(bin.Id == group && bin.By == CloudDeleteBy.Ai && bin.Session == "Night work" && bin.Count == 60);
    Assert.Null(b.WaitingAnswer());
    Assert.Null(f.Text("b", "f59.md"));
  }

  [Fact]
  public async Task Cloud_scope_keeps_both_devices_and_put_in_cloud_again_publishes_this_devices_bytes()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.SetDeleteRuleGate(() => true); b.SetDeleteRuleGate(() => true);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Cloud, Actor(f));
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.True(f.Text("a", "note.md") == "one" && f.Text("b", "note.md") == "one");
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, (await a.NotHereAsync()).First().Mark);
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, (await b.NotHereAsync()).First().Mark);
    var before = CloudFolderFixture.Journal(b).Count;
    f.Clock.Advance(120_000); f.Write("b", "note.md", "B's bytes"); await f.Settle(b);
    Assert.Equal(before, CloudFolderFixture.Journal(b).Count);
    await b.BringBackAsync([Item("note.md")], CloudBringBackDestination.Cloud);
    await f.Send(b, f.DeviceB, a, fromB);
    Assert.Equal("B's bytes", f.Text("a", "note.md"));
    Assert.Empty(await a.NotHereAsync());
    Assert.Empty(await b.NotHereAsync());
    Assert.NotEmpty(a.Versions("note.md"));
  }

  [Fact]
  public async Task Closed_gate_refuses_cloud_and_sends_everywhere_in_old_form()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    await Assert.ThrowsAnyAsync<Exception>(() => a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Cloud, Actor(f)));
    Assert.Equal("one", f.Text("a", "note.md"));
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Everywhere, Actor(f, CloudDeleteBy.Ai));
    var operations = await f.Send(a, f.DeviceA, b, cursor);
    Assert.DoesNotContain(operations, CloudFileDeleteRecords.IsAbout);
    Assert.Null(f.Text("b", "note.md"));
    Assert.Equal(CloudBinEra.OlderVersion, (await b.BinGroupsAsync()).First().Era);
  }

  [Fact]
  public async Task Reappearing_earlier_own_version_uses_newest_and_unknown_bytes_become_new_head()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    f.Write("a", "stay.md", "s"); f.Write("a", "note.md", "old A"); await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    f.Remove("a", "note.md"); await f.Settle(a);
    f.Clock.Advance(120_000); f.Write("b", "note.md", "new B"); await f.Settle(b);
    await f.Send(b, f.DeviceB, a, fromB);
    var before = CloudFolderFixture.Journal(a).Count;
    f.Write("a", "note.md", "old A"); await f.Settle(a);
    Assert.Equal("new B", f.Text("a", "note.md"));
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
    f.Remove("a", "note.md"); await f.Settle(a);
    f.Write("a", "note.md", "brand new", f.Clock.Ms - 1_000_000);
    await f.Settle(a);
    Assert.Equal("brand new", f.Text("a", "note.md"));
    Assert.True(CloudFolderFixture.Journal(a).Count > before);
    Assert.Empty(await a.NotHereAsync());
  }

  [Fact]
  public async Task Reappearing_newest_bytes_clear_only_the_mark()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "stay.md", "s"); f.Write("a", "note.md", "one"); await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    f.Remove("a", "note.md"); await f.Settle(a);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    Assert.Empty(await a.NotHereAsync());
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
  }

  [Fact]
  public async Task Explicit_intent_and_bin_are_durable_before_the_file_goes()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    var who = Actor(f);
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Everywhere, who);
    Assert.Null(f.Text("a", "note.md"));
    Assert.Equal(f.Clock.Ms + CloudBinGroup.RetentionMilliseconds, a.Bin().First().KeptUntil);
    Assert.Null(a.PendingDeleteIntent("note.md"));
    var groups = await a.BinGroupsAsync();
    Assert.Equal(who.Group, groups.First().Id);
    Assert.Single(await a.PutBackGroupAsync(who.Group));
    Assert.Equal("one", f.Text("a", "note.md"));
  }

  /// Windows: the once-only switch-over has nothing to switch (no Cloud folder before the rule); a look marks it done
  /// and sends or marks nothing.
  [Fact]
  public async Task The_switch_over_has_nothing_to_do_on_this_PC()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    f.Write("a", "stay.md", "s"); await f.Settle(a);
    var before = CloudFolderFixture.Journal(a).Count;
    await a.LookAsync();
    Assert.Equal("1", a.Control("deleteRuleMigrated"));
    Assert.Empty(await a.NotHereAsync());
    Assert.Equal(before, CloudFolderFixture.Journal(a).Count);
  }

  [Fact]
  public async Task Sidecar_survives_a_pack_boundary_and_malformed_new_fields_are_refused()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.SetDeleteRuleGate(() => true);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Cloud, Actor(f));
    var engine = a.Core();
    var raw = engine.JournalAfter(cursor.Seq).SelectMany(engine.Operations).ToArray();
    var expanded = a.TravelOperations(raw);
    Assert.Equal(2, expanded.Count);
    foreach (var operation in expanded) await f.Apply(b, [operation], f.DeviceA);
    Assert.Equal("one", f.Text("b", "note.md"));
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, (await b.NotHereAsync()).First().Mark);
    var about = CloudFileDeleteRecords.Read(expanded[0]);
    Assert.NotNull(about);
    var fields = about!.Fields.ToDictionary(x => x.Key, x => x.Value);
    fields[CloudDeleteTravel.Scope] = "wrong";
    var error = Assert.Throws<CloudDeleteRuleException>(() => CloudDeleteTravel.Read(fields, "note.md", f.DeviceA, f.Clock.Ms));
    Assert.Equal(CloudDeleteRuleException.InvalidTravelFields, error.Code);
  }

  [Fact]
  public async Task Cloud_scope_preserves_different_unsent_edits_on_both_devices()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.SetDeleteRuleGate(() => true);
    f.Write("a", "note.md", "Cloud bytes"); await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    f.Write("a", "note.md", "A's unsent bytes");
    f.Write("b", "note.md", "B's unsent bytes");
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Cloud, Actor(f));
    var records = await f.Send(a, f.DeviceA, b, cursor);
    Assert.DoesNotContain(records, op => op.Kind == "put" && !CloudFileDeleteRecords.IsAbout(op));
    Assert.Equal("A's unsent bytes", f.Text("a", "note.md"));
    Assert.Equal("B's unsent bytes", f.Text("b", "note.md"));
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, (await b.NotHereAsync()).First().Mark);
    Assert.Empty(CloudFolderFixture.Journal(b));
  }

  [Fact]
  public async Task Modern_metadata_leaves_the_removal_readable_by_the_installed_decoder()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA);
    a.SetDeleteRuleGate(() => true);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Everywhere, Actor(f));
    var raw = CloudFolderFixture.Journal(a).Where(op => op.Kind == "archive").ToArray();
    var records = a.TravelOperations(raw);
    var marker = (CloudJson.Object)records[^1].Payload;
    Assert.All(marker.Members, m => Assert.Contains(m.Key, CloudBootFilesFormat.MarkerKeys));
    Assert.StartsWith("about/", records[0].Source.RecordId, StringComparison.Ordinal);
  }

  [Fact]
  public async Task A_put_and_removal_in_one_pack_end_in_the_bin()
  {
    using var f = new CloudFolderFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.SetDeleteRuleGate(() => true);
    f.Write("a", "note.md", "one"); await f.Settle(a);
    await a.DeleteItemsAsync([Item("note.md")], CloudDeleteScope.Everywhere, Actor(f));
    var records = a.TravelOperations(CloudFolderFixture.Journal(a));
    await f.Apply(b, records, f.DeviceA);
    Assert.Null(f.Text("b", "note.md"));
    Assert.Single(b.Bin());
  }
}

public sealed class CloudArtifactsDeleteRuleTests
{
  private static CloudDeleteItem Item(string path) => new(path, CloudFileKind.Artifacts.KeeperKind, Path.GetFileName(path), path);

  [Fact]
  public async Task Deleting_from_the_project_or_aging_out_never_infers_a_removal()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA);
    await a.FeedAsync([f.Make("a", "one.md", "one")]); await f.Settle(a);
    var before = CloudArtifactsFixture.Journal(a).Count;
    File.Delete(Path.Combine(f.Project("a"), "one.md"));
    f.Clock.Advance(40 * CloudFolderFormat.Day); await a.FeedAsync([]); await f.Settle(a);
    Assert.Single(a.Items());
    Assert.Equal(before, CloudArtifactsFixture.Journal(a).Count);
  }

  [Fact]
  public async Task By_hand_inside_the_store_is_a_mark_and_feed_never_recreates_it()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    await a.FeedAsync([f.Make("a", "stay.md", "stays"), f.Make("a", "gone.md", "gone")]); await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    File.Delete(Path.Combine(f.Store("a"), "site", "gone.md"));
    await f.Settle(a);
    Assert.Equal(["site/gone.md"], (await a.NotHereAsync()).Select(m => m.Item.Id));
    Assert.Empty(await f.Send(a, f.DeviceA, b, cursor));
    Assert.Equal(2, b.Items().Count);
    f.Clock.Advance(120_000);
    await a.FeedAsync([f.Make("a", "gone.md", "edited project copy")]);
    Assert.DoesNotContain(a.Items(), i => i.Path == "site/gone.md");
    Assert.Empty(a.Bin());
  }

  [Fact]
  public async Task Delete_from_list_is_everywhere_and_groups_the_description_with_its_artifact()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.Owner.SetDeleteRuleGate(() => true);
    await a.FeedAsync([f.Make("a", "one.md", "one")]); await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    Assert.True(await a.RemoveAsync("site/one.md"));
    var operations = await f.Send(a, f.DeviceA, b, cursor);
    Assert.Equal(2, operations.Count(op => op.Kind == "archive"));
    Assert.Empty(b.Items());
    Assert.Equal(1, (await b.BinGroupsAsync()).First().Count);
    var groups = operations.Where(CloudFileDeleteRecords.IsAbout).Select(op => CloudFileDeleteRecords.Read(op)!.Fields[CloudDeleteTravel.Group]).ToHashSet();
    Assert.Single(groups);
    Assert.True(File.Exists(Path.Combine(f.Project("a"), "one.md")));
  }

  [Fact]
  public async Task Cloud_scope_preserves_both_stores_including_descriptions_and_explicitly_rejoins()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.Owner.SetDeleteRuleGate(() => true); b.Owner.SetDeleteRuleGate(() => true);
    await a.FeedAsync([f.Make("a", "one.md", "one")]); await f.Settle(a);
    CloudFolderCursor fromA = new(), fromB = new();
    await f.Send(a, f.DeviceA, b, fromA);
    var actor = new CloudDeleteActor(CloudDeleteBy.Ai, f.DeviceA, "Mac mini", "Explicit cloud scope", null, f.Clock.Ms, Guid.NewGuid().ToString("D"));
    await a.DeleteItemsAsync([Item("site/one.md")], CloudDeleteScope.Cloud, actor);
    await f.Send(a, f.DeviceA, b, fromA);
    Assert.Single(a.Items());
    Assert.Single(b.Items());
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, (await b.NotHereAsync()).First().Mark);
    await b.BringBackAsync([Item("site/one.md")], CloudBringBackDestination.Cloud);
    await f.Send(b, f.DeviceB, a, fromB);
    Assert.Empty(await a.NotHereAsync());
    Assert.Empty(await b.NotHereAsync());
    Assert.Equal("one.md", a.Items().First().Name);
  }

  [Fact]
  public async Task A_witnessed_store_removal_travels_as_AI_without_touching_its_project_original()
  {
    using var f = new CloudArtifactsFixture();
    var a = f.Mac("a", f.DeviceA); var b = f.Mac("b", f.DeviceB);
    a.Owner.SetDeleteRuleGate(() => true);
    await a.FeedAsync([f.Make("a", "stay.md", "stays"), f.Make("a", "gone.md", "gone")]); await f.Settle(a);
    var cursor = new CloudFolderCursor();
    await f.Send(a, f.DeviceA, b, cursor);
    var slot = new CloudDeleteWitnessSlot();
    Assert.True(slot.InstallOnce(new CloudFolderRuleWitness(CloudDeleteWitnessAnswer.Ai("Night", "Reviewer", DateTimeOffset.UtcNow, Guid.NewGuid().ToString("D")))));
    a.Owner.SetDeleteWitness(slot);
    File.Delete(Path.Combine(f.Store("a"), "site", "gone.md"));
    await f.Settle(a);
    await f.Send(a, f.DeviceA, b, cursor);
    Assert.DoesNotContain(b.Items(), i => i.Path == "site/gone.md");
    Assert.Equal(CloudDeleteBy.Ai, (await b.BinGroupsAsync()).First().By);
    Assert.True(File.Exists(Path.Combine(f.Project("a"), "gone.md")));
  }
}
