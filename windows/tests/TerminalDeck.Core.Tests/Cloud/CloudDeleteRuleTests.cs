using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The shared delete-rule types, case for case from the Mac's CloudDeleteRuleTests.swift (td-mac-next2), plus the
// announcement writer (MemoryDeleteRuleReviewTests: anAnnouncementThatWaitedForTheClockIsWrittenByTheNextStep,
// existingAnnouncementWriterDeduplicatesAndForceRenews) and the keeper Bin. Windows keeps marks and intents in one
// atomic file per owner, not in SQLite tables, so the Mac's three database-attachment cases become the reopen case.
public sealed class CloudDeleteRuleTests : IDisposable
{
  private const long Now = 1_900_000_000_000;
  private const string Mac = "A4D541C1-B289-410D-828A-5028D805632F", OtherMac = "5d0a2d02-dd37-49e8-89a7-d71b5c5d4402";
  private const string Group = "dd1c167a-86a7-4503-93ed-7c537acbfc09";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-delete-rule-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private static CloudDeleteIntent Intent(CloudDeleteScope scope = CloudDeleteScope.Everywhere, CloudDeleteBy by = CloudDeleteBy.Ai) =>
    new("notes/plan.md", scope, by, Mac, "Night work", "Integrations", Now, Group);

  [Fact]
  public void Memory_marker_round_trips_both_scopes_and_authors_using_the_same_six_fields()
  {
    foreach (var scope in new[] { CloudDeleteScope.Everywhere, CloudDeleteScope.Cloud })
      foreach (var by in new[] { CloudDeleteBy.Person, CloudDeleteBy.Ai })
      {
        var original = Intent(scope, by);
        var travel = new Dictionary<string, string>();
        CloudDeleteTravel.Write(original, travel);
        var text = new CloudMemoryRemoval(Now, Mac, null, true, travel).Text("n-1", "Plan");
        var parsed = CloudMemoryRemoval.Parse(System.Text.Encoding.UTF8.GetBytes(text))!;
        Assert.Equal(original, CloudDeleteTravel.Read(parsed.Travel, original.Place, Mac, Now).Intent);
        Assert.Equal((Now, true), (parsed.At, parsed.ByAi));
      }
  }

  [Fact]
  public void Sealed_file_payload_round_trips_and_keeps_existing_fields()
  {
    var original = Intent(CloudDeleteScope.Cloud);
    var payload = new Dictionary<string, string> { ["path"] = original.Place, ["origin_device"] = Mac, ["created_at"] = Now.ToString() };
    CloudDeleteTravel.Write(original, payload);
    Assert.Equal(original, CloudDeleteTravel.Read(payload, original.Place, Mac, Now).Intent);
    Assert.Equal(original.Place, payload["path"]);
    Assert.Equal(new HashSet<string> { "td_delete_rule", "td_scope", "td_by", "td_session", "td_agent", "td_group" }, CloudDeleteTravel.Fields.ToHashSet());
  }

  [Fact]
  public void A_new_write_clears_names_left_over_from_another_intent()
  {
    var fields = new Dictionary<string, string> { ["td_session"] = "Old session", ["td_agent"] = "Old agent" };
    var original = new CloudDeleteIntent("file", CloudDeleteScope.Everywhere, CloudDeleteBy.Person, Mac, null, null, Now, Group);
    CloudDeleteTravel.Write(original, fields);
    Assert.False(fields.ContainsKey("td_session") || fields.ContainsKey("td_agent"));
    Assert.Equal(original, CloudDeleteTravel.Read(fields, "file", Mac, Now).Intent);
  }

  [Fact]
  public void Absence_of_the_rule_field_alone_means_older_version_in_both_carriers()
  {
    foreach (var fields in new[] { new Dictionary<string, string> { ["td_removed"] = Now.ToString(), ["td_removed_by"] = Mac }, new() { ["path"] = "file", ["td_scope"] = "cloud" } })
      Assert.True(CloudDeleteTravel.Read(fields, "file", Mac, Now).IsOlderVersion);
  }

