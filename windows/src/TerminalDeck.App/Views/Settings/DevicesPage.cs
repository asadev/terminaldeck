using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// Profile > a device's own page (Mac, 15 Nov): its name and dates; for this PC "Sign out this device" (and, only in
// "Ask me for each new device", this PC's code); for a new device in that mode "Trust…" with the compare dialog (the
// ONLY place a device code is shown). The device's id is the route only; it is never drawn.
public sealed class DevicePage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly string deviceId;
  private readonly Action<string> open;
  private readonly Action<CloudSnapshot> changed;
  private readonly StackPanel body = AccountPages.Body();
  private bool working;
  private string? pressProblem;

  public DevicePage(CloudAccountClient account, string deviceId, Action<string> open)
  {
    this.account = account; this.deviceId = deviceId; this.open = open;
    AutomationProperties.SetAutomationId(this, "settings.device");
    Content = AccountPages.Scroll(body);
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += (_, _) => { account.Changed += changed; Render(); };
    Unloaded += (_, _) => account.Changed -= changed;
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    var snapshot = account.Snapshot;
    if (!snapshot.Subscription.AllowsCloudServices) return;
    var device = snapshot.DeviceRows.FirstOrDefault(d => d.DeviceId == deviceId);
    // The top bar names the page after the device.
    Tag = device?.Name ?? "Device";
    if (device is null || !AccountPages.SignedIn(snapshot))
    {
      body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.LinkRow("This device is no longer in your account", null, null, null, () => open("profile"))]));
      return;
    }
    var name = new TextBox { Text = device.Name, Width = 220, MinHeight = 24, Padding = new(6, 1, 6, 1), BorderThickness = new(0), CornerRadius = new(6), FontSize = 13, TextAlignment = TextAlignment.Right, MaxLength = 128, IsEnabled = !working };
    name.SetResourceReference(Control.BackgroundProperty, "DeckHoverBrush");
    AutomationProperties.SetAutomationId(name, "settings.device.name");
    async Task SaveNameAsync()
    {
      if (working || name.Text.Trim() == device.Name) return;
      var typed = name.Text.Trim();
      await PressAsync(() => account.RenameDeviceAsync(deviceId, typed));
    }
    name.KeyDown += async (_, args) =>
    {
      if (args.Key == Windows.System.VirtualKey.Enter) { args.Handled = true; await SaveNameAsync(); }
      else if (args.Key == Windows.System.VirtualKey.Escape) { name.Text = device.Name; args.Handled = true; }
    };
    name.LostFocus += async (_, _) => await SaveNameAsync();
    var facts = new List<FrameworkElement> { SettingsPanel.SettingRow("Name", "", name) };
    if (device.Added is { } added) facts.Add(SettingsPanel.SettingRow("Added", "", SettingsPanel.StateText(AccountPages.Date(added))));
    facts.Add(SettingsPanel.SettingRow("Last seen", "", SettingsPanel.StateText(AccountPages.DeviceLine(device))));
    body.Children.Add(SettingsPanel.GroupRows(facts));

    if (device.ThisDevice)
    {
      var actions = new List<FrameworkElement>();
      if (snapshot.TrustMode == CloudTrustMode.Ask && account.ThisPcCode is not null)
      {
        var show = new Button { Content = CloudPageText.ShowThisPcCode };
        show.Click += async (_, _) => await ShowThisPcCodeAsync();
        actions.Add(SettingsPanel.SettingRow(CloudPageText.ThisPcCodeTitle, "Only for “Ask me for each new device”: compare it with the code on your other device.", show));
      }
      var signOut = AccountPages.RedButton("Sign out this device");
      signOut.IsEnabled = !working;
      AutomationProperties.SetAutomationId(signOut, "settings.devices.thisPc");
      signOut.Click += async (_, _) => { if (await AccountPages.ConfirmSignOutAsync(this)) await PressAsync(() => account.SignOutAsync()); };
      actions.Add(SettingsPanel.SettingRow("Sign out this device", CloudPageText.SignOutText, signOut));
      body.Children.Add(SettingsPanel.GroupRows(actions));
    }
    else if (CloudPageText.For(snapshot).Devices.FirstOrDefault(d => d.DeviceId == deviceId) is { CanTrust: true })
    {
      var trust = new Button { Content = CloudPageText.TrustNew, IsEnabled = !working };
      trust.Click += async (_, _) => await CompareAndTrustAsync(deviceId);
      body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow("Trust this device", "Its changes wait until you trust it here. Compare its code on both devices first.", trust)]));
    }
    if (pressProblem is { } problem) body.Children.Add(AccountPages.Problem(problem));
  }

  // What the dialog shows when it is drawn (device, key, code) is what a Trust press stores.
  private async Task CompareAndTrustAsync(string id)
  {
    if (working || account.CaptureForDialog(id) is not { } captured) return;
    var words = new StackPanel { Spacing = 12 };
    words.Children.Add(new TextBlock { Text = CloudPageText.CompareText(captured.Name), TextWrapping = TextWrapping.Wrap });
    words.Children.Add(CodeBlock(captured.Code));
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = CloudPageText.CompareTitle(captured.Name), Content = words,
      PrimaryButtonText = CloudPageText.Trust, CloseButtonText = CloudPageText.Cancel, DefaultButton = ContentDialogButton.Close };
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    await PressAsync(() => account.TrustNewDeviceAsync(captured));
  }

  private async Task ShowThisPcCodeAsync()
  {
    if (account.ThisPcCode is not { } code) return;
    var words = new StackPanel { Spacing = 12 };
    words.Children.Add(new TextBlock { Text = CloudPageText.ThisPcCodeText, TextWrapping = TextWrapping.Wrap });
    words.Children.Add(CodeBlock(code));
    await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = CloudPageText.ThisPcCodeTitle, Content = words, CloseButtonText = "Done" }.ShowAsync();
  }

  private static TextBlock CodeBlock(string code)
  {
    var block = new TextBlock { Text = code, FontSize = 20, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), IsTextSelectionEnabled = true };
    AutomationProperties.SetName(block, string.Join(", ", code.Split(' ')));
    return block;
  }

  // One press at a time; a refusal is said in plain words on the page.
  private async Task PressAsync(Func<Task> press)
  {
    if (working) return;
    working = true; pressProblem = null; Render();
    try { await press(); }
    catch (CloudProfileRefusal refusal) { pressProblem = refusal.Words; }
    catch (CloudTrustRefusal refusal) { pressProblem = refusal.Words; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Nothing was changed."; }
    finally { working = false; Render(); }
  }
}
