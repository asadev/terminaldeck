using System.Collections.Immutable;
using System.Text;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane D2: tasks, agents and projects follow the delete rule. The Mac's RecordsDeleteRuleTests (td-mac-next2, 27 cases)
// ported one to one, by name; each device is this records stack on its own scratch disk, through the real engine,
// transport and signed packs against the fixture service (never the live Cloud). "Mac mini" and "MacBook Pro" are the
// two devices' names in the account's device list, as in the Mac's cases.
public sealed class CloudRecordsDeleteRuleTests : IDisposable
{
  private const string Subject = CloudFakeService.Subject;
  private const string A = "0d9a4f0e-6a1b-4c1e-9b7a-1f2e3d4c5b61", B = "5e8b3c2d-1f0a-4b9c-8d7e-6f5a4b3c2d12";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-d2-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }

  private sealed class Peer
  {
    public required string Id;
    public required string Home;
    public required AppDataRoot Root;
    public required ProjectService Projects;
    public required AgentService Agents;
    public required TaskStore Tasks;
    public required CloudRecordsForAccount Records;
    public required CloudKindsForAccount Kinds;
    public required CloudSyncEngine Engine;
    public bool Open = true;
    public long? Ahead = 0;
    public CloudProjectsOwner ProjectOwner => Records.Projects;
    public CloudAgentsOwner AgentOwner => Records.Agents;
    public CloudTasksOwner TaskOwner => Kinds.Tasks;
  }
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private readonly Dictionary<string, CloudTestDevice> devices = [];
  private static string? Name(string device) => device == A ? "Mac mini" : device == B ? "MacBook Pro" : null;

  private Peer Make(string id, bool open = true, CloudDeleteWitnessSlot? witness = null)
  {
    if (!devices.TryGetValue(id, out var device)) { device = devices[id] = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk; }
    var home = Path.Combine(scratch, id[..8]);
    var root = AppDataRoot.Explicit(Path.Combine(home, "data"));
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
    var folders = new CloudProjectFolders(Path.Combine(root.DirectoryPath, "cloud", "project-folders.json"), Path.Combine(home, "profile"), [root.DirectoryPath], () => service.Now);
    var account = Path.Combine(root.DirectoryPath, "cloud", "accounts", Subject);
    var records = new CloudRecordsForAccount(account, Subject, id, projects, agents, folders, () => true, null, () => service.Now,
      witness ?? new CloudDeleteWitnessSlot(), () => DateTimeOffset.FromUnixTimeMilliseconds(service.Now));
    var tasks = TaskStore.At(root);
    var general = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
    var appearance = new TerminalAppearanceService(new JsonStateStore<TerminalAppearanceState>(root, "terminal-appearance"));
    var kinds = new CloudKindsForAccount(account, Subject, id, tasks, projects, CloudSettingsOwner.ForWindows(general, appearance), () => true, () => service.Now, quiet: 0);
    var store = new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [.. records.Adapters, .. kinds.Adapters], null, () => service.Now);
    var peer = new Peer { Id = id, Home = home, Root = root, Projects = projects, Agents = agents, Tasks = tasks, Records = records, Kinds = kinds, Engine = engine, Open = open };
    records.ConfigureDeleteRule(() => peer.Open, Name, () => peer.Ahead is { } ahead ? service.Now + ahead : null);
    kinds.ConfigureDeleteRule(() => peer.Open, Name, () => peer.Ahead is { } ahead ? service.Now + ahead : null);
    return peer;
  }
  private static async Task Sync(params Peer[] peers) { foreach (var p in peers) await p.Engine.SyncAsync(default); }
  /// Two devices level with each other.
  private async Task<(Peer A, Peer B)> Two(bool open = true, CloudDeleteWitnessSlot? witnessA = null, Action<Peer>? before = null)
  {
    var a = Make(A, open, witnessA); var b = Make(B, open);
    before?.Invoke(a);
    await Sync(a, b, a, b);
    return (a, b);
  }
  private CloudDeleteActor Actor(Peer peer, CloudDeleteBy by = CloudDeleteBy.Ai) =>
    new(by, peer.Id, Name(peer.Id)!, "Night work", by == CloudDeleteBy.Ai ? "Reviewer" : null, service.Now, Guid.NewGuid().ToString("D"));
  private static CloudDeleteItem Item(string kind, string id) => new(kind + ":" + id, kind, "Review");

  private void AddTask(Peer peer, string id)
  {
    var at = DateTimeOffset.FromUnixTimeMilliseconds(service.Now);
    peer.Tasks.Change(s => (s with { Tasks = s.Tasks.Add(new DeckTask("local:" + id, "Review the patch", "Details", ProjectIdentity.IndependentId, "", "To-Do", "me", at, at,
      Labels: [], Comments: [], Activity: [])) }, true));
  }
  private static IReadOnlyList<DeckTask> Trash(Peer peer) => peer.Tasks.Read().Tasks.Where(t => t.DeletedAt is not null).ToArray();
  private static IReadOnlyList<DeckTask> Live(Peer peer) => peer.Tasks.Read().Tasks.Where(t => t.DeletedAt is null).ToArray();
  private static void AddAgent(Peer peer, string id = "reviewer", string name = "Reviewer", string text = "Read every changed line.", string project = ProjectIdentity.IndependentId,
    string? reportsTo = null)
  {
    peer.Agents.Save(new SavedAgent(id, name, "claude", Description: "Reviews", ProjectId: project, ReportsTo: reportsTo), createOnly: true);
    peer.Agents.SaveInstructions(id, text);
  }
  private static SavedAgent? AgentOn(Peer peer, string id) => peer.Agents.List().FirstOrDefault(a => a.Id == id);
  private static string Folder(Peer peer, string name)
  {
    var path = Path.Combine(peer.Home, "code", name);
    Directory.CreateDirectory(path);
    return path;
  }
  private static Project? ProjectOn(Peer peer, string id) => peer.Projects.List().FirstOrDefault(p => p.Id == id);
  private CloudMergeView? View(CloudRecordStore store, string domain, string entity, CloudMergeTable table) => store.View(CloudRecordKey.Of(domain, entity), table);

  [Fact]
  public async Task Ai_task_delete_is_the_existing_Trash_on_both_devices_and_ignores_Cloud_scope()
  {
    var (a, b) = await Two(before: p => AddTask(p, "one"));
    var who = Actor(a);
    var group = await a.TaskOwner.DeleteItemsAsync([Item("task", "local:one")], CloudDeleteScope.Cloud, who);
    Assert.Equal((who.Group, 1), (group.Id, group.Count));
    await Sync(a, b);
    foreach (var side in new[] { a, b })
    {
      Assert.Empty(Live(side));
      Assert.Single(Trash(side));
      var meta = side.TaskOwner.Deletes.Saved("meta:task:local:one");
      Assert.Equal(("ai", A, who.Group, "everywhere", "Night work", "Reviewer"), (CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedBy")), CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedOn")),
        CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedGroup")), CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedScope")),
        CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedSession")), CloudRecordJson.Text(CloudRecordJson.Get(meta, "deletedAgent"))));
    }
    var groups = await b.TaskOwner.BinGroupsAsync();
    Assert.Equal(("Mac mini", "Reviewer"), (groups[0].MacName, groups[0].Agent));
  }

  [Fact]
  public async Task Task_delete_for_good_travels_and_an_arriving_purge_applies()
  {
    var (a, b) = await Two(before: p => AddTask(p, "one"));
    await a.TaskOwner.DeleteItemsAsync([Item("task", "local:one")], CloudDeleteScope.Everywhere, Actor(a));
    await Sync(a, b);
    Assert.Single(Trash(b));
    await a.TaskOwner.DeleteForGoodAsync([Item("task", "local:one")]);
    await Sync(a);
    Assert.False(View(a.Kinds.Store, "tasks", "task:local:one", CloudTasksOwner.Kind.Table)!.Exists);
    await Sync(b);
    Assert.Empty(a.Tasks.Read().Tasks);
    Assert.Empty(b.Tasks.Read().Tasks);
  }

  [Fact]
  public async Task Task_put_back_all_restores_one_named_group_on_both_devices()
  {
    var (a, b) = await Two(before: p => { AddTask(p, "one"); AddTask(p, "two"); });
    var who = Actor(a, CloudDeleteBy.Person);
    await a.TaskOwner.DeleteItemsAsync([Item("task", "local:one"), Item("task", "local:two")], CloudDeleteScope.Everywhere, who);
    await Sync(a, b);
    Assert.Equal(2, Trash(b).Count);
    Assert.Equal(2, (await a.TaskOwner.PutBackGroupAsync(who.Group)).Count);
    await Sync(a, b);
    Assert.Equal(2, Live(b).Count);
    Assert.Empty(await b.TaskOwner.BinGroupsAsync());
  }

  [Fact]
  public async Task Ai_agent_delete_bins_the_row_and_text_on_both_devices_and_ignores_Cloud_scope()
  {
    var (a, b) = await Two(before: p => AddAgent(p));
    var who = Actor(a);
    await a.AgentOwner.DeleteItemsAsync([Item("agent", "reviewer")], CloudDeleteScope.Cloud, who);
    await Sync(a, b);
    foreach (var side in new[] { a, b })
    {
      Assert.Null(AgentOn(side, "reviewer"));
      var row = Assert.Single(side.AgentOwner.Deletes.BinRows("agent"));
      Assert.Equal("agent:reviewer", row.Item.Id);
      Assert.Equal("Reviewer", CloudRecordJson.Text(CloudRecordJson.Get(CloudRecordJson.Get(row.Value, "row"), "Name")));
      Assert.Equal("Read every changed line.", CloudRecordJson.Text(CloudRecordJson.Get(row.Value, "text")));
      Assert.Equal((CloudDeleteBy.Ai, who.Group), (row.Actor.By, row.Actor.Group));
    }
    Assert.Single(await b.AgentOwner.PutBackGroupAsync(who.Group));
    Assert.Equal("Read every changed line.", b.Agents.ReadInstructions("reviewer"));
  }

  [Fact]
  public async Task A_concurrent_agent_edit_wins_the_removal_by_ancestry()
  {
    var (a, b) = await Two(before: p => AddAgent(p));
    await a.AgentOwner.DeleteItemsAsync([Item("agent", "reviewer")], CloudDeleteScope.Everywhere, Actor(a));
    await Sync(a);
    // B has not seen A's removal: this is an edit on the original parent, not a timestamp-based restore.
    var onB = b.Agents.Get("reviewer");
    b.Agents.Save(onB with { Description = "Keeps the edit" }, expected: onB);
    await Sync(b, a, b);
    Assert.Equal("Keeps the edit", AgentOn(a, "reviewer")?.Description);
    Assert.Equal("Keeps the edit", AgentOn(b, "reviewer")?.Description);
    Assert.DoesNotContain(a.Records.Adapters[1].Listing().WaitingHere, w => w.Record == "agent:reviewer");
    Assert.Equal("Read every changed line.", a.Agents.ReadInstructions("reviewer"));
    Assert.Equal("Read every changed line.", b.Agents.ReadInstructions("reviewer"));
  }

  [Fact]
  public async Task An_unintended_missing_agent_row_does_not_travel()
  {
    var (a, _) = await Two(before: p => AddAgent(p));
    Assert.Null(a.AgentOwner.CloudMissing("agent:reviewer", CloudRecordJson.Object([("id", CloudJson.From("reviewer"))])));
  }

  private sealed class Witness(CloudDeleteWitnessAnswer answer) : ICloudDeleteWitness
  {
    public Task<CloudDeleteWitnessAnswer> WhoAsync(string removedPath, DateTimeOffset lastSeen, DateTimeOffset seenGoneAt) => Task.FromResult(answer);
  }

  [Fact]
  public async Task An_unknown_instruction_removal_is_marked_and_survives_sync()
  {
    var (a, _) = await Two(before: p => AddAgent(p));
    var path = a.Agents.Get("reviewer").InstructionsFile!;
    File.Delete(path);
    var sent = service.Segments;
    await Sync(a);
    service.Now += 4_000;
    await Sync(a);
    Assert.Equal(sent, service.Segments);
    var marks = await a.AgentOwner.NotHereAsync();
    Assert.Equal(CloudLocalMark.NotOnThisPc, Assert.Single(marks).Mark);
    Assert.False(File.Exists(path));
    await Sync(a);
    Assert.Equal(sent, service.Segments);
    await a.AgentOwner.BringBackAsync(marks.Select(m => m.Item).ToArray(), CloudBringBackDestination.ThisPc);
    Assert.True(File.Exists(a.Agents.Get("reviewer").InstructionsFile));
    Assert.Equal("Read every changed line.", a.Agents.ReadInstructions("reviewer"));
    Assert.Empty(await a.AgentOwner.NotHereAsync());
  }

  [Fact]
  public async Task A_witnessed_AI_instruction_delete_travels_into_both_keeper_Bins()
  {
    var slot = new CloudDeleteWitnessSlot(); var group = Guid.NewGuid().ToString("D");
    Assert.True(slot.InstallOnce(new Witness(CloudDeleteWitnessAnswer.Ai("Night work", "Reviewer", DateTimeOffset.FromUnixTimeMilliseconds(service.Now), group))));
    var (a, b) = await Two(witnessA: slot, before: p => AddAgent(p));
    File.Delete(a.Agents.Get("reviewer").InstructionsFile!);
    await Sync(a);
    service.Now += 4_000;
    await Sync(a, b);
    foreach (var side in new[] { a, b })
    {
      var row = side.AgentOwner.Deletes.BinRows("agent").First();
      Assert.Equal("instruction:reviewer.md", row.Item.Id);
      Assert.Equal((CloudDeleteBy.Ai, group), (row.Actor.By, row.Actor.Group));
      Assert.NotNull(AgentOn(side, "reviewer"));
    }
  }

  [Fact]
  public async Task A_missing_instruction_root_is_never_a_witnessed_delete()
  {
    var slot = new CloudDeleteWitnessSlot();
    Assert.True(slot.InstallOnce(new Witness(CloudDeleteWitnessAnswer.Ai("Night work", null, DateTimeOffset.FromUnixTimeMilliseconds(service.Now), Guid.NewGuid().ToString("D")))));
    var (a, _) = await Two(witnessA: slot, before: p => AddAgent(p));
    var folder = Path.GetDirectoryName(a.Agents.Get("reviewer").InstructionsFile!)!;
    Directory.Move(folder, Path.Combine(a.Home, "unplugged"));
    var sent = service.Segments;
    service.Now += 10_000; await Sync(a);
    service.Now += 10_000; await Sync(a);
    Assert.Equal(sent, service.Segments);
    Assert.Empty(await a.AgentOwner.NotHereAsync());
    Assert.Empty(await a.AgentOwner.BinGroupsAsync());
  }

  [Fact]
  public async Task Project_everywhere_removes_only_entries_and_never_touches_folder_files()
  {
    var a = Make(A); var b = Make(B);
    foreach (var side in new[] { a, b })
    {
      var folder = Folder(side, "own-project");
      File.WriteAllText(Path.Combine(folder, "code.cs"), "User source stays");
      side.Projects.Save(new ProjectDraft("review", "Review", [folder]), createOnly: true);
    }
    await Sync(a, b, a, b);
    await a.ProjectOwner.DeleteItemsAsync([Item("project", "review")], CloudDeleteScope.Everywhere, Actor(a));
    await Sync(a, b);
    foreach (var side in new[] { a, b })
    {
      Assert.Null(ProjectOn(side, "review"));
      Assert.Equal("User source stays", File.ReadAllText(Path.Combine(side.Home, "code", "own-project", "code.cs")));
      Assert.Equal(1, (await side.ProjectOwner.BinGroupsAsync())[0].Count);
    }
  }

  [Fact]
  public async Task Project_Cloud_keeps_each_entry_only_on_its_own_device_and_can_be_republished()
  {
    var (a, b) = await Two(before: p => p.Projects.Save(new ProjectDraft("review", "Review", [Folder(p, "review")]), createOnly: true));
    await a.ProjectOwner.DeleteItemsAsync([Item("project", "review")], CloudDeleteScope.Cloud, Actor(a, CloudDeleteBy.Person));
    await Sync(a, b);
    foreach (var side in new[] { a, b })
    {
      Assert.NotNull(ProjectOn(side, "review"));
      Assert.Equal(CloudLocalMark.OnlyOnThisPc, (await side.ProjectOwner.NotHereAsync())[0].Mark);
    }
    var sent = service.Segments;
    await Sync(b);
    Assert.Equal(sent, service.Segments);
    await b.ProjectOwner.BringBackAsync([Item("project", "review")], CloudBringBackDestination.Cloud);
    await Sync(b, a);
    Assert.Empty(await b.ProjectOwner.NotHereAsync());
    Assert.Empty(await a.ProjectOwner.NotHereAsync());
  }

  [Fact]
  public async Task Remove_from_this_PC_sends_nothing_and_Bring_back_restores_the_folder_map()
  {
    var a = Make(A);
    var folder = Folder(a, "untouched");
    a.Projects.Save(new ProjectDraft("review", "Review", [folder]), createOnly: true);
    await Sync(a);
    var sent = service.Segments;
    a.ProjectOwner.RemoveFromThisPc("review");
    await Sync(a);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(CloudLocalMark.NotOnThisPc, (await a.ProjectOwner.NotHereAsync())[0].Mark);
    Assert.True(Directory.Exists(folder));
    await a.ProjectOwner.BringBackAsync([Item("project", "review")], CloudBringBackDestination.ThisPc);
    Assert.Equal(new[] { folder }, ProjectOn(a, "review")!.Folders.ToArray());
    await Sync(a);
    Assert.Equal(sent, service.Segments);
  }

  [Fact]
  public async Task Closed_gate_uses_only_version_1_fields_and_refuses_project_Cloud()
  {
    var a = Make(A, open: false);
    AddTask(a, "one");
    await Sync(a);
    await a.TaskOwner.DeleteItemsAsync([Item("task", "local:one")], CloudDeleteScope.Cloud, Actor(a));
    await Sync(a);
    var view = View(a.Kinds.Store, "tasks", "task:local:one", CloudTasksOwner.Kind.Table)!;
    Assert.Equal(1, view.MinTable);
    Assert.All(CloudMergeTablesV2.RecordDeleteFields, f => Assert.False(view.Fields.ContainsKey(f)));
    Assert.Equal("trash", CloudRecordJson.Text(view.Fields["place"]));
    a.Projects.Save(new ProjectDraft("review", "Review", [Folder(a, "review")]), createOnly: true);
    var refused = await Assert.ThrowsAsync<CloudRecordRefusal>(() => a.ProjectOwner.DeleteItemsAsync([Item("project", "review")], CloudDeleteScope.Cloud, Actor(a)));
    Assert.Equal(CloudDeleteWords.CloudNeedsUpdatedDevices, refused.Reason);
    Assert.NotNull(ProjectOn(a, "review"));
  }

  [Fact]
  public void Old_record_canonical_bytes_still_read_and_a_version_2_reader_takes_them()
  {
    // The version-1 form an older Mac writes: minTable 1, table 1; its payload re-encodes to the same bytes.
    var stamp = new CloudMergeStamp(1_760_000_000_000, "v1-record");
    var version = new CloudMergeVersion { Table = 1, MinTable = 1, Baseline = false };
    foreach (var (k, v) in new[] { ("id", CloudJson.From("reviewer")), ("name", CloudJson.From("Reviewer")), (CloudRecordMerge.ExistsField, CloudJson.From(true)) }) { version.Fields[k] = v; version.Stamps[k] = stamp; }
    var bytes = CloudCanonical.Encode(version.Payload());
    var redecoded = CloudMergeVersion.Parse(CloudJson.Parse(bytes));
    Assert.Equal(bytes, CloudCanonical.Encode(redecoded.Payload()));
    Assert.True(redecoded.MinTable <= CloudAgentsOwner.AgentKind.Table.Version);
    Assert.Equal(1, CloudMergeTables.Agent.Version);
  }

  [Fact]
  public void A_malformed_new_removal_is_refused_rather_than_treated_as_everywhere()
  {
    Assert.Throws<CloudRecordRefusal>(() => CloudRecordsDeleteLedger.Validate(CloudRecordJson.Object([("deletedScope", CloudJson.From("somewhere"))])));
  }

  [Fact]
  public void Retention_is_thirty_days_and_tasks_keep_their_existing_Trash()
  {
    Assert.Equal(30, CloudTasksOwner.TrashDays);
    Assert.Equal(30L * 86_400_000, CloudBinGroup.RetentionMilliseconds);
  }

  [Fact]
  public async Task An_old_format_agent_removal_applies_into_the_keeper_with_older_version_names()
  {
    var (a, b) = await Two(open: false, before: p => AddAgent(p));
    await a.AgentOwner.DeleteItemsAsync([Item("agent", "reviewer")], CloudDeleteScope.Cloud, Actor(a));
    await Sync(a);
    var view = View(a.Records.Store, "agents", "agent:reviewer", CloudAgentsOwner.AgentKind.Table)!;
    Assert.Equal(1, view.MinTable);
    Assert.All(CloudMergeTablesV2.RecordDeleteFields, f => Assert.False(view.Fields.ContainsKey(f)));
    await Sync(b);
    Assert.Null(AgentOn(b, "reviewer"));
    var groups = await b.AgentOwner.BinGroupsAsync();
    Assert.Equal((CloudBinEra.OlderVersion, "Mac mini"), (groups[0].Era, groups[0].MacName));
    Assert.Equal("Read every changed line.", CloudRecordJson.Text(CloudRecordJson.Get(b.AgentOwner.Deletes.BinRows("agent")[0].Value, "text")));
  }

  [Fact]
  public async Task An_agent_created_and_deleted_before_its_first_capture_still_travels_as_a_deletion()
  {
    var a = Make(A); var b = Make(B);
    AddAgent(a);
    await a.AgentOwner.DeleteItemsAsync([Item("agent", "reviewer")], CloudDeleteScope.Everywhere, Actor(a));
    await Sync(a, b);
    Assert.Null(AgentOn(b, "reviewer"));
    Assert.Equal(1, (await b.AgentOwner.BinGroupsAsync())[0].Count);
  }

  [Fact]
  public async Task Everywhere_after_project_Cloud_also_removes_the_retained_entries()
  {
    var (a, b) = await Two(before: p => p.Projects.Save(new ProjectDraft("review", "Review", [Folder(p, "review")]), createOnly: true));
    await a.ProjectOwner.DeleteItemsAsync([Item("project", "review")], CloudDeleteScope.Cloud, Actor(a));
    await Sync(a, b);
    await a.ProjectOwner.DeleteItemsAsync([Item("project", "review")], CloudDeleteScope.Everywhere, Actor(a));
    var sent = service.Segments;
    await Sync(a);
    Assert.True(service.Segments > sent);
    await Sync(b);
    Assert.Null(ProjectOn(b, "review"));
    Assert.Empty(await b.ProjectOwner.NotHereAsync());
  }

  [Fact]
  public async Task A_marked_instruction_reappearing_as_an_older_version_uses_the_newest_without_uploading_the_old_text()
  {
    var (a, b) = await Two(before: p => AddAgent(p));
    var path = a.Agents.Get("reviewer").InstructionsFile!;
    File.Delete(path);
    await Sync(a);
    service.Now += 4_000;
    await Sync(a);
    b.Agents.SaveInstructions("reviewer", "Keep the newest instruction.");
    await Sync(b, a);
    Assert.False(File.Exists(path));
    File.WriteAllText(path, "Read every changed line.");
    var sent = service.Segments;
    await Sync(a);
    Assert.Equal(sent, service.Segments);
    Assert.Equal("Keep the newest instruction.", a.Agents.ReadInstructions("reviewer"));
    Assert.Empty(await a.AgentOwner.NotHereAsync());
  }

  [Fact]
  public async Task Agent_delete_for_good_only_empties_the_existing_keeper_item()
  {
    var a = Make(A);
    AddAgent(a);
    await Sync(a);
    await a.AgentOwner.DeleteItemsAsync([Item("agent", "reviewer")], CloudDeleteScope.Everywhere, Actor(a));
    Assert.Single(await a.AgentOwner.BinGroupsAsync());
    await a.AgentOwner.DeleteForGoodAsync([Item("agent", "reviewer")]);
    Assert.Empty(await a.AgentOwner.BinGroupsAsync());
    Assert.Null(AgentOn(a, "reviewer"));
  }

  // (The Mac's anOfflineAgentBinMovesToTheExistingAccountKeeperOnceAfterASafetyCopy is the Mac's own SQLite keeper
  // migration; Windows owners exist only while signed in and use the account's one Bin from the start.)

  /// Decision 1: a delete that lands while a capture pass runs is never read as a put back.
  [Fact]
  public async Task A_delete_during_a_sync_pass_keeps_its_Bin_copy_and_travels()
  {
    var (a, b) = await Two(before: p => AddAgent(p));
    var who = Actor(a, CloudDeleteBy.Person); var fired = false;
    a.AgentOwner.AfterRosterRead = () => { if (fired) return; fired = true; a.AgentOwner.RemoveByApp("reviewer", who); };
    await Sync(a);
    a.AgentOwner.AfterRosterRead = null;
    Assert.True(fired);
    Assert.Null(AgentOn(a, "reviewer"));
    Assert.Equal(who.Group, a.AgentOwner.Deletes.BinRows("agent").First(r => r.Item.Id == "agent:reviewer").Actor.Group);
    await Sync(a);
    Assert.False(View(a.Records.Store, "agents", "agent:reviewer", CloudAgentsOwner.AgentKind.Table)!.Exists);
    await Sync(b);
    Assert.Null(AgentOn(b, "reviewer"));
    Assert.Equal(who.Group, b.AgentOwner.Deletes.BinRows("agent").First(r => r.Item.Id == "agent:reviewer").Actor.Group);
    Assert.Contains(a.AgentOwner.Deletes.BinRows("agent"), r => r.Item.Id == "agent:reviewer");
  }

  /// Decision 2: Trash ageing is each device's own, by the service clock only, and never travels.
  [Fact]
  public async Task A_clock_ahead_ages_only_its_own_Trash_and_ageing_waits_for_the_service_clock()
  {
    var (a, b) = await Two(before: p => AddTask(p, "one"));
    b.Ahead = null;
    await a.TaskOwner.DeleteItemsAsync([Item("task", "local:one")], CloudDeleteScope.Everywhere, Actor(a, CloudDeleteBy.Person));
    await Sync(a, b);
    Assert.Single(Trash(b));
    // A's service clock runs 31 days fast: it ages its OWN Trash only.
    a.Ahead = 31L * 86_400_000;
    AddTask(a, "two");
    await Sync(a);
    Assert.Empty(Trash(a));
    Assert.True(View(a.Kinds.Store, "tasks", "task:local:one", CloudTasksOwner.Kind.Table)!.Exists);
    await Sync(b);
    Assert.Equal(new[] { "local:one" }, Trash(b).Select(t => t.Id).ToArray());
    // B has no service clock yet: nothing ages, although its own clock is far past the 30 days.
    service.Now += 40L * 86_400_000;
    await Sync(b);
    Assert.Equal(new[] { "local:one" }, Trash(b).Select(t => t.Id).ToArray());
    // The aged copy is not placed back into A's Trash by a later pass.
    await Sync(a);
    Assert.Empty(Trash(a));
  }

  /// Decision 3: the entry writers add or remove the list ENTRY only.
  [Fact]
  public async Task The_registry_entry_writers_touch_only_the_entry()
  {
    var a = Make(A);
    var folder = Folder(a, "scratch-project");
    Directory.CreateDirectory(Path.Combine(folder, "src"));
    File.WriteAllText(Path.Combine(folder, "notes.md"), "His own notes");
    File.WriteAllText(Path.Combine(folder, "src", "main.cs"), "print(1)");
    byte[][] Bytes() => [File.ReadAllBytes(Path.Combine(folder, "notes.md")), File.ReadAllBytes(Path.Combine(folder, "src", "main.cs"))];
    var before = Bytes();
    a.Projects.Save(new ProjectDraft("review", "Review", [folder]), createOnly: true);
    AddAgent(a, "lead", "Lead");
    a.Projects.SetLead("review", "agent:lead", "Lead");
    await Sync(a);
    var who = Actor(a, CloudDeleteBy.Person);
    await a.ProjectOwner.DeleteItemsAsync([Item("project", "review")], CloudDeleteScope.Everywhere, who);
    Assert.Null(ProjectOn(a, "review"));
    Assert.Equal(before, Bytes());
    Assert.Single(a.ProjectOwner.PutBackAll(who.Group).Restored);
    var back = ProjectOn(a, "review")!;
    Assert.Equal(new[] { folder }, back.Folders.ToArray());
    Assert.Equal("agent:lead", back.Lead);
    Assert.Equal(before, Bytes());
    Assert.Empty((await a.ProjectOwner.DeleteItemsAsync([Item("project", ProjectIdentity.IndependentId)], CloudDeleteScope.Everywhere, who)).Items);
    Assert.NotNull(ProjectOn(a, ProjectIdentity.IndependentId));
  }

  /// Decision 4: Put back restores what the delete cleared; Put back all continues past a failure.
  [Fact]
  public async Task An_agent_put_back_gets_its_links_back_and_put_back_all_continues_past_a_failure()
  {
    var a = Make(A);
    a.Projects.Save(new ProjectDraft("side", "Side", [Folder(a, "side")]), createOnly: true);
    a.Projects.Save(new ProjectDraft("night", "Night", [Folder(a, "night")]), createOnly: true);
    AddAgent(a);
    AddAgent(a, "writer", "Writer", "Write.", reportsTo: "reviewer");
    AddAgent(a, "planner", "Planner", "Plan the night.", project: "night");
    a.Projects.SetLead("side", "agent:reviewer", "Reviewer");
    var who = Actor(a);
    await a.AgentOwner.DeleteItemsAsync([Item("agent", "reviewer"), Item("agent", "planner")], CloudDeleteScope.Everywhere, who);
    Assert.Null(AgentOn(a, "writer")!.ReportsTo);
    Assert.Null(ProjectOn(a, "side")!.Lead);
    // Planner cannot be put back (its project is no longer on this PC): that item fails.
    a.Projects.Remove("night");
    var answer = a.AgentOwner.PutBackAll(who.Group);
    Assert.Equal(new[] { "Reviewer" }, answer.Restored.Select(i => i.Name).ToArray());
    Assert.Equal(new[] { "Planner" }, answer.NotRestored.Select(i => i.Name).ToArray());
    Assert.Equal("Put back: Reviewer. Not put back: Planner.", answer.Line);
    Assert.NotNull(AgentOn(a, "reviewer"));
    Assert.Equal("reviewer", AgentOn(a, "writer")!.ReportsTo);
    Assert.Equal("agent:reviewer", ProjectOn(a, "side")!.Lead);
    // The failed item stays in the Bin for another try.
    Assert.Equal(new[] { "Planner" }, (await a.AgentOwner.BinGroupsAsync()).First(g => g.Id == who.Group).Items.Select(i => i.Name).ToArray());
  }

  /// Decision 6: one Trash row that does not read never hides the rest.
  [Fact]
  public async Task An_unreadable_Trash_row_is_left_out_and_the_rest_shows()
  {
    var a = Make(A);
    AddTask(a, "one"); AddTask(a, "two");
    var good = Actor(a); var bad = Actor(a);
    await a.TaskOwner.DeleteItemsAsync([Item("task", "local:one")], CloudDeleteScope.Everywhere, good);
    await a.TaskOwner.DeleteItemsAsync([Item("task", "local:two")], CloudDeleteScope.Everywhere, bad);
    var meta = (CloudJson.Object)a.TaskOwner.Deletes.Saved("meta:task:local:two")!;
    a.TaskOwner.Deletes.Put("meta:task:local:two", CloudRecordJson.Set(meta, "deletedBy", CloudJson.From("someone else")));
    var groups = await a.TaskOwner.BinGroupsAsync();
    Assert.Equal(new[] { good.Group }, groups.Select(g => g.Id).ToArray());
    Assert.Equal(new[] { "task:local:one" }, groups[0].Items.Select(i => i.Id).ToArray());
  }
}
