using System.Text;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

public sealed record ApiAccountDraft(string Kind, string? BaseUrl = null, string? WorkspaceId = null, string? Model = null);

// Add / Edit API connection and key / Check key / Remove for API-key accounts.
// The key is written only to the secure store and is never returned or logged.
public sealed class ApiAccountService(AccountService accounts, AccountCredentials credentials, AppDataRoot root, HttpClient? http = null)
{
  private readonly HttpClient client = http ?? new HttpClient();
  public ApiConnection? Read(string id) { var row = accounts.Get(id); return row.Authentication == AccountAuthentication.ApiKey ? ApiAccountFiles.Read(root, row.HomeId) : null; }

  public async ValueTask<AccountProfile> AddAsync(string provider, string name, ApiAccountDraft draft, string? key, CancellationToken ct = default)
  {
    var connection = Connection(draft); ApiKinds.Validate(provider, connection);
    if (connection.RequiresKey) ApiKinds.ValidateKey(key ?? "");
    Guard(name, draft, key);
    var row = await accounts.CreateAsync(provider, name, AccountAuthentication.ApiKey, cancellationToken: ct);
    try { return await SaveAsync(row, connection, key, ct); }
    catch { await accounts.DeleteAsync(row.Id, _ => false, CancellationToken.None); try { ApiAccountFiles.Delete(root, row.HomeId); } catch (IOException) { } throw; }
  }

  // An empty key keeps the saved one; only a changed connection or key is written.
  public async ValueTask<AccountProfile> UpdateAsync(string id, ApiAccountDraft draft, string? key, CancellationToken ct = default)
  {
    var row = accounts.Get(id);
    if (row.Authentication != AccountAuthentication.ApiKey) throw new ArgumentException("Choose an API-key account.");
    var previous = ApiAccountFiles.Read(root, row.HomeId);
    var connection = Connection(draft) with { CredentialReference = previous?.CredentialReference };
    ApiKinds.Validate(row.Provider, connection);
    if (!string.IsNullOrEmpty(key)) ApiKinds.ValidateKey(key);
    else if (connection.RequiresKey && connection.CredentialReference is null) throw new ArgumentException("Paste the key for this account.");
    Guard(row.Name, draft, key);
    return await SaveAsync(row, connection, key, ct);
  }

  public async ValueTask<ApiConnection> CheckAsync(string id, CancellationToken ct = default)
  {
    var row = accounts.Get(id);
    var connection = ApiAccountFiles.Read(root, row.HomeId) ?? throw new InvalidOperationException("This API account has no saved connection. Edit it first.");
    string? key = null;
    if (connection.RequiresKey)
    {
      var bytes = connection.CredentialReference is null ? null : await credentials.ReadAsync(connection.CredentialReference, ct);
      if (bytes is null) return Store(row, connection with { CheckState = "needs-key", CheckDetail = null, CheckedAt = DateTimeOffset.UtcNow });
      key = Encoding.UTF8.GetString(bytes);
    }
    var (state, detail) = await ApiKeyCheck.RunAsync(row.Provider, connection, key, client, ct);
    return Store(row, connection with { CheckState = state, CheckDetail = detail, CheckedAt = DateTimeOffset.UtcNow });
  }

  public async ValueTask RemoveAsync(string id, Func<string, bool> inUse, CancellationToken ct = default)
  {
    var row = accounts.Get(id);
    var connection = row.Authentication == AccountAuthentication.ApiKey ? ApiAccountFiles.Read(root, row.HomeId) : null;
    await accounts.DeleteAsync(id, inUse, ct);
    if (connection?.CredentialReference is { } reference) await credentials.DeleteAsync(reference, ct);
    if (row.Authentication == AccountAuthentication.ApiKey) ApiAccountFiles.Delete(root, row.HomeId);
  }

  public static string Status(ApiConnection? connection) => connection is null ? "Needs key" : connection.CheckState switch
  {
    "valid" => "Valid",
    "invalid" => "Invalid key" + (connection.CheckDetail is { Length: > 0 } d ? ": " + d : ""),
    "no-access" => "No access" + (connection.CheckDetail is { Length: > 0 } a ? ": " + a : ""),
    "unavailable" => "Couldn’t check" + (connection.CheckDetail is { Length: > 0 } u ? ": " + u : ""),
    "needs-key" => "Needs key",
    _ => connection.Configured ? "Not checked" : "Needs key"
  };

  private async ValueTask<AccountProfile> SaveAsync(AccountProfile row, ApiConnection connection, string? key, CancellationToken ct)
  {
    var oldReference = connection.CredentialReference;
    if (!string.IsNullOrEmpty(key) && connection.RequiresKey)
      connection = connection with { CredentialReference = await credentials.StoreAsync(Encoding.UTF8.GetBytes(key), ct), CheckState = null, CheckDetail = null, CheckedAt = null };
    if (!connection.RequiresKey) connection = connection with { CredentialReference = null };
    ApiAccountFiles.Write(root, row.HomeId, connection);
    if (oldReference is not null && oldReference != connection.CredentialReference) await credentials.DeleteAsync(oldReference, ct);
    return await accounts.SetApiStateAsync(row.Id, connection.Configured, connection.CredentialReference, ct);
  }
  private ApiConnection Store(AccountProfile row, ApiConnection connection) { ApiAccountFiles.Write(root, row.HomeId, connection); return connection; }
  private static ApiConnection Connection(ApiAccountDraft draft) => new(draft.Kind, Blank(draft.BaseUrl), Blank(draft.WorkspaceId), Blank(draft.Model));
  private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
  private static void Guard(string name, ApiAccountDraft draft, string? key)
  {
    if (string.IsNullOrEmpty(key) || key.Length < 8) return;
    if (name.Contains(key) || (draft.BaseUrl ?? "").Contains(key) || (draft.WorkspaceId ?? "").Contains(key) || (draft.Model ?? "").Contains(key))
      throw new ArgumentException("Keep the API key in the secure key field only.");
  }
}
