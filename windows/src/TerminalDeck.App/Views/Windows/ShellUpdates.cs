using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views;

// Opening the app is the one step that applies an update. When a newer version
// is on this package's App Installer source, the keeper hands its sessions over
// and Windows reopens Terminal Deck on the new version. While a coding AI is in
// the middle of an answer, the update waits for one click instead.
public sealed partial class ShellWindow
{
  private int updateCheckRunning;
  private Button? updateAction;
  internal async Task CheckForUpdateOnOpenAsync()
  {
    if (Interlocked.Exchange(ref updateCheckRunning, 1) == 1) return;
    try
    {
      if (!Services.WindowsUpdateStatus.HasUpdateSource() || !await Services.WindowsUpdateStatus.IsUpdateAvailableAsync()) return;
      if (Runtime.AnswerInProgress) { ShowUpdateNotice(Services.WindowsUpdateStatus.UpdateAvailableText); return; }
      await RestartToUpdateAsync();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { UiRecovery.Log("Update check on open", ex); }
    finally { Interlocked.Exchange(ref updateCheckRunning, 0); }
  }
  private async Task RestartToUpdateAsync()
  {
    ShowUpdateNotice("Updating Terminal Deck. Your sessions are saved and reopen after the update.", action: false);
    try { Model.Notice = await Runtime.RestartToUpdateAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      UiRecovery.Log("Restart to update", ex);
      ShowUpdateNotice("The update could not be applied. Your sessions were kept. " + ex.Message);
    }
  }
  private void ShowUpdateNotice(string message, bool action = true)
  {
    if (updateAction is null)
    {
      updateAction = new Button { Content = Services.WindowsUpdateStatus.RestartLabel, Style = Application.Current.Resources["AccentButtonStyle"] as Style };
      updateAction.Click += async (_, _) => { updateAction.IsEnabled = false; try { await RestartToUpdateAsync(); } finally { updateAction.IsEnabled = true; } };
    }
    lastShellNotice = message;
    Status.Scope = ContentCard;
    Status.Message = message;
    Status.ActionButton = action && Services.WindowsUpdateStatus.Available ? updateAction : null;
    Status.AutoDismiss = false;
    Status.Severity = InfoBarSeverity.Informational;
    Status.IsOpen = true;
  }
}
