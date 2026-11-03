using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private BrowserPrivacy? privacy;
  public BrowserPrivacy Privacy => privacy ??= new(new JsonStateStore<BrowserPrivacyPreferences>(root, "browser-privacy"), new JsonStateStore<BrowserLogins>(root, "browser-logins"), new WindowsCredentialStore(root), TerminalDeck.Core.Brand.Name + "/" + root.NamespaceId + "/browser-password/");
  private readonly SemaphoreSlim passwordPrompt = new(1, 1);
  public nint PrivacyWindowHandle { get; set; }
  private async Task<T> WithPrivacyProfileAsync<T>(string id, Func<CoreWebView2Profile, Task<T>> work)
  {
    _ = Core.Read().Profiles.Single(p => p.Id == id);
    var tab = tabs.FirstOrDefault(t => t.Profile.Id == id && !t.Isolated);
    if (tab is not null) return await work(tab.View.CoreWebView2.Profile);
    await storage.EnsureProfileAsync(id, default);
    var options = new BrowserSurfaceOptions(Guid.NewGuid().ToString("N"), id, false, null);
    var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, storage.PathFor(options), new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = true });
    var view = new WebView2 { Width = 1, Height = 1, Opacity = 0, IsHitTestVisible = false, IsTabStop = false }; SurfaceHost.Children.Add(view);
    try
    {
      var controller = environment.CreateCoreWebView2ControllerOptions(); controller.ProfileName = "Deck"; controller.IsInPrivateModeEnabled = !Privacy.Read().PersistSignIns;
      await view.EnsureCoreWebView2Async(environment, controller); return await work(view.CoreWebView2.Profile);
    }
    finally { SurfaceHost.Children.Remove(view); view.Close(); }
  }
  public async Task<int> BrowserCookieCountAsync(string profile) => await WithPrivacyProfileAsync(profile, async p => (await p.CookieManager.GetCookiesAsync("")).Count);
  public async Task ClearBrowserSignInsAsync(string profile) => await WithPrivacyProfileAsync(profile, async p => { await p.ClearBrowsingDataAsync(CoreWebView2BrowsingDataKinds.AllSite); return true; });
  public async Task<int> ImportBrowserCookiesAsync(string profile, string json)
  {
    var imported = BrowserPrivacy.Cookies(json);
    return await WithPrivacyProfileAsync(profile, p =>
    {
      var prepared = imported.Select(r => { var c = p.CookieManager.CreateCookie(r.Name, r.Value, r.Domain, r.Path); c.IsSecure = r.Secure; c.IsHttpOnly = r.HttpOnly; c.SameSite = Enum.Parse<CoreWebView2CookieSameSiteKind>(r.SameSite); if (r.Expires is { } at) c.Expires = at; return c; }).ToArray();
      foreach (var cookie in prepared) p.CookieManager.AddOrUpdateCookie(cookie);
      return Task.FromResult(prepared.Length);
    });
  }
  public async ValueTask ResetBrowserPreferencesAsync(CancellationToken ct = default)
  { ct.ThrowIfCancellationRequested(); await SetBrowserPrivacyAsync(new()); ct.ThrowIfCancellationRequested(); await Core.SetStartUrlAsync("about:blank", ct); }
  public async Task SetBrowserPrivacyAsync(BrowserPrivacyPreferences preferences)
  {
    var old = Privacy.Read(); if (old.PersistSignIns == preferences.PersistSignIns) { Privacy.Save(preferences); return; }
    // InPrivate is selected when the real controller is created. Recreate only
    // browser views; terminal/chat owners and their input are untouched.
    var ids = Core.Read().Tabs.Select(t => t.Id).ToArray();
    foreach (var id in ids) await Core.CloseAsync(id);
    Privacy.Save(preferences);
  }
  public async Task CopyBrowserPasswordAsync(string profile, string id)
  {
    var row = Privacy.Logins(profile).Single(r => r.Id == id); var password = await Privacy.PasswordForUseAsync(id, profile, row.Origin);
    var data = new DataPackage(); data.SetText(password); Clipboard.SetContent(data);
  }
  public async Task FillBrowserPasswordAsync(string profile, string id)
  {
    var tab = selected is { Isolated: false } chosen && chosen.Profile.Id == profile ? chosen : throw new InvalidOperationException("Select a shared browser tab in this profile first.");
    var row = Privacy.Logins(profile).Single(r => r.Id == id); var origin = BrowserPrivacy.Origin(tab.View.CoreWebView2.Source);
    var password = await Privacy.PasswordForUseAsync(id, profile, origin);
    if (selected != tab || tab.Isolated || BrowserPrivacy.Origin(tab.View.CoreWebView2.Source) != origin) throw new InvalidOperationException("The selected site changed before filling. Nothing was submitted.");
    var expression = "(()=>{if(location.origin!==" + JsonSerializer.Serialize(origin) + ")return false;const visible=e=>!e.disabled&&!e.readOnly&&e.getClientRects().length&&getComputedStyle(e).visibility!=='hidden'&&getComputedStyle(e).opacity!=='0';const p=[...document.querySelectorAll('input[type=password]')].find(visible);if(!p)return false;const u=[...(p.closest('form')||document).querySelectorAll('input[autocomplete=username],input[type=email],input[name*=user i]')].find(visible);const set=(e,v)=>{Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}))};if(u)set(u," + JsonSerializer.Serialize(row.Username) + ");set(p," + JsonSerializer.Serialize(password) + ");return true})()";
    if (await tab.View.CoreWebView2.ExecuteScriptAsync(expression) != "true") throw new InvalidOperationException("This site has no visible password field. Nothing was submitted.");
  }
  private async Task InstallPasswordCaptureAsync(BrowserTab tab)
  {
    tab.View.CoreWebView2.Settings.IsPasswordAutosaveEnabled = false;
    tab.View.CoreWebView2.Settings.IsGeneralAutofillEnabled = false;
    if (tab.Isolated || !Privacy.Read().PersistSignIns) return;
    var nonce = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24));
    var capture = """
      (()=>{
        if(window!==top)return;
        const send=chrome.webview.postMessage.bind(chrome.webview), proof='__DECK_PROOF__';
        let gesture=0;
        for(const kind of ['pointerdown','keydown'])document.addEventListener(kind,e=>{if(e.isTrusted)gesture=Date.now()},true);
        document.addEventListener('submit',e=>{
          if(!e.isTrusted||Date.now()-gesture>2000||!document.hasFocus())return;
          const form=e.target;if(!(form instanceof HTMLFormElement))return;
          const passwords=[...form.querySelectorAll('input[type=password]')].filter(input=>input.value&&!input.disabled);
          if(passwords.length!==1)return;
          const username=form.querySelector('input[autocomplete=username],input[type=email],input[name*=user i]');
          send({kind:'deck-save-login',proof,origin:location.origin,username:username?.value||'',password:passwords[0].value});
          gesture=0;
        },true);
      })()
      """;
    await tab.View.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(capture.Replace("__DECK_PROOF__", nonce, StringComparison.Ordinal));
    tab.View.CoreWebView2.WebMessageReceived += async (_, args) =>
    {
      if (!Privacy.Read().SavePasswords || !Privacy.Read().PersistSignIns || tab.Isolated || tab.AutomationOrigin is not null || Core.Driver(tab.Id) is not null || args.Source != tab.View.CoreWebView2.Source || !await passwordPrompt.WaitAsync(0)) return;
      try
      {
        if (args.WebMessageAsJson.Length > 10000) return; using var doc = JsonDocument.Parse(args.WebMessageAsJson); var value = doc.RootElement;
        if (!BrowserPrivacy.ValidCapture(value, nonce, args.Source, tab.Isolated || !Privacy.Read().PersistSignIns,
          tab.AutomationOrigin is not null || Core.Driver(tab.Id) is not null)) return;
        var username = value.GetProperty("username").GetString() ?? ""; var password = value.GetProperty("password").GetString() ?? "";
        if (username.Length > 1024 || username.Any(char.IsControl) || System.Text.Encoding.UTF8.GetByteCount(password) is < 1 or > 2560 || password.Contains('\0') || !tabs.Contains(tab)) return;
        var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Save this password?", Content = new TextBlock { Text = BrowserPrivacy.Origin(args.Source) + "\n" + username + "\nStored privately in Windows Credential Manager for this browser profile.", TextWrapping = TextWrapping.Wrap, MaxWidth = 420 }, PrimaryButtonText = "Save", CloseButtonText = "Not now" };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await Privacy.SaveLoginAsync(tab.Profile.Id, args.Source, username, password);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { SetTabStatus(tab, "The password was not saved. Manage saved passwords in Browser settings."); }
      finally { passwordPrompt.Release(); }
    };
  }
}
