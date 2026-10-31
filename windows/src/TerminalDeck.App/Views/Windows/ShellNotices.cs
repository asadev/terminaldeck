using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private string lastShellNotice = "";
  private Button? shellRecoveryAction;
  private void UpdateShellNotice(string message, bool recovery = false)
  {
    if (!recovery && message == lastShellNotice) return;
    lastShellNotice = message;
    Status.Scope = ContentCard;
    Status.Message = message;
    // Ordinary outcomes clear themselves. Recovery is offered for an app/service
    // failure only, never for a transient resize or successful operation.
    var needsRecovery = recovery || shellRecoveryRequired && !string.IsNullOrWhiteSpace(message) || message.Contains("session service", StringComparison.OrdinalIgnoreCase) &&
      (message.Contains("unavailable", StringComparison.OrdinalIgnoreCase) || message.Contains("could not connect", StringComparison.OrdinalIgnoreCase));
    Status.ActionButton = needsRecovery ? shellRecoveryAction : null;
    Status.AutoDismiss = !needsRecovery;
    Status.Severity = needsRecovery ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
    Status.IsOpen = !string.IsNullOrWhiteSpace(message);
  }
}
