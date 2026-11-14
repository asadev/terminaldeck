using System.Text;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// 7C-3 safety: a Windows PC joins an account where two Macs already keep a project's AI instruction files. Everything
// runs through the real engine, transport and signed packs against the fixture service (CloudFakeService), never the
// live Cloud. The two "Macs" are this same adapter over their own scratch project folders (it follows the Mac's rules);
// every folder, including the "user profile" whose AI homes are guarded, is a scratch folder, never the real profile.
public sealed class CloudBootFilesJoinTests : IDisposable
{
  private const string Subject = CloudFakeService.Subject;
  private const string MacA = "e3c75f30-363e-4323-a592-cf07fe14c4a6", MacB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e", Pc = "7f306256-7209-4b63-962b-14a7b01b12ee";
  private const string Project = "p1";
  private readonly string scratch = Path.Combine(Path.GetTempPath(), "td-7c3-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(scratch, recursive: true); } catch (DirectoryNotFoundException) { } }

  private sealed class Peer
  {
    public required CloudBootFilesAdapter Adapter;
    public required CloudSyncEngine Engine;
    public required CloudMemoryKeptInMemory Kept;
    public required string Folder;
  }
  private readonly CloudFakeService service = new();
  private readonly CloudTestTrust trust = new();
  private readonly Dictionary<string, CloudTestDevice> devices = [];
  private readonly Dictionary<string, (CloudMemorySlot State, CloudMemorySlot Ledger, CloudMemorySlot Adapter)> slots = [];

  private string FolderOf(string id) => Path.Combine(scratch, id, "app");
  private Peer Make(string id, Dictionary<string, string>? folders = null)
  {
    if (!devices.TryGetValue(id, out var device)) { device = devices[id] = new CloudTestDevice(id, service); trust.Trusted[id] = device.Jwk; }
    if (!slots.TryGetValue(id, out var s)) s = slots[id] = (new CloudMemorySlot(), new CloudMemorySlot(), new CloudMemorySlot());
    var folder = FolderOf(id);
    Directory.CreateDirectory(folder);
    folders ??= new Dictionary<string, string> { [Project] = folder };
    var kept = new CloudMemoryKeptInMemory();
    var adapter = new CloudBootFilesAdapter(s.Adapter, Path.Combine(scratch, id, "state", "retained"), id, () => folders, () => service.Now, kept,
      userProfile: Path.Combine(scratch, "profile"), stateFolder: Path.Combine(scratch, id, "state"));
    var store = new CloudSyncStore(s.State, s.Ledger, Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), Subject, device, service, store, () => service.Now,
      new CloudSyncBackoff(store, () => service.Now, _ => 0));
    var engine = new CloudSyncEngine(Subject, id, client, store, trust, device.Sign, [adapter], null, () => service.Now);
    return new Peer { Adapter = adapter, Engine = engine, Kept = kept, Folder = folder };
  }

  /// Writes a file in a peer's project folder with a fixed time (ms before the service clock).
  private void Write(string id, string relative, string text, long ago)
  {
    var path = Path.Combine([FolderOf(id), .. relative.Split('/')]);
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    File.WriteAllText(path, text);
    File.SetLastWriteTimeUtc(path, DateTimeOffset.FromUnixTimeMilliseconds(service.Now - ago).UtcDateTime);
  }
  private string? Read(string id, string relative)
  {
    var path = Path.Combine([FolderOf(id), .. relative.Split('/')]);
    return File.Exists(path) ? File.ReadAllText(path) : null;
  }
  /// Every file under a peer's project folder (hidden ones too), relative path → text.
  private SortedDictionary<string, string> Snapshot(string id)
  {
    var root = FolderOf(id);
    return new(Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
      .ToDictionary(f => Path.GetRelativePath(root, f).Replace('\\', '/'), f => File.ReadAllText(f), StringComparer.Ordinal), StringComparer.Ordinal);
  }

  private const string Skill = "---\nname: review\ndescription: Reviews a change\n---\nRead the diff, then the tests.\n";

