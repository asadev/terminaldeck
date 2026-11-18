using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Windows.Storage.Pickers;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private bool PersonCanAnswer(BrowserTab tab) => pageSlots.TryGetValue(tab.Id, out var slot) && IsDrawn(slot) && WindowActivity.IsActive(slot.XamlRoot);
  private void RequestUnavailable(BrowserTab tab, string reason)
  { tab.PageRequestNote = reason; tab.RequestAttention.TrySetResult(); SetTabStatus(tab, reason); ShellChanged?.Invoke(); }
  private async Task InstallPageRequestsAsync(BrowserTab tab)
  {
    var web = tab.View.CoreWebView2;
    web.Settings.AreDefaultScriptDialogsEnabled = false;
    web.ScriptDialogOpening += async (_, args) =>
    {
      var deferral = args.GetDeferral();
      BrowserQuestion? question = null;
      try
      {
        question = QueuePageQuestion(tab, "This page has a question."); if (!await question.Review.Task) return;
        var prompt = args.Kind == CoreWebView2ScriptDialogKind.Prompt ? new TextBox { Text = args.DefaultText, MaxLength = 10000 } : null;
        var body = new StackPanel { Spacing = 12 }; body.Children.Add(new TextBlock { Text = args.Message, MaxWidth = 480, MaxHeight = 300, TextWrapping = TextWrapping.Wrap }); if (prompt is not null) body.Children.Add(prompt);
        var confirm = args.Kind != CoreWebView2ScriptDialogKind.Alert;
        question.Dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = new Uri(args.Uri).Host + " asks", Content = body, PrimaryButtonText = "OK", CloseButtonText = confirm ? "Cancel" : "" };
        var answer = await question.Dialog.ShowAsync();
        if (answer == ContentDialogResult.Primary) { if (prompt is not null) args.ResultText = prompt.Text; args.Accept(); }
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { RequestUnavailable(tab, "The page’s question could not be shown. Close another dialog and try that step again."); }
      finally { if (question is not null) FinishPageQuestion(tab, question); deferral.Complete(); }
    };
    web.PermissionRequested += async (_, args) =>
    {
      args.State = CoreWebView2PermissionState.Deny; args.SavesInProfile = false; var deferral = args.GetDeferral(); BrowserQuestion? question = null;
      try
      {
        question = QueuePageQuestion(tab, $"This page wants to use {args.PermissionKind}."); if (!await question.Review.Task) return;
        question.Dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Website permission", Content = $"{new Uri(args.Uri).Host} wants to use {args.PermissionKind}. Allow it for this request?", PrimaryButtonText = "Allow", CloseButtonText = "Don’t allow" };
        var answer = await question.Dialog.ShowAsync();
        args.State = answer == ContentDialogResult.Primary ? CoreWebView2PermissionState.Allow : CoreWebView2PermissionState.Deny;
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { RequestUnavailable(tab, "The website permission could not be shown. Close another dialog and try again."); }
      finally { if (question is not null) FinishPageQuestion(tab, question); deferral.Complete(); }
    };
    web.BasicAuthenticationRequested += async (_, args) =>
    {
      var deferral = args.GetDeferral(); args.Cancel = true; BrowserQuestion? question = null;
      try
      {
        question = QueuePageQuestion(tab, "This page needs a username and password."); if (!await question.Review.Task) return;
        var username = new TextBox { Header = "Username" }; var password = new PasswordBox { Header = "Password" }; var form = new StackPanel { Spacing = 12 }; form.Children.Add(username); form.Children.Add(password);
        question.Dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Sign in to " + new Uri(args.Uri).Host, Content = form, PrimaryButtonText = "Sign in", CloseButtonText = "Cancel" };
        var answer = await question.Dialog.ShowAsync();
        if (answer == ContentDialogResult.Primary) { args.Response.UserName = username.Text; args.Response.Password = password.Password; args.Cancel = false; }
        password.Password = "";
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { RequestUnavailable(tab, "The site’s sign-in window could not be shown. Close another dialog and reload."); }
      finally { if (question is not null) FinishPageQuestion(tab, question); deferral.Complete(); }
    };
    web.ClientCertificateRequested += (_, args) => { args.Handled = true; args.Cancel = true; RequestUnavailable(tab, "This site requires a client certificate. Choosing a certificate is not supported in the built-in browser; open the site in your browser."); };
    web.GetDevToolsProtocolEventReceiver("Page.fileChooserOpened").DevToolsProtocolEventReceived += async (_, args) =>
    {
      await GuardAsync(async () =>
      {
        using var parsed = JsonDocument.Parse(args.ParameterObjectAsJson); var request = parsed.RootElement;
        var node = request.GetProperty("backendNodeId").GetInt32();
        var question = QueuePageQuestion(tab, "This page asks you to choose a file.");
        try
        {
        if (!await question.Review.Task) { await tab.Model.CommandAsync("DOM.setFileInputFiles", new { backendNodeId = node, files = Array.Empty<string>() }); return; }
        var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, Microsoft.UI.Win32Interop.GetWindowFromWindowId(RootFor(tab).ContentIslandEnvironment.AppWindowId)); picker.FileTypeFilter.Add("*");
        string[] paths;
        if (request.TryGetProperty("mode", out var mode) && mode.GetString() == "selectMultiple")
        {
          var picking = picker.PickMultipleFilesAsync(); question.CancelNative = picking.Cancel; paths = (await picking).Select(picked => picked.Path).ToArray();
        }
        else
        {
          var picking = picker.PickSingleFileAsync(); question.CancelNative = picking.Cancel; var single = await picking; paths = single is null ? [] : [single.Path];
        }
        await tab.Model.CommandAsync("DOM.setFileInputFiles", new { backendNodeId = node, files = paths });
        }
        catch (OperationCanceledException) { if (tabs.Contains(tab)) await tab.Model.CommandAsync("DOM.setFileInputFiles", new { backendNodeId = node, files = Array.Empty<string>() }); }
        finally { FinishPageQuestion(tab, question); }
      }, tab);
    };
    await web.AddScriptToExecuteOnDocumentCreatedAsync("""
      (() => {
        window.__tdPageParked = true;
        document.addEventListener('pointerdown', event => { if (event.isTrusted && !window.__tdPageParked) chrome.webview.postMessage({kind:'td-page-request', clear:true}); }, true);
        const open = window.open.bind(window);
        window.open = (url, ...rest) => {
          if (url) {
            try {
              const address = new URL(url, location.href);
              if (!['http:', 'https:'].includes(address.protocol) && address.href !== 'about:blank') {
                chrome.webview.postMessage({kind:'td-page-request', message:'This page requested a popup using an unsupported address. Open the site in your browser to continue.'}); return null;
              }
            } catch { chrome.webview.postMessage({kind:'td-page-request', message:'This page requested a popup with an invalid address.'}); return null; }
          }
          return open(url, ...rest);
        };
        if (!navigator.credentials) return;
        for (const name of ['get', 'create']) {
          const native = navigator.credentials[name].bind(navigator.credentials);
          navigator.credentials[name] = async options => {
            if (!options?.publicKey) return native(options);
            const report = message => chrome.webview.postMessage({kind:'td-page-request', message});
            if (document.visibilityState !== 'visible' || window.__tdPageParked) {
              const message = 'A passkey needs you in this tab. Open the tab and try signing in again.';
              report(message); throw new DOMException(message, 'NotAllowedError');
            }
            try { return await native(options); }
            catch (error) { report('The passkey request did not finish (' + (error.name || 'unavailable') + '). If Windows did not show a passkey window, this WebView2 runtime cannot complete it. Open the site in your browser.'); throw error; }
          };
        }
      })();
      """);
  }
  private async Task EnablePageRequestsAsync(BrowserTab tab)
  {
    await tab.Model.CommandAsync("Page.enable", new { });
    await tab.Model.CommandAsync("Page.setInterceptFileChooserDialog", new { enabled = true });
  }
}
