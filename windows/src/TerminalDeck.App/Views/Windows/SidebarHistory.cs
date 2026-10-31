using TerminalDeck.App.ViewModels;
namespace TerminalDeck.App.Shell;

public static class SidebarHistory
{
  public static bool IsHistory(SessionDraft row, IReadOnlySet<string> completedJobs) => row.State is "ended" or "exited"
    || row.Presentation == SessionPresentation.Chat && row.State is "chat" or "ready" && completedJobs.Contains(row.Id);
}
