using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// Settings > Profile, first in the list (Mac, 14 Nov): the picture, name and e-mail of the Terminal
// Deck account, the ways he signs in (as the site's profile gives them: names and dates, never an
// id), Edit profile on the website, and Sign out. One state and at most one control per section.
public sealed class ProfilePage : UserControl
{
  private const string EditAddress = "https://terminaldeck.dev/account";
  private readonly CloudAccountClient account;
  private readonly Action<CloudSnapshot> changed;
  private readonly StackPanel body = new() { Spacing = 12, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20, 0, 20, 20) };
  private CloudProfile? read;
  private bool working;

  public ProfilePage(CloudAccountClient account)
  {
    this.account = account;
    AutomationProperties.SetAutomationId(this, "settings.profile");
    Content = new ScrollViewer { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += async (_, _) => { account.Changed += changed; Render(); await ReadAsync(); };
    Unloaded += (_, _) => account.Changed -= changed;
    Render();
  }

  private async Task ReadAsync()
  {
    if (account.Snapshot.Phase is CloudPhase.Dormant or CloudPhase.SignedOut or CloudPhase.SigningIn) return;
    read = await account.ProfileAsync();
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    body.Children.Add(SettingsPanel.PageHead("Profile"));
    var snapshot = account.Snapshot;
    var signedIn = snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused or CloudPhase.NotAllowed;
    if (!signedIn)
    {
      var signIn = new Button { Content = snapshot.Phase == CloudPhase.SigningIn ? CloudPageText.Cancel : CloudPageText.SignIn, IsEnabled = !working };
      signIn.Click += async (_, _) => await PressAsync(async () => { if (account.Snapshot.Phase == CloudPhase.SigningIn) account.CancelSignIn(); else await account.BeginSignInAsync(); });
      body.Children.Add(SettingsPanel.SettingRow(snapshot.Phase == CloudPhase.SigningIn ? CloudPageText.SigningInLine : "Not signed in",
        "Sign in once with your Terminal Deck account; your devices, sessions and data follow.", signIn));
      return;
    }
    var profile = read ?? CloudProfile.FromSnapshot(snapshot);
    // Who: picture (initials until the site sends one), name, e-mail; Edit profile on the website.
    var picture = new PersonPicture { Width = 56, Height = 56, DisplayName = profile.Name, Initials = CloudProfile.Initials(profile.Name) };
    if (profile.Picture is { } address) picture.ProfilePicture = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(address);
    AutomationProperties.SetName(picture, "Picture of " + profile.Name);
    var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    words.Children.Add(new TextBlock { Text = profile.Name, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
    if (profile.Email is { } email && email != profile.Name)
    {
      var line = new TextBlock { Text = email, FontSize = 12, TextWrapping = TextWrapping.Wrap };
      line.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); words.Children.Add(line);
    }
    var who = new Grid { ColumnSpacing = 14 };
    who.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); who.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); who.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    who.Children.Add(picture); Grid.SetColumn(words, 1); who.Children.Add(words);
    var edit = new Button { Content = "Edit profile", VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetAutomationId(edit, "settings.profile.edit");
    edit.Click += async (_, _) => await Windows.System.Launcher.LaunchUriAsync(new Uri(EditAddress));
    Grid.SetColumn(edit, 2); who.Children.Add(edit);
    var card = new Border { Child = who, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(10) };
    card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush");
    body.Children.Add(card);

    // Ways you sign in: one row each, the provider and the account as the site names it.
    if (profile.Ways.Count > 0)
    {
      body.Children.Add(Heading("Ways you sign in"));
      body.Children.Add(SettingsPanel.GroupRows(profile.Ways.Select(way => SettingsPanel.SettingRow(way.ProviderName, CloudProfile.WayDetails(way), null))));
    }

    // Sign out: this PC leaves the account (the same as Devices > This PC > Sign out this device).
    body.Children.Add(Heading("This PC"));
    var signOut = new Button { Content = CloudPageText.SignOut, IsEnabled = !working };
    AutomationProperties.SetAutomationId(signOut, "settings.profile.signOut");
    signOut.Click += async (_, _) => { if (await ConfirmSignOutAsync()) await PressAsync(() => account.SignOutAsync()); };
    body.Children.Add(SettingsPanel.SettingRow("Sign out", CloudPageText.SignOutText, signOut));
  }

  private static TextBlock Heading(string text) => new() { Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(8, 20, 0, 0) };

  private async Task<bool> ConfirmSignOutAsync()
  {
    var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = CloudPageText.SignOutTitle,
      Content = new TextBlock { Text = CloudPageText.SignOutText, TextWrapping = TextWrapping.Wrap },
      PrimaryButtonText = CloudPageText.SignOut, CloseButtonText = CloudPageText.Cancel, DefaultButton = ContentDialogButton.Close };
    return await dialog.ShowAsync() == ContentDialogResult.Primary;
  }

  private async Task PressAsync(Func<Task> press)
  {
    if (working) return;
    working = true; Render();
    try { await press(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
    finally { working = false; read = null; Render(); _ = ReadAsync(); }
  }
}
