using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  // The view has already applied the session's native approval flow. Keep the
  // normal MCP door, exact-server grant, live mode check and action audit.
  public async Task<JsonElement> CallChatAppToolAsync(string chatId, string serverId, string tool, JsonElement arguments, CancellationToken ct)
  {
    var chat = await Chats.ReadAsync(chatId, ct);
    var mode = chat.Definition.PermissionMode;
    var policy = new McpCallerPolicy("app-ui:" + Guid.NewGuid().ToString("N"), chatId, null, mode,
      ["mcp.call"], [McpTier.Alter], ["sessions:" + chatId, "folders:" + chat.Definition.Cwd, "mcp:" + serverId]);
    var registration = CallerAuthority.Provision(Door, policy, _ => Chats.List().Any(c => c.Definition.Id == chatId && !c.Ended && c.Definition.PermissionMode == mode));
    try
    {
      var response = await Door.CallAsync(registration.Id, "mcp.call", JsonSerializer.SerializeToElement(new { serverId, tool, arguments }), ct);
      return response.TryGetProperty("data", out var data) ? data.Clone() : response;
    }
    finally { CallerAuthority.Revoke(Door, policy.CallerId); }
  }
}
