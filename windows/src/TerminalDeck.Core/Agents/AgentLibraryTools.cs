using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Agents;

public sealed class AgentLibraryTools(IProjects projects, IAgents agents, Func<IReadOnlyList<ProjectSession>> sessions)
{
  public static IReadOnlyList<McpToolSpec> Specs => [new("agents.library", "agents_library", McpTier.Read,
    JsonSerializer.SerializeToElement(new { type = "object", properties = new {
      action = new { type = "string", @enum = new[] { "work", "skills", "read", "save", "assign", "unassign" } },
      projectId = new { type = "string" }, root = new { type = "string" }, name = new { type = "string" },
      text = new { type = "string", maxLength = 524288 }, expected = new { type = "string", maxLength = 524288 },
      agentId = new { type = "string" }
    }, required = new[] { "action" }, additionalProperties = false }))];

  public void Register(McpDoor door) => door.Register("agents.library", async (context, args, ct) =>
  {
    string? Text(string key) => args.TryGetProperty(key, out var value) ? value.GetString() : null;
    var action = Text("action");
    var projectId = Text("projectId");
    if (projectId is not null) context.Require("projects", projectId);
    var visibleProjects = projects.List().Where(p => context.Has("projects", p.Id) && (projectId is null || p.Id == projectId)).ToArray();
    var visibleAgents = agents.List().Where(a => context.Has("agents", a.Id) && visibleProjects.Any(p => p.Id == a.ProjectId)).ToArray();
    if (action == "work") return JsonSerializer.SerializeToElement(visibleAgents.Select(a => new {
      agent = a, activity = AgentActivity.For(a, agents.Runs(), sessions()),
      runs = agents.Runs().Where(r => r.AgentId == a.Id && r.State != AgentRunState.Ended && context.Has("sessions", r.SessionId))
    }).Where(a => a.activity.Live > 0));
    var roots = AgentSkills.Roots(visibleProjects.SelectMany(p => p.Folders)).Where(r => context.Has("folders", r)).ToArray();
    if (action == "skills") return JsonSerializer.SerializeToElement(roots.SelectMany(r => AgentSkills.Find([r])).GroupBy(s => s.Folder, StringComparer.OrdinalIgnoreCase).Select(g => g.First()));
    var root = Text("root") ?? throw new McpRefusal("Choose an installed-skills folder.");
    if (!roots.Any(r => string.Equals(Path.GetFullPath(r), Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase)))
      throw new McpRefusal("That skills folder is outside this caller's access.");
    var name = Text("name") ?? throw new McpRefusal("Choose a skill.");
    if (action == "read") return JsonSerializer.SerializeToElement(AgentSkillLibrary.Read(root, name));
    await context.EnsureCurrentAsync(ct);
    if (action == "save") return JsonSerializer.SerializeToElement(AgentSkillLibrary.Save(root, name, Text("text") ?? "", Text("expected")));
    if (action is not ("assign" or "unassign")) throw new McpRefusal("Choose a library action.");
    var document = AgentSkillLibrary.Read(root, name);
    var agent = visibleAgents.SingleOrDefault(a => a.Id == Text("agentId")) ?? throw new McpRefusal("Choose an agent in this caller's access.");
    var skills = agent.Skills.IsDefault ? ImmutableArray<string>.Empty : agent.Skills;
    var chosen = action == "assign";
    if (skills.Contains(document.Name) != chosen) agents.Save(agent with { Skills = chosen ? skills.Add(document.Name) : skills.Remove(document.Name) }, agent);
    return JsonSerializer.SerializeToElement(new { assigned = chosen, agentId = agent.Id, skill = document.Name });
  });
}