  [Fact]
  public void Malformed_new_fields_never_become_an_older_everywhere_delete()
  {
    var fields = new Dictionary<string, string>();
    CloudDeleteTravel.Write(Intent(), fields);
    foreach (var key in new[] { CloudDeleteTravel.Scope, CloudDeleteTravel.By, CloudDeleteTravel.Group, CloudDeleteTravel.Rule })
    {
      var invalid = new Dictionary<string, string>(fields) { [key] = "unknown" };
      var e = Assert.Throws<CloudDeleteRuleException>(() => CloudDeleteTravel.Read(invalid, "file", Mac, Now));
      Assert.Equal(CloudDeleteRuleException.InvalidTravelFields, e.Code);
    }
  }

  [Fact]
  public void Gate_opens_for_every_fresh_computer_and_canonicalises_device_case()
  {
    var announcements = new Dictionary<string, string> { [CloudDeleteGate.Key(Mac)] = CloudDeleteGate.Value(Now), [CloudDeleteGate.Key(OtherMac)] = CloudDeleteGate.Value(Now - 1000) };
    Assert.Equal("onerule.understands.deleterule." + Mac.ToLowerInvariant(), CloudDeleteGate.Key(Mac));
    Assert.Equal("v1:1900000000000", CloudDeleteGate.Value(Now));
    Assert.True(CloudDeleteGate.IsOpen([Mac, OtherMac], announcements, Now));
  }

  [Fact]
  public void Gate_closes_for_an_unannounced_computer_or_unknown_account_or_clock()
  {
    var announcements = new Dictionary<string, string> { [CloudDeleteGate.Key(Mac)] = CloudDeleteGate.Value(Now) };
    Assert.False(CloudDeleteGate.IsOpen([Mac, OtherMac], announcements, Now));
    Assert.False(CloudDeleteGate.IsOpen(null, announcements, Now));
    Assert.False(CloudDeleteGate.IsOpen([], announcements, Now));
    Assert.False(CloudDeleteGate.IsOpen([Mac], announcements, null));
    Assert.False(CloudDeleteGate.IsOpen([Mac], announcements, 0));
  }

  [Fact]
  public void None_explicitly_exempts_a_computer_without_exempting_other_missing_computers()
  {
    var announcements = new Dictionary<string, string> { [CloudDeleteGate.Key(Mac)] = CloudDeleteGate.Value(Now), [CloudDeleteGate.Key(OtherMac)] = CloudDeleteGate.None };
    Assert.True(CloudDeleteGate.IsOpen([Mac, OtherMac], announcements, Now));
    Assert.False(CloudDeleteGate.IsOpen([Mac, OtherMac, "unannounced"], announcements, Now));
    Assert.True(CloudDeleteGate.IsOpen([OtherMac], announcements, Now));
  }

  [Fact]
  public void Gate_includes_exactly_three_days_but_rejects_older_future_malformed_and_unknown_formats()
  {
    var key = CloudDeleteGate.Key(Mac);
    Assert.True(CloudDeleteGate.IsOpen([Mac], new Dictionary<string, string> { [key] = CloudDeleteGate.Value(Now - CloudDeleteGate.FreshFor) }, Now));
    foreach (var raw in new[] { CloudDeleteGate.Value(Now - CloudDeleteGate.FreshFor - 1), CloudDeleteGate.Value(Now + 1), "v1:0", "v1:-1", "v1:garbage", "v2:1900000000000", "none:1900000000000" })
      Assert.False(CloudDeleteGate.IsOpen([Mac], new Dictionary<string, string> { [key] = raw }, Now));
  }

