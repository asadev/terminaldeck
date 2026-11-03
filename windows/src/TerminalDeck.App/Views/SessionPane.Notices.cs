using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views.Notices;

namespace TerminalDeck.App.Views;

public sealed partial class SessionPane
{
  private readonly CompactNotice sessionNotice = new();
  private void InitializeSessionNotices(Grid area)
  {
    sessionNotice.Scope = area;
    // Added after WebView: status is scoped to the terminal content, below its header.
    area.Children.Add(sessionNotice);
  }
  private void ShowSessionNotice(string message)
  {
    sessionNotice.Message = message;
    sessionNotice.IsOpen = !string.IsNullOrWhiteSpace(message);
  }
  internal void TerminalActionFailed(Exception error)
  {
    UiRecovery.Log("Terminal action", error);
    // A clipboard, find, theme or late resize failure says nothing about the pipe.
    ShowSessionNotice("The terminal action could not finish. Try again.");
  }
}
