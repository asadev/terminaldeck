using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Cloud;

// Keys travel (port of the Mac's BackendCloudKeysTravel.swift, 15 Nov 2026: "every single thing in cloud"). API keys,
// MCP servers and server keys ride the saved-passwords engine: each is one more ICloudSecretsStore (its own source and
// domain), sealed with the saved-passwords key, wrapped by the saved passwords' delete owner (CloudSecretsDeleteOwner:
// the Bin for 30 days, Put back, an AI's removal = everywhere). No second engine, no click, no question.
// The same rules for all of them:
// - New on another device: made here, and used by the feature itself.
// - The same item on both (same name, or the same value under another name here): ONE item, nothing added.
// - A different value under the same name: never overwritten. His stays; the other device's is added beside it, named
//   apart by that device's name.
// - Names are shown, values never: nothing here logs, throws or returns a value; errors are fixed words.

public static partial class CloudKeysTravel
{
  /// The Mac's account-name limit (BackendAccountProfile.maximumNameLength): a longer name is never sent.
  public const int MaximumNameLength = 60;
  public static int Length(string text) => new StringInfo(text).LengthInTextElements;
  public static string Prefix(string text, int count) { var info = new StringInfo(text); return count >= info.LengthInTextElements ? text : info.SubstringByTextElements(0, count); }
  /// "Name (device)": the other device's value beside his own.
  public static string Apart(string name, string? device)
  {
    var who = device?.Trim() is { Length: > 0 } d ? d : "another device";
    return Prefix(name, Math.Max(1, MaximumNameLength - Length(who) - 3)) + " (" + who + ")";
  }
  /// The device's name as an MCP-name suffix: letters, digits and "-" only, at most 20 characters (byte-exact with the Mac).
  public static string Slug(string? device)
  {
    var lowered = new string((device ?? "").ToLowerInvariant().Select(c => char.IsAsciiLetterOrDigit(c) ? c : '-').ToArray());
    var joined = string.Join("-", lowered.Split('-', StringSplitOptions.RemoveEmptyEntries));
    var shortened = joined[..Math.Min(20, joined.Length)].Trim('-');
    return shortened.Length == 0 ? "other-mac" : shortened;
  }
  /// A stable id for a copy made from one arriving record (the same arrival names the same copy on every device).
  public static string CopyId(string recordId, string? from) =>
    "api-key-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("TD-KEYS-COPY-1\n" + recordId + "\n" + (from ?? ""))))[..24];
  [GeneratedRegex("^api-key-[a-f0-9]{24}$")] private static partial Regex ApiIdPattern();
  public static bool IsApiAccountId(string id) => ApiIdPattern().IsMatch(id);
}

/// A Remove pressed IN THE APP for an API account is a removal EVERYWHERE through its delete owner (Bin 30 days, no
/// question; the Mac's BackendCloudKeysRemovals). The composition sets the handler when saved passwords run; without one
/// (saved passwords off or locked) the feature removes as before. Without this, the Cloud record would bring it back.
public sealed class CloudKeysRemovals
{
  public static CloudKeysRemovals Shared { get; } = new();
  public delegate Task<bool> Handler(string sourceId, string cloudId);
  private readonly Lock gate = new();
  private Handler? handler;
  private readonly Dictionary<string, Func<string, string>> mappers = new(StringComparer.Ordinal);
  public void Set(Handler? next) { lock (gate) handler = next; }
  public void SetMapper(string sourceId, Func<string, string>? mapper) { lock (gate) { if (mapper is null) mappers.Remove(sourceId); else mappers[sourceId] = mapper; } }
  /// false: not handled here (the caller removes the old way). Throws the delete owner's refusal.
  public async Task<bool> RemoveEverywhereAsync(string sourceId, string id)
  {
    Handler? h; Func<string, string>? map;
    lock (gate) { h = handler; mappers.TryGetValue(sourceId, out map); }
    if (h is null) return false;
    return await h(sourceId, map?.Invoke(id) ?? id);
  }
  /// The handler the composition sets: the kind's delete owner removes the item everywhere, by the person.
  public static Handler Through(IReadOnlyDictionary<string, CloudSecretsDeleteOwner> owners, Func<CloudDeleteActor?> person) => async (source, id) =>
  {
    if (!owners.TryGetValue(source, out var owner) || !await owner.CanDeleteEverywhereAsync() || person() is not { } actor) return false;
    if ((await owner.ItemsAsync()).FirstOrDefault(i => i.Id == id) is not { } item) return false;
    await owner.DeleteItemsAsync([item], CloudDeleteScope.Everywhere, actor);
    return true;
  };
}

