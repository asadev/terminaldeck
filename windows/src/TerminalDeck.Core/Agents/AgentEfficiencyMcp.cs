using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Agents;

public static class AgentEfficiencyMcp
{
  public const string Id = "agents.efficiency";
  public static IReadOnlyList<McpToolSpec> Specs => [new(Id, "agents_efficiency", McpTier.Alter, JsonDocument.Parse("""
    {"type":"object","properties":{"action":{"type":"string","enum":["read","save","read-defaults","save-defaults","usage","task-budget"]},"agentId":{"type":"string"},"category":{"type":"string","enum":["orchestrator","lead","agent"]},"taskId":{"type":"string"},"billing":{"type":"string","enum":["api","subscription"]},"tokens":{"type":["integer","null"],"minimum":0,"maximum":1000000000},"policy":{"type":["object","null"],"properties":{"monthlyTokens":{"type":["integer","null"],"minimum":0,"maximum":1000000000},"monthlyUsd":{"type":["number","null"],"minimum":0,"maximum":1000000000},"taskTokens":{"type":["integer","null"],"minimum":0,"maximum":1000000000},"warningPercent":{"type":["integer","null"],"minimum":1,"maximum":100},"onExhaustion":{"type":["string","null"],"enum":[null,"warn","pause"]},"reuseContext":{"type":["boolean","null"]},"completion":{"type":["string","null"],"enum":[null,"park","stop"]},"addonsOff":{"type":["boolean","null"]},"serializeHeavyJobs":{"type":["boolean","null"]}},"additionalProperties":false}},"required":["action"],"additionalProperties":false}
    """).RootElement.Clone())];
  public static McpTier Tier(JsonElement args) => args.GetProperty("action").GetString() is "read" or "read-defaults" or "usage" ? McpTier.Read : McpTier.Alter;
  public static void Register(AgentService agents, AgentBudgetRuntime budgets, Func<TaskService?> tasks, McpDoor door)
  {
    door.Register(Id, async (context, args, ct) =>
    {
      string? Text(string key) => args.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
      var action = Text("action");
      var policy = args.TryGetProperty("policy", out var raw) && raw.ValueKind != JsonValueKind.Null ? raw.Deserialize<AgentEfficiency>(Cloud.CloudWire.Json) : null;
      policy?.Validate();
      if (action is "read-defaults" or "save-defaults")
      {
        context.Require("settings", "agent-templates");
        if (!Enum.TryParse<AgentCategory>(Text("category"), true, out var category)) throw new McpRefusal("Choose an agent category.");
        var template = agents.Templates().Single(t => t.Category == category);
        if (action == "save-defaults") { await context.EnsureCurrentAsync(ct); agents.SaveTemplate(template with { Efficiency = policy }, template); }
        return JsonSerializer.SerializeToElement(agents.Templates().Single(t => t.Category == category).Efficiency, Cloud.CloudWire.Json);
      }
      if (action == "task-budget")
      {
        var owner = tasks() ?? throw new McpRefusal("Open Tasks first.");
        var task = owner.Get(Text("taskId") ?? throw new McpRefusal("Choose a task."));
        context.Require("tasks", task.Id); context.Require("projects", task.ProjectId); context.Require("folders", task.Folder);
        await context.EnsureCurrentAsync(ct);
        var amount = args.TryGetProperty("tokens", out var tokens) && tokens.ValueKind != JsonValueKind.Null ? tokens.GetInt64().ToString(System.Globalization.CultureInfo.InvariantCulture) : null;
        return JsonSerializer.SerializeToElement(owner.Detail(task.Id, "token-budget", null, amount, new(context.Grant.CallerId, "AI", "agent")), Cloud.CloudWire.Json);
      }
      var id = Text("agentId") ?? throw new McpRefusal("Choose an agent."); context.Require("agents", id);
      var agent = agents.Get(id);
      if (action == "usage") return JsonSerializer.SerializeToElement(await budgets.ReadAsync(id, Text("billing") == "api", ct), Cloud.CloudWire.Json);
      if (action == "save") { await context.EnsureCurrentAsync(ct); agents.Save(agent with { Options = agent.Settings with { Efficiency = policy } }, agent); }
      else if (action != "read") throw new McpRefusal("Choose an efficiency action.");
      return JsonSerializer.SerializeToElement(agents.Get(id).Settings.Efficiency, Cloud.CloudWire.Json);
    });
  }
}
