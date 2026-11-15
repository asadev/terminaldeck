using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Core.Cloud
{
  // Server sign-ins travel with saved passwords (the Mac's BackendCloudSecretsServerStore / ServerValue / ServerDefinition
  // and its delete-rule binding): one record per saved server sign-in, under the server's id, carrying the server itself
  // (only what a person types when adding one) so another device keeps the sign-in under the same server. Never a
  // permission of one device: look-only stays on where it arrives, AI app access and folders are decided on each device.
  // This PC keeps passwords only (a server that signs in with a key file keeps that file on the PC that has it): a
  // record carrying a private key cannot be placed here and is refused (noted), never half applied.

  /// The server a sign-in belongs to, exactly as the Mac encodes it (absent members left out).
  public sealed record CloudSecretsServerDefinition(string Name, string Address, int Port, string Username, string? ProjectId, bool? LookOnly,
    string? HostKeyAlgorithm, string? HostKeyFingerprint)
  {
    public CloudJson ToJson() => CloudJson.Obj(("name", CloudJson.From(Name)), ("address", CloudJson.From(Address)), ("port", CloudJson.From(Port)),
      ("username", CloudJson.From(Username)), ("projectId", ProjectId is { } p ? CloudJson.From(p) : null), ("lookOnly", LookOnly is { } l ? CloudJson.From(l) : null),
      ("hostKeyAlgorithm", HostKeyAlgorithm is { } a ? CloudJson.From(a) : null), ("hostKeyFingerprint", HostKeyFingerprint is { } f ? CloudJson.From(f) : null));
    public static CloudSecretsServerDefinition FromJson(CloudJson v) => v is CloudJson.Object o
      ? new(CloudFields.Text(o, "name"), CloudFields.Text(o, "address"), (int)CloudFields.Integer(o, "port"), CloudFields.Text(o, "username"), CloudFields.OptionalText(o, "projectId"),
        o["lookOnly"] switch { null => null, CloudJson.Bool b => b.Value, _ => throw new CloudFailure("invalid_request") },
        CloudFields.OptionalText(o, "hostKeyAlgorithm"), CloudFields.OptionalText(o, "hostKeyFingerprint"))
      : throw new CloudFailure("invalid_request");
    /// The Mac's own rules for what a person types (a definition that breaks them is left out, or refused on arrival).
    public bool Valid
    {
      get
      {
        string[] texts = [Name, Address, Username, ProjectId ?? "", HostKeyAlgorithm ?? "", HostKeyFingerprint ?? ""];
        if (texts.Any(t => t.Any(c => c < 32 || c == 127))) return false;
        var address = Address.Trim();
        if (address.Length is 0 or > 255 || address != Address || address.Any(char.IsWhiteSpace) || address.Contains('@') || address.Contains('/')
          || address.StartsWith('[') && address.EndsWith(']')) return false;
        if (Username.Length is 0 or > 64 || Name.Length is 0 or > 64 || Port is < 1 or > 65535 || LookOnly == false) return false;
        if ((HostKeyFingerprint is null) != (HostKeyAlgorithm is null)) return false;
        if (HostKeyFingerprint is { } f && !(f.StartsWith("SHA256:", StringComparison.Ordinal) && f.Length <= 128)) return false;
        if (HostKeyAlgorithm is { Length: > 64 }) return false;
        return ProjectId is null || ProjectId.Length is > 0 and <= 200;
      }
    }
  }

  /// One server sign-in's value (BackendCloudSecretsServerValue): kind "password" (password) or "key" (privateKey,
  /// passphrase?), and its server.
  public sealed record CloudSecretsServerValue(string Kind, string? Password, string? PrivateKey, string? Passphrase, CloudSecretsServerDefinition? Server)
  {
    public CloudJson ToJson() => CloudJson.Obj(("kind", CloudJson.From(Kind)), ("password", Password is { } p ? CloudJson.From(p) : null),
      ("privateKey", PrivateKey is { } k ? CloudJson.From(k) : null), ("passphrase", Passphrase is { } s ? CloudJson.From(s) : null), ("server", Server?.ToJson()));
    /// Strict, as the Mac decodes it: the value written back must be exactly what arrived (no unknown member).
    public static CloudSecretsServerValue Decode(CloudSecretRecord record)
    {
      if (record.Payload is not CloudJson.Object o) throw new CloudFailure("invalid_request");
      var value = new CloudSecretsServerValue(CloudFields.Text(o, "kind"), CloudFields.OptionalText(o, "password"), CloudFields.OptionalText(o, "privateKey"),
        CloudFields.OptionalText(o, "passphrase"), o["server"] is { } s and not CloudJson.Null ? CloudSecretsServerDefinition.FromJson(s) : null);
      if (!CloudCanonical.Encode(value.ToJson()).AsSpan().SequenceEqual(CloudCanonical.Encode(record.Payload))) throw new CloudFailure("invalid_request");
      if (value.Server is { Valid: false }) throw new CloudFailure("invalid_request");
      var password = value.Kind == "password" && value.Password is { Length: > 0 } && value.PrivateKey is null && value.Passphrase is null;
      var key = value.Kind == "key" && value.PrivateKey is { Length: > 0 } && value.Password is null;
      if (!password && !key) throw new CloudFailure("invalid_request");
      return value;
    }
  }

  /// Saved server sign-ins on this PC as one saved-passwords source (`servers`, domain `server`). Server ids of this PC
  /// are 32 hex characters; a server that arrived from a Mac keeps its Mac id in the Cloud through a small id-only map
  /// beside the saved-passwords state (no name, no value), so both sides name one server with one record.
  public sealed class CloudSecretsServerStore(ServerStore servers, string idMapFile) : ICloudSecretsStore
  {
    public string SourceId => "servers";
    public string InventoryRow => "I14";
    public string Domain => CloudSecretsDomains.Server;
    private Dictionary<string, string> Map()
    {
      try { return File.Exists(idMapFile) && CloudJson.Parse(File.ReadAllBytes(idMapFile)) is CloudJson.Object o ? o.Members.Where(m => m.Value.AsString is not null).ToDictionary(m => m.Key, m => m.Value.AsString!) : []; }
      catch (CloudFailure) { return []; }
    }
    private void Remember(string local, string cloud)
    {
      if (local == cloud) return;
      var map = Map(); map[local] = cloud;
      new CloudFileSlot(idMapFile).Write(CloudCanonical.Encode(CloudJson.Obj(map.OrderBy(m => m.Key, StringComparer.Ordinal).Select(m => (m.Key, (CloudJson?)CloudJson.From(m.Value))).ToArray())));
    }
    /// The Cloud's id for a server of this PC, and the reverse (a Mac id is this PC's id without its dashes).
    private string CloudId(string local, Dictionary<string, string> map) => map.GetValueOrDefault(local, local);
    private static string? LocalId(string cloud) { var id = cloud.Replace("-", "", StringComparison.Ordinal).ToLowerInvariant(); return id.Length == 32 && id.All(char.IsAsciiHexDigit) ? id : null; }

    public static CloudSecretsServerDefinition? Definition(SavedServer server)
    {
      var candidate = new CloudSecretsServerDefinition(server.Name, server.Host, server.Port, server.User, server.ProjectId, server.Access.LookOnly ? true : null, null, null);
      return candidate.Valid ? candidate : null;
    }
    public async Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync()
    {
      var map = Map();
      var output = new List<CloudSecretRecord>();
      foreach (var (server, password) in (await servers.CloudPasswordsAsync()).OrderBy(s => CloudId(s.Server.Id, map), StringComparer.Ordinal))
        output.Add(new(SourceId, CloudId(server.Id, map), Domain, new CloudSecretsServerValue("password", password, null, null, Definition(server)).ToJson()));
      return output;
    }
    public Task ValidateAsync(CloudSecretRecord record) { _ = CloudSecretsServerValue.Decode(record); return Task.CompletedTask; }
    public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
    {
      var value = CloudSecretsServerValue.Decode(record);
      // A key sign-in has no place on this PC (its file stays on the device that has it): refused, nothing written.
      if (value.Kind != "password" || LocalId(record.RecordId) is not { } local) throw new CloudFailure("invalid_request");
      if (!await servers.CloudHasServerAsync(local))
      {
        // The server itself is not on this PC: with its definition it is added first, under the same id, add-only,
        // look only; without one the sign-in has nowhere to go and waits.
        if (value.Server is not { } d) throw new CloudFailure("unavailable");
        await servers.CloudAddIfAbsentAsync(local, new ServerDraft(d.Name, d.Address, d.Port, d.Username, ServerAuthentication.Password, d.ProjectId));
      }
      Remember(local, record.RecordId);
      return await servers.CloudMergePasswordAsync(local, value.Password!);
    }
    public async Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
    {
      if (LocalId(record.RecordId) is not { } local) return false;
      var saved = await servers.CloudPasswordAsync(local);
      return outcome == CloudApplyStatus.KeptBoth ? saved is not null : saved == CloudSecretsServerValue.Decode(record).Password;
    }
    /// The delete rule's compare-and-remove: the sign-in goes only while it is still exactly the removed one; the server
    /// row stays (its own list decides about it).
    public async Task<bool> RemoveAsync(CloudSecretRecord record)
    {
      if (LocalId(record.RecordId) is not { } local) return false;
      return await servers.CloudForgetPasswordIfSameAsync(local, CloudSecretsServerValue.Decode(record).Password ?? "");
    }
    public static string Name(CloudSecretRecord record)
    {
      try { return CloudSecretsServerValue.Decode(record).Server?.Name ?? "Server sign-in"; } catch (Exception) { return "Server sign-in"; }
    }
  }
}

