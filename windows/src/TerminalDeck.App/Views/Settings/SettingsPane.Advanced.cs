using Microsoft.UI.Xaml;
namespace TerminalDeck.App.Views;
public sealed partial class SettingsPane
{
  public Action? ResetWindowAppearance { get; set; }
  private FrameworkElement AdvancedSettings() => new Advanced.AdvancedPreferencesPage(runtime, SettingsBrowser, ResetWindowAppearance, SaveCloseConfirmation);
}
