using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

// The API accounts' narrow door for keys travel (the Mac's BackendAPIAccountService cloudAccounts/cloudKey/cloudCreate/
// cloudRemove/cloudReplaceKey). Ids in Cloud are the Mac's form `api-key-<24 hex>`; an account of this PC (32 hex) is
// named in Cloud by its first 24 characters, and one that arrives is made here as those 24 plus eight zeros, so both
// directions name one account with one id and no map is needed. Kinds are spoken in the Mac's words; an empty Base URL
// is the kind's default address, as the Mac writes it.
internal sealed class ApiAccountCloudDoor(ApiAccountService service, AccountService accounts, AccountCredentials credentials, AppDataRoot root,
  Func<string, bool> inUse) : ICloudKeysApiOwner
{
  private static readonly (string Windows, string Mac)[] Kinds =
    [(ApiKinds.Anthropic, "anthropic"), (ApiKinds.AnthropicToken, "anthropicToken"), (ApiKinds.OpenAi, "openai"), (ApiKinds.Compatible, "compatible"),
     (ApiKinds.CompatibleLocal, "compatibleLocal"), (ApiKinds.Gemini, "gemini")];
  private static string? MacKind(string kind) => Kinds.FirstOrDefault(k => k.Windows == kind).Mac;
  private static string? WindowsKind(string kind) => Kinds.FirstOrDefault(k => k.Mac == kind).Windows;
  private readonly SemaphoreSlim turn = new(1, 1);

  public static string? CloudId(string localId) => Guid.TryParseExact(localId, "N", out _) && localId == localId.ToLowerInvariant() ? "api-key-" + localId[..24] : null;
  private AccountProfile? Find(string cloudId) => CloudKeysTravel.IsApiAccountId(cloudId)
    ? accounts.List().FirstOrDefault(a => a.Authentication == AccountAuthentication.ApiKey && CloudId(a.Id) == cloudId) : null;

  private CloudKeysApiAccount? Read(AccountProfile row)
  {
    if (row.Authentication != AccountAuthentication.ApiKey || CloudId(row.Id) is not { } id) return null;
    ApiConnection? connection;
    try { connection = ApiAccountFiles.Read(root, row.HomeId); } catch (IOException) { return null; }
    if (connection is null || MacKind(connection.Kind) is not { } kind) return null;
    return new(id, row.Name, row.Provider, kind, connection.BaseUrl ?? CloudKeysApiValue.DefaultBaseUrl(kind), connection.Model, connection.WorkspaceId);
  }
  public Task<IReadOnlyList<CloudKeysApiAccount>> CloudAccountsAsync() =>
    Task.FromResult<IReadOnlyList<CloudKeysApiAccount>>(accounts.List().Select(Read).OfType<CloudKeysApiAccount>().ToArray());

  private async Task<string?> KeyAsync(AccountProfile row)
  {
    ApiConnection? connection;
    try { connection = ApiAccountFiles.Read(root, row.HomeId); } catch (IOException) { throw new CloudFailure("secrets_locked"); }
    if (connection?.CredentialReference is not { } reference) return null;
    byte[]? bytes;
    try { bytes = await credentials.ReadAsync(reference); } catch (Exception) { throw new CloudFailure("secrets_locked"); }
    if (bytes is null) return null;
    try { return Encoding.UTF8.GetString(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  public async Task<string?> CloudKeyAsync(string accountId) => Find(accountId) is { } row ? await KeyAsync(row) : null;

  public async Task CloudCreateAsync(string accountId, string name, CloudKeysApiValue value)
  {
    if (!CloudKeysTravel.IsApiAccountId(accountId) || WindowsKind(value.Kind) is not { } kind || kind == ApiKinds.CompatibleLocal
      || !CloudKeysApiValue.Providers.TryGetValue(value.Kind, out var provider) || provider != value.Provider) throw new CloudFailure("invalid_request");
    await turn.WaitAsync();
    try
    {
      if (Find(accountId) is not null) throw new CloudFailure("version_changed");
      var connection = new ApiConnection(kind, value.BaseUrl.Length == 0 || value.BaseUrl == CloudKeysApiValue.DefaultBaseUrl(value.Kind) ? null : value.BaseUrl,
        value.WorkspaceId, value.Model);
      ApiKinds.Validate(provider, connection); ApiKinds.ValidateKey(value.Key);
      var row = await accounts.CloudCreateAsync(accountId[8..] + "00000000", provider, name);
      string? reference = null;
      try
      {
        var bytes = Encoding.UTF8.GetBytes(value.Key);
        try { reference = await credentials.StoreAsync(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
        ApiAccountFiles.Write(root, row.HomeId, connection with { CredentialReference = reference });
        await accounts.SetApiStateAsync(row.Id, true, reference);
      }
      catch
      {
        // Undo on any failure: nothing half made stays.
        try { await accounts.DeleteAsync(row.Id, _ => false); } catch (Exception) { }
        try { ApiAccountFiles.Delete(root, row.HomeId); } catch (Exception) { }
        if (reference is not null) try { await credentials.DeleteAsync(reference); } catch (Exception) { }
        throw;
      }
    }
    finally { turn.Release(); }
  }

  public async Task<bool> CloudRemoveAsync(string accountId, string expectingKey)
  {
    await turn.WaitAsync();
    try
    {
      if (Find(accountId) is not { } row) return true;
      if (await KeyAsync(row) != expectingKey) return false;
      // A session running as it keeps it (the removal is closed as not applied).
      if (inUse(row.Id)) return false;
      await service.RemoveHereAsync(row.Id, inUse);
      return Find(accountId) is null;
    }
    finally { turn.Release(); }
  }

  public async Task<bool> CloudReplaceKeyAsync(string accountId, string key, string expectingKey)
  {
    await turn.WaitAsync();
    try
    {
      if (Find(accountId) is not { } row || ApiAccountFiles.Read(root, row.HomeId) is not { RequiresKey: true } connection) return false;
      if (await KeyAsync(row) != expectingKey || inUse(row.Id)) return false;
      ApiKinds.ValidateKey(key);
      var bytes = Encoding.UTF8.GetBytes(key);
      string reference;
      try { reference = await credentials.StoreAsync(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
      ApiAccountFiles.Write(root, row.HomeId, connection with { CredentialReference = reference, CheckState = null, CheckDetail = null, CheckedAt = null });
      await accounts.SetApiStateAsync(row.Id, true, reference);
      if (connection.CredentialReference is { } old) try { await credentials.DeleteAsync(old); } catch (Exception) { }
      return await KeyAsync(row) == key;
    }
    finally { turn.Release(); }
  }
}
