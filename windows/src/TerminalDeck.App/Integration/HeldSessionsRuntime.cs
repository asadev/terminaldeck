using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public async Task<SessionRecord> ReopenHeldSessionAsync(string id, CancellationToken ct = default)
  {
    var result = await Keeper.ReopenAsync(id, ct);
    await RefreshSessionsAsync();
    return result.Session ?? throw new IOException("The session did not report its reopen result.");
  }
  private void InitializeHeldSessionTools()
  {
    Door.Register("sessions.held", async (context, args, ct) =>
    {
      var action = args.GetProperty("action").GetString();
      var rows = (await Keeper.ListAsync(ct)).Sessions ?? [];
      if (action == "list") return JsonSerializer.SerializeToElement(rows.Where(row => row.State == SessionState.Held && context.Has("sessions", row.Definition.Id) && context.Has("folders", row.Definition.Cwd)).Select(row => new { key = row.Definition.Id, row.Definition.Title, row.Definition.Cwd, state = "not-reopened" }));
      var id = args.GetProperty("key").GetString()!;
      context.Require("sessions", id);
      var row = rows.FirstOrDefault(row => row.Definition.Id == id && row.State == SessionState.Held) ?? throw new McpRefusal("Choose a not-reopened session from the list.");
      context.Require("folders", row.Definition.Cwd);
      if (row.Definition.AccountId is { } account) context.Require("accounts", account);
      await context.EnsureCurrentAsync(ct);
      if (action == "retry") return JsonSerializer.SerializeToElement(await ReopenHeldSessionAsync(id, ct));
      if (action == "forget") { await Keeper.ForgetHeldAsync(id, ct); await RefreshSessionsAsync(); return JsonSerializer.SerializeToElement(new { forgotten = true }); }
      throw new McpRefusal("Choose a listed held-session action.");
    });
  }
}
