using System.Text.Json;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Agents;

public sealed class AgentBudgetTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-agent-budget-" + Guid.NewGuid().ToString("N"));
  private readonly DateTimeOffset at = new(2026, 11, 18, 4, 0, 0, TimeSpan.Zero);
  private AppDataRoot Root => AppDataRoot.Explicit(folder);
  private AgentBudgetLedger Ledger(string name = "usage") => new(new JsonStateStore<AgentUsageLedgerState>(Root, name), TimeZoneInfo.Utc);
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
  private AgentUsageObservation Observation(params AgentUsageSample[] samples) => new("session", "reviewer", "task-run", false, at.AddMinutes(-1), samples, true, true);

  [Fact]
  public async Task Repeated_stream_fragments_and_rewinds_do_not_charge_a_request_twice()
  {
    var ledger = Ledger();
    await ledger.ObserveAsync(Observation(new("claude:home:message-1", at, 10), new("claude:home:message-1", at, 12)));
    await ledger.ObserveAsync(Observation(new AgentUsageSample("claude:home:message-1", at, 8)));
    await ledger.ObserveAsync(Observation(new AgentUsageSample("claude:home:message-2", at, 20)));
    var recreated = Ledger();
    Assert.Equal(32, (await recreated.MonthlyAsync("reviewer", false, at)).Tokens);
    Assert.Equal(32, await recreated.TaskTokensAsync("task-run"));
    await recreated.ObserveAsync(Observation(new AgentUsageSample("claude:home:message-1", at, 12)) with { AgentId = "another-agent", SessionId = "copied-session" });
    Assert.Equal(0, (await recreated.MonthlyAsync("another-agent", false, at)).Tokens);
  }

  [Fact]
  public async Task Cumulative_cost_uses_only_increases_and_a_new_worker_has_its_own_counter()
  {
    var ledger = Ledger();
    await ledger.ObserveAsync(Observation(new("cost:worker-a", at, Usd: .01m, Cumulative: true), new("cost:worker-a", at, Usd: .04m, Cumulative: true)) with { Api = true });
    await ledger.ObserveAsync(Observation(new("cost:worker-a", at, Usd: .04m, Cumulative: true), new("cost:worker-b", at, Usd: .02m, Cumulative: true)) with { Api = true });
    Assert.Equal(.06m, (await ledger.MonthlyAsync("reviewer", true, at)).Usd);
  }

  [Fact]
  public async Task Old_cumulative_context_is_a_baseline_not_new_task_expenditure()
  {
    var ledger = Ledger();
    await ledger.ObserveAsync(Observation(new("codex:home:conversation:total", at.AddMinutes(-2), 1000, Cumulative: true, Baseline: true), new("codex:home:conversation:total", at, 1300, Cumulative: true)));
    Assert.Equal(300, (await ledger.MonthlyAsync("reviewer", false, at)).Tokens);
    Assert.Equal(300, await ledger.TaskTokensAsync("task-run"));
  }

  [Fact]
  public async Task Missing_usage_stays_unknown_and_a_broken_ledger_is_not_reset()
  {
    var ledger = Ledger();
    await ledger.ObserveAsync(Observation() with { TokensKnown = false, MoneyKnown = false });
    var totals = await ledger.MonthlyAsync("reviewer", false, at);
    Assert.Null(totals.Tokens); Assert.Equal(1, totals.UnknownSessions);
    Assert.True(AgentBudgetPolicy.Monthly(new(MonthlyTokens: 100, OnExhaustion: "pause"), totals, false).Pause);
    var store = new JsonStateStore<AgentUsageLedgerState>(Root, "broken"); store.Save(new(99, [], []));
    await Assert.ThrowsAsync<IOException>(() => Ledger("broken").ObserveAsync(Observation()));
    Assert.Equal(99, store.Load()!.Version);
  }

  [Fact]
  public async Task An_unset_policy_never_reads_usage_or_creates_a_ledger()
  {
    var calls = 0;
    var runtime = new AgentBudgetRuntime(Ledger(), (_, _) => { calls++; throw new InvalidOperationException(); });
    Assert.Null((await runtime.BeforeStartAsync("reviewer", null, false, default)).Warning);
    Assert.Equal(0, calls); Assert.False(Directory.Exists(Path.Combine(folder, "state")));
  }

  [Theory]
  [InlineData(false, true)] [InlineData(true, false)]
  public void Plan_accounts_use_tokens_and_API_accounts_use_dollars(bool api, bool pause)
  {
    var decision = AgentBudgetPolicy.Monthly(new(MonthlyTokens: 50, MonthlyUsd: 1, OnExhaustion: "pause"), new(100, .1m, 100, .1m, 0), api);
    Assert.Equal(pause, decision.Pause);
  }

  [Fact]
  public void Default_warning_is_eighty_percent_and_validation_is_real()
  {
    Assert.NotNull(AgentBudgetPolicy.Monthly(new(MonthlyTokens: 100), new(80, 0, 80, 0, 0), false).Warning);
    Assert.Null(AgentBudgetPolicy.Monthly(new(MonthlyTokens: 100), new(79, 0, 79, 0, 0), false).Warning);
    Assert.Throws<ArgumentException>(() => new AgentEfficiency(WarningPercent: 0).Validate());
    var args = JsonSerializer.SerializeToElement(new { action = "save", agentId = "reviewer", policy = new { monthlyTokens = 100, reuseContext = true, completion = "park", addonsOff = true, serializeHeavyJobs = true } });
    McpSchema.Validate(AgentEfficiencyMcp.Specs[0].InputSchema, args);
    Assert.Equal(McpTier.Alter, AgentEfficiencyMcp.Tier(args));
  }

  [Fact]
  public void Real_Claude_JSONL_shape_deduplicates_message_identity_and_counts_cache_tokens()
  {
    var rows = new[] {
      """{"type":"assistant","timestamp":"2026-11-18T04:00:00Z","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}}}""",
      """{"type":"assistant","timestamp":"2026-11-18T04:00:01Z","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}}}"""
    };
    var samples = AgentUsageReadings.Transcript("claude", rows);
    Assert.Equal(new long?[] { 37, 39 }, samples.Select(s => s.Tokens));
    Assert.Single(samples.Select(s => s.Key).Distinct());
  }

  [Fact]
  public void Context_capacity_and_last_request_are_not_cumulative_Codex_expenditure()
  {
    var rows = new[] { """{"type":"event_msg","timestamp":"2026-11-18T04:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":1234},"last_token_usage":{"total_tokens":123},"model_context_window":1000000}}}""" };
    var sample = Assert.Single(AgentUsageReadings.Transcript("codex", rows));
    Assert.Equal(1234, sample.Tokens); Assert.True(sample.Cumulative);
  }

  [Fact]
  public void Claude_chat_cost_is_attributed_only_with_a_worker_identity()
  {
    var definition = new ChatDefinition(Guid.NewGuid().ToString(), "claude", Path.GetTempPath(), "Test", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new());
    var chat = new ChatRecord(1, definition, "worker", [new(1, "usage", "a", Data: JsonSerializer.SerializeToElement(new { creationKey = "worker", totalCostUsd = .1m }), At: at), new(2, "usage", "b", Data: JsonSerializer.SerializeToElement(new { creationKey = "worker", totalCostUsd = .2m }), At: at)], []);
    Assert.Single(AgentUsageReadings.Chat(chat).Where(s => s.Usd is not null).Select(s => s.Key).Distinct());
    var old = chat with { Events = [new(1, "usage", "a", Data: JsonSerializer.SerializeToElement(new { totalCostUsd = .1m }), At: at)] };
    Assert.DoesNotContain(AgentUsageReadings.Chat(old), s => s.Usd is not null);
  }
  [Fact]
  public async Task The_reader_uses_only_the_saved_conversation_account_and_attributed_agent_run()
  {
    var homeId = Guid.NewGuid().ToString("N"); var sessionId = Guid.NewGuid().ToString(); var conversation = Guid.NewGuid().ToString();
    var cwd = Path.Combine(folder, "work"); Directory.CreateDirectory(cwd);
    var home = TerminalDeck.Core.Accounts.AccountHomes.Resolve(Root, "claude", homeId, Path.GetTempPath(), false);
    var transcripts = Path.Combine(home, "projects", "fixture"); Directory.CreateDirectory(transcripts);
    var transcript = Path.Combine(transcripts, conversation + ".jsonl");
    File.WriteAllText(transcript, JsonSerializer.Serialize(new { sessionId = conversation, cwd }) + "\n" +
      JsonSerializer.Serialize(new { type = "assistant", timestamp = at, sessionId = conversation, cwd, message = new { id = "msg_fixture", usage = new { input_tokens = 10, output_tokens = 5 } } }) + "\n");
    var terminal = new TerminalDeck.Core.Sessions.SessionRecord(new(sessionId, "claude", cwd, "Task", homeId, homeId, conversation), "worker", TerminalDeck.Core.Sessions.SessionState.Exited);
    var run = new AgentRun(sessionId, "reviewer", "Reviewer", "claude", "sample", null, 1, "job", "terminal", AgentRunState.Ended, at.AddMinutes(-1), AccountId: homeId, TaskRunId: "task-run");
    var account = new TerminalDeck.Core.Accounts.AccountProfile(homeId, "claude", "Fixture", null, TerminalDeck.Core.Accounts.AccountAuthentication.Subscription, true, homeId);
    var reader = new AgentUsageReader(() => [run], () => [terminal], _ => null, new(Root), id => id == homeId ? account : null);
    var observation = Assert.Single(await reader.ReadAsync("reviewer", default), o => o.SessionId == sessionId);
    Assert.True(observation.TokensKnown); Assert.Equal(15, Assert.Single(observation.Samples).Tokens);
    Assert.DoesNotContain(await reader.ReadAsync("another-agent", default), o => o.Samples.Count > 0);
    terminal = terminal with { AccountRevision = 1 };
    var switched = Assert.Single(await reader.ReadAsync("reviewer", default), o => o.SessionId == sessionId);
    Assert.False(switched.TokensKnown); Assert.Empty(switched.Samples);
  }

}