  /// Two Macs with the project's instruction files already in the account and level with each other.
  private async Task<(Peer A, Peer B)> TwoMacs()
  {
    Write(MacA, "CLAUDE.md", "Rules from Mac A.\n", 900_000);
    Write(MacA, "AGENTS.md", "Agents from Mac A.\n", 900_000);
    Write(MacA, ".claude/skills/review/SKILL.md", Skill, 900_000);
    Write(MacA, ".claude/commands/ship.md", "Ship it.\n", 900_000);
    Write(MacB, "GEMINI.md", "Gemini from Mac B.\n", 800_000);
    var a = Make(MacA); var b = Make(MacB);
    await a.Engine.SyncAsync(default);
    await b.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    Assert.Equal(Snapshot(MacA), Snapshot(MacB));
    Assert.Equal(5, Snapshot(MacA).Count);
    return (a, b);
  }

  [Fact]
  public async Task A_fresh_PC_receives_every_file_sends_nothing_and_changes_nothing_on_the_Macs()
  {
    var (a, b) = await TwoMacs();
    var macFiles = Snapshot(MacA);
    var sent = service.Segments;

    var pc = Make(Pc);
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    // An empty folder is "nothing yet": the PC sent no record at all, and received every file byte for byte.
    Assert.Equal(sent, service.Segments);
    Assert.Equal(CloudSyncPhase.Level, pc.Engine.State().Phase);
    Assert.Equal(macFiles, Snapshot(Pc));
    Assert.Equal(0, pc.Adapter.WaitingCount);
    Assert.All(pc.Adapter.Lines, l => Assert.Equal("created", l.Kind));
    Assert.Empty(pc.Kept.Kept);

    // The Macs see nothing new.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(macFiles, Snapshot(MacA));
    Assert.Equal(macFiles, Snapshot(MacB));
    Assert.Equal(sent, service.Segments);

    // The PC restarts from its own disk: still nothing to send, nothing lost or written again.
    var again = Make(Pc);
    await again.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal(macFiles, Snapshot(Pc));
  }

