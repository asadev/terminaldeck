using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Agents;

// A team brought over from another Terminal Deck (or a Claude .claude/agents folder).
// Applied only through the app's own project and agent services, so every
// validation the Agents page uses also guards an import. Re-running is safe:
// existing projects, roles and non-empty memory are kept, never overwritten.
public sealed record TeamImportAgent(string Role, string Name, string Description = "", string Provider = "claude", string Model = "",
  string Effort = "auto", string Icon = "person", string Instructions = "", string Card = "", string Notes = "");
public sealed record TeamImportProject(string Id, string Name, ImmutableArray<string> Folders, string? Colour = null,
  TeamImportAgent? Lead = null, ImmutableArray<TeamImportAgent> Agents = default);
public sealed record TeamImportPlan(ImmutableArray<TeamImportProject> Projects);

public static class TeamImport
{
  public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
  public static TeamImportPlan Read(string json) => JsonSerializer.Deserialize<TeamImportPlan>(json, Json) ?? throw new ArgumentException("The team file is empty.");

  public static IReadOnlyList<string> Apply(IProjects projects, IAgents agents, TeamImportPlan plan)
  {
    var log = new List<string>();
    foreach (var item in plan.Projects.IsDefault ? [] : plan.Projects)
    {
      var project = projects.List().FirstOrDefault(p => p.Id == item.Id)
        ?? projects.List().FirstOrDefault(p => p.Id != ProjectIdentity.IndependentId && p.Folders.Any(f => item.Folders.Any(n => ProjectPaths.Equal(f, n))));
      if (project is null)
      {
        project = projects.Save(new ProjectDraft(item.Id, item.Name, item.Folders, Colour: item.Colour), createOnly: true);
        log.Add($"project created: {project.Name} ({project.HomeFolder})");
      }
      else log.Add($"project kept: {project.Name} ({project.HomeFolder})");

      string? leadId = null;
      if (item.Lead is { } lead)
      {
        leadId = Hire(agents, project.Id, lead, null, log);
        var current = projects.Get(project.Id).Lead;
        if (current is null) { agents.SetProjectLead(project.Id, leadId); log.Add($"  lead set: {lead.Name}"); }
        else if (current != "agent:" + leadId) log.Add($"  lead kept: project already led by {current[6..]}");
        Memory(agents, AgentSeats.Lead(project.Id).Key, lead, log);
      }
      foreach (var agent in item.Agents.IsDefault ? [] : item.Agents)
      {
        var id = Hire(agents, project.Id, agent, leadId, log);
        Memory(agents, AgentSeats.Role(project.Id, agents.Get(id).Seat).Key, agent, log);
      }
    }
    return log;
  }

  private static string Hire(IAgents agents, string projectId, TeamImportAgent row, string? reportsTo, List<string> log)
  {
    var role = row.Role.Trim();
    if (!AgentSeats.ValidRole(role)) throw new ArgumentException($"'{row.Role}' is not a role name (lowercase words and dashes).");
    var existing = agents.List().FirstOrDefault(a => a.ProjectId == projectId && a.Seat == role && a.Status != SavedAgentStatus.Archived);
    if (existing is not null) { log.Add($"  agent kept: {existing.Name} ({role})"); return existing.Id; }
    var id = agents.NewId(projectId + "-" + role);
    var name = row.Name.Trim(); if (name.Length > 60) name = name[..60].TrimEnd();
    var description = row.Description.Length > 4000 ? row.Description[..4000] : row.Description;
    var saved = agents.Save(new SavedAgent(id, name, row.Provider, description, row.Model, row.Effort, projectId, role, reportsTo, Icon: row.Icon), createOnly: true);
    if (!string.IsNullOrWhiteSpace(row.Instructions)) saved = agents.SaveInstructions(saved.Id, row.Instructions);
    log.Add($"  agent added: {saved.Name} ({role}{(reportsTo is null ? "" : ", reports to " + reportsTo)})");
    return saved.Id;
  }

  private static void Memory(IAgents agents, string seatKey, TeamImportAgent row, List<string> log)
  {
    if (row.Card.Length == 0 && row.Notes.Length == 0) return;
    var old = agents.Seats().FirstOrDefault(s => s.SeatKey == seatKey);
    if (old is not null && (old.Card.Length > 0 || old.Notes.Length > 0)) { log.Add($"  memory kept: {seatKey}"); return; }
    agents.SaveSeatMemory(seatKey, Clip(row.Card, 64_000), Clip(row.Notes, 128_000), old);
    log.Add($"  memory copied: {seatKey} (card {row.Card.Length}, notes {row.Notes.Length} chars)");
  }

  private static string Clip(string text, int limit)
  {
    const string cut = "\n\n[Shortened on import. The full text stays in the project folder.]";
    return text.Length <= limit ? text : text[..(limit - cut.Length)] + cut;
  }
}
