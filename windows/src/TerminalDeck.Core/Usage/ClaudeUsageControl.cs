using System.Text.Json;

namespace TerminalDeck.Core.Usage;

public sealed record UsageProbeOutcome(string Kind, string Detail, IReadOnlyList<UsageReading> Readings, bool Spawned, double ElapsedMs)
{
  public bool Ok => Kind is "ok" or "cached";
}

/// Asks one login for its plan limits without touching any session (Mac `BackendUsageProbe`).
public interface IUsageProbe
{
  ValueTask<UsageProbeOutcome> RunAsync(UsageAccount account, CancellationToken cancellationToken);
}

/// Claude Code's control protocol for usage: a short `claude -p` process in stream-json mode that is sent
/// `initialize` then `get_usage`. It sends no user message, opens no panel and does not touch any terminal.
public sealed class ClaudeUsageConversation
{
  public static readonly string[] Arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"];
  public const int TimeoutSeconds = 15;
  private bool asked;
  public bool Finished { get; private set; }
  public JsonElement? Usage { get; private set; }
  public string? Error { get; private set; }

  public static string Initialize() => Line("init", new { subtype = "initialize" });
  private static string Line(string id, object request) => JsonSerializer.Serialize(new { type = "control_request", request_id = id, request });

  /// Feed one line the CLI printed. Returns the next line to send, if any. `Finished` turns true on the answer.
  public string? Feed(string line)
  {
    if (Finished || UsageSources.Parse(line) is not { } message || UsageSources.Str(UsageSources.P(message, "type")) != "control_response") return null;
    var response = UsageSources.P(message, "response"); var id = UsageSources.Str(UsageSources.P(response, "request_id"));
    if (id == "init" && !asked)
    {
      if (UsageSources.Str(UsageSources.P(response, "subtype")) != "success") { Finish(null, UsageSources.Str(UsageSources.P(response, "error"))); return null; }
      asked = true; return Line("usage", new { subtype = "get_usage" });
    }
    if (id == "usage")
    {
      var inner = UsageSources.P(response, "response");
      Finish(UsageSources.Str(UsageSources.P(response, "subtype")) == "success" && inner.ValueKind == JsonValueKind.Object ? inner : null, UsageSources.Str(UsageSources.P(response, "error")));
    }
    return null;
  }
  public void Finish(JsonElement? usage, string? error) { if (Finished) return; Finished = true; Usage = usage; Error = error; }

  /// What the answer means for this login (Mac `BackendUsageProbe.run`).
  public static UsageProbeOutcome Interpret(UsageAccount account, JsonElement? usage, string? error, double started, double now)
  {
    UsageProbeOutcome Done(string kind, string detail, IReadOnlyList<UsageReading>? readings = null) => new(kind, detail, readings ?? [], true, now - started);
    if (usage is not { } answer)
      return Done("unreadable", error is not null ? "Claude Code could not report usage: " + (error.Length > 160 ? error[..160] : error) : "Claude Code did not return a readable usage answer before the deadline.");
    var subscription = UsageSources.Str(UsageSources.P(answer, "subscription_type"));
    if (UsageSources.P(answer, "rate_limits_available").ValueKind != JsonValueKind.True)
      return subscription is null
        ? Done("signed-out", "That account is not signed in to Claude Code, so it has no plan limits to report.")
        : Done("no-limits", "This login has no subscription limits — Claude Code reports none for it.");
    var readings = UsageSources.Utilization(UsageSources.P(answer, "rate_limits"), subscription).Select(l => l.Reading(account, now, now, "claude-usage-api", apiReset: true)).ToArray();
    return readings.Length == 0 ? Done("no-limits", "Claude Code reports no plan limits for this login.") : Done("ok", "Read from Claude Code in the app's own process; no session was touched.", readings);
  }
}
