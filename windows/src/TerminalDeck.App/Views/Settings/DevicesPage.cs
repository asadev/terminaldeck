using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// Settings > Devices, its own page (Mac, 14 Nov): the account's devices, each a name and dates
// (from CloudPageText, the words #20 put on the Cloud page), "Sign out this device" in this PC's
// row menu, the notices about a new or changed device, and the "Ask me" compare dialog (the ONLY
// place a device code is shown). Phones and computers paired with a code keep their window.
public sealed class DevicesPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly Func<int> pairedCount;
  private readonly Func<bool>? openPaired;
  private readonly Action<CloudSnapshot> changed;
  private readonly StackPanel body = new() { Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20, 0, 20, 20) };
  private bool working;
  private string? pressProblem;

  public DevicesPage(CloudAccountClient account, Func<int> pairedCount, Func<bool>? openPaired)
  {
    this.account = account; this.pairedCount = pairedCount; this.openPaired = openPaired;
    AutomationProperties.SetAutomationId(this, "settings.devices");
    Content = new ScrollViewer { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += (_, _) => { account.Changed += changed; Render(); if (account.Snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused) _ = RefreshQuietlyAsync(); };
    Unloaded += (_, _) => account.Changed -= changed;
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    body.Children.Add(SettingsPanel.PageHead("Devices"));
    var snapshot = account.Snapshot;
    var page = CloudPageText.For(snapshot);
    var signedIn = CloudPageText.Account(snapshot).Button is null;
    if (!signedIn)
    {
      var signIn = new Button { Content = snapshot.Phase == CloudPhase.SigningIn ? CloudPageText.Cancel : CloudPageText.SignIn, IsEnabled = !working };
      signIn.Click += async (_, _) => await PressAsync(async () => { if (account.Snapshot.Phase == CloudPhase.SigningIn) account.CancelSignIn(); else await account.BeginSignInAsync(); });
      body.Children.Add(SettingsPanel.SettingRow(snapshot.Phase == CloudPhase.SigningIn ? CloudPageText.SigningInLine : "Not signed in",
        "Sign in once and your devices appear here by name. No codes.", signIn));
    }
    else
    {
      foreach (var notice in page.Notices ?? []) body.Children.Add(NoticeCard(notice));
      if (page.Devices.Count > 0)
      {
        body.Children.Add(Heading("Your devices"));
        body.Children.Add(SettingsPanel.GroupRows(page.Devices.Select(DeviceRow)));
      }
      if (page.TrustMode == CloudTrustMode.Ask && account.ThisPcCode is not null)
      {
        var show = new Button { Content = CloudPageText.ShowThisPcCode };
        show.Click += async (_, _) => await ShowThisPcCodeAsync();
        body.Children.Add(SettingsPanel.SettingRow("This PC's code", "Only for “Ask me for each new device”: compare it with the code on your other device.", show));
      }
    }
    // Phones and computers paired with a code: their own window, unchanged.
    var count = pairedCount();
    var open = new Button { Content = "Open…" };
    AutomationProperties.SetAutomationId(open, "settings.devices.paired");
    open.Click += (_, _) => openPaired?.Invoke();
    body.Children.Add(Heading("Paired with a code"));
    body.Children.Add(SettingsPanel.SettingRow(count == 0 ? "No phones or computers paired with a code" : count == 1 ? "1 phone or computer paired with a code" : count + " phones and computers paired with a code",
      "Pairing, the web version and phone access to this PC's screen.", open));
    if (pressProblem is { } problem)
    {
      var line = new TextBlock { Text = problem, FontSize = 12, TextWrapping = TextWrapping.Wrap };
      line.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); body.Children.Add(line);
    }
  }

  private static TextBlock Heading(string text) => new() { Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(8, 20, 0, 0) };

  // Owner, 13 Nov: name, date added, last seen, "This PC". No code, id, key or version.
  private FrameworkElement DeviceRow(CloudPageDevice device)
  {
    FrameworkElement? control = null;
    if (device.ThisDevice)
    {
      var more = new Button { Content = new DeckIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6), MinWidth = 28, MinHeight = 28, IsEnabled = !working };
      AutomationProperties.SetName(more, "This PC actions"); AutomationProperties.SetAutomationId(more, "settings.devices.thisPc");
      var menu = new MenuFlyout();
      var signOut = new MenuFlyoutItem { Text = "Sign out this device" };
      signOut.Click += async (_, _) => { if (await ConfirmSignOutAsync()) await PressAsync(() => account.SignOutAsync()); };
      menu.Items.Add(signOut); more.Flyout = menu; control = more;
    }
    else if (device.CanTrust)
    {
      var trust = new Button { Content = CloudPageText.TrustNew, IsEnabled = !working };
      var id = device.DeviceId; trust.Click += async (_, _) => await CompareAndTrustAsync(id);
      control = trust;
    }
    return SettingsPanel.SettingRow(device.Name, device.Details, control);
  }

  private FrameworkElement NoticeCard(CloudPageNotice notice)
  {
    var button = new Button { Content = notice.Button, IsEnabled = !working };
    button.Click += async (_, _) => await PressAsync(() => notice.Action == CloudNoticeAction.Remove ? account.RemoveJoinedDeviceAsync(notice.DeviceId) : account.TrustAgainAsync(notice.DeviceId));
    return SettingsPanel.SettingRow(notice.Text, "", button);
  }

  private async Task<bool> ConfirmSignOutAsync()
  {
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = CloudPageText.SignOutTitle,
      Content = new TextBlock { Text = CloudPageText.SignOutText, TextWrapping = TextWrapping.Wrap },
      PrimaryButtonText = CloudPageText.SignOut, CloseButtonText = CloudPageText.Cancel, DefaultButton = ContentDialogButton.Close };
    return await dialog.ShowAsync() == ContentDialogResult.Primary;
  }

  // What the dialog shows when it is drawn (device, key, code) is what a Trust press stores.
  private async Task CompareAndTrustAsync(string deviceId)
  {
    if (working || account.CaptureForDialog(deviceId) is not { } captured) return;
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
    catch (CloudTrustRefusal refusal) { pressProblem = refusal.Words; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Nothing was changed."; }
    finally { working = false; Render(); }
  }

  private async Task RefreshQuietlyAsync()
  {
    try { await account.RefreshAsync(); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
