using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Accounts;

public static class AccountReadinessTools
{
  // Keep the existing account-status contract, permission and root-level fields.
  // Only granted accounts contribute to the readiness report.
  public static void Register(McpDoor door, AccountService accounts) => door.Compose("accounts.status", previous => async (context, arguments, ct) =>
  {
    if (previous is null) throw new McpRefusal("Account status is not connected.");
    var status = await previous(context, arguments, ct);
    var value = JsonNode.Parse(status.GetRawText())?.AsObject() ?? throw new McpRefusal("Account status could not be read.");
    value["readiness"] = JsonSerializer.SerializeToNode(SignInReadiness.Read(accounts.List().Where(account => context.Has("accounts", account.Id))));
    return JsonSerializer.SerializeToElement(value);
  });
}
