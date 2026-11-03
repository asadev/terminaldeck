using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Hoot;

// Evaluate at invocation and after permission waits, not just when the phone
// sends its prompt. Queued turns retain their initiating device in HootSource.
public static class HootPhoneAuthority
{
  public static HootSource? Source(HootState state) => state.Active?.Source ?? state.Turns.LastOrDefault(t => t.ChatId is not null && t.ChatId == state.ChatId)?.Source;
  public static string? Device(HootState state) => Source(state)?.DeviceId;
  public static void Check(McpGrant grant, string tool, JsonElement args, HootState state,
    Func<string, ApprovedDevice?> current, Func<ApprovedDevice, string, string, bool> has, McpTier tier)
  {
    if (!HootPolicy.IsHoot(grant, state) || Device(state) is not { } id) return;
    var device = current(id) ?? throw new McpRefusal("The phone that requested this Hoot turn is no longer approved.");
    if (device.Access == PhoneAccess.Full) return;
    if (device.Access == PhoneAccess.Look || device.Access == PhoneAccess.Hoot && tier == McpTier.Alter)
      throw new McpRefusal("This Hoot turn is outside the phone's current access.");
    if (tool.StartsWith("settings.", StringComparison.Ordinal) || tool.StartsWith("accounts.", StringComparison.Ordinal) ||
        tool.StartsWith("remote.", StringComparison.Ordinal) || tool.StartsWith("servers.", StringComparison.Ordinal) ||
        tool.StartsWith("mcp.", StringComparison.Ordinal) || tool.StartsWith("app.", StringComparison.Ordinal))
      throw new McpRefusal("This phone cannot manage the computer through Hoot.");
    var targets = new Dictionary<string, string> { ["sessionId"] = "sessions", ["projectId"] = "projects", ["agentId"] = "agents", ["taskId"] = "tasks", ["cwd"] = "folders", ["folder"] = "folders", ["path"] = "folders" };
    foreach (var (key, kind) in targets)
      if (args.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } target && !has(device, kind, target))
        throw new McpRefusal("That item is outside the requesting phone's current grants.");
    if (device.Access == PhoneAccess.Hoot && !tool.StartsWith("hoot.", StringComparison.Ordinal))
      throw new McpRefusal("The requesting phone has Hoot only access.");
  }
}
