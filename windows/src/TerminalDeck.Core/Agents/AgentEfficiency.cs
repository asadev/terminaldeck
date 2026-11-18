using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Agents;

// Null inherits. A zero budget is unlimited; it is different from usage that has not been reported.
public sealed record AgentEfficiency(long? MonthlyTokens = null, decimal? MonthlyUsd = null, long? TaskTokens = null,
  int? WarningPercent = null, string? OnExhaustion = null, bool? ReuseContext = null, string? Completion = null, bool? AddonsOff = null, bool? SerializeHeavyJobs = null)
{
  public bool HasBudget => MonthlyTokens is > 0 || MonthlyUsd is > 0 || TaskTokens is > 0;
  public int WarnAt => WarningPercent ?? 80;
  public bool Pauses => OnExhaustion == "pause";
  public static AgentEfficiency? Merge(AgentEfficiency? parent, AgentEfficiency? child) => parent is null && child is null ? null : new(
    child?.MonthlyTokens ?? parent?.MonthlyTokens, child?.MonthlyUsd ?? parent?.MonthlyUsd, child?.TaskTokens ?? parent?.TaskTokens,
    child?.WarningPercent ?? parent?.WarningPercent, child?.OnExhaustion ?? parent?.OnExhaustion, child?.ReuseContext ?? parent?.ReuseContext, child?.Completion ?? parent?.Completion, child?.AddonsOff ?? parent?.AddonsOff, child?.SerializeHeavyJobs ?? parent?.SerializeHeavyJobs);
  public void Validate()
  {
    if (MonthlyTokens is < 0 or > 1_000_000_000 || TaskTokens is < 0 or > 1_000_000_000 || MonthlyUsd is < 0 or > 1_000_000_000
      || Completion is not (null or "park" or "stop") || WarningPercent is < 1 or > 100 || OnExhaustion is not (null or "warn" or "pause")) throw new ArgumentException("Use budgets from 0 to 1,000,000,000, a warning percentage from 1 to 100, and Warn or Pause.");
  }
}

public sealed record AgentUsageSample(string Key, DateTimeOffset At, long? Tokens = null, decimal? Usd = null, bool Cumulative = false, bool Baseline = false);
public sealed record AgentUsageObservation(string SessionId, string AgentId, string? TaskRunId, bool Api, DateTimeOffset StartedAt,
  IReadOnlyList<AgentUsageSample> Samples, bool TokensKnown, bool MoneyKnown, bool BillingKnown = true, bool Ended = false);
public sealed record AgentBudgetTotals(long? Tokens, decimal? Usd, long KnownTokens, decimal KnownUsd, int UnknownSessions);
public sealed record AgentBudgetDecision(bool Pause, string? Warning);
public sealed class AgentBudgetPauseException(string words) : InvalidOperationException(words);

public static class AgentBudgetPolicy
{
  public static AgentBudgetDecision Monthly(AgentEfficiency? policy, AgentBudgetTotals totals, bool api)
  {
    if (policy is null) return new(false, null);
    var limit = api ? policy.MonthlyUsd ?? 0 : policy.MonthlyTokens ?? 0;
    if (limit == 0) return new(false, null);
    decimal? used = api ? totals.Usd : totals.Tokens;
    if (used is null) return new(policy.Pauses, "This agent's usage is not known yet. Its monthly budget cannot be checked.");
    var exhausted = used >= limit;
    var warning = used * 100 >= limit * policy.WarnAt;
    return new(exhausted && policy.Pauses, warning ? "This agent has used " + used.Value.ToString("0.##", CultureInfo.CurrentCulture)
      + (api ? " USD" : " tokens") + " of its monthly budget of " + limit.ToString("0.##", CultureInfo.CurrentCulture) + (api ? " USD." : " tokens.") : null);
  }
  public static string Brief(AgentEfficiency? policy)
  {
    if (policy is null) return "";
    var lines = new List<string>();
    if (policy.HasBudget) lines.Add("Budget: " + (policy.TaskTokens is > 0 ? policy.TaskTokens + " tokens for this task. " : "")
      + "The app warns at " + policy.WarnAt + "%. " + (policy.Pauses ? "New tasks wait when the monthly budget runs out." : "Warnings do not stop work."));
    if (policy.SerializeHeavyJobs == true) lines.Add("Before a build, test suite or other heavy job, call agents_work action acquire with its label. If not granted, call action wait with your ticket; it waits for the change event. Release your ticket in a finally step. Do not poll.");
    if (policy.Completion is "park" or "stop") lines.Add("When finished, mark this task Done with the app's task status tool. The app waits for the current reply, then " + (policy.Completion == "park" ? "stops your process and keeps this conversation for compatible work." : "ends this session."));
    return string.Join("\n", lines);
  }

}

