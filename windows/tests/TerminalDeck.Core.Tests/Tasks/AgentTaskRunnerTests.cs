using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class AgentTaskRunnerTests
{
  private sealed class Instructions : IAgentInstructions
  { public string Save(string id, string text) => throw new NotSupportedException(); public string Read(string path) => "Saved instructions."; }
  private sealed class ExampleProvider : IAccountProvider
  {
    public string Provider => "codex";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fixture@invalid.test"));
    public ValueTask SignInAsync(AccountProfile a, string folder, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask SignOutAsync(AccountProfile a, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile a, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
  [Theory]
  [InlineData("chat")]
  [InlineData("terminal")]
  public async Task TaskStartsThroughTheExistingAgentCoreWithItsAccountProjectModelAndInstructions(string mode)
  {
    var f = new TaskFixture(); var accounts = new AccountService(new MemoryStore<AccountState>(), [new ExampleProvider()]);
    var account = await accounts.CreateAsync("codex", "Sample subscription"); await accounts.RefreshAsync(account.Id); await accounts.SetDefaultAsync("codex", account.Id);
    var plans = new List<AgentLaunchPlan>();
    var gateway = new DelegateAgentSessionGateway((plan, _) => { plans.Add(plan); return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); });
    var agents = new AgentService(new MemoryStore<AgentState>(), f.Projects, new Instructions(), accounts, gateway);
    agents.Save(new("reviewer", "Reviewer", "codex", Model: "sample-model", Effort: "high", ProjectId: "sample", Seat: "reviewer", AccountId: account.Id, InstructionsFile: "/synthetic/reviewer.md"));
    var runner = new AgentTaskRunner(agents, f.Projects, (_, _, _) => ValueTask.CompletedTask);
    var service = new TaskService(new TaskStore(new MemoryStore<TasksState>()), f.Projects, id => f.People.GetValueOrDefault(id), runner, f.Files);
    var task = service.Create(new("Review this change", "Explain the result here.", "sample"), TaskActor.Owner);
    var checks = 0;
    await service.AssignAsync(task.Id, "reviewer", TaskActor.Owner, mode, authorizeStart: (plan, _) =>
    {
      checks++; Assert.Equal(account.Id, plan.AccountId); Assert.Equal("sample", plan.ProjectId); return ValueTask.CompletedTask;
    });
    var plan = Assert.Single(plans); Assert.Equal(mode, plan.Mode); Assert.Equal("sample-model", plan.Model); Assert.Equal("high", plan.Effort);
    Assert.Contains("Saved instructions.", plan.Instructions); Assert.Equal(account.HomeId, plan.AccountHome); Assert.Equal("C:/Work/Sample", plan.Folder); Assert.Contains("task", plan.Job, StringComparison.OrdinalIgnoreCase);
    Assert.Equal(2, checks); Assert.Equal(plan.SessionId, Assert.Single(service.Runs()).SessionId);
  }
  [Theory]
  [InlineData("chat")]
  [InlineData("terminal")]
  public async Task An_exhausted_monthly_pause_refuses_before_any_run_callback_or_driver_spawn(string mode)
  {
    var f = new TaskFixture(); var accounts = new AccountService(new MemoryStore<AccountState>(), [new ExampleProvider()]);
    var account = await accounts.CreateAsync("codex", "Sample subscription"); await accounts.RefreshAsync(account.Id);
    var starts = 0; var callbacks = 0;
    var gateway = new DelegateAgentSessionGateway((plan, _) => { starts++; return ValueTask.FromResult(new AgentSessionStarted(plan.SessionId, plan.Mode)); });
    var agents = new AgentService(new MemoryStore<AgentState>(), f.Projects, new Instructions(), accounts, gateway);
    agents.Save(new("reviewer", "Reviewer", "codex", ProjectId: "sample", Seat: "reviewer", AccountId: account.Id,
      Options: new(Efficiency: new(MonthlyTokens: 100, OnExhaustion: "pause"))));
    var path = Path.Combine(Path.GetTempPath(), "td-agent-pause-" + Guid.NewGuid().ToString("N"));
    try
    {
      var ledger = new AgentBudgetLedger(new TerminalDeck.Core.Storage.JsonStateStore<AgentUsageLedgerState>(TerminalDeck.Core.Storage.AppDataRoot.Explicit(path), "agent-usage"));
      var now = DateTimeOffset.Now;
      await ledger.ObserveAsync(new("previous", "reviewer", null, false, now, [new("request:previous", now, 100)], true, false, Ended: true));
      agents.Budgets = new(ledger, (_, _) => Task.FromResult<IReadOnlyList<AgentUsageObservation>>([]));
      await Assert.ThrowsAsync<AgentBudgetPauseException>(async () => await agents.StartAsync(new("reviewer", Mode: mode), beforeStart: (_, _) => { callbacks++; return ValueTask.CompletedTask; }));
      Assert.Equal(0, callbacks); Assert.Equal(0, starts); Assert.Empty(agents.Runs());
    }
    finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
  }

}
