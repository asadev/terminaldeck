using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Agents;

public enum AgentActivityState { Working, Idle, Open, Ready, Paused, Archived }
public sealed record AgentActivity(AgentActivityState State, int Live, int Busy)
{
  public string Label => State switch
  {
    AgentActivityState.Working => Busy > 1 ? $"Working · {Busy}" : "Working",
    AgentActivityState.Idle => Live > 1 ? $"Idle · {Live} open" : "Idle",
    AgentActivityState.Open => Live > 1 ? $"{Live} sessions open" : "Session open",
    AgentActivityState.Paused => "Paused",
    AgentActivityState.Archived => "Archived",
    _ => "Ready"
  };
  public string Wire => State.ToString().ToLowerInvariant();

  // A chat says whether it is answering ("working") or waiting ("waiting"/"idle"). A
  // terminal only says it is open, so it is never claimed as working or idle.
  public static AgentActivity For(SavedAgent agent, IEnumerable<AgentRun> runs, IEnumerable<ProjectSession> sessions)
  {
    if (agent.Status == SavedAgentStatus.Archived) return new(AgentActivityState.Archived, 0, 0);
    var rows = sessions.GroupBy(s => s.Id).ToDictionary(g => g.Key, g => g.First());
    var live = runs.Where(r => r.AgentId == agent.Id && r.State != AgentRunState.Ended)
      .Select(r => rows.GetValueOrDefault(r.SessionId)).Where(s => s is null || s.Status is not ("Exited" or "exited" or "ended")).ToArray();
    var busy = live.Count(s => s?.Status is "working" or "stopping");
    var waiting = live.Count(s => s?.Status is "waiting" or "idle");
    if (agent.Status == SavedAgentStatus.Paused) return new(AgentActivityState.Paused, live.Length, busy);
    if (busy > 0) return new(AgentActivityState.Working, live.Length, busy);
    if (live.Length == 0) return new(AgentActivityState.Ready, 0, 0);
    return waiting == live.Length ? new(AgentActivityState.Idle, live.Length, 0) : new(AgentActivityState.Open, live.Length, 0);
  }
}
