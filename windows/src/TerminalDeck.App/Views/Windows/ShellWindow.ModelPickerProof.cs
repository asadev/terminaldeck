using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RunModelPickerProofAsync(string output)
  {
    var root = AppDataRoot.Explicit(Path.Combine(dataRoot.DirectoryPath, "model-picker-fixture"));
    var provider = new PickerProofAccount();
    var accounts = new AccountService(new JsonStateStore<AccountState>(root, "accounts"), [provider]);
    var account = await accounts.CreateAsync("claude", "Synthetic catalogue");
    await accounts.RefreshAsync(account.Id);
    await accounts.WarmModelsAsync();
    var before = provider.Reads;
    var processes = new WindowsChatProcessKeeper(root, Runtime.KeeperExecutable, Path.Combine(root.DirectoryPath, "tools"), KeeperCredentials.GetOrCreate(root));
    await using var chats = new ChatSessions(new ChatHistory(root), processes, accounts);
    var chat = await chats.CreateAsync("claude", root.DirectoryPath, account.Id, new(Model: "opus-fixture", Effort: "high"));
    var page = new ChatPage(chats, chat.Definition.Id, WindowHandle, accountModels: accounts);
    ShowProofChat(page);
    var passed = new List<string>(); var failed = new List<string>();
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    try
    {
      await Task.Delay(120); Root.UpdateLayout();
      var chip = ProofTree(page).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "chat.model");
      var timer = Stopwatch.StartNew();
      ((IInvokeProvider)new ButtonAutomationPeer(chip).GetPattern(PatternInterface.Invoke)).Invoke();
      var elapsed = timer.Elapsed.TotalMilliseconds;
      var menu = page.ModelMenuForProof;
      Check("Picker opens synchronously from the startup cache", menu is not null && elapsed < 100);
      var choices = menu!.Items.OfType<ToggleMenuFlyoutItem>().ToArray();
      Check("Full cached list has no Default choice", choices.Length == 3 && choices.All(c => !c.Text.Contains("Default", StringComparison.OrdinalIgnoreCase)));
      Check("Current model name and menu selection agree", page.Model.SelectedModelName == "Claude Opus fixture" && choices.Single(c => c.IsChecked).Text == page.Model.SelectedModelName);
      Check("Opening the picker does not probe or authenticate", provider.Reads == before);
      menu.Hide();
      // Repeated opens reuse the same account catalogue without a spinner.
      ((IInvokeProvider)new ButtonAutomationPeer(chip).GetPattern(PatternInterface.Invoke)).Invoke();
      Check("Repeated open has the complete cached list", page.ModelMenuForProof!.Items.OfType<ToggleMenuFlyoutItem>().Count() == 3 && provider.Reads == before);
      page.ModelMenuForProof.Hide();
    }
    finally { HideProofChat(); await page.DisposeAsync(); }
    File.WriteAllText(Path.Combine(output, "model-picker-proof.json"), JsonSerializer.Serialize(new { passed, failed, fixture = "Synthetic catalogue only; no AI turn, sign-in, CLI or network calls" }));
    if (failed.Count > 0) throw new InvalidOperationException("Native model-picker proof failed: " + string.Join(", ", failed));
  }
  private sealed class PickerProofAccount : IAccountProvider
  {
    public string Provider => "claude";
    public int Reads;
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(true, "fixture@example.test"));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => throw new InvalidOperationException("Synthetic proof cannot sign in.");
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct)
    {
      Reads++;
      return ValueTask.FromResult<IReadOnlyList<ProviderModel>>([
        new("opus-fixture", "Claude Opus fixture", 200000, IsDefault: true),
        new("sonnet-fixture", "Claude Sonnet fixture", 200000),
        new("haiku-fixture", "Claude Haiku fixture", 200000)]);
    }
  }
}