  [Fact]
  public void Marks_and_intents_survive_reopening_the_owners_state()
  {
    var slot = new CloudFileSlot(Path.Combine(scratch, "delete.json"));
    var original = Intent();
    var missing = new CloudDeleteMark(original.Place, CloudLocalMark.NotOnThisPc, Now);
    var local = new CloudDeleteMark("private.md", CloudLocalMark.OnlyOnThisPc, Now + 1);
    var first = new CloudDeleteState(slot);
    first.PutIntent(original); first.PutMark(missing); first.PutMark(local);
    var state = new CloudDeleteState(slot);
    Assert.Equal(original, state.Intent(original.Place));
    Assert.Equal([missing, local], state.Marks());
    // Reading, and writing a new intent for the place, do not clear a local suppression mark.
    state.PutIntent(Intent(CloudDeleteScope.Cloud));
    Assert.Equal(missing, state.Mark(original.Place));
    state.ClearIntent(original.Place);
    Assert.Null(state.Intent(original.Place));
    Assert.Equal(missing, state.Mark(original.Place));
    state.ClearMark(original.Place);
    Assert.Equal([local], new CloudDeleteState(slot).Marks());
    Assert.Throws<CloudDeleteRuleException>(() => state.PutIntent(original with { Group = "not-a-uuid" }));
  }

