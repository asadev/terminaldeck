using Microsoft.UI.Xaml;
namespace TerminalDeck.App.Views;
public sealed partial class SettingsPane
{
  public Action? ResetWindowAppearance { get; set; }
  // Advanced keeps "Paired with a code" (pairing and phone access), which left the Devices page (Mac, 15 Nov).
  private FrameworkElement AdvancedSettings() => new Advanced.AdvancedPreferencesPage(runtime, SettingsBrowser, ResetWindowAppearance, SaveCloseConfirmation, OpenPairedDevices);
}
