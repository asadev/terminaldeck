using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private FrameworkElement? taskPopupOverlay;
  private void PresentTaskPopup(FrameworkElement? popup)
  {
    if (taskPopupOverlay is not null) Root.Children.Remove(taskPopupOverlay);
    taskPopupOverlay = popup;
    if (popup is null) return;
    Grid.SetRowSpan(popup, 2); Grid.SetColumnSpan(popup, 2); Canvas.SetZIndex(popup, 30);
    Root.Children.Add(popup);
  }
}
