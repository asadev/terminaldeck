using System.Collections.Immutable;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Agents;

public enum AgentCategory { Orchestrator, Lead, Agent }
public enum SavedAgentStatus { Active, Paused, Archived }
public enum AgentRunState { Starting, Running, Uncertain, Ended }
public sealed record SavedAgent(string Id, string Name, string Provider, string Description = "", string Model = "", string Effort = "auto",
  string ProjectId = ProjectIdentity.IndependentId, string Seat = "", string? ReportsTo = null, string? InstructionsFile = null,
  string Icon = "person", SavedAgentStatus Status = SavedAgentStatus.Active, ImmutableArray<string> Skills = default, string? AccountId = null, int? MaxConcurrentTasks = null,
  AgentOptions? Options = null, string? PhotoPath = null)
{
  [System.Text.Json.Serialization.JsonIgnore] public AgentOptions Settings => Options ?? AgentOptions.Default;
}
// Mac Agent settings rows that this Windows build applies. Null means "App default".
// PermissionMode: ask | plan | auto (Before it changes files). WorkingFolder: used when a
// start names no folder. Tools to use/avoid are advice in the brief, exactly as on the Mac.
public sealed record AgentOptions(string? PermissionMode = null, string? WorkingFolder = null,
  ImmutableArray<string> ToolsPreferred = default, ImmutableArray<string> ToolsAvoided = default, bool SkillsOff = false)
{
  public static AgentOptions Default { get; } = new(ToolsPreferred: [], ToolsAvoided: []);
  public static readonly string[] PermissionModes = ["ask", "plan", "auto"];
  public static TerminalDeck.Core.Mcp.AiPermissionMode? ToMode(string? mode) => mode switch { "ask" => TerminalDeck.Core.Mcp.AiPermissionMode.Ask, "plan" => TerminalDeck.Core.Mcp.AiPermissionMode.Plan, "auto" => TerminalDeck.Core.Mcp.AiPermissionMode.Auto, _ => null };
  public static string PermissionLabel(string? mode) => mode switch { "ask" => "Ask before changes", "plan" => "Plan only", "auto" => "Change without asking", _ => "App default" };
}
public sealed record AgentTemplate(AgentCategory Category, string Instructions, int MaxHandsPerSeat = 0, int MaxHandsPerProject = 0,
  string Checklist = "", ImmutableArray<string> Parts = default, string HelperAI = "claude", string HelperModel = "sonnet", int CardLimit = 8000);
public sealed record AgentSeat(string Key, AgentCategory Category, string? ProjectId, string? Role, string MemoryFolder);
public sealed record AgentSeatMemory(string SeatKey, string Card = "", string Notes = "");
public sealed record AgentRun(string SessionId, string? AgentId, string AgentName, string Provider, string ProjectId, string? SeatKey,
  int HandNumber, string Job, string Mode, AgentRunState State, DateTimeOffset StartedAt, string? Problem = null, string? ParentSeatKey = null);
public sealed record AgentState(int Version, ImmutableArray<SavedAgent> Agents, ImmutableArray<AgentTemplate> Templates,
  ImmutableArray<AgentSeatMemory> Seats, ImmutableArray<AgentRun> Runs, ImmutableArray<string> RetiredIds = default);
public sealed record NewAgentSession(string? AgentId, string? ProjectId = null, string? Folder = null, string? Provider = null,
  string? AccountId = null, string Mode = "terminal", string Job = "", bool Helper = false, string? Title = null, string? Model = null, string? Effort = null,
  TerminalDeck.Core.Mcp.AiPermissionMode? Permission = null);
public sealed record AgentLaunchPlan(string SessionId, string? AgentId, string? SeatKey, string ProjectId, string Folder,
  string Provider, string AccountId, string AccountHome, string Model, string Effort, string Instructions,
  string? InstructionsFile, string Title, string Job, string Mode, TerminalDeck.Core.Mcp.AiPermissionMode? Permission = null);
public sealed record AgentSessionStarted(string SessionId, string Mode);
public sealed record AgentTreeNode(SavedAgent Agent, ImmutableArray<AgentTreeNode> Reports);
public sealed record AgentFace(string Id, string Name, string Icon, bool Hoot = false, string? PhotoPath = null);

