using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Usage;

/// `usage.read` (plan limits + context window, reported figures only) and `usage.refresh`
/// (one session's Claude limits from cache or a short get_usage request; never types into a terminal).
public static class UsageMcpTools
{
  public static void Register(McpDoor door, UsageService usage, Func<string, string>? alias = null)
  {
    door.Register("usage.read", (c, a, ct) =>
    {
      if (a.TryGetProperty("sessionId", out var given) && given.GetString() is { Length: > 0 } named)
      {
        var id = alias?.Invoke(named) ?? named; c.Require("sessions", id);
        return ValueTask.FromResult(JsonSerializer.SerializeToElement(usage.ToolView(id)));
      }
      var all = usage.Read(null);
      var mine = all with { Readings = all.Readings.Where(r => r.Account.Id is { } account && c.Has("accounts", account)).ToArray() };
      return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { limits = UsageService.ReportView(mine) }));
    });
    door.Register("usage.refresh", async (c, a, ct) =>
    {
      var id = a.TryGetProperty("sessionId", out var given) ? given.GetString() : null;
      if (string.IsNullOrWhiteSpace(id)) throw new McpRefusal("Choose a value for sessionId.");
      id = alias?.Invoke(id) ?? id;
      c.Require("sessions", id);
      var force = a.TryGetProperty("force", out var f) && f.ValueKind == JsonValueKind.True;
      var outcome = await usage.RefreshAsync(id, force, ct);
      return JsonSerializer.SerializeToElement(new { ok = outcome.Ok, outcome = outcome.Kind, detail = outcome.Detail, elapsedMs = Math.Round(outcome.ElapsedMs), spawned = outcome.Spawned, limits = UsageService.ReportView(usage.Read(id)) });
    });
  }
}
