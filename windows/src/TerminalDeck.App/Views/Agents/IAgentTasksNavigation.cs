namespace TerminalDeck.App.Views.Agents;

// The shell owns page activation; the task page owns the creation draft.
public interface IAgentTasksNavigation
{
  Task AssignTaskAsync(string projectId, string agentId);
}

// The shell's live session rows, for agent status on the Agents page.
public interface IAgentSessionsSource
{
  IReadOnlyList<TerminalDeck.Core.Projects.ProjectSession> AgentSessions();
}
