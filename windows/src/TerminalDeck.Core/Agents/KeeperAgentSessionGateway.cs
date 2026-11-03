using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Agents;

// This uses the existing session owner; it neither starts a second keeper nor
// invents a shadow session list. Chat is supplied by the chat lane's interface.
public sealed class KeeperAgentSessionGateway(
  Func<SessionDefinition, CancellationToken, ValueTask<SessionRecord>> terminal,
  Func<AgentLaunchPlan, CancellationToken, ValueTask<AgentSessionStarted>>? chat = null,
  Func<string, CancellationToken, ValueTask>? stop = null) : IAgentSessionGateway
{
  public bool CanStop => stop is not null;
  public ValueTask StopAsync(string sessionId, CancellationToken cancellationToken) =>
    stop is null ? throw new InvalidOperationException("Stopping sessions is not connected here. Close the session from its tab.") : stop(sessionId, cancellationToken);
  public bool SupportsMode(string mode) => mode == "terminal" || mode == "chat" && chat is not null;
  public static KeeperAgentSessionGateway FromClient(Func<KeeperClient> client,
    Func<AgentLaunchPlan, CancellationToken, ValueTask<AgentSessionStarted>>? chat = null) => new(async (definition, ct) =>
  {
    var response = await client().CreateAsync(definition, ct);
    return response.Session ?? throw new InvalidOperationException("The session service did not confirm this start.");
  }, chat);
  public static KeeperAgentSessionGateway FromKeeper(SessionKeeper keeper,
    Func<AgentLaunchPlan, CancellationToken, ValueTask<AgentSessionStarted>>? chat = null) => new(keeper.CreateAsync, chat);
  public void Validate(AgentLaunchPlan plan)
  {
    if (plan.Mode == "terminal") _ = Definition(plan);
    else if (plan.Mode != "chat" || chat is null) throw new InvalidOperationException("Chat is unavailable. Choose a terminal session for now.");
  }
  public async ValueTask<AgentSessionStarted> StartAsync(AgentLaunchPlan plan, CancellationToken ct)
  {
    Validate(plan);
    if (plan.Mode == "chat") return await chat!(plan, ct);
    var definition = Definition(plan); var row = await terminal(definition, ct);
    if (row.Definition != definition) throw new InvalidOperationException("The session service returned a different launch. Check the session list before trying again.");
    return new(row.Definition.Id, "terminal");
  }
  public static SessionDefinition Definition(AgentLaunchPlan plan)
  {
    var prompt = string.Join("\n\n", new[] { plan.Instructions, plan.Job }.Where(s => s.Length > 0));
    if (prompt.Length > 8000) throw new ArgumentException("A terminal start accepts up to 8,000 characters of instructions and job text. Shorten them or choose chat.");
    if (plan.Model.Length > 128) throw new ArgumentException("Use a model name no longer than 128 characters for a terminal session.");
    if (plan.Provider == "gemini" && plan.Effort is not ("auto" or "")) throw new ArgumentException("This effort choice is unavailable in the terminal driver. Choose Automatic or start a chat.");
    var definition = new SessionDefinition(plan.SessionId, plan.Provider, plan.Folder, plan.Title, plan.AccountId, plan.AccountHome,
      InitialPrompt: prompt.Length == 0 ? null : prompt, Model: plan.Model.Length == 0 ? null : plan.Model, Effort: plan.Effort is "auto" or "" ? null : plan.Effort,
      Permission: plan.Permission switch { null => null, TerminalDeck.Core.Mcp.AiPermissionMode.AcceptEdits => "acceptEdits", { } mode => mode.ToString().ToLowerInvariant() });
    definition.Validate(); return definition;
  }
}
