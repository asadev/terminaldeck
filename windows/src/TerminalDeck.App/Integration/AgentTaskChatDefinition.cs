using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private ChatDefinition AgentTaskChatDefinition(AgentLaunchPlan plan) => new(plan.SessionId, plan.Provider, plan.Folder, plan.Title,
    plan.AccountId, plan.AccountHome, new(plan.Model, plan.Effort), plan.Instructions,
    plan.Permission is { } mode && ChatPermissionModes.Supported(plan.Provider).Contains(mode) ? mode : General.NewChatPermission(plan.Provider))
  { AddonsOff = plan.Efficiency?.AddonsOff == true, RequiresDeckTools = plan.Efficiency?.AddonsOff == true || plan.Efficiency?.SerializeHeavyJobs == true };
}
