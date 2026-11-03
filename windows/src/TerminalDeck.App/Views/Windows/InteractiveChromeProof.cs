using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task VerifyInteractiveChromeAsync(string output, int width, ElementTheme theme, Action<string, bool> check)
  {
    foreach (var control in new[] { SettingsRoute, DevicesButton, SidebarToggle })
    {
      control.ApplyTemplate();
      foreach (var state in new[] { "PointerOver", "Pressed" })
      {
        var entered = VisualStateManager.GoToState(control, state, false); Root.UpdateLayout();
        var fill = ProofTree(control).OfType<Border>().FirstOrDefault(b => b.Name == "ControlSurface");
        var expected = ShellTheme.Resource(control, state == "PointerOver" ? "DeckHoverBrush" : "DeckPressedBrush");
        check(width + " " + theme + " " + AutomationProperties.GetName(control) + " " + state + " uses shared round fill",
          entered && fill is not null && fill.CornerRadius == new CornerRadius(8) && ReferenceEquals(fill.Background, expected));
      }
      VisualStateManager.GoToState(control, "Normal", false);
    }
    foreach (var button in new[] { SettingsRoute, DevicesButton, SidebarToggle }) VisualStateManager.GoToState(button, "PointerOver", false);
    await Verification.W10Proof.CaptureAsync(Root, output, "hover-" + width, theme.ToString().ToLowerInvariant(), "Native VisualStateManager pointer-over on real shared buttons; no input injected into user window", _ => { });
    foreach (var button in new[] { SettingsRoute, DevicesButton, SidebarToggle }) VisualStateManager.GoToState(button, "Normal", false);
    check(width + " " + theme + " no in-app bell", !ProofTree(Root).OfType<Button>().Any(b => AutomationProperties.GetName(b) == "Alerts"));
    var prior = Model.Page;
    ShowDevicesPopup(); await Task.Delay(200);
    check(width + " " + theme + " Devices opens a popup without navigation", devicesPopupOpen && Model.Page == prior && devicesPopupPane?.PopupPresentation == true);
    check(width + " " + theme + " Devices includes pairing and preserves its content", devicesPopupPane is not null && ProofTree(devicesPopupPane).OfType<Button>().Any(b => b.Content as string == "Show code"));
    if (devicesPopupPane is not null)
      await Verification.W10Proof.CaptureAsync(devicesPopupPane, output, "devices-" + width, theme.ToString().ToLowerInvariant(), "Real Devices popup with fresh synthetic empty trust; no code or network pairing requested", _ => { });
    devicesWindow?.Close();
  }
}
