using System.Text;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Accounts;

// Adds an API-key account's key and endpoint to its own launch only. A
// subscription account (no api.json in its home) is returned unchanged.
public static class WindowsApiAccountLaunch
{
  public static (IReadOnlyDictionary<string, string> Environment, string[] Arguments) Apply(AppDataRoot root, string provider, string homeId,
    IReadOnlyDictionary<string, string> environment)
  {
    if (provider is not ("claude" or "codex" or "gemini") || homeId == AccountHomes.ExistingLogin) return (environment, []);
    var connection = ApiAccountFiles.Read(root, homeId);
    if (connection is null)
    {
      if (new JsonStateStore<AccountState>(root, "accounts").Load()?.Accounts.Any(a => a.HomeId == homeId && a.Authentication == AccountAuthentication.ApiKey) == true)
        throw new ApiAccountUnavailableException("This API account has no saved connection. Edit API key to set it up again.");
      return (environment, []);
    }
    if (!ApiAccountService.CanUse(connection)) throw new ApiAccountUnavailableException();
    string? key = null;
    if (connection.RequiresKey)
    {
      byte[]? bytes;
      try
      {
        bytes = connection.CredentialReference is null ? null
          : new AccountCredentials(new WindowsCredentialStore(root), root).ReadAsync(connection.CredentialReference).AsTask().GetAwaiter().GetResult();
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException)
      { throw new ApiAccountUnavailableException("Windows could not open this account’s saved API key. Edit API key to replace it, then check it again."); }
      key = bytes is null ? null : Encoding.UTF8.GetString(bytes);
    }
    // Never fall through to a subscription login when this account's key is absent.
    if (connection.RequiresKey && key is null) throw new ApiAccountUnavailableException();
    var (variables, arguments) = ApiAccountEnvironment.Build(provider, connection, key);
    var result = new Dictionary<string, string>(environment, StringComparer.OrdinalIgnoreCase);
    foreach (var (name, value) in variables) result[name] = value;
    return (result, arguments);
  }
  public static string[] Arguments(AppDataRoot root, string provider, string homeId)
  {
    if (provider != "codex" || homeId == AccountHomes.ExistingLogin || !Guid.TryParseExact(homeId, "N", out _)) return [];
    return ApiAccountFiles.Read(root, homeId) is { Kind: ApiKinds.Compatible or ApiKinds.CompatibleLocal } connection
      ? ApiAccountEnvironment.Build(provider, connection, connection.RequiresKey ? "unused" : null).Arguments : [];
  }
}
