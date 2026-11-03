using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Chats;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W7IntegrationTests
{
  [Fact] public async Task SharedAccountOwnersKeepConcurrentCreatesRenamesAndFreshReads()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w7-accounts-" + Guid.NewGuid().ToString("N")));
    try
    {
      var provider = new FakeAccountProvider("claude");
      var app = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [provider]);
      var keeper = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [provider]);
      var rows = await Task.WhenAll(app.CreateAsync("claude", "One").AsTask(), keeper.CreateAsync("claude", "Two").AsTask());
      Assert.Equal(2, app.List().Count); Assert.Equal(2, keeper.List().Count);
      await keeper.RenameAsync(rows[0].Id, "Renamed");
      await app.SetDefaultAsync("claude", rows[1].Id);
      Assert.Equal("Renamed", app.Get(rows[0].Id).Name); Assert.Equal(rows[1].Id, keeper.Default("claude")!.Id);
    }
    finally { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
  }
  [Fact] public void ProjectContractsKeepNullableArgumentsAndMixedWriteTiers()
  {
    var contracts = McpCatalogue.Load(); Assert.Equal(contracts.Count, contracts.Select(t => t.Id).Distinct().Count());
    foreach (var spec in ProjectsAgentsMcp.Specs) Assert.True(JsonElement.DeepEquals(spec.InputSchema, contracts.Single(s => s.Id == spec.Id).InputSchema));
    McpSchema.Validate(contracts.Single(s => s.Id == "project_registry.switch").InputSchema, J(new { projectId = (string?)null }));
    var mixed = contracts.Single(s => s.Id == "tasks.agents");
    Assert.Equal(McpTier.Read, McpCatalogue.EffectiveTier(mixed, J(new { @do = "list" })));
    Assert.Equal(McpTier.Alter, McpCatalogue.EffectiveTier(mixed, J(new { @do = "save" })));
    Assert.Throws<McpRefusal>(() => McpSchema.Validate(contracts.Single(s => s.Id == "project_registry.switch").InputSchema, J(new { projectId = 4 })));
  }
  [Fact] public async Task ChatAndTerminalHandlersShareOneDoorAndKeepApprovalsAndReadGrants()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync(false);
    var broker = new Broker(); var door = new McpDoor(broker); var terminal = Guid.NewGuid().ToString();
    door.Register("sessions.get", (_, _, _) => ValueTask.FromResult(J(new { terminal = true })));
    door.Register("sessions.send", (_, _, _) => ValueTask.FromResult(J(new { terminal = true })));
    using var tools = new ChatMcpTools(fixture.Chats); tools.Register(door);
    var ids = door.RegisterCaller(new("w7", null, null, true, AiPermissionMode.Ask, ChatMcpTools.Tools, Enum.GetValues<McpTier>(), ["*"], DateTimeOffset.UtcNow.AddMinutes(2)), (_, _, _, _, _) => ValueTask.FromResult(true));
    Assert.True((await door.CallAsync(ids.Id, "sessions.get", J(new { sessionId = terminal }))).GetProperty("terminal").GetBoolean());
    var chat = await door.CallAsync(ids.Id, "sessions.get", J(new { sessionId = fixture.Chat.Definition.Id }));
    Assert.Equal("chat", chat.GetProperty("mode").GetString()); Assert.Empty(broker.Requests);
    await door.CallAsync(ids.Id, "sessions.send", J(new { sessionId = fixture.Chat.Definition.Id, text = ChatMcpTools.CommandPrefix + JsonSerializer.Serialize(new { action = "send", clientId = Guid.NewGuid().ToString(), text = "Hello" }) }));
    Assert.Equal(McpTier.Alter, Assert.Single(broker.Requests).Tier); Assert.Equal(ChatErrors.NotSignedIn("claude"), fixture.Chats.Get(fixture.Chat.Definition.Id).Problem);
    var limited = door.RegisterCaller(new("limited", null, null, true, AiPermissionMode.Ask, ["sessions.get"], [McpTier.Read], ["sessions:" + fixture.Chat.Definition.Id], DateTimeOffset.UtcNow.AddMinutes(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(limited.Id, "sessions.get", J(new { sessionId = fixture.Chat.Definition.Id })));
  }
  [Theory] [InlineData("claude")] [InlineData("codex")] [InlineData("gemini")]
  public async Task SavedInstructionsTravelWithTheUserTurn(string provider)
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync(false);
    var chat = fixture.Chat with { Definition = fixture.Chat.Definition with { Provider = provider, Instructions = "Keep this role brief." } };
    var protocol = new ChatLineProtocol(chat, fixture.History, codexAppServer: true);
    if (provider != "claude")
    {
      protocol.Receive(provider == "codex" ? "{\"id\":\"hello\",\"result\":{}}" : "{\"id\":\"hello\",\"result\":{\"protocolVersion\":1}}");
      protocol.Receive(provider == "codex" ? "{\"id\":\"session\",\"result\":{\"thread\":{\"id\":\"saved-thread\"}}}" : "{\"id\":\"session\",\"result\":{\"sessionId\":\"saved-thread\"}}");
    }
    using var line = JsonDocument.Parse(protocol.User(new(Guid.NewGuid().ToString(), "Do this job.", [])));
    var content = provider == "claude" ? line.RootElement.GetProperty("message").GetProperty("content") : line.RootElement.GetProperty("params").GetProperty(provider == "codex" ? "input" : "prompt");
    Assert.Equal("Keep this role brief.\n\nDo this job.", content[0].GetProperty("text").GetString());
  }
  [Fact] public async Task CodexPersistentResumeKeepsThreadAndInteractiveApprovalPolicy()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync(false);
    var protocol = new ChatLineProtocol(fixture.Chat with { Definition = fixture.Chat.Definition with { Provider = "codex" }, ConversationId = "exact-thread" }, fixture.History, true);
    var hello = protocol.Receive("{\"id\":\"hello\",\"result\":{}}");
    using var resume = JsonDocument.Parse(hello.Writes.Single(s => s.Contains("thread/resume", StringComparison.Ordinal)));
    Assert.Equal("exact-thread", resume.RootElement.GetProperty("params").GetProperty("threadId").GetString());
    Assert.Equal("on-request", resume.RootElement.GetProperty("params").GetProperty("approvalPolicy").GetString());
  }
  [Fact] public async Task SignedOutNoAgentChatStartsWithoutBorrowingProjectLead()
  {
    await using var fixture = new ChatFixture(); await fixture.InitializeAsync(false);
    var projects = new ProjectService(new JsonStateStore<ProjectState>(fixture.Root, "projects"), new LocalProjectFolders(fixture.Root));
    AgentLaunchPlan? received = null;
    var agents = new AgentService(new JsonStateStore<AgentState>(fixture.Root, "agents"), projects, new AgentInstructions(fixture.Root), fixture.Accounts,
      new DelegateAgentSessionGateway((plan, _) => { received = plan; return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); }));
    var run = await agents.StartAsync(new(null, Folder: fixture.Root.DirectoryPath, Provider: "claude", AccountId: fixture.Account.Id, Mode: "chat", Title: "Specific title"));
    Assert.Null(run.AgentId); Assert.NotNull(received); Assert.Empty(received.Instructions); Assert.Equal("Specific title", received.Title);
    Assert.Null(agents.SessionFace(run.SessionId));
    await Assert.ThrowsAsync<SignInRequiredException>(async () => await agents.StartAsync(new(null, Folder: fixture.Root.DirectoryPath, Provider: "claude", AccountId: fixture.Account.Id, Mode: "terminal")));
  }
  private static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);
  private sealed class Broker : IMcpPermissionBroker
  {
    public List<McpPermissionRequest> Requests { get; } = [];
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct)
    { Requests.Add(request); return ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true)); }
  }
}
