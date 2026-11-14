using System.Collections.Immutable;
using System.Text;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Cloud;

// 7C-2 safety: projects and agents. A Windows PC joins an account where two Macs already keep their projects and agents.
// Everything runs through the real engine, transport and signed packs against the fixture service (CloudFakeService),
// never the live Cloud. The two "Macs" are this same records stack (it follows the Mac's rules) over their own data
// folders; every device uses the real project and agent services on disk, in a scratch folder, and is restarted from disk.
public sealed class CloudRecordsJoinTests : IDisposable
{
  private const string Subject = CloudFakeService.Subject;
  private const string MacA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", MacB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e", Pc = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string StoreA = "2b7e1516-28ae-4d2a-a6d2-abf7158809cf", StorePc = "5d41402a-bc4b-4a76-b971-9d911017c592";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-7c2-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { } }

  private sealed class Peer
  {
    public required string Home;
    public required string Profile;
    public required AppDataRoot Root;
    public required ProjectService Projects;
    public required AgentService Agents;
    public required CloudRecordsForAccount Records;
    public required CloudSyncEngine Engine;
    public CloudMemoryAdapter? Memory;
  }
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private readonly Dictionary<string, CloudTestDevice> devices = [];
  private readonly Dictionary<string, (CloudMemorySlot State, CloudMemorySlot Ledger, CloudMemorySlot Memory)> slots = [];

  /// One device from its own disk. `records`: the projects and agents rows are registered; `memory`: Deck Memory too.
  private Peer Make(string id, bool records = true, IDeckMemoryCloudStore? memory = null, bool fullAccess = true)
  {
    if (!devices.TryGetValue(id, out var device)) { device = devices[id] = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk; }
    if (!slots.TryGetValue(id, out var s)) s = slots[id] = (new CloudMemorySlot(), new CloudMemorySlot(), new CloudMemorySlot());
    var home = Path.Combine(scratch, id[..8]);
    var root = AppDataRoot.Explicit(Path.Combine(home, "data"));
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
    var profile = Path.Combine(home, "profile");
    var folders = new CloudProjectFolders(Path.Combine(root.DirectoryPath, "cloud", "project-folders.json"), profile, [root.DirectoryPath], () => service.Now);
    CloudMemoryAdapter? adapter = null;
    var recordsHere = new CloudRecordsForAccount(Path.Combine(root.DirectoryPath, "cloud", "accounts", Subject), Subject, id, projects, agents, folders,
      () => fullAccess, () => adapter?.RetryProjects(), () => service.Now);
    if (memory is not null) adapter = new CloudMemoryAdapter(memory, s.Memory, id, projects: recordsHere.Projects.MemoryProject, localNow: () => service.Now);
    var owners = new List<ICloudSyncAdapter>();
    if (records) owners.AddRange(recordsHere.Adapters);
    if (adapter is not null) owners.Add(adapter);
    var store = new CloudSyncStore(s.State, s.Ledger, Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, owners, null, () => service.Now);
    return new Peer { Home = home, Profile = profile, Root = root, Projects = projects, Agents = agents, Records = recordsHere, Engine = engine, Memory = adapter };
  }

  private static string Folder(Peer peer, string name)
  {
    var path = Path.Combine(peer.Home, "code", name);
    Directory.CreateDirectory(path);
    return path;
  }
  private static void AddProject(Peer peer, string id, string name, string folderName, string colour = "green") =>
    peer.Projects.Save(new ProjectDraft(id, name, [Folder(peer, folderName)], "folder", colour), createOnly: true);
  private static void AddAgent(Peer peer, string id, string name, string project, string instructions)
  {
    peer.Agents.Save(new SavedAgent(id, name, "claude", Description: "Writes the release notes", ProjectId: project), createOnly: true);
    peer.Agents.SaveInstructions(id, instructions);
  }
  private static IReadOnlyList<string> Projects(Peer peer) => peer.Projects.List().Where(p => p.Id != ProjectIdentity.IndependentId).OrderBy(p => p.Id, StringComparer.Ordinal)
    .Select(p => string.Join('|', p.Id, p.Name, p.Icon, p.Colour, p.Lead ?? "", string.Join(';', p.Folders))).ToArray();
  private static IReadOnlyList<string> Agents(Peer peer) => peer.Agents.List().OrderBy(a => a.Id, StringComparer.Ordinal)
    .Select(a => string.Join('|', a.Id, a.Name, a.Provider, a.ProjectId, a.Seat, a.Description, a.Model, a.Effort, a.Icon, a.Status, peer.Agents.ReadInstructions(a.Id))).ToArray();
  private static string ProjectsFolder(Peer peer) => Path.Combine(peer.Profile, CloudProjectFolders.BaseName, CloudProjectFolders.ProjectsName);

  /// Two Macs with their projects and agents in the account, level with each other.
  private async Task<(Peer A, Peer B)> TwoMacs()
  {
    var a = Make(MacA);
    AddProject(a, "deck", "Deck", "deck");
    AddProject(a, "crm", "CRM", "crm", "blue");
    AddAgent(a, "writer", "Writer", "deck", "Write clearly and briefly.");
    var b = Make(MacB);
    AddProject(b, "site", "Site", "site", "teal");
    await a.Engine.SyncAsync(default);
    await b.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    await b.Engine.SyncAsync(default);
    Assert.Equal(new[] { "crm", "deck", "site" }, a.Projects.List().Where(p => p.Id != ProjectIdentity.IndependentId).Select(p => p.Id).Order(StringComparer.Ordinal).ToArray());
    Assert.Equal(new[] { "crm", "deck", "site" }, b.Projects.List().Where(p => p.Id != ProjectIdentity.IndependentId).Select(p => p.Id).Order(StringComparer.Ordinal).ToArray());
    Assert.Equal("Write clearly and briefly.", b.Agents.ReadInstructions("writer"));
    return (a, b);
  }

  [Fact]
  public async Task A_fresh_PC_receives_projects_and_agents_with_folders_sends_nothing_and_the_Macs_keep_what_they_had()
  {
    var (a, b) = await TwoMacs();
    var macA = Projects(a); var macB = Projects(b); var agentsA = Agents(a); var agentsB = Agents(b);
    var sent = service.Segments;

    var pc = Make(Pc);
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    // Nothing of its own: an empty PC is "nothing yet", never "everything removed".
    Assert.Equal(sent, service.Segments);
    Assert.Equal(CloudSyncPhase.Level, pc.Engine.State().Phase);

    // Every project arrived with a folder made BY ITSELF under the PC's own Terminal Deck folder, named after the project.
    var arrived = pc.Projects.List().Where(p => p.Id != ProjectIdentity.IndependentId).OrderBy(p => p.Id, StringComparer.Ordinal).ToArray();
    Assert.Equal(new[] { "crm", "deck", "site" }, arrived.Select(p => p.Id).ToArray());
    Assert.Equal(new[] { "CRM", "Deck", "Site" }, arrived.Select(p => p.Name).ToArray());
    Assert.Equal(new[] { "blue", "green", "teal" }, arrived.Select(p => p.Colour).ToArray());
    foreach (var project in arrived)
    {
      var folder = Assert.Single(project.Folders);
      Assert.Equal(Path.Combine(ProjectsFolder(pc), project.Name), folder, ignoreCase: true);
      Assert.True(Directory.Exists(folder));
      Assert.Empty(Directory.EnumerateFileSystemEntries(folder));
      // Sync never fetches code: the page says "Code not on this PC yet".
      Assert.True(CloudProjectFolders.HoldsOnlyCloudFiles(folder));
    }
    // The agent arrived with its project, seat and instruction text; nothing started.
    var writer = pc.Agents.Get("writer");
    Assert.Equal(("Writer", "deck", "claude", "Writes the release notes"), (writer.Name, writer.ProjectId, writer.Provider, writer.Description));
    Assert.Equal("Write clearly and briefly.", pc.Agents.ReadInstructions("writer"));
    Assert.Empty(pc.Agents.Runs());

    // The Macs see nothing new.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(macA, Projects(a)); Assert.Equal(macB, Projects(b));
    Assert.Equal(agentsA, Agents(a)); Assert.Equal(agentsB, Agents(b));
    Assert.Equal(0, a.Records.Adapters[0].Listing().KeptCount);

    // The PC restarts from its own disk: still nothing to send, no second folder, nothing lost.
    var pcProjects = Projects(pc); var pcAgents = Agents(pc);
    var again = Make(Pc);
    await again.Engine.SyncAsync(default);
    await again.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(pcProjects, Projects(again));
    Assert.Equal(pcAgents, Agents(again));
    Assert.Equal(3, Directory.EnumerateDirectories(ProjectsFolder(again)).Count());
  }

  [Fact]
  public async Task A_PC_with_its_own_older_project_never_overwrites_the_Macs_and_its_folder_is_never_moved_or_sent()
  {
    var (a, b) = await TwoMacs();
    var macA = Projects(a); var macB = Projects(b);
    // Before joining, the PC already had "deck" under an old name, in its own folder, and a project of its own.
    var before = Make(Pc);
    AddProject(before, "deck", "Deck (old PC)", "pc-own-folder-7c2", "pink");
    AddProject(before, "pc-notes", "PC notes", "pc-notes-folder-7c2", "orange");
    var ownFolder = before.Projects.Get("deck").Folders.Single();

    var pc = Make(Pc);
    // Before it has read the whole feed once, the PC hands the engine nothing of its own.
    Assert.Empty((await pc.Records.Adapters[0].CaptureAsync(() => service.Now, default)).Operations);
    Assert.Empty((await pc.Records.Adapters[1].CaptureAsync(() => service.Now, default)).Operations);
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);

    // Rule J: the Cloud's name and colour win on the PC; the PC's own older values are kept and listed.
    var deck = pc.Projects.Get("deck");
    Assert.Equal(("Deck", "green"), (deck.Name, deck.Colour));
    Assert.Equal(new[] { ownFolder }, deck.Folders.ToArray());
    Assert.False(Directory.Exists(Path.Combine(ProjectsFolder(pc), "Deck")));
    Assert.True(pc.Records.Adapters[0].Listing().KeptCount >= 1);

    // The Macs keep exactly what they had, plus the PC's own new project, which gets its own folder on each Mac.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(macA, Projects(a).Where(p => !p.StartsWith("pc-notes|", StringComparison.Ordinal)).ToArray());
    Assert.Equal(macB, Projects(b).Where(p => !p.StartsWith("pc-notes|", StringComparison.Ordinal)).ToArray());
    foreach (var mac in new[] { a, b })
    {
      var notes = mac.Projects.Get("pc-notes");
      Assert.Equal("PC notes", notes.Name);
      Assert.Equal(Path.Combine(ProjectsFolder(mac), "PC notes"), Assert.Single(notes.Folders), ignoreCase: true);
      // No PC folder path reached the Mac: not in its projects, not in anything it keeps.
      foreach (var file in Directory.EnumerateFiles(mac.Root.DirectoryPath, "*", SearchOption.AllDirectories))
        Assert.DoesNotContain("folder-7c2", File.ReadAllText(file), StringComparison.Ordinal);
    }
  }

  [Fact]
  public async Task An_arriving_project_never_takes_a_folder_that_is_already_there()
  {
    var (_, _) = await TwoMacs();
    var pc = Make(Pc);
    // His own folder (and a file in it) already has the project's name.
    var his = Path.Combine(ProjectsFolder(pc), "Deck");
    Directory.CreateDirectory(his);
    File.WriteAllText(Path.Combine(his, "mine.txt"), "his");
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    Assert.Equal(Path.Combine(ProjectsFolder(pc), "Deck 2"), Assert.Single(pc.Projects.Get("deck").Folders), ignoreCase: true);
    Assert.Equal("his", File.ReadAllText(Path.Combine(his, "mine.txt")));
    Assert.Equal(new[] { "mine.txt" }, Directory.EnumerateFileSystemEntries(his).Select(e => Path.GetFileName(e)!).ToArray());
  }

  [Fact]
  public async Task Two_devices_editing_one_field_the_newest_wins_everywhere_and_the_other_is_kept()
  {
    var (a, b) = await TwoMacs();
    a.Projects.Rename("deck", "Deck A", "Deck");
    await a.Engine.SyncAsync(default);
    service.Now += 5_000;
    b.Projects.Rename("deck", "Deck B", "Deck");
    await b.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    await b.Engine.SyncAsync(default);
    Assert.Equal("Deck B", a.Projects.Get("deck").Name);
    Assert.Equal("Deck B", b.Projects.Get("deck").Name);
    Assert.True(a.Records.Adapters[0].Listing().KeptCount >= 1);
    Assert.True(b.Records.Adapters[0].Listing().KeptCount >= 1);
    // A folder is never moved or renamed by a rename.
    Assert.EndsWith("deck", Assert.Single(a.Projects.Get("deck").Folders), StringComparison.Ordinal);
  }

  [Fact]
  public async Task An_agent_removed_on_the_PC_stays_removed_and_is_not_removed_on_the_Macs()
  {
    var (a, _) = await TwoMacs();
    var pc = Make(Pc);
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    var writer = pc.Agents.Get("writer");
    pc.Agents.Save(writer with { Status = SavedAgentStatus.Archived }, expected: writer);
    pc.Agents.Remove("writer");
    await pc.Engine.SyncAsync(default);
    service.Now += 5_000;
    var onMac = a.Agents.Get("writer");
    a.Agents.Save(onMac with { Description = "Edits the release notes" }, expected: onMac);
    await a.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    Assert.DoesNotContain(pc.Agents.List(), x => x.Id == "writer");
    Assert.Contains(pc.Records.Adapters[1].Listing().WaitingHere, w => w.Record == "agent:writer" && w.Reason == CloudAgentsOwner.RemovedHere);
    await a.Engine.SyncAsync(default);
    Assert.Equal(SavedAgentStatus.Active, a.Agents.Get("writer").Status);
    Assert.Equal("Edits the release notes", a.Agents.Get("writer").Description);
  }

  [Fact]
  public async Task Project_memory_that_arrived_first_waits_and_is_placed_when_its_project_arrives()
  {
    var memA = new InMemoryDeckMemoryStore(StoreA);
    var text = Encoding.UTF8.GetBytes("# Release plan\n\nShip on Friday.\n");
    memA.WriteFile("projects/deck/notes/plan.md", text);
    // Mac A sends its memory before its projects (an older Mac, or memory switched on first).
    var memoryOnly = Make(MacA, records: false, memory: memA);
    await memoryOnly.Engine.SyncAsync(default);
    await memoryOnly.Engine.SyncAsync(default);

    var memPc = new InMemoryDeckMemoryStore(StorePc);
    var pc = Make(Pc, memory: memPc);
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    Assert.Null(memPc.ReadFile("projects/deck/notes/plan.md"));
    Assert.Equal(1, pc.Memory!.WaitingCount);

    var a = Make(MacA, memory: memA);
    AddProject(a, "deck", "Deck", "deck");
    await a.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    Assert.Equal("Deck", pc.Projects.Get("deck").Name);
    Assert.Equal(text, memPc.ReadFile("projects/deck/notes/plan.md"));
    Assert.Equal(0, pc.Memory.WaitingCount);
  }

  // ---- folder names and refused places (the Mac's BackendProjectFolders rules, on Windows) ----

  [Theory]
  [InlineData("Deck", "Deck")]
  [InlineData("a/b:c?d", "a-b-c-d")]
  [InlineData("  .hidden  ", "hidden")]
  [InlineData("..", "Project")]
  [InlineData("", "Project")]
  [InlineData("CON", "CON project")]
  [InlineData("lpt1.txt", "lpt1.txt project")]
  [InlineData("Notes.", "Notes")]
  public void A_project_name_becomes_a_safe_folder_name(string name, string expected) => Assert.Equal(expected, CloudProjectFolders.SafeName(name));

  [Fact]
  public void Names_are_capped_in_bytes_and_candidates_are_plain()
  {
    Assert.True(Encoding.UTF8.GetByteCount(CloudProjectFolders.SafeName(new string('é', 300))) <= CloudProjectFolders.MaximumNameBytes);
    Assert.Equal(new[] { "Deck", "Deck 2", "Deck 3" }, CloudProjectFolders.Candidates("Deck").Take(3).ToArray());
  }

  [Fact]
  public void Sensitive_places_are_refused_and_his_own_folders_are_not()
  {
    var profile = Path.Combine(scratch, "profile");
    var app = Path.Combine(scratch, "app-data");
    Directory.CreateDirectory(Path.Combine(profile, "Work"));
    Assert.NotNull(CloudProjectFolders.Refusal(profile, profile, [app]));
    Assert.NotNull(CloudProjectFolders.Refusal(scratch, profile, [app]));
    Assert.NotNull(CloudProjectFolders.Refusal(Path.Combine(profile, "AppData", "Roaming", "x"), profile, [app]));
    Assert.NotNull(CloudProjectFolders.Refusal(Path.Combine(profile, ".ssh"), profile, [app]));
    Assert.NotNull(CloudProjectFolders.Refusal(Path.Combine(app, "projects"), profile, [app]));
    Assert.NotNull(CloudProjectFolders.Refusal(Path.GetPathRoot(Path.GetFullPath(profile))!, profile, [app]));
    Assert.NotNull(CloudProjectFolders.Refusal(Path.Combine(profile, "Work"), profile, [app], [Path.Combine(profile, "Work")]));
    Assert.Null(CloudProjectFolders.Refusal(Path.Combine(profile, "Work"), profile, [app]));
    Assert.Null(CloudProjectFolders.Refusal(Path.Combine(profile, "Terminal Deck", "Projects", "Deck"), profile, [app]));
  }

  [Fact]
  public void A_project_record_never_carries_a_folder()
  {
    var project = new Project("deck", "Deck", ImmutableArray.Create(@"C:\Users\someone\code\deck"), "folder", "green");
    var record = CloudRecordAdapter.Travelling(CloudProjectsOwner.Record(project), CloudMergeTables.Project);
    Assert.DoesNotContain(record.Members, m => m.Key == "folders");
    Assert.DoesNotContain("code", CloudRecordJson.Encode(record), StringComparison.Ordinal);
  }
}