namespace TerminalDeck.Core.Servers
{
  // The Servers owner's own narrow doors for saved passwords (no second password store): read the saved sign-ins, add a
  // server that arrived (add-only, look only), keep an existing DIFFERENT password, forget one only while unchanged.
  public sealed partial class ServerStore
  {
    public async Task<IReadOnlyList<(SavedServer Server, string Password)>> CloudPasswordsAsync()
    {
      var output = new List<(SavedServer, string)>();
      foreach (var server in List().Where(s => s.Authentication == ServerAuthentication.Password && s.SshAlias is null))
        if (await CloudPasswordAsync(server.Id) is { } password) output.Add((server, password));
      return output;
    }
    public async Task<string?> CloudPasswordAsync(string id)
    {
      var bytes = await secrets.ReadAsync(PasswordName(id));
      if (bytes is null) return null;
      try { return Encoding.UTF8.GetString(bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    public Task<bool> CloudHasServerAsync(string id) { ServerValidation.Id(id); return Task.FromResult(List().Any(s => s.Id == id)); }
    public async Task CloudAddIfAbsentAsync(string id, ServerDraft draft)
    {
      ServerValidation.Id(id); ServerValidation.Draft(draft);
      using var lease = await store.AcquireWriteAsync(CancellationToken.None);
      var list = List();
      if (list.Any(s => s.Id == id)) return;
      store.Save([.. list, new SavedServer(id, draft.Name.Trim(), draft.Host, draft.Port, draft.User, draft.Authentication, ServerAccess.Default, draft.ProjectId)]);
    }
    public async Task<TerminalDeck.Core.Cloud.CloudApplyStatus> CloudMergePasswordAsync(string id, string password)
    {
      if (password.Length is < 1 or > 2560 || password.Contains('\n') || password.Contains('\r')) throw new TerminalDeck.Core.Cloud.CloudFailure("invalid_request");
      using var lease = await store.AcquireWriteAsync(CancellationToken.None);
      var server = Get(id);
      if (await CloudPasswordAsync(id) is { } existing) return existing == password ? TerminalDeck.Core.Cloud.CloudApplyStatus.AlreadyPresent : TerminalDeck.Core.Cloud.CloudApplyStatus.KeptBoth;
      if (server.Authentication != ServerAuthentication.Password || server.SshAlias is not null) return TerminalDeck.Core.Cloud.CloudApplyStatus.KeptBoth;
      var bytes = Encoding.UTF8.GetBytes(password);
      try { await secrets.WriteAsync(PasswordName(id), bytes); } finally { CryptographicOperations.ZeroMemory(bytes); }
      if (await CloudPasswordAsync(id) != password) throw new TerminalDeck.Core.Cloud.CloudFailure("checksum_mismatch");
      return TerminalDeck.Core.Cloud.CloudApplyStatus.Applied;
    }
    public async Task<bool> CloudForgetPasswordIfSameAsync(string id, string password)
    {
      using var lease = await store.AcquireWriteAsync(CancellationToken.None);
      if (await CloudPasswordAsync(id) != password) return false;
      await secrets.DeleteAsync(PasswordName(id));
      return await CloudPasswordAsync(id) is null;
    }
  }
}
