using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Tests.Browser;
using TerminalDeck.Core.Tests.Chats;
using TerminalDeck.Core.Tests.Sessions;
using TerminalDeck.Core.Tests.Tasks;

namespace TerminalDeck.Core.Tests.Mcp;

// CAPTEST 30 Oct: Claude inside a Terminal Deck chat could not use the app's tools.
public sealed class DeckToolsAccessTests
{
  private const string Project = "captest";
  private sealed class Facts : ISessionCallerFacts
  {
    public IReadOnlyList<string> ProjectFolders(string projectId) => projectId == Project ? ["C:/TD/captest/scenarios"] : ["C:/TD/other"];
    public string? SessionFolder(string sessionId) => sessionId switch { "shell" => @"C:\TD\captest\scenarios", "foreign" => @"C:\TD\other", _ => null };
    public string? SessionProject(string sessionId) => sessionId switch { "shell" => Project, "foreign" => "other", "bound-elsewhere" => "other", _ => null };
    public string? TaskProject(string taskId) => taskId == "mine" ? Project : taskId == "theirs" ? "other" : null;
    public string? AgentProject(string agentId) => agentId switch { "tester" => Project, "free" => "independent", "stranger" => "other", _ => null };
  }
  private static McpGrant SessionGrant(AiPermissionMode mode = AiPermissionMode.Ask) => new("chat:me", "me", null, true, mode,
    McpCatalogue.Load().Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(), ["sessions:me", "folders:C:/TD/captest/scenarios", "projects:" + Project, "profiles:default"],
    DateTimeOffset.UtcNow.AddHours(1), SeatId: "role:captest/tester", Scope: McpCallerScopes.Session(new Facts(), "me", Project, "C:/TD/captest/scenarios", "role:captest/tester"));

