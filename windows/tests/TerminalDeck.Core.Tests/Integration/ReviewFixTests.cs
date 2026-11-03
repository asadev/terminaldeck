using System.Collections.Concurrent;
using System.Text.Json;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Browser;
using TerminalDeck.Core.Tests.Chats;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class ReviewFixTests
{
  private static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);

  [Theory]
  [InlineData(AiPermissionMode.Ask, true)]
  [InlineData(AiPermissionMode.Plan, false)]
  [InlineData(AiPermissionMode.Bypass, true)]
  public async Task M1RealHttpDispatcherUsesEachCallersNativeModeAndExactGrants(AiPermissionMode mode, bool allowed)
  {
    var authority = new McpCallerAuthority(); var effects = 0; var logs = new List<McpActionRecord>(); authority.Authorized += logs.Add;
    var dispatches = 0;
    var door = new McpDoor(authority, wrap: (_, run) => async (c, a, ct) => { dispatches++; return await run(c, a, ct); });
    door.Register("sessions.rename", (c, a, ct) => { c.Require("sessions", a.GetProperty("sessionId").GetString()!); effects++; return ValueTask.FromResult(J(new { done = true, c.Grant.OwnerApplication, c.Grant.SessionId, c.Grant.SeatId })); });
    var current = true;
    var policy = new McpCallerPolicy("outside-app", "mine", "seat", mode, ["sessions.rename"], Enum.GetValues<McpTier>(), ["sessions:mine"]);
    var key = authority.Provision(door, policy, _ => current);
    var endpoint = new McpHttpEndpoint(door, new("http://127.0.0.1:4321/mcp"), "review");
    async Task<JsonElement> Request(object request)
    {
      var reply = await endpoint.HandleAsync(new() { Method = "POST", Path = "/mcp", Host = "127.0.0.1:4321", Authorization = "Bearer " + key.Token, Body = JsonSerializer.SerializeToUtf8Bytes(request) });
      using var document = JsonDocument.Parse(reply.Body); return document.RootElement.Clone();
    }
    await Request(new { jsonrpc = "2.0", id = 1, method = "initialize", @params = new { protocolVersion = McpHttpEndpoint.Versions[^1] } });
    var result = await Request(new { jsonrpc = "2.0", id = 2, method = "tools/call", @params = new { name = "sessions_rename", arguments = new { sessionId = "mine", title = "Changed" } } });
    Assert.Equal(!allowed, result.GetProperty("result").GetProperty("isError").GetBoolean()); Assert.Equal(allowed ? 1 : 0, effects);
    if (allowed)
    {
      using var content = JsonDocument.Parse(result.GetProperty("result").GetProperty("content")[0].GetProperty("text").GetString()!);
      Assert.False(content.RootElement.GetProperty("OwnerApplication").GetBoolean()); Assert.Equal("seat", content.RootElement.GetProperty("SeatId").GetString());
      Assert.Contains("sessionId=mine", Assert.Single(logs).Target);
    }
    // A second target and a stale live grant are refused even in Bypass.
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(key.Id, "sessions.rename", J(new { sessionId = "other", title = "No" })));
    current = false;
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(key.Id, "sessions.rename", J(new { sessionId = "mine", title = "No" })));
    Assert.Equal(allowed ? 1 : 0, effects); Assert.Equal(allowed ? 2 : 0, dispatches);
  }

  [Fact] public async Task M1OutsideAiCannotBecomeBrowserOwnerAndRevokedRelayKeyStopsWorking()
  {
    var authority = new McpCallerAuthority(); var door = new McpDoor(authority);
    await using var browser = new BrowserModel(new MemoryState<BrowserState>(), new FakeBrowserFactory(), new FakeBrowserStorage());
    BrowserTools.RegisterWithSessionLookup(door, browser, _ => throw new InvalidOperationException());
    var key = authority.Provision(door, new("external", "mine", null, AiPermissionMode.Bypass, ["browser.profiles"], Enum.GetValues<McpTier>(), ["sessions:mine", "settings:browser", "profiles:default"], true), _ => true);
    Assert.True(door.AllowsRelay(key.Token));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(key.Id, "browser.profiles", J(new { action = "create", name = "Other" })));
    authority.Revoke(door, "external"); Assert.False(door.AllowsRelay(key.Token)); Assert.Throws<McpRefusal>(() => door.Authenticate(key.Token));
    Assert.Throws<ArgumentException>(() => authority.Provision(door, new("wide", null, null, AiPermissionMode.Bypass, [], [], ["*"]), _ => true));
  }

  [Fact] public async Task M2FailedReaderRetiresCliBeforeSavedConversationReconnects()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var file = Path.Combine(f.Root.DirectoryPath, "reader-failure.py");
    File.WriteAllText(file, """
      import sys,json,time
      row=json.loads(sys.stdin.readline())
      print(json.dumps({'type':'system','subtype':'init','session_id':sys.argv[1]}),flush=True)
      if sys.argv[2]=='fail':
        sys.stdout.write('x'*(16*1024*1024+1));sys.stdout.flush();time.sleep(60)
      else:
        print(json.dumps({'type':'assistant','message':{'id':'reply','content':[{'type':'text','text':'resumed '+sys.argv[1]}]}}),flush=True)
        print(json.dumps({'type':'result','subtype':'success'}),flush=True)
      """);
    var signals = new ConcurrentQueue<ChatSignal>();
    ProcessLaunch Launch(string kind) => new("/usr/bin/python3", ["-u", file, "saved-exact", kind], new Dictionary<string, string> { ["PATH"] = "/usr/bin:/bin" }, f.Root.DirectoryPath);
    var client = Guid.NewGuid().ToString();
    await using (var failed = new ChatCliConnection(f.Chat, f.History, Launch("fail"), signal => { signals.Enqueue(signal); return ValueTask.CompletedTask; }))
    {
      await failed.StartAsync(); await failed.SendAsync(new(client, "first", [])); await failed.Completion.WaitAsync(TimeSpan.FromSeconds(15));
      Assert.False(failed.Alive); Assert.Equal(client, Assert.Single(signals, s => s.Kind == "connectionLost").ClientId);
      await Assert.ThrowsAsync<IOException>(async () => await failed.SendAsync(new(Guid.NewGuid().ToString(), "must not write", [])));
    }
    var resumed = f.Chat with { ConversationId = signals.Single(s => s.Kind == "conversation").Text };
    await using var next = new ChatCliConnection(resumed, f.History, Launch("resume"), signal => { signals.Enqueue(signal); return ValueTask.CompletedTask; });
    await next.StartAsync(); await next.SendAsync(new(Guid.NewGuid().ToString(), "continue", [])); await next.Completion.WaitAsync(TimeSpan.FromSeconds(10));
    Assert.Equal("resumed saved-exact", Assert.Single(signals, s => s.Kind == "message").Text);
  }

  [Fact] public async Task M3FragmentedToolMediaAndSmallImagesNeverReachSavedEventsOrMcpInline()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false);
    var protocol = new ChatLineProtocol(f.Chat, f.History);
    var encoded = Convert.ToBase64String("small-private-image"u8.ToArray());
    var events = new List<ChatSignal>();
    events.AddRange(protocol.Receive(JsonSerializer.Serialize(new { type = "stream_event", @event = new { type = "content_block_start", index = 0, content_block = new { type = "tool_use", id = "image", name = "Fixture", input = new { } } } })).Signals);
    var input = JsonSerializer.Serialize(new { image = new { type = "base64", media_type = "image/png", data = encoded } });
    foreach (var fragment in input.Chunk(7).Select(c => new string(c)))
      Assert.Empty(protocol.Receive(JsonSerializer.Serialize(new { type = "stream_event", @event = new { type = "content_block_delta", index = 0, delta = new { type = "input_json_delta", partial_json = fragment } } })).Signals);
    events.AddRange(protocol.Receive("{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\",\"index\":0}}").Signals);
    events.AddRange(protocol.Receive(JsonSerializer.Serialize(new { type = "user", message = new { content = new[] { new { type = "tool_result", tool_use_id = "small", content = input } } } })).Signals);
    Assert.Equal(2, events.Count(s => s.Text.Contains("mediaFile", StringComparison.Ordinal)));
    var record = f.Chat with { Events = events.Select((s, i) => new ChatEvent(i + 1, s.Kind, s.Id, s.Text, s.ClientId, s.Data)).ToArray() }; f.History.Save(record);
    Assert.DoesNotContain(encoded, JsonSerializer.Serialize(f.History.Load(record.Definition.Id)));
    Assert.DoesNotContain(encoded, ChatMcpTools.View(record).GetRawText());
    Assert.Single(Directory.GetFiles(Path.Combine(f.Root.DirectoryPath, "chats", Guid.Parse(record.Definition.Id).ToString("N"), "media")));
  }

  [Fact] public async Task M2ContinuingKeepsUncertaintyAndCannotReplayTheOldClientId()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var original = new ChatMessage(Guid.NewGuid().ToString(), "uncertain old turn", [], ChatMessageState.Uncertain);
    f.History.Save(f.Chat with { Messages = [original], ConversationId = "saved-conversation" }); await f.RestartAsync();
    await f.Chats.SendAsync(f.Chat.Definition.Id, original.ClientId, original.Text);
    Assert.Equal(0, f.Keeper.Starts);
    await f.Chats.ContinueWithoutResendingAsync(f.Chat.Definition.Id);
    Assert.Equal(ChatMessageState.Uncertain, f.Chats.Get(f.Chat.Definition.Id).Messages.Single().State);
    await f.Chats.SendAsync(f.Chat.Definition.Id, Guid.NewGuid().ToString(), "new turn");
    await ChatFixture.UntilAsync(() => !f.Chats.Get(f.Chat.Definition.Id).Busy);
    await f.Chats.SendAsync(f.Chat.Definition.Id, original.ClientId, original.Text);
    Assert.False(f.Keeper.Writes.ContainsKey(original.ClientId)); Assert.Equal(1, f.Keeper.Starts);
    Assert.Equal("saved-conversation", f.Chats.Get(f.Chat.Definition.Id).ConversationId);
  }

  [Fact] public async Task M3SmallDataUrlsAndJsonEncodedArgumentsAlsoBecomeFileReferences()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false);
    var encoded = Convert.ToBase64String("another-small-image"u8.ToArray());
    var nested = JsonSerializer.Serialize(new { source = new { type = "base64", media_type = "image/png", data = encoded } });
    var result = f.History.ExternalizeData(f.Chat.Definition.Id, J(new { arguments = nested, url = "data:image/png;base64," + encoded }));
    Assert.DoesNotContain(encoded, result.GetRawText()); Assert.Contains("mediaFile", result.GetRawText());
    Assert.DoesNotContain(encoded, f.History.ExternalizeData(f.Chat.Definition.Id, J("data:image/png;base64," + encoded)).GetRawText());
  }

  [Fact] public async Task M4EndRetiresWorkerKeepsHistoryReleasesLeadLimitAndAllowsRemoval()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync();
    var projects = new ProjectService(new JsonStateStore<ProjectState>(f.Root, "projects"), new LocalProjectFolders(f.Root));
    using var projectFolder = new ScratchFolder();
    var project = projects.Create("Review", projectFolder.DirectoryPath);
    var agents = new AgentService(new JsonStateStore<AgentState>(f.Root, "agents"), projects, new AgentInstructions(f.Root), f.Accounts,
      new DelegateAgentSessionGateway(async (plan, ct) => { await f.Chats.CreateAsync(new(plan.SessionId, plan.Provider, plan.Folder, plan.Title, plan.AccountId, plan.AccountHome, new()), cancellationToken: ct); return new(plan.SessionId, "chat"); }));
    var agent = agents.Hire("Lead", "claude", "", AgentCategory.Lead, project.Id);
    var first = await agents.StartAsync(new(agent.Id, Folder: projectFolder.DirectoryPath, AccountId: f.Account.Id, Mode: "chat"));
    await f.Chats.SendAsync(first.SessionId, Guid.NewGuid().ToString(), "one");
    await ChatFixture.UntilAsync(() => !f.Chats.Get(first.SessionId).Busy);
    Assert.Throws<ArgumentException>(() => agents.Remove(agent.Id));
    var door = new McpDoor(new FakePermission()); using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var key = door.RegisterCaller(McpTests.Grant("sessions.send"), (_, _, _, _, _) => ValueTask.FromResult(true));
    await door.CallAsync(key.Id, "sessions.send", J(new { sessionId = first.SessionId, text = "deck-chat:{\"action\":\"end\"}" }));
    var ended = f.Chats.Get(first.SessionId); Assert.True(ended.Ended); Assert.NotEmpty(ended.Events);
    Assert.Equal(ProcessPresence.Dead, (await f.Keeper.ObserveAsync(ChatSessions.Session(ended), default)).Presence);
    agents.ReconcileSessions([new(first.SessionId, "Lead", "claude", projectFolder.DirectoryPath, "ended", Mode: "chat")]);
    Assert.Equal(AgentRunState.Ended, agents.Runs().Single().State);
    var second = await agents.StartAsync(new(agent.Id, Folder: projectFolder.DirectoryPath, AccountId: f.Account.Id, Mode: "chat"));
    await f.Chats.EndAsync(second.SessionId);
    agents.ReconcileSessions([new(second.SessionId, "Lead", "claude", projectFolder.DirectoryPath, "ended", Mode: "chat")]);
    agents.Save(agents.Get(agent.Id) with { Status = SavedAgentStatus.Archived }); agents.Remove(agent.Id); Assert.Empty(agents.List());
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await f.Chats.SendAsync(first.SessionId, Guid.NewGuid().ToString(), "closed"));
    await f.RestartAsync(); Assert.True(f.Chats.Get(first.SessionId).Ended);
  }

  [Fact] public async Task M4UnconfirmedWorkerRetirementNeverMarksAChatEnded()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(); f.Keeper.PresenceOverride = ProcessPresence.Unknown;
    await Assert.ThrowsAsync<IOException>(async () => await f.Chats.EndAsync(f.Chat.Definition.Id)); Assert.False(f.Chats.Get(f.Chat.Definition.Id).Ended);
  }

  [Theory] [InlineData("claude", "claude.exe")] [InlineData("codex", "codex.exe")]
  public void M5OrdinaryPathNativeInstallDoesNotNeedDeveloperTools(string provider, string file)
  {
    var directory = Path.Combine(Path.GetTempPath(), "td-install-search-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
    try { var path = Path.Combine(directory, file); File.WriteAllText(path, "planner fixture"); var plan = InstalledAiResolver.Resolve(provider, new([directory], [], [])); Assert.Equal(path, plan.Executable); Assert.Empty(plan.Prefix); }
    finally { Directory.Delete(directory, true); }
  }
  [Fact] public void M5NpmWrapperResolvesItsKnownEntryWithNodeAndActionableMissingState()
  {
    var directory = Path.Combine(Path.GetTempPath(), "td-npm-search-" + Guid.NewGuid().ToString("N"));
    var modules = Path.Combine(directory, "node_modules"); var entry = Path.Combine(modules, "@google", "gemini-cli", "dist", "index.js"); Directory.CreateDirectory(Path.GetDirectoryName(entry)!);
    try
    {
      File.WriteAllText(entry, "planner fixture"); File.WriteAllText(Path.Combine(directory, "node.exe"), "planner fixture");
      var plan = InstalledAiResolver.Resolve("gemini", new([directory], [modules], [directory])); Assert.Equal(entry, Assert.Single(plan.Prefix));
      var error = Assert.Throws<ProviderUnavailableException>(() => InstalledAiResolver.Resolve("claude", new([], [], []))); Assert.Equal("Claude Code isn’t installed. Install it from Coding AIs.", error.Message); Assert.DoesNotContain("C:\\TD", error.Message);
    }
    finally { Directory.Delete(directory, true); }
  }

  [Fact] public async Task M6PopupsInheritOriginProfileIsolationAndSessionBeforeFirstNavigation()
  {
    var factory = new FakeBrowserFactory(); await using var browser = new BrowserModel(new MemoryState<BrowserState>(), factory, new FakeBrowserStorage());
    var source = await browser.OpenAsync("https://allowed.test/first", true, sessionId: "mine");
    await browser.PerformAsync(source.Id, BrowserPageAction.Step, J(new { verb = "click", selector = "button" }));
    var count = factory.Created.Count;
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.OpenPopupAsync(source.Id, "https://other.test/")); Assert.Equal(count, factory.Created.Count);
    var popup = await browser.OpenPopupAsync(source.Id, "https://allowed.test/popup");
    Assert.True(popup.Isolated); Assert.Equal(source.ProfileId, popup.ProfileId); Assert.Equal("mine", popup.SessionId); Assert.Equal("https://allowed.test", factory.Created[^1].Options.AutomationOrigin);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.NavigateAsync(popup.Id, "https://other.test/redirect"));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.OpenPopupAsync(popup.Id, "http://allowed.test/"));
  }

  [Fact] public void M7ControlByteTitleSelectionAndEditedDraftHaveOnlyOneTrustedSubmit()
  {
    var context = BrowserContext.Create("https://fixture.test/page", "title\r\u001b[31m\u009bhidden", "selection\n\t\0\u2028\u202eend");
    Assert.DoesNotContain(context, char.IsControl); Assert.Contains("Untrusted webpage data", context);
    var input = BrowserContext.TerminalMessage(context + "\r\u001b[201~"); Assert.Equal('\r', input[^1]); Assert.DoesNotContain(input[..^1], char.IsControl);
    Assert.DoesNotContain('\u2028', input); Assert.DoesNotContain('\u202e', input);
  }

  [Fact] public async Task M8UnknownWorkerNeverStartsAReplacementAndDeadShellDoesNotResume()
  {
    Assert.False(new ProcessObservation(ProcessPresence.Live, ActivityKnown: false).Idle);
    var processes = new FakeProcessKeeper(); var store = new MemoryState<SessionLedger>(); var keeper = new SessionKeeper(store, processes);
    var row = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "shell", "/fixture", "Fixture"));
    processes.Observations[row.Definition.Id] = new(ProcessPresence.Unknown);
    await keeper.RecoverAsync(); Assert.Equal(SessionState.Held, keeper.Get(row.Definition.Id).State); Assert.Single(processes.Calls, c => c.StartsWith("start:", StringComparison.Ordinal));
    processes.Observations[row.Definition.Id] = new(ProcessPresence.Dead);
    await keeper.RecoverAsync(); Assert.Equal(SessionState.Exited, keeper.Get(row.Definition.Id).State); Assert.Single(processes.Calls, c => c.StartsWith("start:", StringComparison.Ordinal));
    var ai = await keeper.CreateAsync(new(Guid.NewGuid().ToString(), "codex", "/fixture", "AI", ConversationId: "exact-conversation"));
    processes.Observations[ai.Definition.Id] = new(ProcessPresence.Dead); processes.Calls.Clear();
    await keeper.RecoverAsync(); await keeper.RecoverAsync();
    Assert.Single(processes.Calls, c => c.StartsWith("resume:", StringComparison.Ordinal));
    Assert.NotEqual(ai.CreationKey, keeper.Get(ai.Definition.Id).CreationKey);
  }

  [Fact] public async Task S1CoreOpenAndRestoreKeepAtMostTwelvePagesIncludingSelected()
  {
    var store = new MemoryState<BrowserState>(); var factory = new FakeBrowserFactory();
    await using (var browser = new BrowserModel(store, factory, new FakeBrowserStorage()))
    {
      for (var i = 0; i < 12; i++) await browser.OpenAsync("https://fixture.test/" + i);
      await Assert.ThrowsAsync<InvalidOperationException>(async () => await browser.OpenAsync("https://fixture.test/extra")); Assert.Equal(12, factory.Created.Count);
    }
    var old = store.Value!; var extra = new BrowserTab(Guid.NewGuid().ToString("N"), "W13", "https://fixture.test/extra", "", "default", false);
    store.Save(old with { Tabs = [.. old.Tabs, extra], SelectedTabId = extra.Id, NextWindow = 14 });
    var restored = new FakeBrowserFactory(); await using var next = new BrowserModel(store, restored, new FakeBrowserStorage()); await next.RestoreAsync();
    Assert.Equal(12, restored.Created.Count); Assert.Equal(extra.Id, next.Read().SelectedTabId); Assert.Contains(next.Read().Tabs, t => t.Id == extra.Id);
  }

  [Fact] public async Task S5SavedGeminiAndDirectChatStartRejectUnsupportedEffort()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false);
    Assert.Throws<ArgumentException>(() => (f.Chat.Definition with { Provider = "gemini", Options = new(Effort: "high") }).Validate());
    var projects = new ProjectService(new JsonStateStore<ProjectState>(f.Root, "projects"), new LocalProjectFolders(f.Root));
    var agents = new AgentService(new JsonStateStore<AgentState>(f.Root, "agents"), projects, new AgentInstructions(f.Root));
    Assert.Throws<ArgumentException>(() => agents.Save(new("fixture", "Fixture", "gemini", Effort: "high")));
  }

  [Fact] public async Task S4ExternalToolOutputKeepsSourceAndAnUntrustedDataMarker()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false);
    await using var manager = new McpManager(new MemoryState<McpManagerState>(), new TestSecretStore(), f.Root, new FakeCommandResolver(), new FakeMcpFactory());
    var server = await manager.AddAsync(new() { Name = "fixture", Scope = "user", Transport = "http", Url = "http://127.0.0.1:1/mcp" });
    await manager.ConnectAsync(server.Id); var result = await manager.CallAsync(server.Id, "echo", J(new { }));
    Assert.True(result.GetProperty("untrusted").GetBoolean()); Assert.Equal(server.Id, result.GetProperty("source").GetProperty("serverId").GetString());
    Assert.True(result.GetProperty("data").GetProperty("ok").GetBoolean());
    Assert.Contains("untrusted:true", BrowserAutomation.ReadScript(J(new { })));
  }

  [Fact] public async Task S5OldUnsupportedGeminiChoicesRemainReadableAndCanBeCorrected()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false);
    var old = f.Chat with { Definition = f.Chat.Definition with { Provider = "gemini", Options = new(Effort: "high") } };
    f.History.Save(old); var read = f.History.Load(old.Definition.Id)!;
    Assert.Equal("high", read.Definition.Options.Effort); Assert.Throws<ArgumentException>(() => read.Definition.Validate());
    var projects = new ProjectService(new JsonStateStore<ProjectState>(f.Root, "projects"), new LocalProjectFolders(f.Root));
    var state = new MemoryState<AgentState>(); var agents = new AgentService(state, projects, new AgentInstructions(f.Root));
    var saved = agents.Save(new("old", "Old", "claude", Effort: "high"));
    state.Save(state.Value! with { Agents = [saved with { Provider = "gemini" }] });
    var restored = new AgentService(state, projects, new AgentInstructions(f.Root));
    Assert.Equal("high", restored.Get("old").Effort);
    Assert.Equal("high", restored.Save(restored.Get("old") with { Name = "Renamed legacy profile" }).Effort);
    Assert.Equal("auto", restored.Save(restored.Get("old") with { Effort = "auto" }).Effort);
  }

  [Fact] public async Task M5MissingProviderShowsItsInstallStepBeforeCreatingAnUncertainDelivery()
  {
    await using var f = new ChatFixture(); await f.InitializeAsync(false);
    var accounts = new TerminalDeck.Core.Accounts.AccountService(new MemoryState<TerminalDeck.Core.Accounts.AccountState>(), [new MissingProvider()]);
    var account = await accounts.CreateAsync("claude", "Missing CLI");
    await using var chats = new ChatSessions(f.History, f.Keeper, accounts);
    var chat = await chats.CreateAsync("claude", f.Root.DirectoryPath, account.Id);
    await chats.SendAsync(chat.Definition.Id, Guid.NewGuid().ToString(), "kept message");
    Assert.Equal("Install the Windows CLI and reopen the app to update PATH.", chats.Get(chat.Definition.Id).Problem);
    Assert.Equal(ChatMessageState.Failed, chats.Get(chat.Definition.Id).Messages.Single().State); Assert.Equal(0, f.Keeper.Starts);
  }
  private sealed class MissingProvider : TerminalDeck.Core.Accounts.IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<TerminalDeck.Core.Accounts.ProviderAccountStatus> StatusAsync(TerminalDeck.Core.Accounts.AccountProfile account, CancellationToken ct) => throw new ProviderUnavailableException("Install the Windows CLI and reopen the app to update PATH.");
    public ValueTask SignInAsync(TerminalDeck.Core.Accounts.AccountProfile account, string folder, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask SignOutAsync(TerminalDeck.Core.Accounts.AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel>> ModelsAsync(TerminalDeck.Core.Accounts.AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel>>([]);
  }
  private sealed class ScratchFolder : IDisposable
  {
    public string DirectoryPath { get; } = Path.Combine(Path.GetTempPath(), "td-review-project-" + Guid.NewGuid().ToString("N"));
    public ScratchFolder() => Directory.CreateDirectory(DirectoryPath);
    public void Dispose() => Directory.Delete(DirectoryPath, true);
  }

}