/// One API account of this PC as the travelling store sees it, in the Mac's words (kind raw value, base URL filled with
/// the kind's default). `AccountId` is the account's id in Cloud (`api-key-<24 hex>`). Never holds the key.
public sealed record CloudKeysApiAccount(string AccountId, string Name, string Provider, string Kind, string BaseUrl, string? Model, string? WorkspaceId)
{
  public bool RequiresKey => Kind != "compatibleLocal";
}

/// The API accounts' own owner (ApiAccountService on this PC; tests a memory owner). Ids are Cloud ids.
public interface ICloudKeysApiOwner
{
  Task<IReadOnlyList<CloudKeysApiAccount>> CloudAccountsAsync();
  Task<string?> CloudKeyAsync(string accountId);
  /// Make an API account with exactly this id (absent here), these settings and this key. Throws on any refusal.
  Task CloudCreateAsync(string accountId, string name, CloudKeysApiValue value);
  /// Compare-and-remove: only while its key still equals `expectingKey` and nothing runs as it.
  Task<bool> CloudRemoveAsync(string accountId, string expectingKey);
  /// Compare-and-swap of the key in place (the account, its settings and name stay). false = changed here.
  Task<bool> CloudReplaceKeyAsync(string accountId, string key, string expectingKey);
}

/// What travels for one API account (the Mac's BackendCloudKeysAPIValue): what a person types when adding it, and its key.
public sealed record CloudKeysApiValue(string Name, string Provider, string Kind, string BaseUrl, string? Model, string? WorkspaceId, string Key, string? From)
{
  public static readonly IReadOnlyDictionary<string, string> Providers = new Dictionary<string, string>(StringComparer.Ordinal)
  { ["anthropic"] = "claude", ["anthropicToken"] = "claude", ["openai"] = "codex", ["compatible"] = "codex", ["compatibleLocal"] = "codex", ["gemini"] = "gemini" };
  public static string DefaultBaseUrl(string kind) => kind switch
  {
    "anthropic" or "anthropicToken" => "https://api.anthropic.com",
    "openai" => "https://api.openai.com/v1",
    "gemini" => "https://generativelanguage.googleapis.com/v1beta",
    _ => ""
  };
  public static CloudKeysApiValue Of(CloudKeysApiAccount account, string key, string? from) =>
    new(CloudKeysTravel.Prefix(account.Name, CloudKeysTravel.MaximumNameLength), account.Provider, account.Kind, account.BaseUrl, account.Model, account.WorkspaceId, key, from);
  public CloudJson ToJson() => CloudJson.Obj(("name", CloudJson.From(Name)), ("provider", CloudJson.From(Provider)), ("kind", CloudJson.From(Kind)),
    ("baseURL", CloudJson.From(BaseUrl)), ("model", Model is { } m ? CloudJson.From(m) : null), ("workspaceID", WorkspaceId is { } w ? CloudJson.From(w) : null),
    ("key", CloudJson.From(Key)), ("from", From is { } f ? CloudJson.From(f) : null));
  /// The same API connection with the same key (name, model and sender aside).
  public bool Same(CloudKeysApiAccount account, string? key) => SameConnection(account) && Key == key;
  public bool SameConnection(CloudKeysApiAccount account) =>
    Provider == account.Provider && Kind == account.Kind && BaseUrl == account.BaseUrl && WorkspaceId == account.WorkspaceId;
  public bool SameValue(CloudKeysApiValue other) =>
    Provider == other.Provider && Kind == other.Kind && BaseUrl == other.BaseUrl && WorkspaceId == other.WorkspaceId && Key == other.Key;

