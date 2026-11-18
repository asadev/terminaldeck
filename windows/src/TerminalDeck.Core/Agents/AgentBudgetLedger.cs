using System.Globalization;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Agents;

public sealed record AgentUsageCharge(string SessionId, string AgentId, string? TaskRunId, bool Api, string Key,
  DateTimeOffset At, long Tokens, decimal Usd, bool Baseline = false, bool BillingKnown = true);
public sealed record AgentUsageSession(string SessionId, string AgentId, bool Api, DateTimeOffset StartedAt, bool TokensKnown, bool MoneyKnown, bool BillingKnown = true, DateTimeOffset? EndedAt = null, string? TaskRunId = null);
public sealed record AgentUsageLedgerState(int Version, AgentUsageCharge[] Charges, AgentUsageSession[] Sessions);

// Shared by the foreground launch guard and the keeper's event observer. Every write reloads under one file lease.
public sealed class AgentBudgetLedger(JsonStateStore<AgentUsageLedgerState> store, TimeZoneInfo? timeZone = null)
{
  private readonly TimeZoneInfo zone = timeZone ?? TimeZoneInfo.Local;
  private string Month(DateTimeOffset at) => TimeZoneInfo.ConvertTime(at, zone).ToString("yyyy-MM", CultureInfo.InvariantCulture);
  private readonly SemaphoreSlim gate = new(1, 1);
  private AgentUsageLedgerState Read()
  {
    var state = store.Load();
    if (state is null) return new(1, [], []);
    if (state.Version != 1 || state.Charges is null || state.Sessions is null) throw new IOException("The agent usage ledger could not be read. It was kept.");
    return state;
  }

  public async Task ObserveAsync(AgentUsageObservation observation, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      using var lease = await store.AcquireWriteAsync(ct);
      var state = Read(); var charges = state.Charges.ToList();
      foreach (var sample in observation.Samples.OrderBy(s => s.At))
      {
        if (sample.At == default || sample.Key.Length is 0 or > 300 || sample.Tokens is < 0 || sample.Usd is < 0) continue;
        var old = charges.Where(c => c.Key == sample.Key).ToArray();
        // A cumulative reading contributes only its increase. A rewind cannot refund prior expenditure.
        var knownTokens = old.Sum(c => c.Tokens); var knownMoney = old.Sum(c => c.Usd);
        var tokens = Math.Max(0, (sample.Tokens ?? 0) - knownTokens);
        var usd = Math.Max(0, (sample.Usd ?? 0) - knownMoney);
        if (tokens == 0 && usd == 0) continue;
        charges.Add(new(observation.SessionId, observation.AgentId, observation.TaskRunId, observation.Api, sample.Key, sample.At, tokens, usd, sample.Baseline, observation.BillingKnown));
      }
      var prior = state.Sessions.FirstOrDefault(s => s.SessionId == observation.SessionId);
      var session = new AgentUsageSession(observation.SessionId, observation.AgentId, observation.Api, observation.StartedAt, observation.TokensKnown, observation.MoneyKnown, observation.BillingKnown,
        observation.Ended ? prior?.EndedAt ?? DateTimeOffset.Now : null, observation.TaskRunId);
      var sessions = state.Sessions.Where(s => s.SessionId != observation.SessionId).Append(session).ToArray();
      store.Save(new(1, charges.ToArray(), sessions));
    }
    finally { gate.Release(); }
  }

  public async Task<AgentBudgetTotals> MonthlyAsync(string agentId, bool api, DateTimeOffset now, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      using var lease = await store.AcquireWriteAsync(ct); var state = Read();
      var month = Month(now);
      var rows = state.Charges.Where(c => !c.Baseline && c.BillingKnown && c.AgentId == agentId && c.Api == api && Month(c.At) == month).ToArray();
      var sessions = state.Sessions.Where(s => s.AgentId == agentId && (s.Api == api || !s.BillingKnown) && string.CompareOrdinal(Month(s.StartedAt), month) <= 0 && (s.EndedAt is null || string.CompareOrdinal(Month(s.EndedAt.Value), month) >= 0)).ToArray();
      var unknown = sessions.Count(s => !s.BillingKnown || (api ? !s.MoneyKnown : !s.TokensKnown));
      var tokens = rows.Sum(c => c.Tokens); var usd = rows.Sum(c => c.Usd);
      return new(sessions.All(s => s.BillingKnown && s.TokensKnown) ? tokens : null, sessions.All(s => s.BillingKnown && s.MoneyKnown) ? usd : null, tokens, usd, unknown);
    }
    finally { gate.Release(); }
  }

  public async Task<long?> TaskTokensAsync(string taskRunId, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      using var lease = await store.AcquireWriteAsync(ct); var state = Read();
      var rows = state.Charges.Where(c => !c.Baseline && c.TaskRunId == taskRunId).ToArray();
      return rows.Length == 0 || state.Sessions.Any(s => s.TaskRunId == taskRunId && !s.TokensKnown) ? null : rows.Sum(c => c.Tokens);
    }
    finally { gate.Release(); }
  }
}

// The platform supplies exact session records/transcripts. The guard never estimates usage from a model or context size.
public sealed class AgentBudgetRuntime(AgentBudgetLedger ledger, Func<string, CancellationToken, Task<IReadOnlyList<AgentUsageObservation>>> read,
  TimeProvider? clock = null)
{
  private readonly TimeProvider clock = clock ?? TimeProvider.System;
  public async Task ReconcileAsync(string agentId, CancellationToken ct = default)
  {
    foreach (var observation in await read(agentId, ct)) await ledger.ObserveAsync(observation, ct);
  }
  public async Task<AgentBudgetDecision> BeforeStartAsync(string agentId, AgentEfficiency? policy, bool api, CancellationToken ct)
  {
    if (policy?.HasBudget != true) return new(false, null);
    await ReconcileAsync(agentId, ct);
    var decision = AgentBudgetPolicy.Monthly(policy, await ledger.MonthlyAsync(agentId, api, clock.GetUtcNow(), ct), api);
    if (decision.Pause) throw new AgentBudgetPauseException((decision.Warning ?? "This agent's monthly budget is used up.") + " Change its budget or pause policy before starting another task.");
    return decision;
  }
  public async Task<AgentBudgetTotals> ReadAsync(string agentId, bool api, CancellationToken ct = default)
  {
    await ReconcileAsync(agentId, ct); return await ledger.MonthlyAsync(agentId, api, clock.GetUtcNow(), ct);
  }
}