  [Fact]
  public async Task A_PC_with_its_own_text_never_overwrites_the_Macs_its_text_is_kept_and_listed()
  {
    var (a, b) = await TwoMacs();
    var macFiles = Snapshot(MacA);
    var sent = service.Segments;
    // The PC had its own CLAUDE.md before it joined, NEWER than the Macs' one: rule J still makes it lose.
    Write(Pc, "CLAUDE.md", "The PC's own rules.\n", 1_000);

    var pc = Make(Pc);
    await pc.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    // The account's text is in use on the PC; the PC's own is kept (outside the folder) and listed. Nothing was sent.
    Assert.Equal(macFiles, Snapshot(Pc));
    var kept = Assert.Single(pc.Kept.Kept);
    Assert.Equal("The PC's own rules.\n", Encoding.UTF8.GetString(kept.Bytes));
    var line = Assert.Single(pc.Adapter.Lines, l => l.Kind == "replaced");
    Assert.Equal("CLAUDE.md", line.Path);
    Assert.Equal(Project, line.Place);
    Assert.NotNull(line.Kept);
    Assert.Equal(sent, service.Segments);

    // The Macs end exactly as they were, and another round anywhere sends nothing.
    await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default); await pc.Engine.SyncAsync(default);
    Assert.Equal(macFiles, Snapshot(MacA));
    Assert.Equal(macFiles, Snapshot(MacB));
    Assert.Equal(sent, service.Segments);
  }

  [Fact]
  public async Task Nothing_is_sent_before_the_whole_feed_was_read_then_a_new_file_goes_up()
  {
    var (a, _) = await TwoMacs();
    Write(Pc, ".claude/commands/from-pc.md", "Made on the PC.\n", 5_000);
    var pc = Make(Pc);
    var early = await pc.Adapter.CaptureAsync(() => service.Now, default);
    Assert.Empty(early.Operations);

    await pc.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    Assert.Equal("Made on the PC.\n", Read(MacA, ".claude/commands/from-pc.md"));
    Assert.Equal("Rules from Mac A.\n", Read(Pc, "CLAUDE.md"));
  }

  [Fact]
  public async Task The_newer_edit_is_used_on_every_device_and_the_other_text_is_kept()
  {
    var (a, b) = await TwoMacs();
    var pc = Make(Pc);
    await pc.Engine.SyncAsync(default);

    // Both edit CLAUDE.md apart from each other; the PC's edit is the later one.
    service.Now += 60_000;
    Write(MacA, "CLAUDE.md", "Mac A's edit.\n", 30_000);
    Write(Pc, "CLAUDE.md", "The PC's edit.\n", 10_000);
    await a.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    await b.Engine.SyncAsync(default);
    Assert.Equal("The PC's edit.\n", Read(Pc, "CLAUDE.md"));
    Assert.Equal("The PC's edit.\n", Read(MacA, "CLAUDE.md"));
    Assert.Equal("The PC's edit.\n", Read(MacB, "CLAUDE.md"));
    Assert.Contains(pc.Kept.Kept, k => Encoding.UTF8.GetString(k.Bytes) == "Mac A's edit.\n");
    Assert.Contains(a.Kept.Kept, k => Encoding.UTF8.GetString(k.Bytes) == "Mac A's edit.\n");

    // Then Mac B's later edit is the newest: it is used on the PC too, and the PC's text is kept.
    service.Now += 60_000;
    Write(MacB, "CLAUDE.md", "Mac B's edit.\n", 1_000);
    await b.Engine.SyncAsync(default);
    await pc.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    Assert.Equal("Mac B's edit.\n", Read(Pc, "CLAUDE.md"));
    Assert.Equal("Mac B's edit.\n", Read(MacA, "CLAUDE.md"));
    // Everyone level: another round sends nothing.
    var sent = service.Segments;
    await pc.Engine.SyncAsync(default); await a.Engine.SyncAsync(default); await b.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
  }

  [Fact]
  public async Task A_removal_on_the_PC_or_on_a_Mac_removes_nothing()
  {
    var (a, _) = await TwoMacs();
    var pc = Make(Pc);
    await pc.Engine.SyncAsync(default);
    var sent = service.Segments;

    // Removed on the PC: never sent as a removal; the Macs keep the file.
    File.Delete(Path.Combine(FolderOf(Pc), "AGENTS.md"));
    await pc.Engine.SyncAsync(default);
    await a.Engine.SyncAsync(default);
    Assert.Equal(sent, service.Segments);
    Assert.Equal("Agents from Mac A.\n", Read(MacA, "AGENTS.md"));

    // Removed on a Mac (a removal record): listed on the PC, the PC's file stays.
    const string key = "file/project/7031/CLAUDE.md";
    string store = Guid.NewGuid().ToString("D"), parent = Guid.NewGuid().ToString("D"), version = Guid.NewGuid().ToString("D");
    var hash = CloudMemoryFormat.Hash(Encoding.UTF8.GetBytes("Rules from Mac A.\n"));
    var marker = CloudJson.Obj(("format", CloudJson.From("td-file-archive-1")), ("inventoryRow", CloudJson.From("I09")), ("key", CloudJson.From(key)),
      ("parents", CloudJson.Arr([CloudJson.From(parent)])), ("resourceHash", CloudJson.From(hash)), ("storeId", CloudJson.From(store)), ("version", CloudJson.From(version)));
    var opId = CloudMemoryFormat.OperationId(version + "\narchive");
    var removal = new CloudOperation(1, opId, MacA, CloudBootFilesFormat.Domain, CloudMemoryFormat.Uuid(store + "\n" + key + "\narchive"), opId,
      [CloudMemoryFormat.OperationId(parent + "\narchive")], "archive", Project, "primary", new CloudSourceReference("files/I09/project/7031", key, null, hash),
      service.Now, marker, CloudOperation.PayloadHashOf(marker));
    await pc.Adapter.ApplyAsync(removal, new CloudImportOrigin(MacA, 999, null, false), default);
    await pc.Adapter.SettleAsync(default);
    Assert.Equal("Rules from Mac A.\n", Read(Pc, "CLAUDE.md"));
    Assert.Contains(pc.Adapter.Lines, l => l.Kind == "removed-elsewhere" && l.Path == "CLAUDE.md");
  }

  [Fact]
  public async Task Settings_hooks_MCP_and_sign_in_files_are_never_sent_and_never_written()
  {
    var never = new[] { ".claude/settings.json", ".claude/settings.local.json", ".mcp.json", ".claude/skills/x/settings.json", ".claude/skills/x/hooks/pre.md",
      ".claude/skills/x/mcp.json", ".claude/skills/x/auth.json", ".claude/skills/x/.credentials.json", ".claude/skills/x/token.json", ".claude/agents/hooks.json",
      ".claude/skills/x/node_modules/p/readme.md", ".claude/skills/x/server.pem", ".codex/config.toml", ".gemini/settings.json", "src/CLAUDE.md" };
    foreach (var path in never) Write(Pc, path, "{\"secret\": true}\n", 5_000);
    Write(Pc, ".claude/skills/x/SKILL.md", "An ordinary skill.\n", 5_000);
    var pc = Make(Pc);
    pc.Adapter.FeedRead();
    var capture = await pc.Adapter.CaptureAsync(() => service.Now, default);
    var keys = capture.Operations.Select(o => ((CloudJson.Object)o.Payload)["key"]!.AsString!).ToArray();
    Assert.Equal(new[] { "file/project/7031/.claude/skills/x/SKILL.md" }, keys);

    // A record that names one of them is refused before a byte is kept or written.
    var before = Snapshot(Pc);
    foreach (var path in never.Append("../outside.md").Append(".claude/skills/../../outside.md"))
    {
      var op = CloudBootFilesFormat.Records(Guid.NewGuid().ToString("D"), "file/project/7031/" + path, "project/7031", Guid.NewGuid().ToString("D"), [],
        Encoding.UTF8.GetBytes("planted\n"), MacA, service.Now, Project, "primary")[0];
      var refused = await Assert.ThrowsAsync<CloudFailure>(() => pc.Adapter.ApplyAsync(op, new CloudImportOrigin(MacA, 1, null, false), default));
      Assert.Equal("invalid_request", refused.Code);
    }
    Assert.Equal(before, Snapshot(Pc));
    Assert.Empty(pc.Adapter.Lines);
    Assert.False(Directory.Exists(Path.Combine(scratch, Pc, "state", "retained")));
  }

  [Fact]
  public async Task A_projects_files_wait_without_a_folder_then_arrive_when_it_has_one()
  {
    var (a, _) = await TwoMacs();
    var macFiles = Snapshot(MacA);
    var sent = service.Segments;
    var folders = new Dictionary<string, string>();
    var pc = Make(Pc, folders);
    await pc.Engine.SyncAsync(default);
    // No folder for the project on this PC: nothing written anywhere, nothing sent, every file waits (kept).
    Assert.Empty(Snapshot(Pc));
    Assert.Equal(5, pc.Adapter.WaitingCount);
    Assert.All(pc.Adapter.Lines, l => Assert.Equal("waiting", l.Kind));
    Assert.Equal(sent, service.Segments);

    // A folder that is the user's own folder (or holds an AI account's folder) is never used.
    folders[Project] = Path.Combine(scratch, "profile");
    await pc.Engine.SyncAsync(default);
    Assert.False(Directory.Exists(Path.Combine(scratch, "profile")));
    Assert.Equal(5, pc.Adapter.WaitingCount);

    // The project gets its folder here (7C-2): the files arrive, and still nothing is sent.
    folders[Project] = FolderOf(Pc);
    await pc.Engine.SyncAsync(default);
    Assert.Equal(macFiles, Snapshot(Pc));
    Assert.Equal(0, pc.Adapter.WaitingCount);
    Assert.Equal(sent, service.Segments);
    await a.Engine.SyncAsync(default);
    Assert.Equal(macFiles, Snapshot(MacA));
  }
}
