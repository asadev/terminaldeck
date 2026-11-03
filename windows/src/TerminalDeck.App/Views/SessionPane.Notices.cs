using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.ViewModels;
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
    sessionNotice.AutoDismiss = true;
    sessionNotice.Message = message;
    sessionNotice.IsOpen = !string.IsNullOrWhiteSpace(message);
  }
  // A terminal whose process has ended keeps showing its last screen, so it
  // looks alive while typing does nothing. Say so until the user dismisses
  // it, and again when they type into it.
  private const string EndedMessage = "This session has ended, so typing here does nothing. Open a new tab to keep working.";
  private bool ended;
  private void ShowEnded(bool value)
  {
    ended = value;
    if (!value) { if (sessionNotice.Message == EndedMessage) ShowSessionNotice(""); return; }
    sessionNotice.AutoDismiss = false; sessionNotice.Message = EndedMessage; sessionNotice.IsOpen = true;
  }
  // Sync raises State on every refresh, so act only when it crosses "exited".
  private void DraftStateChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
  {
    if (args.PropertyName != nameof(SessionDraft.State)) return;
    DispatcherQueue.TryEnqueue(() => { if (!disposed && (draft.State == "exited") != ended) ShowEnded(!ended); });
  }
  internal void TerminalActionFailed(Exception error)
  {
    UiRecovery.Log("Terminal action", error);
    // A clipboard, find, theme or late resize failure says nothing about the pipe.
    ShowSessionNotice("The terminal action could not finish. Try again.");
  }
}
