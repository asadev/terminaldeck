using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Platform.Windows.Integration;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly Dictionary<string, McpRegistration> terminalToolConnections = new(StringComparer.Ordinal);
  private void ConnectAgentTerminalTools(string id)
  {
    if (LocalToolAddress is null) throw new IOException("The app tools are still connecting.");
    var session = Sessions.FirstOrDefault(s => s.Definition.Id == id && s.State != SessionState.Exited && s.Definition.RequiresDeckTools)
      ?? throw new McpRefusal("This agent terminal is no longer running.");
    var run = Agents.Runs().LastOrDefault(r => r.SessionId == id && r.AgentId is not null) ?? throw new McpRefusal("This terminal has no current agent owner.");
    var account = session.Definition.AccountId ?? throw new McpRefusal("This terminal has no account.");
    var mode = session.Definition.Permission switch { "plan" => AiPermissionMode.Plan, "auto" => AiPermissionMode.Auto, "acceptEdits" => AiPermissionMode.AcceptEdits, "bypass" => AiPermissionMode.Bypass, _ => AiPermissionMode.Ask };
    var callerId = "terminal:" + id;
    lock (terminalToolConnections)
    {
      if (terminalToolConnections.TryGetValue(id, out var kept) && CallerAuthority.Current(callerId) == kept && Live(kept))
      { HootToolConnection.Save(Root, id, new(LocalToolAddress.AbsoluteUri, kept.Token)); return; }
      CallerAuthority.Revoke(Door, callerId);
      var resources = new HashSet<string> { "sessions:" + id, "accounts:" + account, "folders:" + session.Definition.Cwd, "projects:" + run.ProjectId, "agents:" + run.AgentId, "profiles:default" };
      if (Tasks is not null) foreach (var task in Tasks.Runs().Where(r => r.SessionId == id)) resources.Add("tasks:" + task.TaskId);
      var policy = new McpCallerPolicy(callerId, id, run.SeatKey, mode, McpCatalogue.Load().Select(s => s.Id).ToArray(), Enum.GetValues<McpTier>(), resources.ToArray(),
        Scope: McpCallerScopes.Session(new CallerFacts(this), id, run.ProjectId, session.Definition.Cwd, run.SeatKey));
      var registration = CallerAuthority.Provision(Door, policy, _ => Sessions.Any(s => s.Definition.Id == id && s.State != SessionState.Exited
        && s.Definition.AccountId == account && s.Definition.Cwd == session.Definition.Cwd && s.Definition.Permission == session.Definition.Permission)
        && Agents.Runs().LastOrDefault(r => r.SessionId == id)?.SeatKey == run.SeatKey);
      HootToolConnection.Save(Root, id, new(LocalToolAddress.AbsoluteUri, registration.Token));
      terminalToolConnections[id] = registration;
    }
  }
}
