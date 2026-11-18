using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public AgentBudgetLedger AgentUsage { get; private set; } = null!;
  public AgentBudgetRuntime AgentBudgets { get; private set; } = null!;
  // Called after Agents/Accounts are constructed. No data is read or written until a budget is read or applied.
  private void InitializeAgentBudgets()
  {
    AgentUsage = new(new JsonStateStore<AgentUsageLedgerState>(Root, "agent-usage"));
    var reader = new AgentUsageReader(() => Agents.Runs(),
      () => new JsonStateStore<SessionLedger>(Root, "sessions").Load()?.Sessions ?? [],
      id => new ChatHistory(Root).Load(id), new TerminalDeck.Core.Accounts.ConversationFiles(Root),
      id => Accounts.List().FirstOrDefault(a => a.Id == id));
    AgentBudgets = new(AgentUsage, reader.ReadAsync);
    Agents.Budgets = AgentBudgets;
    Agents.LaunchPreflight = plan =>
    {
      if (plan.Efficiency?.AddonsOff != true && plan.Efficiency?.SerializeHeavyJobs != true && plan.Efficiency?.Completion is not ("park" or "stop")) return;
      if (!File.Exists(Path.Combine(AppContext.BaseDirectory, "tools-bridge", "TerminalDeck.ToolBridge.exe"))) throw new IOException("The app's own tools are unavailable in this installation.");
      if (plan.Efficiency?.AddonsOff == true)
      {
        var home = TerminalDeck.Core.Accounts.AccountHomes.Resolve(Root, plan.Provider, plan.AccountHome, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StableChannel.IsStable(AppContext.BaseDirectory));
        _ = TerminalDeck.Platform.Windows.AgentAddonLaunch.Restrict(plan.Provider, home);
      }
    };
    Agents.ParkedConversation = plan => Tasks is null ? null : AgentContextPolicy.Parked(plan,
      TerminalDeck.Core.Tasks.TaskStore.At(Root).Read(), new JsonStateStore<SessionLedger>(Root, "sessions").Load()?.Sessions ?? [], new ChatHistory(Root).List());
    var work = new AgentHeavyWork(new JsonStateStore<AgentWorkState>(Root, "agent-heavy-work"), id =>
    {
      var terminal = Sessions.FirstOrDefault(s => s.Definition.Id == id);
      if (terminal is not null) return terminal.State != SessionState.Exited;
      var chat = Chats?.List().FirstOrDefault(c => c.Definition.Id == id); return chat is null ? null : !chat.Ended;
    });
    AgentHeavyWorkMcp.Register(work, Door);
    Changed += () => { if (work.HasTickets) _ = ReconcileHeavyWorkAsync(work); };
    AgentEfficiencyMcp.Register(Agents, AgentBudgets, () => Tasks, Door);
  }
  private static async Task ReconcileHeavyWorkAsync(AgentHeavyWork work)
  {
    try { await work.ReconcileAsync(); }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { System.Diagnostics.Trace.WriteLine("The shared work queue could not be refreshed; its saved state was kept."); }
  }

}
