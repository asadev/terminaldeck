using TerminalDeck.App.ViewModels;
using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class SidebarHistoryTests
{
  [Fact] public void FinishedReadyChatJobsDoNotMasqueradeAsRunningButWorkAndUncertaintyStayVisible()
  {
    var chat = new SessionDraft("Completed job", "codex", "/scratch", SessionPresentation.Chat) { State = "chat" };
    var completed = new HashSet<string> { chat.Id };
    Assert.True(SidebarHistory.IsHistory(chat, completed));
    chat.State = "working"; Assert.False(SidebarHistory.IsHistory(chat, completed));
    chat.State = "held"; Assert.False(SidebarHistory.IsHistory(chat, completed));
    var terminal = new SessionDraft("Uncertain terminal", "shell", "/scratch", SessionPresentation.Terminal) { State = "running" };
    completed.Add(terminal.Id); Assert.False(SidebarHistory.IsHistory(terminal, completed));
    terminal.State = "exited"; Assert.True(SidebarHistory.IsHistory(terminal, completed));
  }
}
