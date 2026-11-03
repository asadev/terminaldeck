using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.ViewModels;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Coming back to a window (Alt+Tab, the taskbar, a click on its title bar)
  // should let the user type straight away, as in a terminal app. WinUI does
  // not give keyboard focus back to a WebView2 when its window activates, so
  // put it on the active tab's input: the terminal, a chat composer or the
  // browser. Focus stays where it is when it already sits in a text field, a
  // dialog or menu is open, or the window shows a page rather than tabs.
  private void FocusInputOnActivation(Window window, FrameworkElement root, string host) =>
    window.Activated += (_, args) =>
    {
      if (args.WindowActivationState == WindowActivationState.Deactivated) return;
      // Low priority: a click that activated the window moves focus first.
      window.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
      {
        if (root.XamlRoot is not { } xamlRoot || IsShellModalOpen(xamlRoot)) return;
        if (VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot).Any(popup => popup.Child is not ToolTip)) return;
        if (FocusManager.GetFocusedElement(xamlRoot) is TextBox or PasswordBox or RichEditBox or AutoSuggestBox) return;
        if (host == "main" && Model.Page is not (ShellPage.Sessions or ShellPage.Browser)) return;
        var surface = host == "main" ? mainSurface : detached.TryGetValue(host, out var child) ? child.Surface : null;
        if (surface is null || FocusedTab(host) is not { Kind: not "page" } tab) return;
        surface.FocusInput(tab.Id);
      });
    };
}
