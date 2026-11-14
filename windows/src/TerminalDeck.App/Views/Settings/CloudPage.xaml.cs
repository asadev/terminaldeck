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
    DevicesHeading.Visibility = page.Devices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    DeviceList.Children.Clear();
    foreach (var device in page.Devices) DeviceList.Children.Add(DeviceCard(device));
    Show(Problem, summary.Problem);
  }

  private static void Show(TextBlock block, string? text)
  { block.Text = text ?? ""; block.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible; }

  private static FrameworkElement DeviceCard(CloudPageDevice device)
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

  private async Task RefreshQuietlyAsync()
  {
    try { await account.RefreshAsync(); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
