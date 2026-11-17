using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Accounts;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.NewSession;

public sealed class SessionStartPermissionMcpTests
{
  [Theory]
  [InlineData("Ask", false)]
  [InlineData("Plan", false)]
  [InlineData("Auto", false)]
  [InlineData("AcceptEdits", false)]
  [InlineData("Bypass", false)]
  [InlineData("Ask", true)]
  [InlineData("Plan", true)]
  [InlineData("Auto", true)]
  [InlineData("AcceptEdits", true)]
  [InlineData("Bypass", true)]
  public async Task Approved_start_permission_reaches_the_real_agent_plan_and_terminal_definition(string permission, bool savedAgent)
  {
    using var fixture = await Fixture.CreateAsync("claude");
    var args = JsonSerializer.SerializeToElement(new Dictionary<string, object>
    {
      ["cwd"] = fixture.Work, ["projectId"] = "sample", ["provider"] = "claude", ["mode"] = "terminal", ["permission"] = permission
    }.Concat(savedAgent ? new Dictionary<string, object> { ["differ"] = new { agentId = "reviewer", reason = "Use this saved agent" } } : []).ToDictionary(x => x.Key, x => x.Value));
    await fixture.Door.CallAsync(fixture.Caller, "sessions.start", args);
    var plan = Assert.Single(fixture.Plans);
    Assert.Equal(Enum.Parse<AiPermissionMode>(permission), plan.Permission);
    Assert.Equal(SessionStartPermission.TerminalValue(plan.Permission), KeeperAgentSessionGateway.Definition(plan).Permission);
    Assert.Equal(savedAgent ? "reviewer" : null, plan.AgentId);
    Assert.Single(fixture.Permissions.Requests);
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task Unsupported_provider_mode_is_refused_before_any_session_starts(bool savedAgent)
  {
    using var fixture = await Fixture.CreateAsync("codex");
    var args = savedAgent
      ? JsonSerializer.SerializeToElement(new { cwd = fixture.Work, permission = "Auto", differ = new { agentId = "reviewer", reason = "Use this saved agent" } })
      : JsonSerializer.SerializeToElement(new { cwd = fixture.Work, provider = "codex", permission = "Auto" });
    await Assert.ThrowsAsync<McpRefusal>(async () => await fixture.Door.CallAsync(fixture.Caller, "sessions.start", args));
    Assert.Empty(fixture.Plans);
  }

  [Fact]
  public void Omission_keeps_defaults_and_shell_or_invalid_values_never_turn_into_a_permission()
  {
    Assert.Null(SessionStartPermission.Parse(JsonSerializer.SerializeToElement(new { }), "claude"));
    foreach (var value in new object[] { "99", "unknown", 1 })
      Assert.Throws<McpRefusal>(() => SessionStartPermission.Parse(JsonSerializer.SerializeToElement(new { permission = value }), "claude"));
    Assert.Throws<McpRefusal>(() => SessionStartPermission.Parse(JsonSerializer.SerializeToElement(new { permission = "Bypass" }), "shell"));
  }

  private sealed class Fixture : IDisposable
  {
    private readonly string directory = Path.Combine(Path.GetTempPath(), "td-start-permission-" + Guid.NewGuid().ToString("N"));
    public string Work => Path.Combine(directory, "work");
    public List<AgentLaunchPlan> Plans { get; } = [];
    public FakePermission Permissions { get; } = new();
    public McpDoor Door { get; private set; } = null!;
    public string Caller { get; private set; } = "";

    public static async Task<Fixture> CreateAsync(string provider)
    {
      var f = new Fixture(); Directory.CreateDirectory(f.Work);
      var root = AppDataRoot.Explicit(Path.Combine(f.directory, "data"));
      var folders = new LocalProjectFolders(root);
      var projects = new ProjectService(new MemoryState<ProjectState>(), folders);
      projects.Save(new("sample", "Sample", [f.Work]));
      var accountProvider = new FakeAccountProvider(provider);
      var accounts = new AccountService(new MemoryState<AccountState>(), [accountProvider]);
      var account = await accounts.CreateAsync(provider, "Test");
      accountProvider.Statuses[account.Id] = new(true, "test@example.invalid");
      await accounts.RefreshAsync(account.Id);
      var gateway = new DelegateAgentSessionGateway((plan, _) => { f.Plans.Add(plan); return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); });
      var agents = new AgentService(new MemoryState<AgentState>(), projects, new AgentInstructions(root), accounts, gateway);
      agents.Save(new("reviewer", "Reviewer", provider, ProjectId: "sample", Seat: "reviewer", AccountId: account.Id));
      var tools = new ProjectsAgentsMcp(projects, agents, folders, () => [], accounts);
      f.Door = new(f.Permissions);
      f.Door.Register("sessions.start", tools.SessionStartHandler((context, args, ct) => tools.StartAsync(new(null, "sample", f.Work, provider,
        account.Id, "terminal", Permission: SessionStartPermission.Parse(args, provider)), context, ct)));
      f.Caller = f.Door.RegisterCaller(McpTests.Grant("sessions.start"), (_, _, _, _, _) => ValueTask.FromResult(true)).Id;
      return f;
    }
    public void Dispose() => Directory.Delete(directory, true);
  }
}
