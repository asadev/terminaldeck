using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task VerifyW12PairingAsync(string output, Action<string, bool> check)
  {
    await settingsPanel!.SelectAsync("devices");
    using var phone = NoiseIdentity.Generate();
    InvokeW12(settingsPanel, "Show code"); await Task.Delay(250);
    var dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(settingsPanel.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<ContentDialog>().Single();
    await WaitPairingCodeAsync();
    var receipt = Runtime.Remote.Trust.Redeem(settings.ActiveCode!, "Pending audit phone", "android", phone.PublicKey);
    await Task.Delay(150);
    check("Pairing request appears in the same sheet with Full control selected", SettingsTree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("Pending audit phone wants to connect", StringComparison.Ordinal)) && SettingsTree(dialog).OfType<ComboBox>().Single().SelectedIndex == 0);
    await CaptureSettingsAsync(dialog, Path.Combine(output, "pairing-request-dark.png"));
    InvokeW12(dialog, "Let it in"); await Task.Delay(200);
    check("Let it in approves exactly the reviewed pending device", Runtime.Remote.Trust.List().Any(d => d.Id == receipt.DeviceId && d.Access == PhoneAccess.Full));
    check("Approval closes the one-use offer", !Runtime.Remote.Trust.Pairing.IsOpen);
    using var denied = NoiseIdentity.Generate();
    InvokeW12(settingsPanel, "Show code"); await Task.Delay(250); await WaitPairingCodeAsync();
    dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(settingsPanel.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<ContentDialog>().Single();
    var refusal = Runtime.Remote.Trust.Redeem(settings.ActiveCode!, "Denied audit phone", "android", denied.PublicKey);
    await Task.Delay(150); InvokeW12(dialog, "Not now"); await Task.Delay(150);
    check("Not now denies only the pending device and leaves approved phones intact", !Runtime.Remote.Trust.Pending().Any(d => d.Id == refusal.DeviceId) && Runtime.Remote.Trust.List().Any(d => d.Id == receipt.DeviceId));
    check("Dismissing pairing cancels its code", !Runtime.Remote.Trust.Pairing.IsOpen);
  }
  private async Task WaitPairingCodeAsync()
  {
    var until = DateTimeOffset.UtcNow.AddSeconds(5);
    while (settings.ActiveCode is null)
    { if (DateTimeOffset.UtcNow > until) throw new InvalidOperationException("Pairing code did not become ready."); await Task.Delay(50); }
  }
}
