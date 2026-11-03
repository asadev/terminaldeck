using Microsoft.UI.Xaml;
using TerminalDeck.App.Views.Servers;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow : IServerSettingsWindowHost
{
  AppDataRoot IServerSettingsWindowHost.SettingsStateRoot => dataRoot;
  void IServerSettingsWindowHost.OwnServerSettingsWindow(Window window, FrameworkElement root)
  {
    SetSettingsOwner(WinRT.Interop.WindowNative.GetWindowHandle(window), -8, WinRT.Interop.WindowNative.GetWindowHandle(this));
    UpdateSettingsMinimum(window, 520, 440);
    window.AppWindow.Changed += (_, _) => UpdateSettingsMinimum(window, 520, 440);
    void OwnerClosed(object sender, WindowEventArgs args) => window.Close();
    Closed += OwnerClosed; window.Closed += (_, _) => Closed -= OwnerClosed;
  }
}
