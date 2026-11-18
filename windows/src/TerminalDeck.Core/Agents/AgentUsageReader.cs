using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Agents;

public sealed class AgentUsageReader(Func<IReadOnlyList<AgentRun>> runs, Func<IReadOnlyList<SessionRecord>> terminals,
  Func<string, ChatRecord?> chats, ConversationFiles conversations, Func<string, AccountProfile?> account)
{
  private readonly SemaphoreSlim reading = new(1, 1);
  public async Task<IReadOnlyList<AgentUsageObservation>> ReadAsync(string agentId, CancellationToken ct)
  {
    await reading.WaitAsync(ct);
    try { return await Task.Run(() => ReadOwned(agentId, ct), ct); }
    finally { reading.Release(); }
  }
  private IReadOnlyList<AgentUsageObservation> ReadOwned(string agentId, CancellationToken ct)
  {
    var terminalRows = terminals().ToDictionary(s => s.Definition.Id);
    var result = new List<AgentUsageObservation>();
    var owned = runs().Where(r => r.AgentId == agentId).ToArray();
    var completeInventory = owned.Length <= 512;
    result.Add(new("unread:subscription:" + agentId, agentId, null, false, DateTimeOffset.Now, [], completeInventory, completeInventory));
    result.Add(new("unread:api:" + agentId, agentId, null, true, DateTimeOffset.Now, [], completeInventory, completeInventory));
    long remainingBytes = 128 * 1024 * 1024;
    var began = System.Diagnostics.Stopwatch.StartNew();
    foreach (var run in owned.TakeLast(512))
    {
      ct.ThrowIfCancellationRequested();
      IReadOnlyList<AgentUsageSample> samples = [];
      var api = run.Api; var knownTokens = false; var knownMoney = false; var billingKnown = run.AccountId is not null; var ended = false;
      var scope = run.Provider + ":" + (run.AccountId ?? run.SessionId) + ":";
      string? conversation = null;
      if (began.Elapsed > TimeSpan.FromSeconds(5))
      {
        result.Add(new(run.SessionId, agentId, run.TaskRunId, run.Api, run.StartedAt, [], false, false, BillingKnown: run.AccountId is not null));
        continue;
      }
      if (chats(run.SessionId) is { } chat)
      {
        var selected = account(chat.Definition.AccountId); billingKnown |= selected is not null; ended = chat.Ended;
        api = selected?.Authentication is { } billing ? billing == AccountAuthentication.ApiKey : run.Api;
        scope = chat.Definition.Provider + ":" + chat.Definition.AccountHome + ":"; conversation = chat.ConversationId;
        // Account switches mix ownership inside one history. Keep that spend unknown rather than moving it to a new login.
        if (chat.AccountRevision == 0)
        {
          samples = AgentUsageReadings.Chat(chat);
          knownTokens = samples.Any(s => s.Tokens is not null) && !chat.Busy;
          var costs = chat.Events.Where(e => e.Kind == "usage").ToArray();
          knownMoney = chat.Definition.Provider == "claude" && costs.Length > 0 && !chat.Busy && costs.All(e => e.Data is { ValueKind: System.Text.Json.JsonValueKind.Object } data
            && data.TryGetProperty("creationKey", out var epoch) && epoch.ValueKind == System.Text.Json.JsonValueKind.String && !string.IsNullOrWhiteSpace(epoch.GetString())
            && data.TryGetProperty("totalCostUsd", out var cost) && cost.ValueKind == System.Text.Json.JsonValueKind.Number && cost.TryGetDecimal(out var usd) && usd >= 0);
        }
      }
      else if (terminalRows.TryGetValue(run.SessionId, out var terminal))
      {
        var selected = terminal.Definition.AccountId is { } id ? account(id) : null; billingKnown |= selected is not null; ended = terminal.State == SessionState.Exited;
        api = selected?.Authentication is { } kind ? kind == AccountAuthentication.ApiKey : run.Api;
        scope = terminal.Definition.Provider + ":" + (terminal.Definition.AccountHome ?? terminal.Definition.AccountId ?? terminal.Definition.Id) + ":"; conversation = terminal.Definition.ConversationId;
        if (terminal.AccountRevision == 0 && conversations.AgentUsage(terminal, out var bytes, remainingBytes) is { } read)
        {
          remainingBytes -= bytes; samples = read;
          knownTokens = read.Any(s => s.Tokens is not null);
          knownMoney = read.Any(s => s.Usd is not null);
        }
      }
      var scoped = new List<AgentUsageSample>();
      foreach (var sample in samples)
      {
        if (sample.Cumulative && sample.Key == "cumulative" && conversation is null) continue;
        var key = scope + (sample.Key == "cumulative" ? conversation + ":" : "") + sample.Key;
        if (sample.At >= run.StartedAt) scoped.Add(sample with { Key = key });
        else if (sample.Cumulative) scoped.Add(sample with { Key = key, Baseline = true });
      }
      knownTokens = knownTokens && scoped.Any(s => !s.Baseline && s.Tokens is not null);
      knownMoney = knownMoney && scoped.Any(s => !s.Baseline && s.Usd is not null);
      result.Add(new(run.SessionId, agentId, run.TaskRunId, api, run.StartedAt, scoped, knownTokens, knownMoney, billingKnown, ended));
    }
    return result;
  }
}
