using System.Text.Json;

namespace TerminalDeck.Core.Mcp;

public enum McpTier { Read, Act, Alter }
public sealed record McpToolSpec(string Id, string Wire, McpTier Tier, JsonElement InputSchema);
public static class McpCatalogue
{
  public static IReadOnlyList<McpToolSpec> Load()
  {
    var assembly = typeof(McpCatalogue).Assembly;
    var result = new Dictionary<string, McpToolSpec>();
    foreach (var name in new[] { "deck-tools-static-source.json", "deck-tools-runtime-source.json", "deck-tools-windows-integration.json" })
    {
      using var stream = assembly.GetManifestResourceStream("Contracts." + name) ?? throw new IOException("The MCP contracts are missing.");
      using var doc = JsonDocument.Parse(stream);
      foreach (var row in doc.RootElement.GetProperty("entries").EnumerateArray())
      {
        var spec = new McpToolSpec(row.GetProperty("id").GetString()!, row.GetProperty("wire").GetString()!, Enum.Parse<McpTier>(row.GetProperty("tier").GetString()!, true), row.GetProperty("inputSchema").Clone());
        result[spec.Id] = spec;
      }
    }
    foreach (var spec in TerminalDeck.Core.Projects.ProjectsAgentsMcp.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Tasks.TasksMcp.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Servers.ServersMcp.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Receiver.ReceiverContracts.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Hoot.HootMcpTools.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Browser.BrowserWorkspaceTools.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Code.CodeMcp.Specs) result[spec.Id] = spec;
    foreach (var spec in TerminalDeck.Core.Accounts.AccountMcp.Specs) result[spec.Id] = spec;
    return result.Values.ToArray();
  }
  public static McpTier EffectiveTier(McpToolSpec spec, JsonElement arguments, bool ownsSession = false)
  {
    if (TerminalDeck.Core.Tasks.TasksMcp.Specs.Any(t => t.Id == spec.Id)) return TerminalDeck.Core.Tasks.TasksMcp.Tier(spec, arguments);
    if (TerminalDeck.Core.Code.CodeMcp.Specs.Any(t => t.Id == spec.Id)) return TerminalDeck.Core.Code.CodeMcp.Tier(spec, arguments);
    if (TerminalDeck.Core.Accounts.AccountMcp.Specs.Any(t => t.Id == spec.Id)) return TerminalDeck.Core.Accounts.AccountMcp.Tier(spec, arguments);
    var action = arguments.TryGetProperty("action", out var a) ? a.GetString() : null;
    return spec.Id switch
    {
      "accounts.install" => action == "state" ? McpTier.Read : McpTier.Alter,
      "accounts.sign_in_flow" => action is null or "state" ? McpTier.Read : McpTier.Alter,
      "tasks.agents" => arguments.GetProperty("do").GetString() == "list" ? McpTier.Read : McpTier.Alter,
      "remote.workspace" => arguments.TryGetProperty("projects", out _) ? McpTier.Alter : McpTier.Read,
      "mcp.callers" => action == "list" ? McpTier.Read : McpTier.Alter,
      "mcp.remote" => arguments.TryGetProperty("enabled", out _) ? McpTier.Alter : McpTier.Read,
      "ui.workspace" => arguments.TryGetProperty("shellCommand", out var shellCommand) && shellCommand.GetString() == "stop-exit" ? McpTier.Alter : arguments.EnumerateObject().Any() ? McpTier.Act : McpTier.Read,
      "sessions.send" or "sessions.stop" or "sessions.keys" => ownsSession ? McpTier.Act : McpTier.Alter,
      "sessions.account" => action is "switch" or "later" ? McpTier.Alter : action == "cancel" ? McpTier.Act : McpTier.Read,
      "sessions.held" => action == "forget" ? McpTier.Alter : action == "retry" ? McpTier.Act : McpTier.Read,
      "agents.set_control" => arguments.GetProperty("control").GetString() == "permission" || !ownsSession ? McpTier.Alter : McpTier.Act,
      "browser.windows" => action is "attach" or "detach" ? McpTier.Alter : action is null or "list" ? McpTier.Read : McpTier.Act,
      "browser.page" => action == "recordclear" ? McpTier.Alter : action is null or "state" or "recording" or "screenshot" ? McpTier.Read : McpTier.Act,
      "browser.profiles" => action is null or "list" ? McpTier.Read : McpTier.Alter,
      "browser.store" => action is null or "list" ? McpTier.Read : McpTier.Alter,
      "browser.history" => action is "forget" or "clear" ? McpTier.Alter : McpTier.Read,
      _ => spec.Tier
    };
  }
}
