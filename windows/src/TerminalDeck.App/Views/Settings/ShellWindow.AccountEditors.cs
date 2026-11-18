using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private async Task RenewCodingAccountAsync(string accountId, string folder, CancellationToken ct = default)
  {
    ct.ThrowIfCancellationRequested();
    if (Runtime.Accounts.Get(accountId).Authentication == TerminalDeck.Core.Accounts.AccountAuthentication.ApiKey)
      await OpenApiAccountAsync(accountId);
    else await Runtime.Accounts.SignInAsync(accountId, folder, ct);
  }

  private async Task OpenAddAccountAsync(string provider)
  {
    await ReadyAccountEditorAsync();
    await settings.ShowAddAccountAsync(provider);
  }

  private async Task OpenApiAccountAsync(string accountId)
  {
    var account = Runtime.Accounts.Get(accountId);
    await ReadyAccountEditorAsync();
    await settings.ShowApiAccountAsync(account.Provider, account.Id);
  }

  private async Task ReadyAccountEditorAsync()
  {
    await OpenSettingsAsync("coding-ais");
    if (settings.XamlRoot is not null) return;
    var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    void Loaded(object sender, RoutedEventArgs args) => ready.TrySetResult();
    settings.Loaded += Loaded;
    try
    {
      if (settings.XamlRoot is null) await ready.Task.WaitAsync(TimeSpan.FromSeconds(10));
    }
    finally { settings.Loaded -= Loaded; }
  }
}