  /// Strict, as the Mac decodes and checks it (the value written back is exactly what arrived).
  public static CloudKeysApiValue Decode(CloudSecretRecord record, string sourceId)
  {
    if (record.SourceId != sourceId || record.Domain != CloudSecretsDomains.ApiKey || !CloudKeysTravel.IsApiAccountId(record.RecordId)
      || record.Payload is not CloudJson.Object o) throw new CloudFailure("invalid_request");
    var value = new CloudKeysApiValue(CloudFields.Text(o, "name"), CloudFields.Text(o, "provider"), CloudFields.Text(o, "kind"), CloudFields.Text(o, "baseURL"),
      CloudFields.OptionalText(o, "model"), CloudFields.OptionalText(o, "workspaceID"), CloudFields.Text(o, "key"), CloudFields.OptionalText(o, "from"));
    if (!CloudCanonical.Encode(value.ToJson()).AsSpan().SequenceEqual(CloudCanonical.Encode(record.Payload))) throw new CloudFailure("invalid_request");
    if (!Providers.TryGetValue(value.Kind, out var provider) || provider != value.Provider || value.Kind == "compatibleLocal"
      || value.Name.Trim().Length == 0 || CloudKeysTravel.Length(value.Name) > CloudKeysTravel.MaximumNameLength || value.Name.Any(c => c is '\n' or '\r' or '\u0085' or '\u2028' or '\u2029')
      || CloudKeysTravel.Length(value.From ?? "") > 128 || !UrlAccepted(value.BaseUrl) || !KeyAccepted(value.Key)) throw new CloudFailure("invalid_request");
    return value;
  }
  private static bool UrlAccepted(string url)
  {
    if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || u.UserInfo.Length > 0 || url.Contains('?') || url.Contains('#') || u.Host.Length == 0) return false;
    var host = u.Host.Trim('[', ']');
    return u.Scheme == "https" || u.Scheme == "http" && host is "localhost" or "127.0.0.1" or "::1";
  }
  /// The Mac's key rule: 8 to 8192 bytes of printable ASCII, no quote or backslash.
  public static bool KeyAccepted(string key)
  {
    var bytes = Encoding.UTF8.GetByteCount(key);
    return bytes is >= 8 and <= 8192 && key.All(c => c is >= '!' and <= '~' && c != '"' && c != '\\');
  }
}

/// Which local account is the one item another device names otherwise (ids only; the Mac's BackendCloudKeysAliases).
/// Two devices that made the same key into two accounts agree on ONE id (the smaller), so the item is one in Cloud too.
internal sealed class CloudKeysAliases(string? file)
{
  private Dictionary<string, string> map = Load(file);
  private static Dictionary<string, string> Load(string? file)
  {
    try { return file is not null && File.Exists(file) && CloudJson.Parse(File.ReadAllBytes(file)) is CloudJson.Object o ? o.Members.Where(m => m.Value.AsString is not null).ToDictionary(m => m.Key, m => m.Value.AsString!) : []; }
    catch (Exception) { return []; }
  }
  /// Cloud id -> this PC's account id (both in Cloud form).
  public string Local(string cloudId) => map.GetValueOrDefault(cloudId, cloudId);
  /// The id this PC uses in Cloud for its account `localId`: the smallest id that names it.
  public string Cloud(string localId) => map.Where(m => m.Value == localId).Select(m => m.Key).Append(localId).Min(StringComparer.Ordinal)!;
  public void Alias(string cloudId, string localId)
  {
    if (cloudId == localId || map.GetValueOrDefault(cloudId) == localId) return;
    map[cloudId] = localId; Save();
  }
  public void Forget(string localId)
  {
    var before = map.Count;
    map = map.Where(m => m.Value != localId && m.Key != localId).ToDictionary(m => m.Key, m => m.Value);
    if (map.Count != before) Save();
  }
  private void Save()
  {
    if (file is null) return;
    try { new CloudFileSlot(file).Write(CloudCanonical.Encode(CloudJson.Obj(map.OrderBy(m => m.Key, StringComparer.Ordinal).Select(m => (m.Key, (CloudJson?)CloudJson.From(m.Value))).ToArray()))); }
    catch (Exception) { }
  }
}

