using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// Settings > Profile, first in the list (Mac, 15 Nov): the picture centred, name and e-mail; then Personal information,
// Sign-in and Cloud; then the account's devices, one row each (a device's own page opens from its row). Names and
// dates, never an id or a code.
public sealed class ProfilePage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly Action<string> open;
  private readonly Action<CloudSnapshot> changed;
  private readonly StackPanel body = AccountPages.Body();
  private CloudProfile? read;
  private bool working;
  private string? pressProblem;

  public ProfilePage(CloudAccountClient account, Action<string> open)
  {
    this.account = account; this.open = open;
    AutomationProperties.SetAutomationId(this, "settings.profile");
    Content = AccountPages.Scroll(body);
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += async (_, _) =>
    {
      account.Changed += changed; Render();
      if (account.Snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused) _ = AccountPages.RefreshQuietlyAsync(account);
      await ReadAsync();
    };
    Unloaded += (_, _) => account.Changed -= changed;
    Render();
  }

  private async Task ReadAsync()
  {
    if (!AccountPages.SignedIn(account.Snapshot)) return;
    read = await account.ProfileAsync();
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    var snapshot = account.Snapshot;
    if (!AccountPages.SignedIn(snapshot))
    {
      // Signed out (15 Nov): centred, a round placeholder picture, "Not signed in", ONE accent "Sign in".
      var signingIn = snapshot.Phase == CloudPhase.SigningIn;
      var signIn = new Button { Content = signingIn ? CloudPageText.Cancel : CloudPageText.SignIn, IsEnabled = !working, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
      if (!signingIn) signIn.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
      AutomationProperties.SetAutomationId(signIn, "settings.profile.signInButton");
      signIn.Click += async (_, _) => await PressAsync(async () => { if (account.Snapshot.Phase == CloudPhase.SigningIn) account.CancelSignIn(); else await account.BeginSignInAsync(); });
      var nobody = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
      nobody.Children.Add(new PersonPicture { Width = 96, Height = 96, HorizontalAlignment = HorizontalAlignment.Center });
      nobody.Children.Add(new TextBlock { Text = signingIn ? CloudPageText.SigningInLine : "Not signed in", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
      nobody.Children.Add(signIn);
      body.Children.Add(nobody);
      if (pressProblem is { } failed) body.Children.Add(AccountPages.Problem(failed));
      return;
    }
    var profile = read ?? CloudProfile.FromSnapshot(snapshot);
    // Who: the picture centred and larger (initials until the site sends one), the name, the e-mail.
    var picture = new PersonPicture { Width = 96, Height = 96, DisplayName = profile.Name, Initials = CloudProfile.Initials(profile.Name), HorizontalAlignment = HorizontalAlignment.Center };
    if (profile.Picture is { } address) picture.ProfilePicture = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(address);
    AutomationProperties.SetName(picture, "Picture of " + profile.Name);
    var who = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
    who.Children.Add(picture);
    who.Children.Add(new TextBlock { Text = profile.Name, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 8, 0, 0) });
    if (profile.Email is { } email && email != profile.Name)
    {
      var line = new TextBlock { Text = email, FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap };
      line.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush"); who.Children.Add(line);
    }
    body.Children.Add(who);

    body.Children.Add(SettingsPanel.GroupRows([
      SettingsPanel.LinkRow("Personal information", null, SettingsPanel.IconTile("", "DeckProjectGraphiteBrush"), null, () => open("personal")),
      SettingsPanel.LinkRow("Sign-in", null, SettingsPanel.IconTile("", "DeckProjectGraphiteBrush"), null, () => open("sign-in")),
      SettingsPanel.LinkRow("Cloud", null, SettingsPanel.IconTile("", "DeckProjectBlueBrush"), CloudPageText.Account(snapshot).CloudRow, () => open("cloud"))
    ]));

    // A device that joined by itself, or whose identity changed: one row each, with its one button.
    var page = CloudPageText.For(snapshot);
    if (page.Notices is { Count: > 0 } notices) body.Children.Add(SettingsPanel.GroupRows(notices.Select(NoticeRow)));

    // Devices: one row per device, this PC first; a row opens the device's own page.
    var devices = snapshot.DeviceRows.OrderByDescending(d => d.ThisDevice).ThenByDescending(d => d.LastSeen ?? DateTimeOffset.MinValue).ToArray();
    if (devices.Length > 0)
    {
      body.Children.Add(SettingsPanel.GroupTitle("Devices"));
      body.Children.Add(SettingsPanel.GroupRows(devices.Select(device =>
        SettingsPanel.LinkRow(device.Name, AccountPages.DeviceLine(device), AccountPages.DeviceGlyph(device), null, () => open(SettingsNavigation.DevicePrefix + device.DeviceId)))));
    }
    if (pressProblem is { } problem) body.Children.Add(AccountPages.Problem(problem));
  }

  private FrameworkElement NoticeRow(CloudPageNotice notice)
  {
    var button = new Button { Content = notice.Button, IsEnabled = !working };
    button.Click += async (_, _) => await PressAsync(() => notice.Action == CloudNoticeAction.Remove ? account.RemoveJoinedDeviceAsync(notice.DeviceId) : account.TrustAgainAsync(notice.DeviceId));
    return SettingsPanel.SettingRow(notice.Text, "", button);
  }

  private async Task PressAsync(Func<Task> press)
  {
    if (working) return;
    working = true; pressProblem = null; Render();
    try { await press(); }
    catch (CloudTrustRefusal refusal) { pressProblem = refusal.Words; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Nothing was changed."; }
    finally { working = false; read = null; Render(); _ = ReadAsync(); }
  }
}

// Profile > Personal information: the name and e-mail as the site gives them; the rest on the website.
public sealed class PersonalPage : UserControl
{
  private const string EditAddress = "https://terminaldeck.dev/account";
  private readonly CloudAccountClient account;
  private readonly StackPanel body = AccountPages.Body();
  private CloudProfile? read;

  public PersonalPage(CloudAccountClient account)
  {
    this.account = account;
    AutomationProperties.SetAutomationId(this, "settings.profile.personal");
    Content = AccountPages.Scroll(body);
    Loaded += async (_, _) => { if (AccountPages.SignedIn(account.Snapshot)) { read = await account.ProfileAsync(); Render(); } };
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    var profile = read ?? CloudProfile.FromSnapshot(account.Snapshot);
    var rows = new List<FrameworkElement> { SettingsPanel.SettingRow("Name", "", SettingsPanel.StateText(profile.Name)) };
    if (profile.Email is { } email) rows.Add(SettingsPanel.SettingRow("E-mail", "", SettingsPanel.StateText(email)));
    var more = SettingsPanel.LinkRow("More on the website", null, null, null, () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri(EditAddress)));
    AutomationProperties.SetAutomationId(more, "settings.profile.edit");
    rows.Add(more);
    body.Children.Add(SettingsPanel.GroupRows(rows));
  }
}

// Profile > Sign-in: the ways he signs in ("Connected" at the right; the account and date behind the info button),
// then Sign out as its own group: the only red text on the page.
public sealed class SignInPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly StackPanel body = AccountPages.Body();
  private CloudProfile? read;
  private bool working;

  public SignInPage(CloudAccountClient account)
  {
    this.account = account;
    AutomationProperties.SetAutomationId(this, "settings.profile.signIn");
    Content = AccountPages.Scroll(body);
    Loaded += async (_, _) => { if (AccountPages.SignedIn(account.Snapshot)) { read = await account.ProfileAsync(); Render(); } };
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    if (!AccountPages.SignedIn(account.Snapshot))
    {
      body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow("Not signed in", "", null)]));
      return;
    }
    var profile = read ?? CloudProfile.FromSnapshot(account.Snapshot);
    if (profile.Ways.Count > 0)
      body.Children.Add(SettingsPanel.GroupRows(profile.Ways.Select(way => SettingsPanel.SettingRow(way.ProviderName, CloudProfile.WayDetails(way), SettingsPanel.StateText("Connected")))));
    var signOut = AccountPages.RedButton(CloudPageText.SignOut);
    signOut.IsEnabled = !working;
    AutomationProperties.SetAutomationId(signOut, "settings.profile.signOut");
    signOut.Click += async (_, _) =>
    {
      if (working || !await AccountPages.ConfirmSignOutAsync(this)) return;
      working = true; Render();
      try { await account.SignOutAsync(); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { }
      finally { working = false; Render(); }
    };
    body.Children.Add(SettingsPanel.GroupRows([SettingsPanel.SettingRow("Sign out of this PC", CloudPageText.SignOutText, signOut)]));
  }
}

