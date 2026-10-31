using TerminalDeck.Core.Projects;

namespace TerminalDeck.Core.Mcp;

// Live facts a session caller's scope reads at call time. Paths may use either
// Windows spelling; the scope compares them with ProjectPaths.
public interface ISessionCallerFacts
{
  IReadOnlyList<string> ProjectFolders(string projectId);
  string? SessionFolder(string sessionId);
  string? SessionProject(string sessionId);
  string? TaskProject(string taskId);
  string? AgentProject(string agentId);
}

public static class McpCallerScopes
{
  public static bool Within(string root, string path)
  {
    try { return ProjectPaths.Contains(root, path); }
    catch (ArgumentException) { return false; }
  }
  // The same seat-defined allowance for every signed-in AI working in a project
  // (Mac BackendTAGTaskProjectScope): its project's folders, sessions, tasks and
  // agents, any web origin in the windows it opens, its own seat memory, and the
  // project's private MCP servers. App-wide settings, other projects, devices,
  // servers and Hoot's own desk stay outside; Hoot and the owner keep those.
  public static IMcpCallerScope Session(ISessionCallerFacts facts, string sessionId, string projectId, string folder, string? seatKey)
    => new SessionScope(facts, sessionId, projectId, folder, seatKey);
  // Hoot has every app capability. HootPolicy still fences his own settings.
  public static IMcpCallerScope Everything { get; } = new AllScope();

  private sealed class AllScope : IMcpCallerScope
  {
    public bool Has(string kind, string id) => true;
  }
  private sealed class SessionScope(ISessionCallerFacts facts, string sessionId, string projectId, string folder, string? seatKey) : IMcpCallerScope
  {
    private IEnumerable<string> Roots() => projectId == ProjectIdentity.IndependentId ? [folder] : facts.ProjectFolders(projectId).Append(folder);
    private bool InProject(string? path) => path is { Length: > 0 } && Roots().Any(root => Within(root, path));
    public bool Has(string kind, string id) => kind switch
    {
      "origins" or "profiles" => true,
      "accounts" => true,
      "projects" => id == projectId,
      "folders" => InProject(id),
      "sessions" or "chats" => id == sessionId || (facts.SessionProject(id) is { } bound ? bound == projectId : InProject(facts.SessionFolder(id))),
      "tasks" => id == "*" || facts.TaskProject(id) == projectId,
      "agents" => id != "*" && (id == "lead:" + projectId || facts.AgentProject(id) is { } owner && (owner == projectId || owner == ProjectIdentity.IndependentId)),
      "memory" => seatKey is not null && id == seatKey,
      "mcp" => McpServerFolder(id) is { } serverFolder && InProject(serverFolder),
      _ => false
    };
    // "local:<folder>:<name>" and "project:<folder>:<name>"; app-wide "user:" servers stay with the owner and Hoot.
    private static string? McpServerFolder(string id)
    {
      foreach (var scope in new[] { "local:", "project:" })
        if (id.StartsWith(scope, StringComparison.Ordinal) && id.LastIndexOf(':') is var last && last > scope.Length)
          return id[scope.Length..last];
      return null;
    }
  }
}
