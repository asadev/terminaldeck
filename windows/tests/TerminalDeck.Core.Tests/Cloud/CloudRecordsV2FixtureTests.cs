using System.Text;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Cloud;

// Lane D2 cross-check (Security, 15 Nov): version-2 records MADE BY THE MAC (td-mac-records-fixtures,
// RecordsV2FixturesTests) read by this PC's record reader, and one record made here for the Mac's reading test.
// Mac files, td-ops-1 pack bytes + the Mac's merged view of each record: `Fixtures/records-v2-mac-task.json`,
// `-project-cloud-removal.json`, `-agent-old-removal.json`, `-views.json` (or the folder in TD_RECORDS_MAC_FIXTURES).
// Windows file for the Mac: `records-v2-windows-project-cloud-removal.json` + `records-v2-windows-views.json`, written to
// TD_RECORDS_FIXTURES_OUT (else `records-v2-windows` beside the test assembly).
public sealed class CloudRecordsV2FixtureTests : IDisposable
{
  private static readonly string[] MacFiles = ["task", "project-cloud-removal", "agent-old-removal", "views"];
  private static string MacFolder => Environment.GetEnvironmentVariable("TD_RECORDS_MAC_FIXTURES") is { Length: > 0 } given ? given : Path.Combine(AppContext.BaseDirectory, "Fixtures");
  private static string MacPath(string name) => Path.Combine(MacFolder, "records-v2-mac-" + name + ".json");
  public static bool MacFixturesHere => MacFiles.All(n => File.Exists(MacPath(n)));

  /// Skipped, with the reason, while the Mac-made files are not here yet.
  public sealed class MacFixturesFactAttribute : FactAttribute
  {
    public MacFixturesFactAttribute()
    {
      if (!MacFixturesHere) Skip = "The Mac-made version-2 fixtures are not here yet (records-v2-mac-*.json in " + MacFolder
        + "). Made by the Mac test RecordsV2FixturesTests (td-mac-records-fixtures); copy them in and run again.";
    }
  }