  private sealed class Recorder(CloudDeleteWitnessAnswer answer) : ICloudDeleteWitness
  {
    public readonly List<(string, DateTimeOffset, DateTimeOffset)> Calls = [];
    public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt)
    { Calls.Add((removedPath, lastSeen, seenGoneAt)); return Task.FromResult(answer); }
  }

  [Fact]
  public async Task Witness_slot_defaults_to_by_hand_installs_once_and_forwards_both_times()
  {
    var slot = new CloudDeleteWitnessSlot();
    var path = Path.Combine(Path.GetTempPath(), "notes", "plan.md");
    var seen = DateTimeOffset.FromUnixTimeSeconds(10); var gone = DateTimeOffset.FromUnixTimeSeconds(12);
    Assert.Equal(CloudDeleteWitnessAnswer.CannotKnow, await slot.WhoAsync(path, seen, gone));
    var answer = CloudDeleteWitnessAnswer.Ai("Night work", "Integrations", seen, Group);
    var witness = new Recorder(answer);
    Assert.True(slot.InstallOnce(witness));
    Assert.False(slot.InstallOnce(new CloudDeleteUnknownWitness()));
    Assert.Equal(answer, await slot.WhoAsync(path, seen, gone));
    Assert.Equal((path, seen, gone), Assert.Single(witness.Calls));
    Assert.Equal(CloudDeleteWitnessAnswer.CannotKnow, await slot.WhoAsync(path, gone, seen));
    Assert.Equal(CloudDeleteWitnessAnswer.CannotKnow, await slot.WhoAsync("notes/plan.md", seen, gone));
    Assert.Equal(CloudDeleteBy.Person, CloudDeleteWitnessAnswer.NotAi.By);
    Assert.Equal(CloudDeleteBy.Person, CloudDeleteWitnessAnswer.CannotKnow.By);
    Assert.Equal(CloudDeleteBy.Ai, answer.By);
  }

  [Fact]
  public void Bin_groups_keep_names_counts_and_one_group_across_kinds()
  {
    var actor = new CloudDeleteActor(CloudDeleteBy.Ai, Mac, "Mac mini", "Night work", "Integrations", Now, Group);
    CloudDeleteItem[] items = [new("memory-key", "memory", "Plan", "plan.md"), new("task-key", "task", "Write a plan")];
    Assert.Equal(actor.Intent("plan.md", CloudDeleteScope.Everywhere).Group, actor.Intent("task-key", CloudDeleteScope.Everywhere).Group);
    var bin = new CloudBinGroup(Group, actor.By, actor.MacName, actor.Session, actor.Agent, Now, items);
    Assert.Equal(2, bin.Count);
    Assert.Equal(("Night work", "Integrations", Now), (bin.Session, bin.Agent, bin.At));
    Assert.Equal("Removed by an AI on Mac mini", bin.Title);
    Assert.Equal("Removed on MacBook Pro", new CloudBinGroup(Group, CloudDeleteBy.Person, "MacBook Pro", null, null, Now, items).Title);
    Assert.Equal("Removed on MacBook Pro (older version)", new CloudBinGroup(Group, CloudDeleteBy.Person, "MacBook Pro", null, null, Now, items, CloudBinEra.OlderVersion).Title);
    Assert.Equal("Before the new rule", new CloudBinGroup(Group, CloudDeleteBy.Person, "MacBook Pro", null, null, Now, items, CloudBinEra.BeforeNewRule).Title);
  }

  [Fact]
  public void Words_are_the_agreed_words_and_retention_is_thirty_days()
  {
    Assert.Equal("Not on this PC", CloudDeleteWords.NotOnThisPc);
    Assert.Equal("Bring back", CloudDeleteWords.BringBack);
    Assert.Equal("Bring all back", CloudDeleteWords.BringAllBack);
    Assert.Equal("Only on this PC", CloudDeleteWords.OnlyOnThisPc);
    Assert.Equal("Put in Cloud again", CloudDeleteWords.PutInCloudAgain);
    Assert.Equal("Removed by an AI on Mac mini", CloudDeleteWords.RemovedByAi("Mac mini"));
    Assert.Equal("Removed on Mac mini", CloudDeleteWords.Removed("Mac mini"));
    Assert.Equal("Removed on Mac mini (older version)", CloudDeleteWords.RemovedOlderVersion("Mac mini"));
    Assert.Equal("Before the new rule", CloudDeleteWords.BeforeNewRule);
    Assert.Equal("Put back all", CloudDeleteWords.PutBackAll);
    Assert.Equal("Cloud", CloudDeleteWords.Cloud);
    Assert.Equal("Everywhere", CloudDeleteWords.Everywhere);
    Assert.Equal("Cloud only works once your other devices are updated", CloudDeleteWords.CloudNeedsUpdatedDevices);
    Assert.Equal(CloudDeleteWords.NotOnThisPc, CloudDeleteText.Title(CloudLocalMark.NotOnThisPc));
    Assert.Equal(CloudDeleteWords.OnlyOnThisPc, CloudDeleteText.Title(CloudLocalMark.OnlyOnThisPc));
    Assert.Equal(2_592_000_000, CloudBinGroup.RetentionMilliseconds);
    Assert.Equal(43_200_000, CloudDeleteGate.RenewAfter);
  }

  [Fact]
  public void The_about_record_round_trips_and_a_misaddressed_one_is_refused()
  {
    var removal = CloudOperation.Create(Mac.ToLowerInvariant(), "brain/files/i09", Guid.NewGuid().ToString(), [], "archive", new CloudSourceReference("project:x", "file/CLAUDE.md"), Now, CloudJson.Obj(("a", CloudJson.From("b"))));
    var intent = Intent() with { Mac = Mac.ToLowerInvariant(), Place = "project:x\nCLAUDE.md" };
    var about = CloudFileDeleteRecords.Operation(removal, intent);
    var read = CloudFileDeleteRecords.Read(about)!;
    Assert.Equal(intent, read.Travel.Intent);
    Assert.Equal(CloudFileDeleteRecords.AboutKey(Group, removal.OpId), about.Source.RecordId);
    Assert.Null(CloudFileDeleteRecords.Read(about with { OriginDevice = OtherMac }));
    Assert.Null(CloudFileDeleteRecords.Read(about with { Parents = [removal.OpId] }));
    // Arrived with its about-record: as it says. Without one from a device that announced the rule: the safe way
    // ("Cloud", the file is kept). From a device that never announced: an older build's Everywhere.
    Assert.Equal(intent, CloudFileDeleteRecords.ArrivedRemoval(removal, intent.Place, Mac, announced: true, read, aboutRefused: false).Intent);
    var safe = CloudFileDeleteRecords.ArrivedRemoval(removal, intent.Place, Mac, announced: true, null, aboutRefused: false).Intent!;
    Assert.Equal((CloudDeleteScope.Cloud, CloudDeleteBy.Person), (safe.Scope, safe.By));
    Assert.True(CloudFileDeleteRecords.ArrivedRemoval(removal, intent.Place, Mac, announced: false, null, aboutRefused: false).IsOlderVersion);
    Assert.Equal(CloudDeleteScope.Cloud, CloudFileDeleteRecords.ArrivedRemoval(removal, intent.Place, Mac, announced: false, null, aboutRefused: true).Intent!.Scope);
    Assert.Equal(CloudDeleteScope.Cloud, CloudFileDeleteRecords.ArrivedRemoval(removal, intent.Place, OtherMac, announced: true, read, aboutRefused: false).Intent!.Scope);
  }

  [Fact]
  public void The_keeper_Bin_keeps_thirty_days_groups_and_puts_back()
  {
    var bin = new CloudBin(Path.Combine(scratch, "versions"));
    var item = new CloudDeleteItem("notes/plan.md", "memory", "Plan");
    var group = new CloudBinGroup(Group, CloudDeleteBy.Ai, "Mac mini", "Night work", null, Now, [item]);
    var first = "first"u8.ToArray(); var second = "second"u8.ToArray();
    bin.Put("memory", "memory:notes/plan.md", "Plan", null, "notes/plan.md", Now, Mac, first, shown: true, Now, group);
    bin.Put("memory", "memory:notes/plan.md", "Plan", null, "notes/plan.md", Now + 1, Mac, second, shown: true, Now + 1, group);
    // The earlier content stays as a kept version; the reopened Bin lists one group.
    var again = new CloudBin(Path.Combine(scratch, "versions"));
    Assert.Single(again.Versions("memory:notes/plan.md"));
    var listed = Assert.Single(again.Groups("memory", b => item, _ => null));
    Assert.True(group.SameAs(listed));
    Assert.Equal("second"u8.ToArray(), again.Content("memory", again.Get("memory:notes/plan.md")!.Sha256));
    // An entry from before the rule gets a day group named by its device.
    again.Put("memory", "memory:old.md", "Old", null, "old.md", Now, OtherMac, "old"u8.ToArray(), shown: true, Now);
    Assert.Contains(again.Groups("memory", b => new CloudDeleteItem(b.Path, "memory", b.Name), d => d == OtherMac ? "MacBook Pro" : null), g => g.Era == CloudBinEra.BeforeNewRule && g.MacName == "MacBook Pro");
    again.Take("memory:notes/plan.md", Now + 2);
    Assert.Null(again.Get("memory:notes/plan.md"));
    Assert.Equal(2, again.Versions("memory:notes/plan.md").Count);
    // 30 days: everything kept until then or earlier goes, content nothing names any more is removed.
    Assert.Equal(3, again.Sweep(Now + 2 + CloudBin.KeptFor));
    Assert.Empty(again.List("memory"));
    Assert.Null(again.Content("memory", CloudBytes.Sha256Hex(first)));
  }

  [Fact]
  public void An_announcement_that_waited_for_the_clock_is_written_by_the_next_step()
  {
    var memory = new InMemoryDeckMemoryStore(Guid.NewGuid().ToString());
    long? clock = null;
    var pending = new CloudMemorySlot();
    var announce = new CloudAnnounce(memory, () => Mac, () => clock, () => [Mac.ToLowerInvariant()], pending);
    Assert.False(announce.Announce(CloudDeleteGate.Feature, 1));
    Assert.Null(announce.Setting(CloudDeleteGate.Key(Mac)));
    clock = Now;
    new CloudAnnounce(memory, () => Mac, () => clock, () => [Mac.ToLowerInvariant()], pending).RetryPending();
    Assert.Equal(CloudDeleteGate.Value(Now), announce.Setting(CloudDeleteGate.Key(Mac)));
    Assert.True(announce.DeleteRuleIsOpen());
  }

  [Fact]
  public void Phones_and_browsers_never_hold_travel_back()
  {
    CloudDeviceRow Row(string id, string? platform, bool removed = false) => new(id, "x", false, null, null,
      removed ? new CloudTrustRow(id, "x", CloudTrustStanding.Trusted, null, null, null, null, true) : null, Platform: platform);
    string Phone = Guid.NewGuid().ToString(), Android = Guid.NewGuid().ToString(), Web = Guid.NewGuid().ToString(), Gone = Guid.NewGuid().ToString(),
      Old = Guid.NewGuid().ToString();
    var computers = CloudAnnounce.Computers([Row(Mac, "windows"), Row(OtherMac, "macos"), Row(Phone, "ios"), Row(Android, "android"), Row(Web, "web"),
      Row(Gone, "macos", removed: true), Row(Old, null)]);
    Assert.Equal(new[] { Mac.ToLowerInvariant(), OtherMac, Old.ToLowerInvariant() }, computers);
    // The two computers announced; the phone, the Android phone and the browser never did: it travels.
    var account = CloudAnnounce.Computers([Row(Mac, "windows"), Row(OtherMac, "macos"), Row(Phone, "ios"), Row(Android, "android"), Row(Web, "web")]);
    var memory = new InMemoryDeckMemoryStore(Guid.NewGuid().ToString());
    var both = new CloudAnnounce(memory, () => Mac, () => Now, () => account, new CloudMemorySlot());
    Assert.True(both.Announce("projectfolders", 1));
    Assert.False(both.EveryDeviceUnderstands("projectfolders", 1));
    new CloudAnnounce(memory, () => OtherMac, () => Now, () => account, new CloudMemorySlot()).Announce("projectfolders", 1);
    Assert.True(both.EveryDeviceUnderstands("projectfolders", 1));
    Assert.Empty(both.DevicesWaiting("projectfolders", 1));
  }

  [Fact]
  public void The_announcement_writer_deduplicates_and_force_renews()
  {
    var memory = new InMemoryDeckMemoryStore(Guid.NewGuid().ToString());
    var clock = Now;
    var announce = new CloudAnnounce(memory, () => Mac, () => clock, () => [Mac.ToLowerInvariant(), OtherMac], new CloudMemorySlot());
    Assert.True(announce.Announce("cloudfolder", 1));
    clock += 1_000;
    Assert.False(announce.Announce("cloudfolder", 1));
    Assert.True(announce.Announce("cloudfolder", 1, force: true));
    clock += CloudAnnounce.RenewAfter;
    Assert.True(announce.Announce("cloudfolder", 1));
    Assert.Equal(CloudAnnounce.Value(1, clock), announce.Setting(CloudAnnounce.FeatureKey("cloudfolder", Mac)));
    Assert.False(announce.EveryDeviceUnderstands("cloudfolder", 1));
    Assert.Equal([OtherMac], announce.DevicesWaiting("cloudfolder", 1));
    // J-1: `none` is never waited for by the delete rule's gate; a feature gate does not accept it.
    Assert.True(announce.AnnounceNone(CloudDeleteGate.Feature));
    Assert.False(announce.AnnounceNone(CloudDeleteGate.Feature));
    memory.PutRow(new("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(CloudDeleteGate.Key(OtherMac)), DeckMemoryCell.Text(CloudDeleteGate.Value(clock)), DeckMemoryCell.Real(1)]),
      null);
    Assert.True(announce.DeleteRuleIsOpen());
    Assert.True(announce.DeleteRuleAnnounced(Mac));
    // Memory's own key (no feature) is never written.
    Assert.DoesNotContain(memory.Rows("settings"), r => r.Cells[1].Value == "onerule.understands." + Mac.ToLowerInvariant());
  }
}
