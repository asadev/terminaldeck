using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Accounts;

public static class AccountFlowTools
{
  public static void Register(McpDoor door, AccountService accounts, Func<string, Task> install,
    Func<string, string, Task<JsonElement>> installationFlow, Func<string, string, Task<JsonElement>> signInFlow)
  {
    door.Register("accounts.install", async (c, a, ct) =>
    {
      c.Require("settings", "accounts");
      var provider = a.GetProperty("provider").GetString()!;
      if (provider is not ("claude" or "codex" or "gemini")) throw new McpRefusal("Choose a coding AI.");
      var action = a.TryGetProperty("action", out var operation) ? operation.GetString() : "install";
      if (action is not ("install" or "state" or "cancel")) throw new McpRefusal("Choose install, state or cancel.");
      if (action is "state" or "cancel")
      {
        if (action == "cancel") await c.EnsureCurrentAsync(ct);
        return await installationFlow(provider, action);
      }
      await c.EnsureCurrentAsync(ct); await install(provider);
      return JsonSerializer.SerializeToElement(new { installation = await accounts.InstallationAsync(accounts.List(provider).First().Id, ct) });
    });
    door.Register("accounts.sign_in_flow", async (c, a, ct) =>
    {
      var id = a.GetProperty("accountId").GetString()!; c.Require("accounts", id); _ = accounts.Get(id);
      var action = a.TryGetProperty("action", out var operation) ? operation.GetString()! : "state";
      if (action == "cancel") await c.EnsureCurrentAsync(ct);
      return await signInFlow(id, action);
    });
  }
}
