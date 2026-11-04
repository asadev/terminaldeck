using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public async Task<SessionRecord> StartAsync(string provider, string folder, string? accountId = null, string? title = null, string? shell = null)
  {
    if (!Directory.Exists(folder)) throw new ArgumentException("Choose an existing folder.");
    if (TerminalDeck.Core.Sessions.CustomTerminalProviders.IsKey(provider)) return await StartCustomTerminalAsync(provider, folder, title);
    AccountProfile? account = null;
    if (provider != "shell")
    {
      account = accountId is null ? Accounts.Preferred(provider, folder) : Accounts.Get(accountId);
      if (account is null) throw new InvalidOperationException("Sign in to this AI under Coding AIs first.");
      if (account.Provider != provider) throw new ArgumentException("Choose an account for the selected AI.");
      account = await Accounts.RequireSignedInAsync(account.Id);
    }
    // Resolve the default here so desktop, phone and web starts share the same
    // choice. Explicit choices and saved sessions keep their original shell.
    shell = provider == "shell" ? shell ?? General.Read().TerminalShell ?? TerminalShells.WindowsPowerShell : null;
    var response = await Keeper.CreateAsync(new(Guid.NewGuid().ToString(), provider, folder, title ?? (provider == "shell" ? TerminalDeck.Core.Sessions.TerminalShells.Label(shell) : provider), account?.Id, account?.HomeId, Shell: shell));
    await RefreshSessionsAsync(); return response.Session ?? throw new IOException("The session could not start.");
  }
}
