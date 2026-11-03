using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Browser;
using CoreBrowserProfile = TerminalDeck.Core.Browser.BrowserProfile;
using Windows.Storage.Pickers;
using Windows.System;

namespace TerminalDeck.App.Views.Settings;

public sealed class BrowserPrivacyPage : StackPanel
{
  public BrowserPrivacyPage(BrowserPane browser)
  {
    Spacing = 12;
    var notice = new TextBlock { TextWrapping = TextWrapping.Wrap };
    var profile = new ComboBox { Header = "Profile", ItemsSource = browser.Core.Read().Profiles, DisplayMemberPath = "Name", SelectedItem = browser.Core.Read().Profiles.First(p => p.Id == browser.Core.Read().ActiveProfileId), HorizontalAlignment = HorizontalAlignment.Stretch };
    var keep = new ToggleSwitch { Header = "Keep sign-ins between app launches", IsOn = browser.Privacy.Read().PersistSignIns };
    var save = new ToggleSwitch { Header = "Offer to save passwords", IsOn = browser.Privacy.Read().SavePasswords };
    var logins = new StackPanel { Spacing = 8 };
    string Profile() => ((CoreBrowserProfile)profile.SelectedItem).Id;
    async Task Run(Func<Task> work)
    { try { notice.Text = "Working…"; await work(); notice.Text = "Done."; Render(); } catch (Exception e) when (e is not OutOfMemoryException) { notice.Text = e.Message; } }
    Button Action(string text, Func<Task> action) { var b = new Button { Content = text }; b.Click += async (_, _) => await Run(action); return b; }
    async Task<bool> Confirm(string title, string detail)
    { return await new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = title, Content = new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, MaxWidth = 440 }, PrimaryButtonText = "Continue", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }.ShowAsync() == ContentDialogResult.Primary; }
    keep.Toggled += async (_, _) =>
    {
      if (keep.IsOn == browser.Privacy.Read().PersistSignIns) return;
      if (!await Confirm("Change saved sign-ins?", "Close this app's browser tabs to change whether their sign-ins persist. Sessions and chats stay open.")) { keep.IsOn = browser.Privacy.Read().PersistSignIns; return; }
      await Run(() => browser.SetBrowserPrivacyAsync(browser.Privacy.Read() with { PersistSignIns = keep.IsOn }));
    };
    save.Toggled += (_, _) => browser.Privacy.Save(browser.Privacy.Read() with { SavePasswords = save.IsOn });
    Children.Add(keep); Children.Add(save); Children.Add(profile);
    var cookies = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    cookies.Children.Add(Action("Show what is kept", async () => { var count = await browser.BrowserCookieCountAsync(Profile()); await new ContentDialog { XamlRoot = XamlRoot, Title = "What this profile keeps", Content = count + " cookies · " + browser.Privacy.Logins(Profile()).Count + " saved passwords. Site storage, cache and sign-ins belong to this profile. Passwords are kept separately in Windows Credential Manager.", CloseButtonText = "Done" }.ShowAsync(); }));
    cookies.Children.Add(Action("Import cookies…", async () =>
    {
      var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".json"); WinRT.Interop.InitializeWithWindow.Initialize(picker, browser.PrivacyWindowHandle);
      var file = await picker.PickSingleFileAsync(); if (file is null) return;
      if ((await file.GetBasicPropertiesAsync()).Size > 2 * 1024 * 1024) throw new ArgumentException("Import up to 2 MB of cookies.");
      var json = await BrowserPrivacy.ReadCookieFileAsync(file.Path); var rows = BrowserPrivacy.Cookies(json);
      if (!await Confirm("Import " + rows.Length + " cookies?", "This signs this profile into sites from the exported JSON file. Matching cookies are replaced. Direct access to another browser's encrypted store is not used.")) return;
      await browser.ImportBrowserCookiesAsync(Profile(), json);
    }));
    Children.Add(cookies);
    Children.Add(new TextBlock { Text = "Import an exported cookie JSON array with name, value, domain, path, secure, httpOnly, expires and sameSite fields. Other browsers protect their own live stores with their own Windows keys.", TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = .7 });
    Children.Add(Action("Clear sign-ins and website data…", async () => { if (await Confirm("Sign out of this profile?", "Remove cookies and website storage in this profile. Saved passwords remain in their protected store.")) await browser.ClearBrowserSignInsAsync(Profile()); }));
    Children.Add(new TextBlock { Text = "Saved passwords", FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); Children.Add(logins);
    Children.Add(Action("Save a password…", async () =>
    {
      var site = new TextBox { Header = "Website", PlaceholderText = "https://example.com" }; var user = new TextBox { Header = "Username" }; var password = new PasswordBox { Header = "Password", PasswordRevealMode = PasswordRevealMode.Hidden, MaxLength = 2560 };
      var body = new StackPanel { Spacing = 12, Children = { site, user, password } };
      if (await new ContentDialog { XamlRoot = XamlRoot, Title = "Save a password", Content = body, PrimaryButtonText = "Save", CloseButtonText = "Cancel" }.ShowAsync() == ContentDialogResult.Primary) await browser.Privacy.SaveLoginAsync(Profile(), site.Text, user.Text, password.Password);
    }));
    Children.Add(Action("Forget all saved passwords…", async () => { if (await Confirm("Forget saved passwords?", "Delete this profile's saved passwords from Windows Credential Manager. This cannot be undone.")) await browser.Privacy.ForgetAsync(Profile()); }));
    Children.Add(notice); profile.SelectionChanged += (_, _) => Render(); Render();
    void Render()
    {
      logins.Children.Clear();
      foreach (var row in browser.Privacy.Logins(Profile()))
      {
        var content = new StackPanel { Spacing = 4 }; content.Children.Add(new TextBlock { Text = row.Origin + " · " + row.Username, TextWrapping = TextWrapping.Wrap });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        buttons.Children.Add(Action("Copy password", () => browser.CopyBrowserPasswordAsync(Profile(), row.Id)));
        buttons.Children.Add(Action("Fill selected tab", () => browser.FillBrowserPasswordAsync(Profile(), row.Id)));
        buttons.Children.Add(Action("Forget", async () => { if (await Confirm("Forget this password?", row.Origin + " · " + row.Username)) await browser.Privacy.ForgetAsync(Profile(), row.Id); }));
        content.Children.Add(buttons); logins.Children.Add(content);
      }
      if (logins.Children.Count == 0) logins.Children.Add(new TextBlock { Text = "No passwords saved in this profile.", Opacity = .7 });
    }
  }
}