// What the account pages share: the centred column, the signed-in test, the device words and the sign-out question.
internal static class AccountPages
{
  internal static StackPanel Body() => SettingsPanel.Column();

  internal static ScrollViewer Scroll(StackPanel body) => new() { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };

  internal static bool SignedIn(CloudSnapshot snapshot) => snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused or CloudPhase.NotAllowed;

  // One second line per device: "This PC", "Active now", "Last seen today", "Last seen 3 Nov 2026".
  internal static string DeviceLine(CloudDeviceRow device)
  {
    if (device.ThisDevice) return "This PC";
    if (device.LastSeen is not { } seen) return "Not seen yet";
    var now = DateTimeOffset.Now;
    if (now - seen < TimeSpan.FromMinutes(5)) return "Active now";
    var day = seen.ToLocalTime().Date;
    if (day == now.Date) return "Last seen today";
    if (day == now.Date.AddDays(-1)) return "Last seen yesterday";
    return "Last seen " + Date(seen);
  }

  internal static string Date(DateTimeOffset at) => at.ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture);

  // The kind of device, as its name tells it: a phone or a computer.
  internal static FrameworkElement DeviceGlyph(CloudDeviceRow device)
  {
    var phone = new[] { "iphone", "android", "pixel", "galaxy", "phone" }.Any(word => device.Name.Contains(word, StringComparison.OrdinalIgnoreCase));
    var icon = new DeckIcon { Glyph = phone ? "" : "", FontSize = 20, Width = 28, Height = 28, VerticalAlignment = VerticalAlignment.Center };
    icon.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    return icon;
  }

  internal static Button RedButton(string text)
  {
    var words = new TextBlock { Text = text };
    words.SetResourceReference(TextBlock.ForegroundProperty, "DeckStatusFailedBrush");
    var button = new Button { Content = words, VerticalAlignment = VerticalAlignment.Center };
    AutomationProperties.SetName(button, text);
    return button;
  }

  internal static TextBlock Problem(string text)
  {
    var line = new TextBlock { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8, -8, 0, 0) };
    line.SetResourceReference(TextBlock.ForegroundProperty, "DeckProjectOrangeBrush");
    return line;
  }

  /// One confirmation: "Sign out" or "Cancel". Signing out removes this PC from the account and drops its key.
  internal static async Task<bool> ConfirmSignOutAsync(FrameworkElement owner)
  {
    var dialog = new ContentDialog { XamlRoot = owner.XamlRoot, RequestedTheme = owner.ActualTheme, Title = CloudPageText.SignOutTitle,
      Content = new TextBlock { Text = CloudPageText.SignOutText, TextWrapping = TextWrapping.Wrap },
      PrimaryButtonText = CloudPageText.SignOut, CloseButtonText = CloudPageText.Cancel, DefaultButton = ContentDialogButton.Close };
    return await dialog.ShowAsync() == ContentDialogResult.Primary;
  }

  internal static async Task RefreshQuietlyAsync(CloudAccountClient account)
  {
    try { await account.RefreshAsync(); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }
}