// Provider usage is deduplicated by request identity. Repeated stream fragments update maxima, never add another charge.
public static class AgentUsageReadings
{
  private static JsonElement P(JsonElement root, string name) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) ? value : default;
  private static long? N(JsonElement root, string name) => P(root, name) is { ValueKind: JsonValueKind.Number } n && n.TryGetInt64(out var value) && value is >= 0 and <= 1_000_000_000_000_000 ? value : null;
  private static decimal? D(JsonElement root, string name) => P(root, name) is { ValueKind: JsonValueKind.Number } n && n.TryGetDecimal(out var value) && value is >= 0 and <= 1_000_000_000 ? value : null;
  private static string? S(JsonElement root, string name) => P(root, name) is { ValueKind: JsonValueKind.String } s ? s.GetString() : null;
  private static long? Claude(JsonElement usage) => N(usage, "input_tokens") is { } input && N(usage, "output_tokens") is { } output
    ? input + output + (N(usage, "cache_read_input_tokens") ?? 0) + (N(usage, "cache_creation_input_tokens") ?? ((N(P(usage, "cache_creation"), "ephemeral_5m_input_tokens") ?? 0) + (N(P(usage, "cache_creation"), "ephemeral_1h_input_tokens") ?? 0))) : null;

  public static IReadOnlyList<AgentUsageSample> Chat(TerminalDeck.Core.Chats.ChatRecord chat)
  {
    var result = new List<AgentUsageSample>();
    var requests = chat.Events.Where(e => (e.Kind is "requestStarted" or "requestUsage") && e.Id.Length > 0).ToArray();
    foreach (var entry in requests)
      if (entry.Data is { } data && Claude(P(data, "usage")) is { } tokens) result.Add(new("request:" + entry.Id[(entry.Id.LastIndexOf(':') + 1)..], entry.At, tokens));
    var codexCumulative = chat.Events.Any(e => e.Kind == "usage" && e.Data is { } data && N(P(P(data, "usage"), "total"), "totalTokens") is not null);
    foreach (var entry in chat.Events.Where(e => e.Kind == "usage"))
    {
      if (entry.Data is not { } data) continue;
      var usage = P(data, "usage");
      if (chat.Definition.Provider == "claude")
      {
        if (!requests.Any(r => r.ClientId == entry.ClientId) && Claude(usage) is { } tokens) result.Add(new("turn:" + entry.Id, entry.At, tokens));
        if (D(data, "totalCostUsd") is { } usd && S(data, "creationKey") is { Length: > 0 } epoch) result.Add(new("cost:" + epoch, entry.At, Usd: usd, Cumulative: true));
      }
      else if (chat.Definition.Provider == "codex")
      {
        var total = N(P(usage, "total"), "totalTokens");
        if (total is not null) result.Add(new("cumulative", entry.At, total, Cumulative: true));
        else if (!codexCumulative && N(usage, "input_tokens") is { } input && N(usage, "output_tokens") is { } output) result.Add(new("turn:" + entry.Id, entry.At, input + output));
      }
      else if ((N(usage, "total_tokens") ?? N(usage, "total")) is { } tokens) result.Add(new("turn:" + entry.Id, entry.At, tokens));
    }
    return result;
  }

  public static IReadOnlyList<AgentUsageSample> Gemini(JsonElement root)
  {
    var rows = P(root, "messages"); var result = new List<AgentUsageSample>();
    if (rows.ValueKind != JsonValueKind.Array) return result;
    foreach (var row in rows.EnumerateArray())
      if (S(row, "type") == "gemini" && S(row, "id") is { Length: > 0 } id && N(P(row, "tokens"), "total") is { } tokens
        && DateTimeOffset.TryParse(S(row, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)) result.Add(new("request:" + id, at, tokens));
    return result;
  }

  public static IReadOnlyList<AgentUsageSample> Transcript(string provider, IEnumerable<string> lines)
  {
    var result = new List<AgentUsageSample>();
    foreach (var line in lines)
    {
      try
      {
        using var doc = JsonDocument.Parse(line); var row = doc.RootElement;
        if (!DateTimeOffset.TryParse(S(row, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at)) continue;
        if (provider == "claude" && S(row, "type") == "assistant" && P(row, "message") is { } message && S(message, "id") is { Length: > 0 } id && Claude(P(message, "usage")) is { } tokens)
          result.Add(new("request:" + id, at, tokens));
        else if (provider == "codex" && S(row, "type") == "event_msg" && P(row, "payload") is { } payload && S(payload, "type") == "token_count"
          && N(P(P(payload, "info"), "total_token_usage"), "total_tokens") is { } total) result.Add(new("cumulative", at, total, Cumulative: true));
      }
      catch (JsonException) { }
    }
    return result;
  }
}
