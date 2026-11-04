using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.App.Views.Settings;

internal static class TerminalShellChoice
{
  internal static ComboBox Create(GeneralSettings settings, Func<Func<Task>, Task> run)
  {
    var available = TerminalDeck.Platform.Windows.WindowsProviderLaunchPlanner.FindPowerShell7(TerminalDeck.Platform.Windows.Accounts.WindowsAiEnvironment.Read()) is not null;
    var selected = settings.Read().TerminalShell ?? TerminalShells.WindowsPowerShell;
    var picker = new ComboBox { MinWidth = 220 };
    foreach (var shell in TerminalShells.All)
    {
      var missing = shell == TerminalShells.PowerShell7 && !available;
      picker.Items.Add(new ComboBoxItem { Content = TerminalShells.Name(shell) + (missing ? " · not installed" : ""), IsEnabled = !missing || shell == selected });
    }
    picker.SelectedIndex = Math.Max(0, Array.IndexOf(TerminalShells.All, selected));
    picker.SelectionChanged += async (_, _) =>
    {
      if (picker.SelectedIndex < 0) return;
      var chosen = TerminalShells.All[picker.SelectedIndex];
      await run(() => { settings.Save(settings.Read() with { TerminalShell = chosen }); return Task.CompletedTask; });
    };
    AutomationProperties.SetName(picker, "Shell for new terminal tabs");
    return picker;
  }
}