  private const string Subject = CloudFakeService.Subject, Pc = "c4d5e6f7-0a1b-4c2d-9e3f-5a6b7c8d9e0f";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-d2-fix-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }

  private sealed record Side(string Home, ProjectService Projects, AgentService Agents, TaskStore Tasks, CloudRecordsForAccount Records, CloudKindsForAccount Kinds)
  {
    public IEnumerable<CloudRecordAdapter> Adapters => Records.Adapters.Concat(Kinds.Adapters);
    public CloudRecordAdapter For(string domain) => Adapters.First(a => a.Domain == domain);
  }
  private Side Make()
  {
    var home = Path.Combine(scratch, "pc");
    var root = AppDataRoot.Explicit(Path.Combine(home, "data"));
    long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
    var folders = new CloudProjectFolders(Path.Combine(root.DirectoryPath, "cloud", "project-folders.json"), Path.Combine(home, "profile"), [root.DirectoryPath], Now);
    var account = Path.Combine(root.DirectoryPath, "cloud", "accounts", Subject);
    var records = new CloudRecordsForAccount(account, Subject, Pc, projects, agents, folders, () => true, null, Now, new CloudDeleteWitnessSlot());
    var tasks = TaskStore.At(root);
    var general = new GeneralSettings(new JsonStateStore<GeneralPreferences>(root, "general-settings"));
    var appearance = new TerminalAppearanceService(new JsonStateStore<TerminalAppearanceState>(root, "terminal-appearance"));
    var kinds = new CloudKindsForAccount(account, Subject, Pc, tasks, projects, CloudSettingsOwner.ForWindows(general, appearance), () => true, Now, quiet: 0);
    records.ConfigureDeleteRule(() => true, _ => null, () => Now());
    kinds.ConfigureDeleteRule(() => true, _ => null, () => Now());
    return new(home, projects, agents, tasks, records, kinds);
  }
  private static string View(CloudRecordStore store, string domain, string entity, CloudMergeTable table)
  {
    var view = store.View(CloudRecordKey.Of(domain, entity), table);
    CloudJson value = view is null ? CloudJson.Null.Value : CloudRecordJson.Object([("exists", CloudJson.From(view.Exists)), ("shown", view.Shown())]);
    return Encoding.UTF8.GetString(CloudCanonical.Encode(value));
  }
  private static string Theirs(CloudJson views, string entity) => Encoding.UTF8.GetString(CloudCanonical.Encode(CloudRecordJson.Get(views, entity) ?? CloudJson.Null.Value));

  /// Every Mac pack reads back to the same bytes and every payload hash is equal on this PC; applied here, each record
  /// merges to exactly the Mac's merged record; the project is kept as "Only on this PC"; the agent is in the Bin.
  [MacFixturesFact]
  public async Task Mac_made_version_2_records_are_accepted_with_equal_hashes_and_the_same_merged_record()
  {
    var pc = Make();
    foreach (var name in MacFiles.Where(n => n != "views"))
    {
      var bytes = File.ReadAllBytes(MacPath(name));
      var operations = CloudPackFormat.Decode(bytes);
      Assert.Equal(bytes, CloudPackFormat.Encode(operations));
      foreach (var op in operations)
      {
        Assert.Equal(op.PayloadHash, CloudOperation.PayloadHashOf(op.Payload));
        await pc.For(op.Domain).ApplyAsync(op, new CloudImportOrigin(op.OriginDevice, 1, op.CreatedAt, false), default);
      }
      foreach (var adapter in pc.Adapters) await adapter.SettleAsync(default);
    }
    // Nothing set aside: no record waits as unreadable or "written by a newer version".
    Assert.All(pc.Adapters, a => Assert.DoesNotContain(a.Listing().WaitingHere, w => w.Reason.Contains("newer version", StringComparison.Ordinal)));
    var views = CloudJson.Parse(File.ReadAllBytes(MacPath("views")));
    Assert.Equal(Theirs(views, "task:local:one"), View(pc.Kinds.Store, "tasks", "task:local:one", CloudTasksOwner.Kind.Table));
    Assert.Equal(Theirs(views, "project:review"), View(pc.Records.Store, "projects", "project:review", CloudProjectsOwner.Kind.Table));
    Assert.Equal(Theirs(views, "agent:reviewer"), View(pc.Records.Store, "agents", "agent:reviewer", CloudAgentsOwner.AgentKind.Table));
    Assert.Equal(Theirs(views, "instruction:reviewer.md"), View(pc.Records.Store, "agents", "instruction:reviewer.md", CloudAgentsOwner.InstructionKind.Table));
    // The task is on this PC; the awkward values are carried exactly as the Mac wrote them.
    Assert.Contains(pc.Tasks.Read().Tasks, t => t.Id == "local:one" && t.DeletedAt is null);
    // The project removed with scope "Cloud" stays here as "Only on this PC".
    Assert.NotNull(pc.Projects.List().FirstOrDefault(p => p.Id == "review"));
    Assert.Equal(CloudLocalMark.OnlyOnThisPc, Assert.Single(await pc.Records.Projects.NotHereAsync()).Mark);
    // The old-kind agent removal: the agent is gone and in the Bin, grouped "(older version)".
    Assert.DoesNotContain(pc.Agents.List(), a => a.Id == "reviewer");
    var group = Assert.Single(await pc.Records.Agents.BinGroupsAsync());
    Assert.Equal(CloudBinEra.OlderVersion, group.Era);
    Assert.Contains(group.Items, i => i.Id == "agent:reviewer");
  }

  /// The Windows-made record the Mac's reading test takes: a project removed with full attribution and scope "Cloud".
  [Fact]
  public async Task Writes_a_Windows_made_version_2_project_removal_for_the_Mac()
  {
    var pc = Make();
    pc.Projects.Save(new ProjectDraft("review", "Review", [Directory.CreateDirectory(Path.Combine(pc.Home, "code", "review")).FullName]), createOnly: true);
    var adapter = pc.For("projects");
    adapter.FeedRead();
    long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    var first = await adapter.CaptureAsync(Now, default); first.Commit();
    var actor = new CloudDeleteActor(CloudDeleteBy.Person, Pc, "Office PC", null, null, Now(), Guid.NewGuid().ToString("D"));
    await pc.Records.Projects.DeleteItemsAsync([new CloudDeleteItem("project:review", "project", "Review")], CloudDeleteScope.Cloud, actor);
    var removal = await adapter.CaptureAsync(Now, default); removal.Commit();
    var operations = first.Operations.Concat(removal.Operations).ToArray();
    Assert.Contains(operations, o => CloudMergeVersion.Parse(o.Payload).MinTable == 2
      && CloudRecordJson.Text(CloudRecordJson.Get(CloudRecordJson.Get(o.Payload, "fields"), "deletedScope")) == "cloud"
      && CloudRecordJson.Bool(CloudRecordJson.Get(CloudRecordJson.Get(o.Payload, "fields"), CloudRecordMerge.ExistsField)) == false);
    var folder = Environment.GetEnvironmentVariable("TD_RECORDS_FIXTURES_OUT") is { Length: > 0 } given ? given : Path.Combine(AppContext.BaseDirectory, "records-v2-windows");
    Directory.CreateDirectory(folder);
    var bytes = CloudPackFormat.Encode(operations);
    Assert.Equal(bytes, CloudPackFormat.Encode(CloudPackFormat.Decode(bytes)));
    File.WriteAllBytes(Path.Combine(folder, "records-v2-windows-project-cloud-removal.json"), bytes);
    var view = CloudJson.Parse(View(pc.Records.Store, "projects", "project:review", CloudProjectsOwner.Kind.Table));
    File.WriteAllBytes(Path.Combine(folder, "records-v2-windows-views.json"), CloudCanonical.Encode(CloudRecordJson.Object([("project:review", view)])));
  }
}
