using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Computers;

public sealed record ComputerOperation(string Tag, string Capability, string Reply, string[] Required);

// Shared by the UI and MCP adapter. These are protocol facts, not a generic RPC
// escape hatch: callers can select only the host's defined service operations.
public static class ComputerOperations
{
  public static IReadOnlyDictionary<string, ComputerOperation> All { get; } = new Dictionary<string, ComputerOperation>
  {
    ["controls-read"] = new("controls.read", "controls", "controls.reading", ["id"]),
    ["controls-set"] = new("controls.apply", "controls", "controls.applied", ["id", "control", "value"]),
    ["usage"] = new("usage.read", "usage", "usage.reading", ["id", "want"]),
    ["account-read"] = new("account.read", "account", "account.state", ["id"]),
    ["account-switch"] = new("account.switch", "account", "account.switched", ["id", "accountId"]),
    ["logins"] = new("logins.read", "logins", "logins.state", []),
    ["sign-in"] = new("logins.signin", "logins", "logins.signedin", ["accountId"]),
    ["sign-out"] = new("logins.signout", "logins", "logins.signedout", ["accountId"]),
    ["send"] = new("session.send", "send", "session.sent", ["id", "data"]),
    ["host-read"] = new("host.status", "host.control", "host.state", []),
    ["host-restart"] = new("host.restart", "host.control", "host.state", []),
    ["host-stop"] = new("host.stop", "host.control", "host.state", []),
    ["github-read"] = new("github.read", "github", "github.state", []),
    ["github-connect"] = new("github.connect", "github", "github.state", []),
    ["github-cancel"] = new("github.cancel", "github", "github.state", []),
    ["github-disconnect"] = new("github.disconnect", "github", "github.state", [])
  };
  public static ComputerOperation Validate(string action, JsonObject fields)
  {
    if (!All.TryGetValue(action, out var operation)) throw new ArgumentException("Choose a listed computer service action.");
    if (fields.Any(p => p.Key is "t" or "rid")) throw new ArgumentException("Protocol fields are owned by the connection.");
    var allowed = operation.Required.Concat(action == "usage" ? ["force"] : Array.Empty<string>()).ToHashSet();
    if (fields.Any(p => !allowed.Contains(p.Key))) throw new ArgumentException("This action does not accept that field.");
    foreach (var key in operation.Required)
      if (fields[key] is not JsonValue value || !value.TryGetValue<string>(out var text) || string.IsNullOrEmpty(text) || text.Length > 65536)
        throw new ArgumentException("Supply " + key + " for this action.");
    if (action == "controls-set" && fields["control"]!.GetValue<string>() is not ("model" or "effort" or "fast" or "permission")) throw new ArgumentException("Choose model, effort, fast or permission.");
    if (action == "usage" && fields["want"]!.GetValue<string>() is not ("plan" or "context" or "refresh")) throw new ArgumentException("Choose plan, context or refresh.");
    return operation;
  }
}
