using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Hoot;

// Apply this wrapper to the shared door, including its non-Hoot tools. Prompt
// instructions alone cannot stop an AI from changing its own account or grant.
public static class HootPolicy
{
  public static bool IsHoot(McpGrant grant, HootState state) => grant.SeatId == HootDesk.Seat ||
    grant.SessionId is { } id && (id == state.ChatId || id == state.ConversationId || state.Turns.Any(t => t.ChatId == id) || state.History.Any(h => h.Turns.Any(t => t.ChatId == id)));
  public static void Check(McpGrant grant, string tool, JsonElement args, HootState state)
  {
    if (!IsHoot(grant, state)) return;
    var read = tool.EndsWith(".read", StringComparison.Ordinal) || tool.EndsWith(".list", StringComparison.Ordinal) ||
      tool is "hoot.chat.history" or "hoot.chat.background" or "hoot.settings.read" or "accounts.status" or "hoot.routines.settings_get" or "hoot.routines.memory_list" or "hoot.routines.actions_list";
    if (read || tool == "sessions.account" && args.TryGetProperty("action", out var accountAction) && accountAction.GetString() is "show" or "plan" ||
        tool == "mcp.callers" && args.TryGetProperty("action", out var callerAction) && callerAction.GetString() == "list") return;
    string S(string key) => args.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    var ownSession = S("sessionId") == state.ChatId || state.Turns.Any(t => t.ChatId is not null && t.ChatId == S("sessionId")) ||
      state.History.Any(h => h.Turns.Any(t => t.ChatId is not null && t.ChatId == S("sessionId")));
    if (ownSession && tool is "sessions.send" or "sessions.stop" or "sessions.keys")
      throw new McpRefusal("Hoot cannot ask, approve or stop itself through its own tool door.");
    var ownAccount = state.Settings is { } settings && (S("accountId") == settings.AccountId || S("account") == settings.AccountId);
    if (tool.StartsWith("hoot.settings.", StringComparison.Ordinal) || tool.StartsWith("hoot.routines.", StringComparison.Ordinal) ||
        tool is "settings.set" or "settings.patch" or "mcp.callers" or "hoot.set_model" or "hoot.set_permission_mode" ||
        tool is "agents.set_control" or "sessions.account" && ownSession ||
        (tool.StartsWith("accounts.", StringComparison.Ordinal) || tool == "hooks.change") && ownAccount)
      throw new McpRefusal("Hoot cannot change its own settings. Only you can, in Hoot's settings.");
    if (tool is "hoot.chat.new" or "hoot.send" or "hoot.chat.ask" or "hoot.chat.stop" or "hoot.background.start" or "hoot.background.cancel" or "hoot.chat.continue" or "hoot.chat.keep_unconfirmed")
      throw new McpRefusal("Hoot cannot ask or stop itself through its own tool door.");
  }
  public static McpToolHandler Wrap(McpToolSpec spec, McpToolHandler run, Func<HootState> read) => async (context, args, ct) =>
  { Check(context.Grant, spec.Id, args, read()); return await run(context, args, ct); };
}
