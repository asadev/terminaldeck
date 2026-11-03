using TerminalDeck.Core.Settings;

namespace TerminalDeck.App.Views;

public sealed partial class SettingsPane
{
  internal TerminalAppearanceService TerminalAppearance => runtime.TerminalAppearance;
}
