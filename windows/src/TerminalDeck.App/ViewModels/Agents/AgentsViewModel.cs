using TerminalDeck.App.ViewModels.Projects;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using System.Runtime.CompilerServices;

namespace TerminalDeck.App.ViewModels.Agents;

public sealed class AgentsViewModel : ProjectAgentViewModel, IDisposable
{
  private sealed class DragOwner { public string Id { get; } = Guid.NewGuid().ToString("N"); }
  private static readonly ConditionalWeakTable<IAgents, DragOwner> dragOwners = new();
  public string DragScope => dragOwners.GetValue(Agents, _ => new()).Id;
  public IAgents Agents { get; }
  public IProjects Projects { get; }
  public AccountService? Accounts { get; }
  private string? selectedId;
  public string? SelectedId { get => selectedId; set { selectedId = value; Refresh(); } }
  public SavedAgent? Selected => selectedId is not null && selectedId != AgentSeats.HootId ? Agents.List().FirstOrDefault(a => a.Id == selectedId) : null;
  public AgentsViewModel(IAgents agents, IProjects projects, AccountService? accounts = null)
  {
    Agents = agents; Projects = projects; Accounts = accounts;
    agents.Changed += Refresh; projects.Changed += Refresh;
  }
  // Role filter: "" all, "lead" project leads, "role:<name>" one role. State filter: "" any, else an AgentActivityState name.
  public IReadOnlyList<SavedAgent> Filter(string query = "", string? projectId = null, bool archived = false, string role = "", string state = "") => Agents.List().Where(a => (a.Status == SavedAgentStatus.Archived) == archived &&
    (projectId is null || a.ProjectId == projectId) && (a.Name.Contains(query, StringComparison.OrdinalIgnoreCase) || a.Description.Contains(query, StringComparison.OrdinalIgnoreCase) || a.Seat.Contains(query, StringComparison.OrdinalIgnoreCase) || a.Model.Contains(query, StringComparison.OrdinalIgnoreCase)) &&
    (role.Length == 0 || (role == "lead" ? IsLead(a) : role.StartsWith("role:", StringComparison.Ordinal) && a.Seat == role[5..] && !IsLead(a))) &&
    (state.Length == 0 || Activity(a).State.ToString() == state)).ToArray();
  public Func<IReadOnlyList<ProjectSession>>? Sessions { get; set; }
  public AgentActivity Activity(SavedAgent agent) => AgentActivity.For(agent, Agents.Runs(), Sessions?.Invoke() ?? []);
  public bool IsLead(SavedAgent agent) => Projects.List().Any(p => p.Lead == "agent:" + agent.Id);
  public IReadOnlyList<string> Roles(string? projectId = null) => Agents.List().Where(a => a.Status != SavedAgentStatus.Archived && (projectId is null || a.ProjectId == projectId) && !IsLead(a))
    .Select(a => a.Seat).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
  // Seats that keep memory but have no active agent: a lead or a role waiting for its next hire.
  public IReadOnlyList<AgentSeat> VacantSeats(string? projectId = null)
  {
    var filled = Agents.List().Where(a => a.Status != SavedAgentStatus.Archived).Select(a => AgentSeats.Role(a.ProjectId, a.Seat).Key).ToHashSet(StringComparer.Ordinal);
    return Agents.Seats().Select(s => { try { return AgentSeats.Parse(s.SeatKey); } catch (ArgumentException) { return null; } }).OfType<AgentSeat>()
      .Where(s => s.Category == AgentCategory.Agent && !filled.Contains(s.Key) && !s.Key.Contains("--helper-", StringComparison.Ordinal) &&
        (projectId is null || (s.ProjectId ?? ProjectIdentity.IndependentId) == projectId) && Projects.List().Any(p => p.Id == (s.ProjectId ?? ProjectIdentity.IndependentId))).ToArray();
  }
  public string AccountLine(SavedAgent agent)
  {
    if (Accounts is null) return "Accounts are not connected";
    if (agent.AccountId is { } id) return (Accounts.List().FirstOrDefault(a => a.Id == id)?.Name ?? "Unavailable saved account") + " · chosen for this agent";
    var project = Projects.List().FirstOrDefault(p => p.Id == agent.ProjectId);
    var choice = project?.Preferences.WhoUsesWhat.FirstOrDefault(c => c.Provider == agent.Provider && c.AccountId is not null);
    if (choice?.AccountId is { } projectAccount) return (Accounts.List().FirstOrDefault(a => a.Id == projectAccount)?.Name ?? "Unavailable account") + " · from " + project!.Name;
    var preferred = Accounts.Preferred(agent.Provider, agent.Settings.WorkingFolder ?? project?.HomeFolder ?? "");
    return preferred is null ? "No signed-in " + AgentSeats.ProviderName(agent.Provider) + " account · add one in Coding AIs" : preferred.Name + " · the app's default for " + AgentSeats.ProviderName(agent.Provider);
  }
  public string RoleName(SavedAgent agent) => Agents.SeatOf(agent.Id).Category == AgentCategory.Lead ? "Lead" : RoleWords(agent.Seat);
  // A role id ("ai-link", "shell-design") shown as words ("AI link", "Shell design"), never the raw id.
  public static string RoleWords(string seat)
  {
    var words = seat.Split('-', '_', ' ').Where(w => w.Length > 0).Select(w => w.ToLowerInvariant() switch
    { "ai" => "AI", "ios" => "iOS", "mcp" => "MCP", "ui" => "UI", "qa" => "QA", "api" => "API", var other => other }).ToArray();
    if (words.Length == 0) return seat;
    if (words[0] == words[0].ToLowerInvariant()) words[0] = char.ToUpperInvariant(words[0][0]) + words[0][1..];
    return string.Join(' ', words);
  }
  public string ProjectName(string id) => Projects.List().FirstOrDefault(p => p.Id == id)?.Name ?? id;
  public string ManagerName(SavedAgent a) => a.ReportsTo == AgentSeats.HootId ? "Hoot" : Agents.List().FirstOrDefault(m => m.Id == a.ReportsTo)?.Name ?? "No one · independent";
  public IReadOnlyList<AgentRun> Hands(string id) => Agents.Runs().Where(r => r.AgentId == id && r.State != AgentRunState.Ended).ToArray();
  public void Dispose() { Agents.Changed -= Refresh; Projects.Changed -= Refresh; }
}
