using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Browser;
using CoreBrowserProfile = TerminalDeck.Core.Browser.BrowserProfile;
using Windows.Storage.Pickers;
using Windows.System;

namespace TerminalDeck.App.Views.Settings;

// The Browser's sign-ins and saved passwords (Browser settings window, 15 Nov): every row one line inside its
// group's card. `SignInRows` join the "Cookies and sign-ins" group; this panel itself is the "Saved passwords"
// group and the one notice line.
public sealed class BrowserPrivacyPage : StackPanel
{
  public IReadOnlyList<FrameworkElement> SignInRows { get; }

  public BrowserPrivacyPage(BrowserPane browser)
  {
    Spacing = 20;
    var notice = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(12, -8, 0, 0) };
    var profile = new ComboBox { ItemsSource = browser.Core.Read().Profiles, DisplayMemberPath = "Name", SelectedItem = browser.Core.Read().Profiles.First(p => p.Id == browser.Core.Read().ActiveProfileId), MinWidth = 160 };
    var keep = new ToggleSwitch { IsOn = browser.Privacy.Read().PersistSignIns, OnContent = "", OffContent = "", MinWidth = 40 };
    var save = new ToggleSwitch { IsOn = browser.Privacy.Read().SavePasswords, OnContent = "", OffContent = "", MinWidth = 40 };
    var passwords = new StackPanel { Spacing = 20 };
    string Profile() => ((CoreBrowserProfile)profile.SelectedItem).Id;
    async Task Run(Func<Task> work)
    { try { notice.Text = "Working…"; await work(); notice.Text = "Done."; Render(); } catch (Exception e) when (e is not OutOfMemoryException) { notice.Text = e.Message; } }
    Button Action(string text, Func<Task> action) { var b = new Button { Content = text, VerticalAlignment = VerticalAlignment.Center }; b.Click += async (_, _) => await Run(action); return b; }
    async Task<bool> Confirm(string title, string detail)
    { return await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = title, Content = new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, MaxWidth = 440 }, PrimaryButtonText = "Continue", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary; }
    keep.Toggled += async (_, _) =>
    {
      if (keep.IsOn == browser.Privacy.Read().PersistSignIns) return;
      if (!await Confirm("Change saved sign-ins?", "Close this app's browser tabs to change whether their sign-ins persist. Sessions and chats stay open.")) { keep.IsOn = browser.Privacy.Read().PersistSignIns; return; }
      await Run(() => browser.SetBrowserPrivacyAsync(browser.Privacy.Read() with { PersistSignIns = keep.IsOn }));
    };
    save.Toggled += (_, _) => browser.Privacy.Save(browser.Privacy.Read() with { SavePasswords = save.IsOn });
    var import = Action("Import…", async () =>
    {
      var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".json"); WinRT.Interop.InitializeWithWindow.Initialize(picker, browser.PrivacyWindowHandle);
      var file = await picker.PickSingleFileAsync(); if (file is null) return;
      if ((await file.GetBasicPropertiesAsync()).Size > 2 * 1024 * 1024) throw new ArgumentException("Import up to 2 MB of cookies.");
      var json = await BrowserPrivacy.ReadCookieFileAsync(file.Path); var rows = BrowserPrivacy.Cookies(json);
      if (!await Confirm("Import " + rows.Length + " cookies?", "This signs this profile into sites from the exported JSON file. Matching cookies are replaced. Direct access to another browser's encrypted store is not used.")) return;
      await browser.ImportBrowserCookiesAsync(Profile(), json);
    });
    var clear = Action("Clear…", async () => { if (await Confirm("Sign out of this profile?", "Remove cookies and website storage in this profile. Saved passwords remain in their protected store.")) await browser.ClearBrowserSignInsAsync(Profile()); });
    var clearWords = new TextBlock { Text = "Clear…" };
    clearWords.SetResourceReference(TextBlock.ForegroundProperty, "DeckStatusFailedBrush");
    clear.Content = clearWords; AutomationProperties.SetName(clear, "Clear sign-ins and website data");
    SignInRows = (FrameworkElement[])[
      SettingsPanel.SettingRow("Keep sign-ins between app launches", "", keep),
      SettingsPanel.SettingRow("Offer to save passwords", "", save),
      SettingsPanel.SettingRow("Profile", "The profile the rows below and the saved passwords belong to.", profile),
      SettingsPanel.SettingRow("What this profile keeps", "", Action("Show…", async () => { var count = await browser.BrowserCookieCountAsync(Profile()); await new ContentDialog { XamlRoot = XamlRoot, Title = "What this profile keeps", Content = count + " cookies · " + browser.Privacy.Logins(Profile()).Count + " saved passwords. Site storage, cache and sign-ins belong to this profile. Passwords are kept separately in Windows Credential Manager.", CloseButtonText = "Done" }.ShowAsync(); })),
      SettingsPanel.SettingRow("Import cookies", "Import an exported cookie JSON array with name, value, domain, path, secure, httpOnly, expires and sameSite fields. Other browsers protect their own live stores with their own Windows keys.", import),
      SettingsPanel.SettingRow("Clear sign-ins and website data", "", clear)
    ];
    Children.Add(SettingsPanel.GroupTitle("Saved passwords")); Children.Add(passwords); Children.Add(notice);
    profile.SelectionChanged += (_, _) => Render(); Render();
    void Render()
    {
      var rows = new List<FrameworkElement>();
      foreach (var row in browser.Privacy.Logins(Profile()))
      {
        var menu = new MenuFlyout();
        void Item(string text, Func<Task> work) { var item = new MenuFlyoutItem { Text = text }; item.Click += async (_, _) => await Run(work); menu.Items.Add(item); }
        Item("Copy password", () => browser.CopyBrowserPasswordAsync(Profile(), row.Id));
        Item("Fill selected tab", () => browser.FillBrowserPasswordAsync(Profile(), row.Id));
        Item("Forget…", async () => { if (await Confirm("Forget this password?", row.Origin + " · " + row.Username)) await browser.Privacy.ForgetAsync(Profile(), row.Id); });
        var more = new Button { Content = new DeckIcon { Glyph = "", FontSize = 13 }, Flyout = menu, Padding = new Thickness(6), MinWidth = 28, MinHeight = 28 };
        more.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
        AutomationProperties.SetName(more, "Password actions");
        rows.Add(SettingsPanel.SettingRow(row.Origin + " · " + row.Username, "", more));
      }
      if (rows.Count == 0) rows.Add(SettingsPanel.SettingRow("No passwords saved in this profile", "", null));
      rows.Add(SettingsPanel.SettingRow("Save a password", "", Action("Save…", async () =>
      {
        var site = new TextBox { Header = "Website", PlaceholderText = "https://example.com" }; var user = new TextBox { Header = "Username" }; var password = new PasswordBox { Header = "Password", PasswordRevealMode = PasswordRevealMode.Hidden, MaxLength = 2560 };
        var body = new StackPanel { Spacing = 12, Children = { site, user, password } };
        if (await new ContentDialog { XamlRoot = XamlRoot, Title = "Save a password", Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel" }.ShowAsync() == ContentDialogResult.Primary) await browser.Privacy.SaveLoginAsync(Profile(), site.Text, user.Text, password.Password);
      })));
      rows.Add(SettingsPanel.SettingRow("Forget all saved passwords", "", Action("Forget all…", async () => { if (await Confirm("Forget saved passwords?", "Delete this profile's saved passwords from Windows Credential Manager. This cannot be undone.")) await browser.Privacy.ForgetAsync(Profile()); })));
      passwords.Children.Clear(); passwords.Children.Add(SettingsPanel.GroupRows(rows));
    }
  }
}
