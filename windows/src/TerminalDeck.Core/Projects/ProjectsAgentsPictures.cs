using TerminalDeck.Core.Agents;

namespace TerminalDeck.Core.Projects;

public sealed record ProjectPicture(string Id, string Name, string Icon, string Colour, string Logo);
public sealed record ProjectsAgentsPictureSnapshot(IReadOnlyList<ProjectPicture> Projects, IReadOnlyList<AgentFace> Agents, IReadOnlyDictionary<string, AgentFace> Sessions);

// The desktop and phone composition can read one picture source. A live session
// without a saved agent is not an extra agent, and never borrows a project lead.
public sealed class ProjectsAgentsPictures(IProjects projects, IAgents agents)
{
  public ProjectsAgentsPictureSnapshot Read(Func<string, bool> projectVisible, Func<string, bool> agentVisible, IEnumerable<string> sessionIds)
  {
    var faces = agents.List().Where(a => agentVisible(a.Id) && projectVisible(a.ProjectId)).Select(a => new AgentFace(a.Id, a.Name, a.Icon)).ToList();
    if (agentVisible(AgentSeats.HootId)) faces.Insert(0, new(AgentSeats.HootId, "Hoot", "hoot", true));
    var sessions = new Dictionary<string, AgentFace>(StringComparer.Ordinal);
    foreach (var id in sessionIds.Distinct())
    {
      var run = agents.Runs().FirstOrDefault(r => r.SessionId == id);
      if (run?.AgentId is { } owner && agentVisible(owner) && projectVisible(run.ProjectId) && agents.SessionFace(id) is { } face) sessions.Add(id, face);
    }
    return new(projects.List().Where(p => projectVisible(p.Id)).Select(p => new ProjectPicture(p.Id, p.Name, p.Icon, p.Colour, p.Logo)).ToArray(), faces, sessions);
  }
}
