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

  private async void AccountButton_Click(object sender, RoutedEventArgs e)
  {
    if (working) return;
    var label = (sender as Button)?.Content as string;
    working = true; Render();
    try
    {
      if (label == CloudPageText.SignIn) await account.BeginSignInAsync();
      else if (label == CloudPageText.Cancel) account.CancelSignIn();
      else if (label == CloudPageText.SignOut && await ConfirmSignOutAsync()) await account.SignOutAsync();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { working = false; Render(); }
  }

  /// One confirmation: "Sign out" or "Cancel". Signing out removes this PC from the account and drops its key.
  private async Task<bool> ConfirmSignOutAsync()
  {
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = CloudPageText.SignOutTitle,
      Content = new TextBlock { Text = CloudPageText.SignOutText, TextWrapping = TextWrapping.Wrap },
      PrimaryButtonText = CloudPageText.SignOut, CloseButtonText = CloudPageText.Cancel, DefaultButton = ContentDialogButton.Close };
    return await dialog.ShowAsync() == ContentDialogResult.Primary;
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
