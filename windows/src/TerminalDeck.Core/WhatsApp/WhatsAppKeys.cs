using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.WhatsApp;

// WhatsApp agents' keys (DESIGN-WHATSAPP.md section 5), a port of the Mac's BackendWhatsAppKeys.swift: each key is one of
// the keys that travel with saved passwords, store "whatsapp" (domain whatsapp), one record per WhatsApp agent. On this
// PC a key lives only in its own Windows Credential Manager entry; it is never written to a plain file, a log line, an
// error, a test output or a picture.

/// Where this computer keeps the keys. Ready false = not open yet (the store then says "locked", never "none").
public interface IWhatsAppKeyKeeping
{
  Task<bool> ReadyAsync();
  Task<IReadOnlyList<string>> IdsAsync();
  Task<string?> KeyAsync(string id);
  Task SetKeyAsync(string key, string id);
  /// Sets only when the entry is absent (an arrival never overwrites his own).
  Task<bool> InsertIfAbsentAsync(string key, string id);
  /// Removes only while the key is still `expecting` (the delete rule's compare-and-remove); true when gone.
  Task<bool> RemoveAsync(string id, string? expecting);
}

/// The Credential Manager keeper (the Mac's Keychain keeper): one entry per WhatsApp agent,
/// "&lt;app&gt;/&lt;namespace&gt;/whatsapp/&lt;id&gt;", plus one entry holding only the list of ids (Credential Manager cannot be
/// listed by prefix through ISecretStore). Never asks the person.
public sealed class WhatsAppCredentialKeeper(ISecretStore secrets, AppDataRoot root) : IWhatsAppKeyKeeping
{
  private readonly SemaphoreSlim gate = new(1, 1);
  private string Name(string id) => WhatsAppAgentIds.Valid(id) ? $"{Brand.Name}/{root.NamespaceId}/whatsapp/{id}" : throw WhatsAppProblem.NotFound;
  private string IndexName => $"{Brand.Name}/{root.NamespaceId}/whatsapp-index";

  public Task<bool> ReadyAsync() => Task.FromResult(true);

  private async Task<List<string>> IndexAsync()
  {
    var bytes = await secrets.ReadAsync(IndexName);
    if (bytes is null) return [];
    try { return (JsonSerializer.Deserialize<List<string>>(bytes) ?? []).Where(WhatsAppAgentIds.Valid).Distinct().ToList(); }
    catch (JsonException) { return []; }
  }
  private async Task SaveIndexAsync(List<string> ids)
  {
    if (ids.Count == 0) { await secrets.DeleteAsync(IndexName); return; }
    await secrets.WriteAsync(IndexName, JsonSerializer.SerializeToUtf8Bytes(ids.Order(StringComparer.Ordinal).ToList()));
  }
  public async Task<IReadOnlyList<string>> IdsAsync()
  {
    await gate.WaitAsync();
    try { return (await IndexAsync()).Order(StringComparer.Ordinal).ToArray(); }
    catch (IOException) { throw new CloudFailure("secrets_locked"); }
    finally { gate.Release(); }
  }
  public async Task<string?> KeyAsync(string id)
  {
    try { return await secrets.ReadAsync(Name(id)) is { } bytes ? Encoding.UTF8.GetString(bytes) : null; }
    catch (IOException) { throw new CloudFailure("secrets_locked"); }
  }
  public async Task SetKeyAsync(string key, string id)
  {
    if (!WhatsAppAgentIds.Valid(id) || !WhatsAppAgentIds.PlausibleKey(key)) throw WhatsAppProblem.KeyRefused;
    await gate.WaitAsync();
    try
    {
      await secrets.WriteAsync(Name(id), Encoding.UTF8.GetBytes(key));
      var ids = await IndexAsync();
      if (!ids.Contains(id)) { ids.Add(id); await SaveIndexAsync(ids); }
    }
    catch (Exception error) when (error is IOException or ArgumentException)
    {
      throw new WhatsAppProblem("Windows did not let Terminal Deck keep this key in the Credential Manager.");
    }
    finally { gate.Release(); }
  }
  public async Task<bool> InsertIfAbsentAsync(string key, string id)
  {
    if (await KeyAsync(id) is not null) return false;
    await SetKeyAsync(key, id); return true;
  }
  public async Task<bool> RemoveAsync(string id, string? expecting)
  {
    if (await KeyAsync(id) is not { } current) return true;
    if (expecting is not null && current != expecting) return false;
    await gate.WaitAsync();
    try
    {
      await secrets.DeleteAsync(Name(id));
      var ids = await IndexAsync();
      if (ids.Remove(id)) await SaveIndexAsync(ids);
      return true;
    }
    catch (IOException) { throw new CloudFailure("unavailable"); }
    finally { gate.Release(); }
  }
}

