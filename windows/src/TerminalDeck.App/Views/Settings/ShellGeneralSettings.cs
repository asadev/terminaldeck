using TerminalDeck.Core.Settings;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private readonly WindowsKeepAwake keepAwake = new();
  private void InitializeGeneralSettings()
  {
    Runtime.General.Changed += ApplyGeneralSettings;
    ApplyGeneralSettings();
  }
  private void ApplyGeneralSettings() => keepAwake.Set(Runtime.General.Read().KeepAwake);
  private void RegisterGeneralSettingsTools() => GeneralSettingsTools.Register(Runtime.General, Runtime.Door,
    () => sidebar.Read.ConfirmDelete, value => sidebar.AskBeforeDelete(value), Services.WindowsUpdateStatus.Version, Services.WindowsUpdateStatus.CheckAsync);
}