// The integrate lane supplies the sessions/chat Core adapter. The full launch plan
// must reach the driver; dropping model or instructions is not a successful start.
public interface IAgentSessionGateway
{
  bool SupportsMode(string mode) => mode is "terminal" or "chat";
  void Validate(AgentLaunchPlan plan) { }
  ValueTask<AgentSessionStarted> StartAsync(AgentLaunchPlan plan, CancellationToken cancellationToken);
  bool CanStop => false;
  ValueTask StopAsync(string sessionId, CancellationToken cancellationToken) => throw new InvalidOperationException("Stopping sessions is not connected here. Close the session from its tab.");
}
public sealed class DelegateAgentSessionGateway(Func<AgentLaunchPlan, CancellationToken, ValueTask<AgentSessionStarted>> start) : IAgentSessionGateway
{
  public ValueTask<AgentSessionStarted> StartAsync(AgentLaunchPlan plan, CancellationToken cancellationToken) => start(plan, cancellationToken);
}
public interface IAgentInstructions
{
  string Save(string id, string text);
  string Read(string path);
}

public interface IAgents
{
  ValueTask<IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel>> ModelsAsync(string provider, string? accountId = null, CancellationToken cancellationToken = default) => ValueTask.FromResult<IReadOnlyList<TerminalDeck.Core.Accounts.ProviderModel>>([]);
  bool CanStartSessions { get; }
  bool CanStart(string mode);
  event Action? Changed;
  IReadOnlyList<SavedAgent> List();
  SavedAgent Get(string id);
  string NewId(string name);
  SavedAgent Save(SavedAgent agent, SavedAgent? expected = null, bool createOnly = false, AgentSeatMemory? initialMemory = null);
  SavedAgent Duplicate(string id, string? name = null);
  SavedAgent Hire(string name, string provider, string description, AgentCategory category, string projectId, string? role = null, string? reportsTo = null, string icon = "person");
  void Remove(string id);
  SavedAgent SaveInstructions(string id, string text, string? expectedText = null);
  string ReadInstructions(string id);
  IReadOnlyList<AgentTemplate> Templates();
  void SaveTemplate(AgentTemplate template, AgentTemplate? expected = null);
  AgentSeat SeatOf(string id);
  IReadOnlyList<AgentSeatMemory> Seats();
  AgentSeatMemory SaveSeatMemory(string key, string card, string notes, AgentSeatMemory? expected = null);
  void SetProjectLead(string projectId, string? agentId);
  IReadOnlyList<AgentRun> Runs();
  IReadOnlyList<AgentTreeNode> OrgChart();
  ValueTask<AgentRun> StartAsync(NewAgentSession request, CancellationToken cancellationToken = default, Func<AgentLaunchPlan, CancellationToken, ValueTask>? beforeStart = null);
  void EndHand(string sessionId);
  ValueTask<int> StopHandsAsync(string agentId, CancellationToken cancellationToken = default) => throw new InvalidOperationException("Stopping sessions is not connected here.");
  AgentSeatMemory? SeatMemory(string agentId) => Seats().FirstOrDefault(s => s.SeatKey == SeatOf(agentId).Key);
  void ReconcileSessions(IEnumerable<ProjectSession> sessions);
  string SessionLabel(string sessionId, string provider);
  AgentFace? SessionFace(string sessionId);
  IReadOnlyList<ProjectSetupAgent> SetupAgents();
}

public static class AgentSeats
{
  public const string HootId = "@hoot";
  public static bool ValidRole(string role) => role.Length is > 0 and <= 64 && char.IsAsciiLetterOrDigit(role[0]) && role.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-');
  public static AgentSeat Orchestrator { get; } = new("orchestrator", AgentCategory.Orchestrator, null, null, "hoot");
  public static AgentSeat Lead(string projectId)
  {
    if (!ProjectIdentity.ValidId(projectId) || projectId == ProjectIdentity.IndependentId) throw new ArgumentException("Choose a project for the lead seat.");
    return new("lead:" + projectId, AgentCategory.Lead, projectId, null, "projects/" + projectId + "/lead");
  }
  public static AgentSeat Role(string? projectId, string role)
  {
    if (!ValidRole(role) || projectId is not null && !ProjectIdentity.ValidId(projectId)) throw new ArgumentException("Use lowercase words and dashes for the role.");
    if (projectId == ProjectIdentity.IndependentId) projectId = null;
    return new("role:" + (projectId ?? "") + "/" + role, AgentCategory.Agent, projectId, role, (projectId is null ? "" : "projects/" + projectId + "/") + "roles/" + role);
  }
  public static AgentSeat Parse(string key)
  {
    if (key == "orchestrator") return Orchestrator;
    if (key.StartsWith("lead:", StringComparison.Ordinal)) return Lead(key[5..]);
    if (key.StartsWith("role:", StringComparison.Ordinal) && key.IndexOf('/') is var slash && slash >= 5)
      return Role(slash == 5 ? null : key[5..slash], key[(slash + 1)..]);
    throw new ArgumentException("Choose an Orchestrator, Lead or Agent seat.");
  }
  public static string ProviderName(string provider) => provider switch { "claude" => "Claude Code", "codex" => "Codex", "gemini" => "Gemini", "shell" => "PowerShell", _ => provider };
}