/// A keeper in memory: tests and fixtures only.
public sealed class WhatsAppKeysInMemory(IReadOnlyDictionary<string, string>? keys = null, bool ready = true) : IWhatsAppKeyKeeping
{
  private readonly Lock gate = new();
  private readonly Dictionary<string, string> keys = keys?.ToDictionary() ?? [];
  private bool isReady = ready;
  public void SetReady(bool value) { lock (gate) isReady = value; }
  private void Check() { if (!isReady) throw new CloudFailure("secrets_locked"); }
  public Task<bool> ReadyAsync() { lock (gate) return Task.FromResult(isReady); }
  public Task<IReadOnlyList<string>> IdsAsync() { lock (gate) { Check(); return Task.FromResult<IReadOnlyList<string>>(keys.Keys.Order(StringComparer.Ordinal).ToArray()); } }
  public Task<string?> KeyAsync(string id) { lock (gate) { Check(); return Task.FromResult(keys.GetValueOrDefault(id)); } }
  public Task SetKeyAsync(string key, string id) { lock (gate) { Check(); keys[id] = key; } return Task.CompletedTask; }
  public Task<bool> InsertIfAbsentAsync(string key, string id)
  {
    lock (gate) { Check(); if (keys.ContainsKey(id)) return Task.FromResult(false); keys[id] = key; return Task.FromResult(true); }
  }
  public Task<bool> RemoveAsync(string id, string? expecting)
  {
    lock (gate)
    {
      if (!keys.TryGetValue(id, out var current)) return Task.FromResult(true);
      if (expecting is not null && current != expecting) return Task.FromResult(false);
      keys.Remove(id); return Task.FromResult(true);
    }
  }
}

public static class WhatsAppAgentIds
{
  /// The key's fingerprint in the synced record: the first 16 hex characters of its SHA-256. Not the key.
  public static string Fingerprint(string key) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..16];
  /// "wa-" and 32 lowercase hex characters: made by the app, never from the key.
  public static string Make() => "wa-" + Guid.NewGuid().ToString("N");
  public static bool Valid(string id) =>
    id.StartsWith("wa-", StringComparison.Ordinal) && id.Length is > 3 and <= 64 && id[3..].All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
  /// One line of printable characters, at most 4096: anything else is not a key WhatsApp gave.
  public static bool PlausibleKey(string key) => key.Length is > 0 and <= 4096 && key.All(c => c > ' ' && c < '\u007f');
}

/// What travels for one WhatsApp agent: its key and his name for it (the Mac's WhatsAppKeyValue). Never the creator, the
/// offset or a message.
public sealed record WhatsAppKeyValue(string Key, string Name)
{
  public CloudJson ToJson() => CloudJson.Obj(("key", CloudJson.From(Key)), ("name", CloudJson.From(Name)));
  public override string ToString() => $"WhatsAppKeyValue {{ Name = {Name} }}";

  public static WhatsAppKeyValue Decode(CloudSecretRecord record, string sourceId)
  {
    if (record.SourceId != sourceId || record.Domain != CloudSecretsDomains.WhatsApp || !WhatsAppAgentIds.Valid(record.RecordId)
      || record.Payload is not CloudJson.Object o) throw new CloudFailure("invalid_request");
    var value = new WhatsAppKeyValue(CloudFields.Text(o, "key"), CloudFields.Text(o, "name"));
    if (!WhatsAppAgentIds.PlausibleKey(value.Key) || value.Name.Length == 0 || CloudKeysTravel.Length(value.Name) > WhatsAppAgentsLimits.MaximumNameLength
      || value.Name.Any(c => c is '\n' or '\r' or '\u0085' or '\u2028' or '\u2029')) throw new CloudFailure("invalid_request");
    return value;
  }
}

/// The saved-passwords store "whatsapp", a port of the Mac's BackendWhatsAppKeysStore in the style of CloudKeysApiStore:
/// - not ready = "locked" (an empty list would read as every key gone);
/// - capture resends the last exchanged record while the value is unchanged (no echo brings an old key back);
/// - an arrival is taken when absent; the same key is one item; a different key replaces his only while his is unchanged
///   since the last exchange (he pressed Replace key on another computer), else his stays (kept both);
/// - a removal goes through the delete owner: Bin 30 days, Put back, everywhere; compare-and-remove;
/// - no value ever appears in a name, an error or the shelf list.
public sealed class WhatsAppKeysStore(IWhatsAppKeyKeeping keeper, Func<string, Task<string?>>? names = null, string sourceId = WhatsAppKeysStore.Source) : ICloudSecretsStore
{
  public const string Source = "whatsapp";
  public string SourceId { get; } = sourceId;
  public string InventoryRow => "I15";
  public string Domain => CloudSecretsDomains.WhatsApp;
  private readonly Func<string, Task<string?>> names = names ?? (_ => Task.FromResult<string?>(null));
  private CloudSecretsDeleteOwner? exchanged;