/// API keys as one saved-passwords source (`api`, domain api-key). Port of the Mac's BackendCloudKeysAPIStore, with its
/// review fixes: the last exchanged record is sent again while the value is unchanged (no echo), a key changed on one
/// device replaces the unchanged other in place, the id given up when two devices agree leaves Cloud (Cloud only).
public sealed class CloudKeysApiStore : ICloudSecretsStore
{
  public string SourceId { get; }
  public string InventoryRow => "I13";
  public string Domain => CloudSecretsDomains.ApiKey;
  private readonly ICloudKeysApiOwner owner;
  private readonly Func<string?> thisDevice;
  private readonly CloudKeysAliases aliases;
  private CloudSecretsDeleteOwner? exchanged;
  /// `stateRoot`: where the id-only alias file lives (the saved passwords' own state folder); null keeps it in memory.
  /// `removals`: where an app Remove finds this kind's Cloud id.
  public CloudKeysApiStore(ICloudKeysApiOwner owner, string? stateRoot, Func<string?> thisDevice, string sourceId = "api", CloudKeysRemovals? removals = null)
  {
    SourceId = sourceId; this.owner = owner; this.thisDevice = thisDevice;
    aliases = new(stateRoot is null ? null : Path.Combine(stateRoot, "keys-travel-api-aliases.json"));
    (removals ?? CloudKeysRemovals.Shared).SetMapper(sourceId, aliases.Cloud);
  }
  private async Task<List<(CloudKeysApiAccount Account, string Key)>> KeyedAsync()
  {
    var output = new List<(CloudKeysApiAccount, string)>();
    foreach (var account in await owner.CloudAccountsAsync())
    {
      if (!account.RequiresKey || !CloudKeysTravel.IsApiAccountId(account.AccountId)) continue;
      if (await owner.CloudKeyAsync(account.AccountId) is not { } key) continue;
      output.Add((account, key));
    }
    return output;
  }
  private CloudSecretRecord Record(string id, CloudKeysApiValue value) => new(SourceId, id, Domain, value.ToJson());
  private CloudKeysApiValue? TryValue(CloudSecretRecord? record) { if (record is null) return null; try { return CloudKeysApiValue.Decode(record, SourceId); } catch (Exception) { return null; } }
  public async Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync()
  {
    var device = thisDevice();
    var output = new List<CloudSecretRecord>();
    foreach (var (account, key) in await KeyedAsync())
    {
      var id = aliases.Cloud(account.AccountId);
      var fresh = CloudKeysApiValue.Of(account, key, device);
      // Still the value last exchanged for this id: that very record again, so nothing comes back as an echo with
      // another device's name inside it.
      if (exchanged?.LastExchanged(id) is { } last && TryValue(last) is { } before && before.SameValue(fresh)) { output.Add(last); continue; }
      output.Add(Record(id, fresh));
    }
    return output;
  }
  public Task ValidateAsync(CloudSecretRecord record) { _ = CloudKeysApiValue.Decode(record, SourceId); return Task.CompletedTask; }
  private static async Task<T> Owned<T>(Func<Task<T>> step)
  {
    try { return await step(); }
    catch (CloudFailure f) when (f.Code == "secrets_locked") { throw; }
    catch (Exception) { throw new CloudFailure("unavailable"); }
  }
  public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
  {
    var incoming = CloudKeysApiValue.Decode(record, SourceId);
    var here = await KeyedAsync();
    var localId = aliases.Local(record.RecordId);
    if (here.FirstOrDefault(h => h.Account.AccountId == localId) is { Account: not null } mine0 && incoming.Same(mine0.Account, mine0.Key)) return CloudApplyStatus.AlreadyPresent;
    var mineExists = here.Any(h => h.Account.AccountId == localId) || (await owner.CloudAccountsAsync()).Any(a => a.AccountId == localId);
    // The same key under another account here: one item. Only when this id names nothing else here does the alias keep
    // the two devices on one id (a copy named apart never takes over the id of his own account).
    if (here.FirstOrDefault(h => incoming.Same(h.Account, h.Key)) is { Account: not null } twin)
    {
      if (!mineExists)
      {
        var own = twin.Account.AccountId; var before = aliases.Cloud(own);
        aliases.Alias(record.RecordId, own);
        // The id this PC used in Cloud before the two devices agreed leaves Cloud (only Cloud).
        if (before != aliases.Cloud(own)) exchanged?.RetireFromCloud(before);
      }
      return CloudApplyStatus.AlreadyPresent;
    }
    if (mineExists)
    {
      // Unchanged here since the last value exchanged for this id: the other device's newer key replaces it in place
      // (one account). Both changed: his stays and the other one is added beside it.
      if (here.FirstOrDefault(h => h.Account.AccountId == localId) is { Account: not null } mine && incoming.SameConnection(mine.Account)
        && TryValue(exchanged?.LastExchanged(record.RecordId)) is { } last && last.Same(mine.Account, mine.Key))
      {
        if (await Owned(() => owner.CloudReplaceKeyAsync(localId, incoming.Key, mine.Key))) return CloudApplyStatus.Applied;
      }
      var copy = CloudKeysTravel.CopyId(record.RecordId, incoming.From);
      // A copy made earlier: the same key = one item; another = kept both (never a failure on every sync).
      if (here.FirstOrDefault(h => h.Account.AccountId == copy) is { Account: not null } made) return incoming.Same(made.Account, made.Key) ? CloudApplyStatus.AlreadyPresent : CloudApplyStatus.KeptBoth;
      if ((await owner.CloudAccountsAsync()).Any(a => a.AccountId == copy)) return CloudApplyStatus.KeptBoth;
      await Owned(async () => { await owner.CloudCreateAsync(copy, CloudKeysTravel.Apart(incoming.Name, incoming.From), incoming); return true; });
      return CloudApplyStatus.KeptBoth;
    }
    await Owned(async () => { await owner.CloudCreateAsync(record.RecordId, incoming.Name, incoming); return true; });
    return CloudApplyStatus.Applied;
  }
  public async Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
  {
    var incoming = CloudKeysApiValue.Decode(record, SourceId);
    if (outcome == CloudApplyStatus.KeptBoth) return (await owner.CloudAccountsAsync()).Any(a => a.AccountId == aliases.Local(record.RecordId));
    return (await KeyedAsync()).Any(h => incoming.Same(h.Account, h.Key));
  }
  /// The delete rule's compare-and-remove (through the alias: Cloud's one id may name another account here).
  public async Task<bool> RemoveAsync(CloudSecretRecord record)
  {
    var incoming = CloudKeysApiValue.Decode(record, SourceId);
    var localId = aliases.Local(record.RecordId);
    var removed = await owner.CloudRemoveAsync(localId, incoming.Key);
    if (removed) aliases.Forget(localId);
    return removed;
  }
  public static string Name(CloudSecretRecord record)
  {
    try { return CloudKeysApiValue.Decode(record, record.SourceId).Name; } catch (Exception) { return "API key"; }
  }
  /// The sending device's name rides beside the value; the value alone decides "the same removed value".
  public static bool SameValue(CloudSecretRecord one, CloudSecretRecord other)
  {
    if (one.RecordId != other.RecordId) return false;
    try { return CloudKeysApiValue.Decode(one, one.SourceId).SameValue(CloudKeysApiValue.Decode(other, other.SourceId)); } catch (Exception) { return false; }
  }
  /// This store under the saved passwords' delete rule (the Mac's deleteRuleStore). `vanished`: this PC's id and name
  /// only (an id retired from Cloud); an absent account is never judged.
  public CloudSecretsDeleteOwner DeleteRuleOwner(string stateRoot, Func<bool> gate, Func<string, string?>? deviceName = null, Func<long?>? serviceClock = null,
    CloudSecretsVanished? vanished = null, Func<long>? now = null)
  {
    var made = new CloudSecretsDeleteOwner(this, stateRoot, gate, Name, RemoveAsync, deviceName: deviceName, serviceClock: serviceClock, now: now,
      sameValue: SameValue, vanished: vanished);
    exchanged = made;
    return made;
  }
}
