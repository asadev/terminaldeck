using TerminalDeck.App.Views.Agents;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.App.Views;

// The Agents page reads live session states (working / waiting / open) to show
// each agent's status, from the same session list the sidebar uses.
public sealed partial class ShellWindow : IAgentSessionsSource, IAgentLibraryNavigation
{
  public void OpenSkillsStore() => Model.Page = TerminalDeck.App.ViewModels.ShellPage.Store;
  public IReadOnlyList<ProjectSession> AgentSessions() => Runtime.ProjectSessions();
}
