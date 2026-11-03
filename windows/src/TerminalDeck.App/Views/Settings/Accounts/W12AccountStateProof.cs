using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task VerifyW12AccountReadStatesAsync(string output, Action<string, bool> check)
  {
    var path = Path.Combine(dataRoot.DirectoryPath, "state", "accounts.json");
    var original = await File.ReadAllBytesAsync(path);
    try
    {
      // Only the opt-in fixture's isolated store is changed; bytes are restored even on failure.
      await File.WriteAllTextAsync(path, "not-json");
      await settingsPanel!.SelectAsync("coding-ais");
      check("Account read error stays in its owning card with retry", SettingsTree(settings).OfType<TextBlock>().Any(t => t.Text == "Couldn’t read accounts") && SettingsTree(settings).OfType<Button>().Any(b => b.Content as string == "Try again"));
      await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, "accounts-read-error-dark.png"));
      await File.WriteAllBytesAsync(path, JsonSerializer.SerializeToUtf8Bytes(new AccountState(1, [], [], [])));
      await settingsPanel.SelectAsync("coding-ais");
      check("No accounts yet is an explicit empty state", SettingsTree(settings).OfType<TextBlock>().Any(t => t.Text == "No accounts yet"));
      await CaptureSettingsAsync(settingsWindowRoot!, Path.Combine(output, "accounts-empty-dark.png"));
    }
    finally { await File.WriteAllBytesAsync(path, original); }
    await settingsPanel!.SelectAsync("coding-ais");
    check("Account retry retains every original profile", Runtime.Accounts.List().SequenceEqual(JsonSerializer.Deserialize<AccountState>(original)!.Accounts));
    var account = Runtime.Accounts.List("codex").First();
    InvokeW12(CallerCard(account.Name), "Account actions"); await Task.Delay(100);
    var renameItem = VisualTreeHelper.GetOpenPopupsForXamlRoot(settings.XamlRoot).SelectMany(p => SettingsTree(p.Child)).OfType<MenuFlyoutItem>().Single(m => m.Text == "Rename…");
    if (FrameworkElementAutomationPeer.CreatePeerForElement(renameItem)?.GetPattern(PatternInterface.Invoke) is not IInvokeProvider rename) throw new InvalidOperationException("Account rename cannot be invoked.");
    rename.Invoke(); await Task.Delay(100);
    var renameDialog = CallerDialog(); SettingsTree(renameDialog).OfType<TextBox>().Single().Text = "Audit Codex";
    InvokeW12(renameDialog, "Save"); await Task.Delay(150);
    check("Account rename preserves its identity and isolated home", Runtime.Accounts.Get(account.Id) == (account with { Name = "Audit Codex" }));
    var renamedBytes = await File.ReadAllBytesAsync(path);
    try
    {
      var renamed = JsonSerializer.Deserialize<AccountState>(renamedBytes)!;
      var signedOut = renamed with { Accounts = renamed.Accounts.Select(a => a.Id == account.Id ? a with { Email = "prior-signin@example.invalid", SignedIn = false } : a).ToArray() };
      await File.WriteAllBytesAsync(path, JsonSerializer.SerializeToUtf8Bytes(signedOut));
      await settingsPanel.SelectAsync("coding-ais");
      check("Previously used signed-out account offers Sign in again", SettingsTree(settings).OfType<Button>().Any(b => b.Content as string == "Sign in again"));
    }
    finally { await File.WriteAllBytesAsync(path, renamedBytes); }
    await settingsPanel.SelectAsync("coding-ais");

  }
}
