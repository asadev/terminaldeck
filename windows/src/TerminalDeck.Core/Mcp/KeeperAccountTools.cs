using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Mcp;

public static class KeeperAccountTools
{
  public static void Register(McpDoor door, AccountService accounts, Func<KeeperClient> keeper, IConversationAccountRuntime conversations, AccountSwitchCoordinator switches, Func<string, bool>? chatInUse = null)
  {
    door.Register("accounts.list", (c, a, ct) => ValueTask.FromResult(JsonSerializer.SerializeToElement(accounts.List(DeckCoreTools.Text(a, "agent")).Where(x => c.Has("accounts", x.Id)))));
    door.Register("accounts.status", async (c, a, ct) =>
    {
      var id = Id(c, a);
      var account = a.TryGetProperty("refresh", out var refresh) && refresh.GetBoolean() ? await accounts.RefreshAsync(id, ct) : accounts.Get(id);
      if (a.TryGetProperty("installation", out var installation) && installation.GetBoolean()) return JsonSerializer.SerializeToElement(new { account, installation = await accounts.InstallationAsync(id, ct) });
      return JsonSerializer.SerializeToElement(account);
    });
    door.Register("accounts.create", async (c, a, ct) => { c.Require("settings", "accounts"); await c.EnsureCurrentAsync(ct); return JsonSerializer.SerializeToElement(await accounts.CreateAsync(DeckCoreTools.Text(a, "agent") ?? "claude", DeckCoreTools.Required(a, "name"), cancellationToken: ct)); });
    door.Register("accounts.rename", async (c, a, ct) => { var id = Id(c, a); await c.EnsureCurrentAsync(ct); await accounts.RenameAsync(id, DeckCoreTools.Required(a, "name"), ct); return Done(); });
    door.Register("accounts.share_history", async (c, a, ct) => { var id = Id(c, a); await c.EnsureCurrentAsync(ct); await accounts.ShareHistoryAsync(id, a.GetProperty("share").GetBoolean(), ct); return Done(); });
    door.Register("accounts.sign_in", async (c, a, ct) => { var id = Id(c, a); var folder = DeckCoreTools.Required(a, "folder"); c.Require("folders", folder); await c.EnsureCurrentAsync(ct); try { await accounts.SignInAsync(id, folder, ct); } catch (SignInCancelledException) { return JsonSerializer.SerializeToElement(new { cancelled = true }); } return Done(); });
    door.Register("accounts.sign_out", async (c, a, ct) => { var id = Id(c, a); await c.EnsureCurrentAsync(ct); await accounts.SignOutAsync(id, ct); return Done(); });
    door.Register("accounts.set_default", async (c, a, ct) =>
    {
      c.Require("settings", "accounts"); var folder = DeckCoreTools.Text(a, "projectPath"); if (folder is not null) c.Require("folders", folder);
      var id = DeckCoreTools.Text(a, "accountId"); if (id is not null) c.Require("accounts", id); await c.EnsureCurrentAsync(ct);
      if (id is null) foreach (var provider in new[] { "claude", "codex", "gemini" }) await accounts.SetDefaultAsync(provider, null, folder, ct);
      else { var account = await accounts.RequireSignedInAsync(id, ct); await accounts.SetDefaultAsync(account.Provider, account.Id, folder, ct); }
      return Done();
    });
    door.Register("accounts.delete", async (c, a, ct) =>
    {
      var id = Id(c, a);
      if (a.TryGetProperty("deleteFiles", out var files) && files.GetBoolean()) throw new McpRefusal("Remove the account row here. Deleting its saved sign-ins and transcripts is not connected.");
      var sessions = (await keeper().ListAsync(ct)).Sessions ?? [];
      await c.EnsureCurrentAsync(ct); await accounts.DeleteAsync(id, account => chatInUse?.Invoke(account) == true || sessions.Any(s => s.Definition.AccountId == account || s.PendingAccount?.AccountId == account), ct); return Done();
    });
    door.Register("sessions.account", async (c, a, ct) =>
    {
      var action = DeckCoreTools.Required(a, "action");
      if (action == "armed") return JsonSerializer.SerializeToElement(Array.Empty<object>());
      var id = DeckCoreTools.Required(a, "sessionId"); c.Require("sessions", id);
      var before = await conversations.ReadAsync(id, ct); c.Require("accounts", before.AccountId);
      if (action == "show") return JsonSerializer.SerializeToElement(before);
      if (action is "later" or "cancel") throw new McpRefusal("This terminal cannot reliably report when an AI turn finishes. Switch now after checking the session.");
      var account = accounts.Get(DeckCoreTools.Required(a, "account")); c.Require("accounts", account.Id);
      var plan = await switches.PlanAsync(id, account.Id, ct);
      if (action == "plan") return JsonSerializer.SerializeToElement(new { sessionId = id, accountId = account.Id, keepsConversation = true, reopensTerminal = true, mayInterruptWork = true, conversationId = plan.Before.ProviderConversationId });
      if (action != "switch") throw new McpRefusal("Choose show, plan or switch.");
      await c.EnsureCurrentAsync(ct); var result = await switches.SwitchAsync(id, account.Id, ct); return JsonSerializer.SerializeToElement(result.After);
    });
  }
  private static string Id(McpCallContext c, JsonElement a) { var id = DeckCoreTools.Required(a, "accountId"); c.Require("accounts", id); return id; }
  private static JsonElement Done() => JsonSerializer.SerializeToElement(new { done = true });
}