  // Bug 1 root cause: chat grants listed exact items in one spelling ("C:/TD/…"),
  // while Claude passes Windows paths ("C:\TD\…") and any web origin; every
  // browser/task/session/artifact/MCP/memory call was refused after approval.
  [Fact] public void SessionGrantFollowsTheSeatsProjectScopeInAnyPathSpelling()
  {
    var grant = SessionGrant();
    Assert.True(grant.Has("folders", @"C:\TD\captest\scenarios"));
    Assert.True(grant.Has("folders", @"c:\td\captest\scenarios\site"));
    Assert.True(grant.Has("origins", "https://news.ycombinator.com"));
    Assert.True(grant.Has("origins", "http://127.0.0.1:18972"));
    Assert.True(grant.Has("sessions", "shell"));
    Assert.True(grant.Has("tasks", "*")); Assert.True(grant.Has("tasks", "mine"));
    Assert.True(grant.Has("agents", "tester")); Assert.True(grant.Has("agents", "free")); Assert.True(grant.Has("agents", "lead:" + Project));
    Assert.True(grant.Has("memory", "role:captest/tester"));
    Assert.True(grant.Has("mcp", @"local:C:\TD\captest\scenarios:Captest-Echo"));
    // Designed fences stay: other projects, app settings, app-wide MCP, Hoot's desk, devices.
    Assert.False(grant.Has("folders", @"C:\TD\other")); Assert.False(grant.Has("sessions", "foreign")); Assert.False(grant.Has("sessions", "bound-elsewhere"));
    Assert.False(grant.Has("tasks", "theirs")); Assert.False(grant.Has("agents", "stranger")); Assert.False(grant.Has("agents", "*"));
    Assert.False(grant.Has("projects", "other")); Assert.False(grant.Has("settings", "mcp")); Assert.False(grant.Has("settings", "browser"));
    Assert.False(grant.Has("mcp", "user:Everywhere")); Assert.False(grant.Has("hoot", "main")); Assert.False(grant.Has("devices", "phone"));
    Assert.False(grant.Has("memory", "orchestrator"));
  }
  [Fact] public void KindWideAndExactItemsStillWorkWithoutAScope()
  {
    var grant = new McpGrant("c", null, null, true, AiPermissionMode.Ask, [], [McpTier.Read], ["origins:*", "folders:C:/Work"], DateTimeOffset.UtcNow.AddHours(1));
    Assert.True(grant.Has("origins", "https://example.com")); Assert.True(grant.Has("folders", @"C:\Work\Sub")); Assert.False(grant.Has("folders", @"C:\Workshop"));
    Assert.False(grant.Has("sessions", "x"));
  }
  [Fact] public async Task ApprovedSessionCallReachesItsHandlerThroughTheDoor()
  {
    var door = new McpDoor(new FakePermission()); var reached = 0;
    door.Register("sessions.screen", (c, a, ct) =>
    {
      c.Require("sessions", a.GetProperty("sessionId").GetString()!); c.Require("origins", "https://news.ycombinator.com"); c.Require("folders", @"C:\TD\captest\scenarios");
      reached++; return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { ok = true }));
    });
    var authority = new McpCallerAuthority(); var grant = SessionGrant();
    var caller = authority.Provision(door, new(grant.CallerId, grant.SessionId, grant.SeatId, grant.PermissionMode, grant.Tools, grant.Tiers, grant.Resources, Scope: grant.Scope), _ => true);
    await door.CallAsync(caller.Id, "sessions_screen", JsonSerializer.SerializeToElement(new { sessionId = "shell" }));
    Assert.Equal(1, reached);
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(caller.Id, "sessions_screen", JsonSerializer.SerializeToElement(new { sessionId = "foreign" })).AsTask());
    Assert.Same(caller, authority.Current(grant.CallerId));
  }

  // Bug 5: a session lists and reads the windows linked to it (Send/attach), by label in any case.
  [Fact] public async Task SessionCallerListsAndReadsItsLinkedWindowsOnly()
  {
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    var linked = await browser.OpenAsync("http://127.0.0.1:18972/", sessionId: "me"); var other = await browser.OpenAsync("https://example.com/");
    var door = new McpDoor(new FakePermission()); BrowserTools.RegisterWithSessionLookup(door, browser, id => new SessionRecord(new(id, "claude", "C:/TD/captest/scenarios", "chat"), "key", SessionState.Running));
    var caller = door.RegisterCaller(SessionGrant(), (_, _, _, _, _) => ValueTask.FromResult(true));
    var listed = await door.CallAsync(caller.Id, "browser_windows", JsonSerializer.SerializeToElement(new { action = "list" }));
    Assert.Equal(linked.Id, Assert.Single(listed.EnumerateArray()).GetProperty("Id").GetString());
    var state = await door.CallAsync(caller.Id, "browser_page", JsonSerializer.SerializeToElement(new { window = linked.Window.ToLowerInvariant(), action = "state" }));
    Assert.Equal(linked.Id, state.GetProperty("Id").GetString());
    var refused = await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(caller.Id, "browser_page", JsonSerializer.SerializeToElement(new { window = other.Window, action = "state" })).AsTask());
    Assert.Contains("not linked to this session", refused.Message);
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(caller.Id, "browser_profiles", JsonSerializer.SerializeToElement(new { action = "list" })).AsTask());
    // Hoot (all-capability scope) manages every window; an outside key naming settings:browser does not.
    var hoot = door.RegisterCaller(SessionGrant() with { CallerId = "hoot:x", SessionId = "hoot-chat", Resources = ["sessions:hoot-chat", "settings:browser"], Scope = McpCallerScopes.Everything }, (_, _, _, _, _) => ValueTask.FromResult(true));
    Assert.Equal(2, (await door.CallAsync(hoot.Id, "browser_windows", JsonSerializer.SerializeToElement(new { action = "list" }))).GetArrayLength());
    await door.CallAsync(hoot.Id, "browser_profiles", JsonSerializer.SerializeToElement(new { action = "list" }));
    var outside = door.RegisterCaller(SessionGrant() with { CallerId = "ai:x", Resources = ["sessions:me", "settings:browser", "profiles:default"], Scope = null }, (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(outside.Id, "browser_profiles", JsonSerializer.SerializeToElement(new { action = "list" })).AsTask());
  }

  // Bug 6: reads never ask; changes still ask through the AI's own permission prompt.
  [Theory]
  [InlineData("mcp__deck-tools__sessions_list", "{}", true)]
  [InlineData("mcp__deck-tools__sessions_screen", "{\"sessionId\":\"x\"}", true)]
  [InlineData("mcp__deck-tools__browser_read", "{}", true)]
  [InlineData("mcp__deck-tools__browser_page", "{\"action\":\"screenshot\"}", true)]
  [InlineData("mcp__deck-tools__browser_windows", "{\"action\":\"list\"}", true)]
  [InlineData("mcp__deck-tools__memory_card_read", "{}", true)]
  [InlineData("mcp__deck-tools__browser_windows", "{\"action\":\"attach\"}", false)]
  [InlineData("mcp__deck-tools__browser_page", "{\"action\":\"click\"}", false)]
  [InlineData("mcp__deck-tools__browser_open", "{\"url\":\"https://example.com\"}", false)]
  [InlineData("mcp__deck-tools__tasks_local_change", "{\"do\":\"create\"}", false)]
  [InlineData("mcp__deck-tools__tasks_agents", "{\"do\":\"save\"}", false)]
  [InlineData("mcp__deck-tools__sessions_start", "{}", false)]
  [InlineData("mcp__other__sessions_list", "{}", false)]
  [InlineData("Bash", "{}", false)]
  public void OnlyReadingDeckToolsRunWithoutAsking(string tool, string input, bool quiet)
    => Assert.Equal(quiet, DeckToolReads.Quiet(tool, JsonDocument.Parse(input).RootElement));
  [Fact] public async Task ClaudeReadPromptIsAnsweredQuietlyAndAChangeStillAsks()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); var protocol = new ChatLineProtocol(f.Chat, f.History);
    var read = protocol.Receive("{\"type\":\"control_request\",\"request_id\":\"r1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"mcp__deck-tools__sessions_list\",\"input\":{\"cwd\":\"C:\\\\TD\"}}}");
    Assert.Empty(read.Signals); using var answer = JsonDocument.Parse(Assert.Single(read.Writes));
    Assert.Equal("allow", answer.RootElement.GetProperty("response").GetProperty("response").GetProperty("behavior").GetString());
    Assert.Equal("r1", answer.RootElement.GetProperty("response").GetProperty("request_id").GetString());
    var change = protocol.Receive("{\"type\":\"control_request\",\"request_id\":\"r2\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"mcp__deck-tools__sessions_start\",\"input\":{}}}");
    Assert.Empty(change.Writes); Assert.Equal("approval", Assert.Single(change.Signals).Kind);
  }

  // Bug 4: bounded rows and a folder filter that matches Windows paths.
  [Fact] public async Task SessionRowsAreShortAndTheFolderFilterMatchesWindowsSpellings()
  {
    Assert.True(SessionRows.InFolder(JsonSerializer.SerializeToElement(new { cwd = @"C:\TD\captest\scenarios" }), "C:/TD/captest/scenarios"));
    Assert.True(SessionRows.InFolder(JsonSerializer.SerializeToElement(new { cwd = "c:/td/captest/scenarios/" }), @"C:\TD\captest\scenarios"));
    Assert.False(SessionRows.InFolder(JsonSerializer.SerializeToElement(new { cwd = @"C:\TD\captest\scenarios" }), @"C:\TD\captest\main"));
    Assert.True(SessionRows.InFolder(JsonSerializer.SerializeToElement(new { }), @"C:\anything"));
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var events = Enumerable.Range(1, 500).Select(i => new ChatEvent(i, "message", "m" + i, new string('x', 400))).ToArray();
    var row = JsonSerializer.SerializeToElement(SessionRows.Chat(f.Chat with { Events = events }));
    Assert.True(row.GetRawText().Length < 1000); Assert.False(row.TryGetProperty("events", out _)); Assert.Equal("idle", row.GetProperty("status").GetString());
  }

  // Bug 3: a task names no account; the agent start used only an explicit default and stopped.
  [Fact] public async Task AssignedTaskStartsItsAgentWithTheOnlySignedInAccount()
  {
    var f = new TaskFixture(); var provider = new FakeSignedIn();
    var accounts = new AccountService(new MemoryState<AccountState>(), [provider]);
    var unused = await accounts.CreateAsync("codex", "Not signed in"); var signedIn = await accounts.CreateAsync("codex", "Signed in");
    provider.SignedIn.Add(signedIn.Id); await accounts.RefreshAsync(signedIn.Id); await accounts.RefreshAsync(unused.Id);
    var plans = new List<AgentLaunchPlan>();
    var agents = new AgentService(new MemoryState<AgentState>(), f.Projects, new NoInstructions(), accounts,
      new DelegateAgentSessionGateway((plan, _) => { plans.Add(plan); return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); }));
    agents.Save(new("tester", "Captest Tester", "codex", ProjectId: "sample", Seat: "tester"));
    var service = new TaskService(new TaskStore(new MemoryState<TasksState>()), f.Projects, id => TaskRecipients.Resolve(id, agents, f.Projects, () => []),
      new AgentTaskRunner(agents, f.Projects, (_, _, _) => ValueTask.CompletedTask), f.Files);
    var task = service.Create(new("Check headlines daily", "", "sample"), TaskActor.Owner);
    var started = await service.AssignAsync(task.Id, "tester", TaskActor.Owner);
    Assert.Equal(signedIn.Id, Assert.Single(plans).AccountId); Assert.Equal("Working on it", started.Status);
    Assert.Equal("tester", TaskRecipients.Resolve("captest tester", agents, f.Projects, () => [])!.Id);
  }
  // ---- CAPTEST rerun (TEST 0.20.2.44036) ----
  // S6: a project NAME in "project" was resolved, then Patch read it back as the folder.
  [Fact] public async Task TaskCreateAcceptsTheProjectsNameAndKeepsItsHomeFolder()
  {
    var f = new TaskFixture(); var door = new McpDoor(new FakePermission()); new TasksMcp(f.Tasks, f.Projects, "pc", _ => null).Register(door);
    var caller = door.RegisterCaller(new("c", "s", null, true, AiPermissionMode.Bypass, ["tasks.local_change"], Enum.GetValues<McpTier>(), ["sessions:s", "projects:sample", "folders:C:/Work/Sample", "tasks:*"], DateTimeOffset.UtcNow.AddHours(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(caller.Id, "tasks_local_change", JsonSerializer.SerializeToElement(new { @do = "create", title = "Check headlines daily", project = "Sample project", due_date = "2026-10-31" }));
    var task = Assert.Single(f.Tasks.List(new(Status: "all")), t => t.Title == "Check headlines daily");
    Assert.Equal("sample", task.ProjectId); Assert.Equal("C:/Work/Sample", task.Folder); Assert.Equal("2026-10-31", task.DueDate);
    var refused = await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(caller.Id, "tasks_local_change", JsonSerializer.SerializeToElement(new { @do = "create", title = "x", project = "No such project" })).AsTask());
    Assert.Contains("exact name", refused.Message);
  }
  // S6/S10: a tool failure said only "could not be completed"; people-written refusals now come through.
  [Fact] public void ToolFailuresCarryTheirOwnMessageButNotFileOrProviderText()
  {
    Assert.Equal("Choose an absolute home folder.", McpHttpEndpoint.Failure(new ArgumentException("Choose an absolute home folder.")));
    Assert.Equal("The page did not draw a picture.", McpHttpEndpoint.Failure(new TimeoutException("The page did not draw a picture.")));
    Assert.Equal("This action could not be completed (IOException). Try again.", McpHttpEndpoint.Failure(new IOException(@"C:\Users\x\secret.txt is locked")));
  }
  // S10: markdown is not an artifact type (Mac parity); say so instead of failing silently.
  [Fact] public void ArtifactPreviewExplainsFilesThatAreNotArtifacts()
  {
    var temp = OperatingSystem.IsMacOS() && Path.GetTempPath().StartsWith("/var/", StringComparison.Ordinal) ? "/private" + Path.GetTempPath() : Path.GetTempPath();
    var folder = Path.Combine(temp, "td-art-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
    try
    {
      File.WriteAllText(Path.Combine(folder, "headlines.md"), "# Headlines"); File.WriteAllText(Path.Combine(folder, "index.html"), "<h1>ok</h1>");
      var index = new ReceiverArtifacts(new MemoryState<ReceiverArtifactState>(), _ => "project", (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
      Assert.Contains("not an artifact type", Assert.Throws<ArgumentException>(() => index.Preview(folder, "headlines.md")).Message);
      Assert.Contains("not in this folder's Artifacts list yet", Assert.Throws<ArgumentException>(() => index.Preview(folder, "index.html")).Message);
      index.Record(folder, "index.html", "session", DateTimeOffset.UtcNow);
      Assert.Equal("text/html", index.Preview(folder, "index.html").MediaType);
    }
    finally { Directory.Delete(folder, true); }
  }
  // S1: browser_read returned text only; it now returns every match and its web links.
  [Fact] public void PageReadReturnsEveryMatchAndItsLinks()
  {
    var script = BrowserAutomation.ReadScript(JsonSerializer.SerializeToElement(new { selector = ".titleline > a" }));
    Assert.Contains("querySelectorAll", script); Assert.Contains("links.push({text:label,href})", script); Assert.Contains("untrusted:true", script);
  }
  // S7: a tool-started chat took the unsigned placeholder account; the caller's own account comes first.
  [Fact] public async Task StartsPreferTheCallersAccountThenASignedInOne()
  {
    var provider = new FakeSignedIn(); var accounts = new AccountService(new MemoryState<AccountState>(), [provider]);
    var placeholder = await accounts.CreateAsync("codex", "Placeholder"); var mine = await accounts.CreateAsync("codex", "Mine");
    provider.SignedIn.Add(mine.Id); await accounts.RefreshAsync(mine.Id);
    Assert.Equal(mine.Id, accounts.Preferred("codex")!.Id);
    Assert.Equal(placeholder.Id, accounts.Preferred("codex", null, placeholder.Id)!.Id);
    Assert.Equal(mine.Id, accounts.Preferred("codex", null, "someone-elses-claude")!.Id);
  }
  // Live chat model chip: the provider reports a full id; people see the name.
  [Theory]
  [InlineData("claude-opus-5-5", "Opus 5.5")]
  [InlineData("claude-sonnet-4-5-20250929[1m]", "Sonnet 4.5")]
  [InlineData("claude-haiku-4", "Haiku 4")]
  [InlineData("gpt-5-codex", "gpt-5-codex")]
  public void ProviderModelIdsShowTheirNames(string id, string name) => Assert.Equal(name, ModelNames.Display(id, []));
  [Fact] public void ListedModelNameWinsOverTheDerivedOne()
    => Assert.Equal("Opus 5.5 (1M)", ModelNames.Display("claude-opus-5-5", [new ProviderModel("claude-opus-5-5[1m]", "Opus 5.5 (1M)", 1_000_000)]));
  [Fact] public void ScreenshotsReturnAsImageBlocks()
  {
    var reply = JsonSerializer.SerializeToElement(McpHttpEndpoint.Content(JsonSerializer.SerializeToElement(new { url = "http://127.0.0.1:18972/", mimeType = "image/png", data = "iVBORw0KGgo=" })));
    var blocks = reply.GetProperty("content");
    Assert.Equal("image", blocks[0].GetProperty("type").GetString()); Assert.Equal("iVBORw0KGgo=", blocks[0].GetProperty("data").GetString());
    Assert.DoesNotContain("iVBORw0KGgo", blocks[1].GetProperty("text").GetString()); Assert.Contains("18972", blocks[1].GetProperty("text").GetString());
    Assert.Equal("text", JsonSerializer.SerializeToElement(McpHttpEndpoint.Content(JsonSerializer.SerializeToElement(new { ok = true }))).GetProperty("content")[0].GetProperty("type").GetString());
  }
  private sealed class NoInstructions : IAgentInstructions
  { public string Save(string id, string text) => throw new NotSupportedException(); public string Read(string path) => ""; }
  private sealed class FakeSignedIn : IAccountProvider
  {
    public HashSet<string> SignedIn { get; } = [];
    public string Provider => "codex";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(SignedIn.Contains(account.Id), SignedIn.Contains(account.Id) ? "fixture@invalid.test" : null));
    public ValueTask SignInAsync(AccountProfile a, string folder, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask SignOutAsync(AccountProfile a, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile a, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
}
