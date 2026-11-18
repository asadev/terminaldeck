using System.Globalization;
using TerminalDeck.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// Settings > Profile, first in the list (Mac, 15 Nov): the picture centred, name and e-mail; then Personal information,
// Sign-in and Cloud; then the account's devices, one row each (a device's own page opens from its row). Names and
// dates, never an id or a code.
public sealed partial class ProfilePage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly Action<string> open;
  private readonly Func<string, Task>? alsoRemove;
  private readonly Action<CloudSnapshot> changed;
  private readonly StackPanel body = AccountPages.Body();
  private CloudProfile? read;
  private bool working;
  private string? pressProblem;
  private readonly ProfileDeviceActions? deviceActions;
  private bool allDevices;
  private readonly Dictionary<string, CancellationTokenSource> pendingRemovals = new(StringComparer.Ordinal);
  private readonly Dictionary<string, string> deviceProblems = new(StringComparer.Ordinal);
  private string? editingDevice;
  private string? savedDevice;

  /// `alsoRemove`: what else a device's "Remove" ends (its reach to this PC: one Remove means one thing, as on the Mac).
  public ProfilePage(CloudAccountClient account, Action<string> open, Func<string, Task>? alsoRemove = null, ProfileDeviceActions? deviceActions = null)
  {
    this.account = account; this.open = open; this.alsoRemove = alsoRemove; this.deviceActions = deviceActions;
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
      nobody.Children.Add(new PersonPicture { Width = 72, Height = 72, HorizontalAlignment = HorizontalAlignment.Center });
      nobody.Children.Add(new TextBlock { Text = signingIn ? CloudPageText.SigningInLine : Brand.Name + " account", FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
      nobody.Children.Add(new TextBlock { Text = "Sign in once and your sessions, memory and settings are on every device you use.", FontSize = 13, MaxWidth = 380, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center });
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
    who.Children.Add(PhotoButton(picture, profile));
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

    var devices = DeviceRows();
    if (devices.Count > 0)
    {
      body.Children.Add(SettingsPanel.GroupTitle("Devices"));
      var rows = devices.Take(allDevices ? devices.Count : 8).Select(DeviceRow).ToList();
      if (devices.Count > 8)
      {
        var more = QuietButton(allDevices ? "Show fewer" : $"Show {devices.Count - 8} more");
        more.Click += (_, _) => { allDevices = !allDevices; Render(); };
        rows.Add(SettingsPanel.SettingRow("", "", more));
      }
      var others = devices.Where(d => !d.ThisDevice).ToArray();
      if (others.Length >= 2)
      {
        var allPending = others.All(d => pendingRemovals.ContainsKey(d.DeviceId));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var signOut = QuietButton(allPending ? $"Signing out {others.Length} others…" : "Sign out of all the others");
        signOut.IsEnabled = !allPending;
        signOut.Click += (_, _) => QueueRemoval(others);
        actions.Children.Add(signOut);
        if (allPending && !others.Any(d => sentRemovals.Contains(d.DeviceId)))
        {
          var undo = QuietButton("Undo"); undo.Click += (_, _) => CancelRemoval(others); actions.Children.Add(undo);
        }
        rows.Add(SettingsPanel.SettingRow("", "", actions));
      }
      body.Children.Add(SettingsPanel.GroupRows(rows));
    }
    if (pressProblem is { } problem) body.Children.Add(AccountPages.Problem(problem));
  }

  private async Task PressAsync(Func<Task> press)
  {
    if (working) return;
    working = true; pressProblem = null; Render();
    try { await press(); }
    catch (CloudProfileRefusal refusal) { pressProblem = refusal.Words; }
    catch (CloudTrustRefusal refusal) { pressProblem = refusal.Words; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { pressProblem = "Could not finish that change. Nothing was changed."; }
    finally { working = false; Render(); _ = ReadAsync(); }
  }
}

// What the account pages share: the centred column, the signed-in test, the device words and the sign-out question.
internal static class AccountPages
{
  internal static StackPanel Body() => SettingsPanel.Column();

  internal static ScrollViewer Scroll(StackPanel body) => SettingsPanel.Scroll(body);

  internal static bool SignedIn(CloudSnapshot snapshot) => snapshot.Phase is CloudPhase.SignedIn or CloudPhase.Paused or CloudPhase.NotAllowed;

  // One second line per device: "This PC", "Active now", "Last seen today", "Last seen 3 Nov 2026".
  internal static string DeviceLine(CloudDeviceRow device)
  {
    if (device.ThisDevice) return "This PC";
    if (device.Trust is { CanBeTrusted: true }) return "Waiting for you";
    if (device.LastSeen is not { } seen) return "Not seen yet";
    var now = DateTimeOffset.Now;
    if (now - seen < TimeSpan.FromMinutes(5)) return "Active now";
    var day = seen.ToLocalTime().Date;
    if (day == now.Date) return "Last seen today";
    if (day == now.Date.AddDays(-1)) return "Last seen yesterday";
    return "Last seen " + seen.ToLocalTime().ToString(seen.Year == now.Year ? "d MMM" : "d MMM yyyy", CultureInfo.CurrentCulture);
  }

  internal static string Date(DateTimeOffset at) => at.ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture);

  // The kind of device (its platform, then its model words): a desktop, a laptop, a PC, a phone.
  internal static FrameworkElement DeviceGlyph(CloudDeviceRow device)
  {
    return DevicePicture.Create(device.Platform, device.Name, device.ReportedModel);
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
