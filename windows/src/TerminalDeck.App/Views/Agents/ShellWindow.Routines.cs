using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Hoot;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow : IAgentRoutinesNavigation
{
  HootRoutines IAgentRoutinesNavigation.AgentRoutines => Runtime.Routines;
}
