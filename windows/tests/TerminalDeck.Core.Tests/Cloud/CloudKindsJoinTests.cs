using System.Collections.Immutable;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Cloud;

// 7C-4 safety: tasks and settings. A Windows PC joins an account where two Macs already keep their tasks and settings.
// Everything runs through the real engine, transport and signed packs against the fixture service (CloudFakeService),
// never the live Cloud. The two "Macs" are this same stack (it follows the Mac's rules) over their own data folders; every
// device uses the real task ledger, settings files and project service on disk, in a scratch folder, and is restarted
// from disk.
public sealed class CloudKindsJoinTests : IDisposable
{
  private const string Subject = CloudFakeService.Subject;
  private const string MacA = "0c1f6a7e-5b0d-4f55-9d0e-3f1f3c1d7a11", MacB = "6a3e2c1d-9f4b-4e8a-8c7d-2b1a0f9e8d22", Pc = "c2d4e6f8-1a3b-4c5d-8e7f-9a0b1c2d3e33";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-7c4-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }

  private sealed class Peer
  {
    public required string Home;
    public required ProjectService Projects;
    public required TaskStore Tasks;
    public required GeneralSettings General;
    public required TerminalAppearanceService Appearance;
    public required CloudKindsForAccount Kinds;
    public required CloudSyncEngine Engine;
  }
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private readonly Dictionary<string, CloudTestDevice> devices = [];
  private readonly Dictionary<string, (CloudMemorySlot State, CloudMemorySlot Ledger)> slots = [];

  /// One device from its own disk: projects and agents first, then tasks and settings (the app's order).
  private Peer Make(string id, bool fullAccess = true)
  {
    if (!devices.TryGetValue(id, out var device)) { device = devices[id] = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk; }
    if (!slots.TryGetValue(id, out var s)) s = slots[id] = (new CloudMemorySlot(), new CloudMemorySlot());
    var home = Path.Combine(scratch, id[..8]);
    var root = AppDataRoot.Explicit(Path.Combine(home, "data"));
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
    var folders = new CloudProjectFolders(Path.Combine(root.DirectoryPath, "cloud", "project-folders.json"), Path.Combine(home, "profile"), [root.DirectoryPath], () => service.Now);
    var account = Path.Combine(root.DirectoryPath, "cloud", "accounts", Subject);
    var records = new CloudRecordsForAccount(account, Subject, id, projects, agents, folders, () => fullAccess, null, () => service.Now);
    var tasks = TaskStore.At(root);
    var general = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
    var appearance = new TerminalAppearanceService(new JsonStateStore<TerminalAppearanceState>(root, "terminal-appearance"));
    var kinds = new CloudKindsForAccount(account, Subject, id, tasks, projects, CloudSettingsOwner.ForWindows(general, appearance), () => fullAccess, () => service.Now, quiet: 0);
    var store = new CloudSyncStore(s.State, s.Ledger, Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [.. records.Adapters, .. kinds.Adapters], null, () => service.Now);
    return new Peer { Home = home, Projects = projects, Tasks = tasks, General = general, Appearance = appearance, Kinds = kinds, Engine = engine };
  }

  private static string Folder(Peer peer, string name)
  {
    var path = Path.Combine(peer.Home, "code", name);
    Directory.CreateDirectory(path);
    return path;
  }
  private DeckTask NewTask(string id, string title, string project, string folder, string? comment = null, ConnectedTaskLink? connected = null)
  {
    var at = DateTimeOffset.FromUnixTimeMilliseconds(service.Now);
    ImmutableArray<TaskComment> comments = comment is null ? [] : [new TaskComment("c-" + id[6..], TaskActor.Owner, comment, at, [])];
    return new DeckTask(id, title, "Details of " + title, project, folder, "To-Do", "me", at, at, Priority: "High", DueDate: "2026-12-01",
      Labels: ["cloud"], Comments: comments, Activity: [], Connected: connected);
  }
  private static void Add(Peer peer, DeckTask task) => peer.Tasks.Change(s => (s with { Tasks = s.Tasks.Add(task) }, true));
  private static IReadOnlyList<string> Tasks(Peer peer) => peer.Tasks.Read().Tasks.OrderBy(t => t.Id, StringComparer.Ordinal)
    .Select(t => string.Join('|', t.Id, t.Title, t.Details, t.Status, t.Assignee, t.ProjectId, t.Priority, t.DueDate, string.Join(';', t.Labels), t.Revision, t.UpdatedAt.ToUnixTimeMilliseconds(),
      t.DeletedAt is null, t.Connected is null, string.Join(';', t.Comments.Select(c => c.Id + "=" + c.Text)))).ToArray();
  private static string Settings(Peer peer)
  {
    var g = peer.General.Read(); var a = peer.Appearance.Preferences();
    return string.Join('|', g.RestoreSessions, g.AutoNameSessions, g.CopyOnSelect, g.DefaultProvider, g.KeepAwake, a.Scheme, a.FontFamily, a.FontSize);
  }

  /// Two Macs with their tasks and chosen settings in the account, level with each other.
  private async Task<(Peer A, Peer B)> TwoMacs()
  {
    var a = Make(MacA);
    a.Projects.Save(new ProjectDraft("deck", "Deck", [Folder(a, "deck")], "folder", "green"), createOnly: true);
    Add(a, NewTask("local:t1", "Ship the Windows sync", "deck", Folder(a, "deck"), "Looks good to me."));
    Add(a, NewTask("local:t2", "Write the notes", ProjectIdentity.IndependentId, ""));
    // A task of a connected task system: never sent.
    Add(a, NewTask("iloop:x9", "Connected system task", ProjectIdentity.IndependentId, "", connected: new ConnectedTaskLink("iloop", "x9")));
    a.General.Save(a.General.Read() with { CopyOnSelect = true, KeepAwake = true });
    a.Appearance.Set(fontSize: 15);
    var b = Make(MacB);
    b.General.Save(b.General.Read() with { DefaultProvider = "codex" });
    for (var round = 0; round < 2; round++) { await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default); }
    Assert.Equal(new[] { "local:t1", "local:t2" }, b.Tasks.Read().Tasks.Select(t => t.Id).Order(StringComparer.Ordinal).ToArray());
    // A chosen value beats a default, in both directions; keep-awake is about each machine and never travels.
    Assert.Equal("True|True|True|codex|True|follow-app||15", Settings(a));
    Assert.Equal("True|True|True|codex|False|follow-app||15", Settings(b));
    return (a, b);
  }

  [Fact]
  public async Task A_fresh_PC_receives_tasks_and_settings_sends_nothing_and_the_Macs_keep_what_they_had()
  {
    var (a, b) = await TwoMacs();
    var tasksA = Tasks(a); var tasksB = Tasks(b); var settingsA = Settings(a); var settingsB = Settings(b);
    var sent = service.Segments;

    var pc = Make(Pc);
    // Before it has read the whole feed once, the PC hands the engine nothing of its own.
    Assert.Empty((await pc.Kinds.Adapters[0].CaptureAsync(() => service.Now, default)).Operations);
    Assert.Empty((await pc.Kinds.Adapters[1].CaptureAsync(() => service.Now, default)).Operations);
    for (var round = 0; round < 3; round++) await pc.Engine.SyncAsync(default);
    // Nothing of its own: an empty PC is "nothing yet", never "everything removed" and never "all defaults".
    Assert.Equal(sent, service.Segments);
    Assert.Equal(CloudSyncPhase.Level, pc.Engine.State().Phase);

    // The tasks arrived stopped and unassigned, with their project and comment; the connected system's task did not.
    var arrived = pc.Tasks.Read();
    Assert.Equal(new[] { "local:t1", "local:t2" }, arrived.Tasks.Select(t => t.Id).Order(StringComparer.Ordinal).ToArray());
    var t1 = arrived.Tasks.Single(t => t.Id == "local:t1");
    Assert.Equal(("Ship the Windows sync", "Details of Ship the Windows sync", "To-Do", "none", "deck", "High", "2026-12-01"),
      (t1.Title, t1.Details, t1.Status, t1.Assignee, t1.ProjectId, t1.Priority, t1.DueDate));
    Assert.Equal(new[] { "cloud" }, t1.Labels.ToArray());
    Assert.Equal("Looks good to me.", Assert.Single(t1.Comments).Text);
    Assert.Equal(pc.Projects.Get("deck").HomeFolder, t1.Folder);
    Assert.Empty(arrived.Runs); Assert.Empty(arrived.Mentions);
    // Settings: every chosen value of the account, never keep-awake.
    Assert.Equal("True|True|True|codex|False|follow-app||15", Settings(pc));

    // The Macs see nothing new and keep exactly what they had.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(tasksA, Tasks(a)); Assert.Equal(tasksB, Tasks(b));
    Assert.Equal(settingsA, Settings(a)); Assert.Equal(settingsB, Settings(b));

    // The PC restarts from its own disk: still nothing to send, nothing lost.
    var pcTasks = Tasks(pc); var pcSettings = Settings(pc);
    var again = Make(Pc);
    for (var round = 0; round < 2; round++) await again.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(pcTasks, Tasks(again));
    Assert.Equal(pcSettings, Settings(again));
  }

  [Fact]
  public async Task A_PC_with_its_own_older_task_and_chosen_settings_never_overwrites_the_Macs_and_loses_nothing()
  {
    var (a, b) = await TwoMacs();
    // The PC joins later than the Macs made their first copies (two first copies made in the same millisecond would be
    // decided by their ids).
    service.Now += 60_000;
    var tasksA = Tasks(a); var tasksB = Tasks(b);
    var before = Make(Pc);
    // Before joining, the PC already had t1 under an old title, a task of its own, and two settings it CHOSE: a font size
    // (the Macs chose 15) and a font (the Macs never chose one).
    Add(before, NewTask("local:t1", "Old title on the PC", ProjectIdentity.IndependentId, ""));
    Add(before, NewTask("local:pc1", "Only on the PC", ProjectIdentity.IndependentId, "", "A comment written on the PC."));
    before.Appearance.Set(fontSize: 18, fontFamily: "Cascadia Code");

    var pc = Make(Pc);
    Assert.Empty((await pc.Kinds.Adapters[0].CaptureAsync(() => service.Now, default)).Operations);
    Assert.Empty((await pc.Kinds.Adapters[1].CaptureAsync(() => service.Now, default)).Operations);
    for (var round = 0; round < 3; round++) await pc.Engine.SyncAsync(default);

    // Rule J: the Cloud's task wins on the PC; the PC's own older value is kept on the PC for 30 days.
    var t1 = pc.Tasks.Read().Tasks.Single(t => t.Id == "local:t1");
    Assert.Equal(("Ship the Windows sync", "deck"), (t1.Title, t1.ProjectId));
    Assert.Contains(pc.Kinds.Kept.Entries(), e => e.Record == "task:local:t1" && e.Value.Contains("Old title on the PC", StringComparison.Ordinal));
    // Nothing deleted on the PC: its own task is still there.
    Assert.Contains(pc.Tasks.Read().Tasks, t => t.Id == "local:pc1");
    // Two CHOSEN values both stay (the PC keeps 18); a chosen value beats a default (the PC takes the Macs' copy on select
    // and default AI).
    Assert.Equal("True|True|True|codex|False|follow-app|Cascadia Code|18", Settings(pc));

    // The Macs keep exactly what they had, plus what was new from the PC: its own task and the font they never chose.
    for (var round = 0; round < 2; round++) { await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default); }
    Assert.Equal(tasksA, Tasks(a).Where(t => !t.StartsWith("local:pc1|", StringComparison.Ordinal)).ToArray());
    Assert.Equal(tasksB, Tasks(b).Where(t => !t.StartsWith("local:pc1|", StringComparison.Ordinal)).ToArray());
    foreach (var mac in new[] { a, b })
    {
      var mine = mac.Tasks.Read().Tasks.Single(t => t.Id == "local:pc1");
      Assert.Equal(("Only on the PC", "none"), (mine.Title, mine.Assignee));
      Assert.Equal("A comment written on the PC.", Assert.Single(mine.Comments).Text);
      Assert.Equal("Cascadia Code|15", mac.Appearance.Preferences().FontFamily + "|" + mac.Appearance.Preferences().FontSize);
    }
  }

  [Fact]
  public void Approval_required_travels_approval_off_never_and_a_larger_budget_never_arrives()
  {
    var pc = Make(Pc);
    var owner = pc.Kinds.Tasks;
    CloudJson.Object Value(bool? approval, double? budget, string title = "Needs a yes")
    {
      var fields = new List<(string, CloudJson)> { ("id", CloudJson.From("local:a1")), ("keyId", CloudJson.From("local")), ("externalTaskId", CloudJson.From("a1")),
        ("title", CloudJson.From(title)), ("crmStatus", CloudJson.From("To-Do")), ("place", CloudJson.From("tasks")), ("notes", CloudJson.Arr([])) };
      if (approval is { } yes) fields.Add(("decisionRequired", CloudJson.From(yes)));
      if (budget is { } limit) fields.Add(("tokenBudget", CloudJson.From(limit)));
      return CloudRecordJson.Object(fields);
    }
    // "Needs your approval" arrives on a task that had none here: applied.
    var first = owner.CloudPlan("task:local:a1", Value(true, 1000));
    Assert.Null(first.Waiting);
    Assert.True(CloudRecordJson.Bool(CloudRecordJson.Get(first.Store, "decisionRequired")));
    owner.CloudWrite("task:local:a1", first.Store!, null);
    Assert.Equal("none", pc.Tasks.Read().Tasks.Single(t => t.Id == "local:a1").Assignee);

    // "No approval needed" and a larger budget from another device: held, the PC keeps approval and its smaller budget.
    var off = owner.CloudPlan("task:local:a1", Value(false, 5000, "Renamed elsewhere"));
    Assert.Equal(CloudTasksOwner.ApprovalStays, off.Held!["decisionRequired"]);
    Assert.Equal(CloudTasksOwner.BudgetStays, off.Held!["tokenBudget"]);
    Assert.True(CloudRecordJson.Bool(CloudRecordJson.Get(off.Store, "decisionRequired")));
    Assert.Equal((double?)1000, CloudRecordJson.Number(CloudRecordJson.Get(off.Store, "tokenBudget")));
    Assert.Equal("Renamed elsewhere", CloudRecordJson.Text(CloudRecordJson.Get(off.Store, "title")));
    // The PC's own record keeps both, so an edit here never turns approval off on the Macs.
    var records = owner.CloudRecords();
    Assert.True(CloudRecordJson.Bool(CloudRecordJson.Get(records["task:local:a1"], "decisionRequired")));

    // A connected system's task and a task whose project is not here wait; nothing is written.
    var connected = CloudRecordJson.Set(Value(null, null), "keyId", CloudJson.From("iloop"));
    Assert.Equal(CloudTasksOwner.ConnectedSystem, owner.CloudPlan("task:local:a1", connected).Waiting);
    var elsewhere = CloudRecordJson.Set(CloudRecordJson.Set(CloudRecordJson.Set(CloudRecordJson.Set(Value(null, null), "id", CloudJson.From("local:a2")),
      "externalTaskId", CloudJson.From("a2")), "title", CloudJson.From("Waits")), "projectRef", CloudRecordJson.Object([("projectId", CloudJson.From("not-here"))]));
    Assert.Equal(CloudTasksOwner.WaitsForProject, owner.CloudPlan("task:local:a2", elsewhere).Waiting);
    Assert.DoesNotContain(pc.Tasks.Read().Tasks, t => t.Id == "local:a2");
  }

  [Fact]
  public void A_setting_never_chosen_is_not_sent_and_a_default_AI_waits_under_ask_me()
  {
    var pc = Make(Pc, fullAccess: false);
    var owner = pc.Kinds.Settings;
    // Every setting still at its default: nothing is this PC's record.
    Assert.Empty(owner.CloudRecords());
    // A default AI from another device is a widening value: under "Ask me for each new device" it waits, listed.
    var plan = owner.CloudPlan("preference:defaultProvider", CloudRecordJson.Object([("key", CloudJson.From("defaultProvider")), ("value", CloudJson.From("codex"))]));
    Assert.Equal(CloudSettingsOwner.WideningHeld, plan.Held!["value"]);
    // A value of a shape this PC cannot use is held; a setting this PC does not have waits.
    var size = owner.CloudPlan("setting:appearance.terminalFontSize", CloudRecordJson.Object([("key", CloudJson.From("appearance.terminalFontSize")), ("value", CloudJson.From(99))]));
    Assert.Equal(CloudSettingsOwner.NotUsable, size.Held!["value"]);
    Assert.Equal(CloudSettingsOwner.NotListed, owner.CloudPlan("setting:remote.enabled", CloudRecordJson.Object([("key", CloudJson.From("remote.enabled")), ("value", CloudJson.From(true))])).Waiting);
    // Chosen here once, it always travels, also when set back to its default.
    pc.General.Save(pc.General.Read() with { CopyOnSelect = true });
    Assert.Contains("setting:general.copyOnSelect", owner.CloudRecords().Keys);
    pc.General.Save(pc.General.Read() with { CopyOnSelect = false });
    Assert.False(CloudRecordJson.Bool(CloudRecordJson.Get(owner.CloudRecords()["setting:general.copyOnSelect"], "value")));
  }
}
