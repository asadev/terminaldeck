using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

/// Settings → Cloud, second after General as on the Mac. Every word comes from `CloudPageText` (tested in Core); this file
/// only draws it and forwards the person's own presses. Sign in starts here, or from a terminaldeck://cloud/signin link after the person says yes; never from a tool.
/// The browser comes back on terminaldeck://cloud/return/… and the sign-in finishes by itself (ShellWindow.Cloud.cs); nothing here asks again.
public sealed partial class CloudPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly Action<CloudSnapshot> changed;
  private bool working;
  private bool drawing;
  /// The plain words of the last trust press that changed nothing (a refusal), until the next press.
  private string? pressProblem;

  public CloudPage(CloudAccountClient account)
  {
    this.account = account;
    InitializeComponent();
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += (_, _) => { account.Changed += changed; Render(); if (account.Snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused) _ = RefreshQuietlyAsync(); };
    Unloaded += (_, _) => account.Changed -= changed;
    Render();
  }

  private void Render()
  {
    var snapshot = account.Snapshot;
    var summary = CloudPageText.Account(snapshot);
    var page = CloudPageText.For(snapshot);
    var signedIn = summary.Button is null;

    AccountName.Text = signedIn ? summary.Name ?? summary.Email ?? "" : page.Line;
    Show(AccountEmail, signedIn && summary.Name is not null ? summary.Email : null);
    Show(AccountProvider, signedIn ? summary.Provider : null);
    AccountButton.Content = page.Button ?? "";
    AccountButton.Visibility = page.Button is null ? Visibility.Collapsed : Visibility.Visible;
    AccountButton.IsEnabled = !working;

    CloudSection.Visibility = signedIn ? Visibility.Visible : Visibility.Collapsed;
    CloudLine.Text = signedIn ? page.Line : "";
    Show(ThisDevice, page.ThisDevice is null ? null : "This PC: " + page.ThisDevice);
    drawing = true;
    UseCloudSwitch.Header = CloudPageText.UseCloudToggle;
    UseCloudSwitch.IsOn = page.UseCloud ?? false;
    UseCloudSwitch.IsEnabled = !working && page.UseCloud is not null;
    drawing = false;
    Show(UseCloudState, page.UseCloud is { } on ? CloudPageText.UseCloudState(on) : null);
    NoticeList.Children.Clear();
    foreach (var notice in page.Notices ?? []) NoticeList.Children.Add(NoticeCard(notice));
    DevicesHeading.Visibility = page.Devices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    DeviceList.Children.Clear();
    foreach (var device in page.Devices) DeviceList.Children.Add(DeviceCard(device));
    ThisPcCodeButton.Content = CloudPageText.ShowThisPcCode;
    ThisPcCodeButton.Visibility = page.TrustMode == CloudTrustMode.Ask && account.ThisPcCode is not null ? Visibility.Visible : Visibility.Collapsed;
    TrustModeCard.Visibility = page.TrustMode is null ? Visibility.Collapsed : Visibility.Visible;
    drawing = true;
    TrustModeChoice.Header = CloudPageText.TrustModeTitle;
    TrustModeChoice.SelectedIndex = page.TrustMode == CloudTrustMode.Ask ? 1 : 0;
    TrustModeChoice.IsEnabled = !working;
    drawing = false;
    TrustModeNote.Text = page.TrustMode is { } mode ? CloudPageText.TrustModeNote(mode) : "";
    Show(Problem, pressProblem ?? page.Problem ?? summary.Problem);
  }

  private static void Show(TextBlock block, string? text)
  { block.Text = text ?? ""; block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible; }

  private FrameworkElement NoticeCard(CloudPageNotice notice)
  {
    var row = new Grid { ColumnSpacing = 16 };
    row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.Children.Add(new TextBlock { Text = notice.Text, FontSize = 13, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
    var button = new Button { Content = notice.Button, MinHeight = 28, Padding = new Thickness(12, 3, 12, 3), FontSize = 13, VerticalAlignment = VerticalAlignment.Center, IsEnabled = !working };
    button.Click += (_, _) => _ = PressAsync(() => notice.Action == CloudNoticeAction.Remove ? account.RemoveJoinedDeviceAsync(notice.DeviceId) : account.TrustAgainAsync(notice.DeviceId));
    Grid.SetColumn(button, 1); row.Children.Add(button);
    var card = new Border { Child = row, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10) };
    card.SetValue(Border.BackgroundProperty, Application.Current.Resources["DeckCardBrush"]);
    return card;
  }

  private FrameworkElement DeviceCard(CloudPageDevice device)
  {
    var words = new StackPanel { Spacing = 3 };
    words.Children.Add(new TextBlock { Text = device.Name, FontSize = 13, TextWrapping = TextWrapping.Wrap });
    var details = new TextBlock { Text = device.Details, FontSize = 12, TextWrapping = TextWrapping.Wrap };
    details.SetValue(TextBlock.ForegroundProperty, Application.Current.Resources["DeckSecondaryInkBrush"]); words.Children.Add(details);
    var row = new Grid { ColumnSpacing = 16 };
    row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.Children.Add(words);
    var code = new TextBlock { Text = device.Code, FontSize = 12, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center, IsTextSelectionEnabled = true };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(code, "Device code " + device.Code);
    Grid.SetColumn(code, 1); row.Children.Add(code);
    if (device.CanTrust)
    {
      var trust = new Button { Content = CloudPageText.TrustNew, MinHeight = 28, Padding = new Thickness(12, 3, 12, 3), FontSize = 13, VerticalAlignment = VerticalAlignment.Center, IsEnabled = !working };
      trust.Click += (_, _) => _ = CompareAndTrustAsync(device.DeviceId);
      Grid.SetColumn(trust, 1); row.Children.Add(trust);
    }
    var card = new Border { Child = row, CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10) };
    card.SetValue(Border.BackgroundProperty, Application.Current.Resources["DeckCardBrush"]);
    return card;
  }

  private async void AccountButton_Click(object sender, RoutedEventArgs e)
  {
    if (working) return;
    var label = (sender as Button)?.Content as string;
    working = true; Render();
    try
    {
      if (label == CloudPageText.SignIn) await account.BeginSignInAsync();
      else if (label == CloudPageText.Cancel) account.CancelSignIn();
      else if (label == CloudPageText.SignOut) await account.SignOutAsync();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { working = false; Render(); }
  }

  private async void UseCloudSwitch_Toggled(object sender, RoutedEventArgs e)
  {
    if (drawing || working) return;
    var on = UseCloudSwitch.IsOn;
    working = true; Render();
    try { await account.SetUseCloudAsync(on); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { working = false; Render(); }
  }

  private async void TrustModeChoice_SelectionChanged(object sender, SelectionChangedEventArgs e)
  {
    if (drawing || working || TrustModeChoice.SelectedIndex < 0) return;
    var mode = TrustModeChoice.SelectedIndex == 1 ? CloudTrustMode.Ask : CloudTrustMode.Account;
    if (mode == account.Snapshot.TrustMode) return;
    await PressAsync(() => account.SetTrustModeAsync(mode));
  }

  /// "Ask me for each new device": the compare dialog, the ONLY place a device code is shown. What the dialog shows when
  /// it is drawn (device, key, code) is what a Trust press stores.
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

  private async void ThisPcCodeButton_Click(object sender, RoutedEventArgs e)
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
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(block, string.Join(", ", code.Split(' ')));
    return block;
  }

  /// A trust press: one at a time, its refusal said in plain words on the page.
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
