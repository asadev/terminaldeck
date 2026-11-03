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
    if (connection is null) return (environment, []);
    string? key = null;
    if (connection.RequiresKey)
    {
      var bytes = connection.CredentialReference is null ? null
        : new AccountCredentials(new WindowsCredentialStore(root), root).ReadAsync(connection.CredentialReference).AsTask().GetAwaiter().GetResult();
      key = bytes is null ? null : Encoding.UTF8.GetString(bytes);
    }
    // A missing key starts the AI without one, so its own "not signed in" reply shows
    // and the account card says Needs key; a status probe never fails on it.
    if (connection.RequiresKey && key is null) return (environment, []);
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