  private WhatsAppKeyValue? TryValue(CloudSecretRecord? record) { if (record is null) return null; try { return WhatsAppKeyValue.Decode(record, SourceId); } catch (CloudFailure) { return null; } }

  public async Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync()
  {
    if (!await keeper.ReadyAsync()) throw new CloudFailure("secrets_locked");
    var output = new List<CloudSecretRecord>();
    foreach (var id in await keeper.IdsAsync())
    {
      if (!WhatsAppAgentIds.Valid(id) || await keeper.KeyAsync(id) is not { } key) continue;
      if (exchanged?.LastExchanged(id) is { } last && TryValue(last) is { } before && before.Key == key) { output.Add(last); continue; }
      var name = await names(id) is { Length: > 0 } n ? CloudKeysTravel.Prefix(n, WhatsAppAgentsLimits.MaximumNameLength) : WhatsAppAgentsLimits.DefaultName([]);
      output.Add(new CloudSecretRecord(SourceId, id, Domain, new WhatsAppKeyValue(key, name).ToJson()));
    }
    return output;
  }
  public Task ValidateAsync(CloudSecretRecord record) { _ = WhatsAppKeyValue.Decode(record, SourceId); return Task.CompletedTask; }

  public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
  {
    var incoming = WhatsAppKeyValue.Decode(record, SourceId);
    if (!await keeper.ReadyAsync()) throw new CloudFailure("secrets_locked");
    try
    {
      if (await keeper.KeyAsync(record.RecordId) is not { } mine)
        return await keeper.InsertIfAbsentAsync(incoming.Key, record.RecordId) ? CloudApplyStatus.Applied : CloudApplyStatus.KeptBoth;
      if (mine == incoming.Key) return CloudApplyStatus.AlreadyPresent;
      // Replace key pressed on another computer: his is still the value last exchanged here, so the newer one replaces it
      // in place. Both changed: his stays.
      if (TryValue(exchanged?.LastExchanged(record.RecordId)) is { } before && before.Key == mine)
      {
        await keeper.SetKeyAsync(incoming.Key, record.RecordId);
        return CloudApplyStatus.Applied;
      }
      return CloudApplyStatus.KeptBoth;
    }
    catch (CloudFailure f) when (f.Code == "secrets_locked") { throw; }
    catch (Exception) { throw new CloudFailure("unavailable"); }
  }
  public async Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
  {
    var incoming = WhatsAppKeyValue.Decode(record, SourceId);
    string? mine;
    try { mine = await keeper.KeyAsync(record.RecordId); } catch (Exception) { throw new CloudFailure("unavailable"); }
    return outcome == CloudApplyStatus.KeptBoth ? mine is not null : mine == incoming.Key;
  }
  public async Task<bool> RemoveAsync(CloudSecretRecord record)
  {
    var incoming = WhatsAppKeyValue.Decode(record, SourceId);
    try { return await keeper.RemoveAsync(record.RecordId, incoming.Key); }
    catch (CloudFailure f) when (f.Code == "secrets_locked") { throw; }
    catch (Exception) { throw new CloudFailure("unavailable"); }
  }
  public static string Name(CloudSecretRecord record)
  {
    try { return "WhatsApp · " + WhatsAppKeyValue.Decode(record, record.SourceId).Name; } catch (CloudFailure) { return "WhatsApp · WhatsApp agent"; }
  }
  /// The value alone (the key) decides "the same removed value".
  public static bool SameValue(CloudSecretRecord one, CloudSecretRecord other)
  {
    if (one.RecordId != other.RecordId) return false;
    try { return WhatsAppKeyValue.Decode(one, one.SourceId).Key == WhatsAppKeyValue.Decode(other, other.SourceId).Key; } catch (CloudFailure) { return false; }
  }
  /// This store under the saved passwords' delete rule (the Mac's deleteRuleStore).
  public CloudSecretsDeleteOwner DeleteRuleOwner(string stateRoot, Func<bool> gate, Func<string, string?>? deviceName = null, Func<long?>? serviceClock = null,
    CloudSecretsVanished? vanished = null, Func<long>? now = null)
  {
    var made = new CloudSecretsDeleteOwner(this, stateRoot, gate, Name, RemoveAsync, deviceName: deviceName, serviceClock: serviceClock, now: now,
      sameValue: SameValue, vanished: vanished);
    exchanged = made;
    return made;
  }
}
