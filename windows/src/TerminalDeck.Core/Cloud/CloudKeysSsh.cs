using System.Text;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Core.Cloud;

// Server keys travel (the Mac's BackendCloudKeysSSH.swift, keys travel part 2, with review fixes). A server saved in
// Terminal Deck that signs in through his SSH settings carries what THAT server needs to his other devices, as one
// saved-passwords entry of its own kind ("Server key · <server name>"): host name, user, port, the private key file(s)
// and the known-host lines for that host, plus the server itself (so the row arrives under the same id).
// On this PC a server added from his SSH settings keeps the key HE picked in the app's own server folder
// (`servers\<id>\identity`, owner-only): that is his own entry here, it is what this PC sends, and it always wins.
// A copy from another device lives in the saved passwords' own folder (`ssh-travelled\<id>`, owner-only), never in his
// SSH folder, and is used by the dialer only for a server that has no key of its own here. An arriving copy replaces the
// app's older copy (a changed key arrives); his own key is never touched. Delete removes only the app's copy.

/// One server's value, exactly as the Mac encodes it (key bytes and host keys as standard base64).
public sealed record CloudKeysSshValue(CloudSecretsServerDefinition Server, string Alias, string Hostname, string User, int Port,
  IReadOnlyList<(string Name, byte[] Bytes)> Keys, IReadOnlyList<(string Algorithm, byte[] Key)> KnownHosts)
{
  public const int MaximumKeys = 8, MaximumKeyBytes = 64 * 1024, MaximumHostLines = 16;
  public CloudJson ToJson() => CloudJson.Obj(("server", Server.ToJson()), ("alias", CloudJson.From(Alias)), ("hostname", CloudJson.From(Hostname)),
    ("user", CloudJson.From(User)), ("port", CloudJson.From(Port)),
    ("keys", CloudJson.Arr(Keys.Select(k => (CloudJson)CloudJson.Obj(("name", CloudJson.From(k.Name)), ("bytes", CloudJson.From(Convert.ToBase64String(k.Bytes))))))),
    ("knownHosts", CloudJson.Arr(KnownHosts.Select(h => (CloudJson)CloudJson.Obj(("algorithm", CloudJson.From(h.Algorithm)), ("key", CloudJson.From(Convert.ToBase64String(h.Key))))))));
  public byte[] Canonical() => CloudCanonical.Encode(ToJson());
  public bool SameAs(CloudKeysSshValue? other) => other is not null && Canonical().AsSpan().SequenceEqual(other.Canonical());
  private static bool Plain(string text, int limit) => text.Length > 0 && Encoding.UTF8.GetByteCount(text) <= limit && !text.StartsWith('-') && !text.Any(c => c < 33 || c == 127);
  public static bool ValidAlias(string alias)
  {
    var bytes = Encoding.UTF8.GetBytes(alias);
    return bytes.Length is >= 1 and <= 255 && bytes[0] != (byte)'-' && bytes.All(b => b is >= 65 and <= 90 or >= 97 and <= 122 or >= 48 and <= 57 or 45 or 46 or 95);
  }
  public bool Valid => Server.Valid && ValidAlias(Alias) && Plain(Hostname, 255) && Plain(User, 64) && Port is >= 1 and <= 65535
    && Keys.Count is >= 1 and <= MaximumKeys && KnownHosts.Count <= MaximumHostLines
    && Keys.All(k => k.Bytes.Length is >= 1 and <= MaximumKeyBytes && Plain(k.Name, 128) && !k.Name.Contains('/') && k.Name is not (".." or "."))
    && KnownHosts.All(h => Plain(h.Algorithm, 64) && h.Key.Length is >= 1 and <= 8192);
  /// Strict, as the Mac decodes it (the value written back must be exactly what arrived).
  public static CloudKeysSshValue Decode(CloudJson payload)
  {
    if (payload is not CloudJson.Object o || o["keys"] is not CloudJson.Array keys || o["knownHosts"] is not CloudJson.Array hosts || o["server"] is not { } server)
      throw new CloudFailure("invalid_request");
    static byte[] Bytes(CloudJson.Object item, string key)
    {
      try { return Convert.FromBase64String(CloudFields.Text(item, key)); } catch (FormatException) { throw new CloudFailure("invalid_request"); }
    }
    var value = new CloudKeysSshValue(CloudSecretsServerDefinition.FromJson(server), CloudFields.Text(o, "alias"), CloudFields.Text(o, "hostname"),
      CloudFields.Text(o, "user"), (int)CloudFields.Integer(o, "port"),
      keys.Items.Select(k => k is CloudJson.Object ko ? (CloudFields.Text(ko, "name"), Bytes(ko, "bytes")) : throw new CloudFailure("invalid_request")).ToArray(),
      hosts.Items.Select(h => h is CloudJson.Object ho ? (CloudFields.Text(ho, "algorithm"), Bytes(ho, "key")) : throw new CloudFailure("invalid_request")).ToArray());
    if (!value.Canonical().AsSpan().SequenceEqual(CloudCanonical.Encode(payload)) || !value.Valid) throw new CloudFailure("invalid_request");
    return value;
  }
}

/// What a connection uses from a travelled copy: the settings, the app's own key files and its known-hosts file.
public sealed record CloudSshTravelled(string Hostname, string User, int Port, IReadOnlyList<string> IdentityFiles, string KnownHostsFile);

/// The app's own folder of travelled copies: `<root>\<server id>\value.json` (the value, kept so it can be compared and
/// put back), `key-<n>` (what ssh reads with -i) and `known_hosts`. Owner-only (the composition's `protect`), written by
/// temp + rename, never through a link. Never his SSH folder.
public sealed class CloudKeysSshFolder(string root, Action<string>? protect = null)
{
  public string Root => root;
  public static bool ValidId(string id) => id.Length is >= 1 and <= 64 && id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
  private string Folder(string id) => ValidId(id) ? Path.Combine(root, id) : throw new CloudFailure("invalid_request");
  private static void Refuse(string path) { if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new CloudFailure("unavailable"); }
  private void MakeFolder(string path)
  {
    if (Directory.Exists(path)) Refuse(path); else Directory.CreateDirectory(path);
    protect?.Invoke(path);
  }
  private static void Write(byte[] data, string file)
  {
    var temp = Path.Combine(Path.GetDirectoryName(file)!, "." + Path.GetFileName(file) + "." + Guid.NewGuid().ToString("N"));
    try
    {
      using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { stream.Write(data); stream.Flush(true); }
      if (File.Exists(file)) Refuse(file);
      File.Move(temp, file, overwrite: true);
    }
    catch (Exception) { try { File.Delete(temp); } catch (Exception) { } throw new CloudFailure("unavailable"); }
  }
  public CloudKeysSshValue? Value(string id)
  {
    var file = Path.Combine(Folder(id), "value.json");
    if (!File.Exists(file)) return null;
    try { return new FileInfo(file).Length > CloudPackFormat.MaximumPlainChunkBytes ? null : CloudKeysSshValue.Decode(CloudJson.Parse(File.ReadAllBytes(file))); }
    catch (Exception) { return null; }
  }
  public void Put(string id, CloudKeysSshValue value)
  {
    if (!value.Valid) throw new CloudFailure("invalid_request");
    MakeFolder(root);
    var place = Folder(id);
    MakeFolder(place);
    for (var i = 0; i < value.Keys.Count; i++) Write(value.Keys[i].Bytes, Path.Combine(place, "key-" + i));
    // Key files beyond this copy's count are old ones: removed, so ssh never offers a key that no longer travels.
    for (var i = value.Keys.Count; i < CloudKeysSshValue.MaximumKeys; i++) File.Delete(Path.Combine(place, "key-" + i));
    var host = value.Port == 22 ? value.Hostname : "[" + value.Hostname + "]:" + value.Port;
    Write(Encoding.UTF8.GetBytes(string.Concat(value.KnownHosts.Select(h => host + " " + h.Algorithm + " " + Convert.ToBase64String(h.Key) + "\n"))), Path.Combine(place, "known_hosts"));
    Write(value.Canonical(), Path.Combine(place, "value.json"));
  }
  public void Remove(string id)
  {
    var place = Folder(id);
    if (!Directory.Exists(place)) return;
    for (var i = 0; i < CloudKeysSshValue.MaximumKeys; i++) File.Delete(Path.Combine(place, "key-" + i));
    File.Delete(Path.Combine(place, "known_hosts"));
    File.Delete(Path.Combine(place, "value.json"));
    if (!Directory.EnumerateFileSystemEntries(place).Any()) Directory.Delete(place);
  }
  /// What a connection to server `id` would use from the copy here (null: none).
  public CloudSshTravelled? Travelled(string id)
  {
    if (!ValidId(id) || Value(id) is not { } value) return null;
    var place = Folder(id);
    var files = Enumerable.Range(0, value.Keys.Count).Select(i => Path.Combine(place, "key-" + i)).Where(File.Exists).ToArray();
    return files.Length == 0 ? null : new(value.Hostname, value.User, value.Port, files, Path.Combine(place, "known_hosts"));
  }
}

/// The servers' one SSH dialer asks here for a travelled copy (set by the composition when saved passwords start).
public sealed class CloudSshTravelledBox
{
  public static CloudSshTravelledBox Shared { get; } = new();
  private CloudKeysSshFolder? held;
  public void Set(CloudKeysSshFolder? folder) => Volatile.Write(ref held, folder);
  public CloudSshTravelled? Travelled(string serverId) { try { return Volatile.Read(ref held)?.Travelled(serverId); } catch (Exception) { return null; } }
}

/// Source "ssh", domain ssh: one record per server added from his SSH settings, named by the server id.
public sealed class CloudKeysSshStore : ICloudSecretsStore
{
  public string SourceId { get; }
  public string InventoryRow => "I14";
  public string Domain => CloudSecretsDomains.Ssh;
  private readonly ServerStore servers;
  private readonly Func<string, string> serverFolder;
  private readonly CloudKeysSshFolder folder;
  private readonly string idMapFile;
  /// `serverFolder(id)`: the app's own folder of a server on this PC (`servers\<id>`, where his picked key lives).
  public CloudKeysSshStore(ServerStore servers, Func<string, string> serverFolder, CloudKeysSshFolder folder, string idMapFile, string sourceId = "ssh")
  {
    this.servers = servers; this.serverFolder = serverFolder; this.folder = folder; this.idMapFile = idMapFile; SourceId = sourceId;
  }
  public CloudKeysSshFolder Folder => folder;

  // A server that arrived from a Mac keeps its Mac id in Cloud (ids only, no name, no value), as server sign-ins do.
  private Dictionary<string, string> Map()
  {
    try { return File.Exists(idMapFile) && CloudJson.Parse(File.ReadAllBytes(idMapFile)) is CloudJson.Object o ? o.Members.Where(m => m.Value.AsString is not null).ToDictionary(m => m.Key, m => m.Value.AsString!) : []; }
    catch (Exception) { return []; }
  }
  private void Remember(string local, string cloud)
  {
    if (local == cloud) return;
    var map = Map(); if (map.GetValueOrDefault(local) == cloud) return; map[local] = cloud;
    new CloudFileSlot(idMapFile).Write(CloudCanonical.Encode(CloudJson.Obj(map.OrderBy(m => m.Key, StringComparer.Ordinal).Select(m => (m.Key, (CloudJson?)CloudJson.From(m.Value))).ToArray())));
  }
  private static string? LocalId(string cloud)
  {
    var id = cloud.Replace("-", "", StringComparison.Ordinal).ToLowerInvariant();
    return id.Length == 32 && id.All(char.IsAsciiHexDigit) ? id : null;
  }

  /// His own key for this server here (the one he picked when adding it). null: none of his own on this PC.
  private CloudKeysSshValue? Own(SavedServer server)
  {
    if (server.SshAlias is not { } alias || server.Authentication != ServerAuthentication.Key) return null;
    var place = serverFolder(server.Id);
    var keyFile = Path.Combine(place, "identity");
    if (!File.Exists(keyFile)) return null;
    byte[] key;
    try { if (new FileInfo(keyFile).Length is < 1 or > CloudKeysSshValue.MaximumKeyBytes) return null; key = File.ReadAllBytes(keyFile); }
    catch (Exception) { return null; }
    var lines = new List<(string, byte[])>();
    try
    {
      var known = Path.Combine(place, "known_hosts");
      if (File.Exists(known))
        foreach (var line in File.ReadAllLines(known))
        {
          var parts = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
          if (parts.Length < 3 || lines.Count >= CloudKeysSshValue.MaximumHostLines) continue;
          try { lines.Add((parts[1], Convert.FromBase64String(parts[2]))); } catch (FormatException) { }
        }
    }
    catch (Exception) { }
    if (CloudSecretsServerStore.Definition(server) is not { } definition) return null;
    var value = new CloudKeysSshValue(definition, alias, server.Host, server.User, server.Port, [("identity", key)], lines);
    return value.Valid ? value : null;
  }
  public Task<IReadOnlyList<CloudSecretRecord>> CaptureAsync()
  {
    var map = Map();
    var output = new List<CloudSecretRecord>();
    foreach (var server in servers.List())
    {
      if (server.SshAlias is null || server.Authentication != ServerAuthentication.Key) continue;
      var cloud = map.GetValueOrDefault(server.Id, server.Id);
      if (!CloudKeysSshFolder.ValidId(cloud)) continue;
      // His own key here, else the copy from another device (so the item stays one).
      var value = Own(server) ?? folder.Value(server.Id);
      if (value is null) continue;
      output.Add(new(SourceId, cloud, Domain, value.ToJson()));
    }
    return Task.FromResult<IReadOnlyList<CloudSecretRecord>>(output.OrderBy(r => r.RecordId, StringComparer.Ordinal).ToArray());
  }
  private CloudKeysSshValue Value(CloudSecretRecord record)
  {
    if (record.SourceId != SourceId || record.Domain != Domain || !CloudKeysSshFolder.ValidId(record.RecordId)) throw new CloudFailure("invalid_request");
    return CloudKeysSshValue.Decode(record.Payload);
  }
  public Task ValidateAsync(CloudSecretRecord record) { _ = Value(record); return Task.CompletedTask; }
  public async Task<CloudApplyStatus> MergeAsync(CloudSecretRecord record)
  {
    var incoming = Value(record);
    if (LocalId(record.RecordId) is not { } local) throw new CloudFailure("unavailable");
    var server = servers.List().FirstOrDefault(s => s.Id == local);
    if (server is null)
    {
      try { await servers.CloudAddSshIfAbsentAsync(local, incoming.Server, incoming.Alias); } catch (Exception) { throw new CloudFailure("unavailable"); }
      server = servers.List().FirstOrDefault(s => s.Id == local);
    }
    if (server is null || server.SshAlias != incoming.Alias) return CloudApplyStatus.KeptBoth;
    Remember(local, record.RecordId);
    // His own key on this PC always wins: nothing is stored, nothing overwritten.
    if (Own(server) is { } own) return own.SameAs(incoming) ? CloudApplyStatus.AlreadyPresent : CloudApplyStatus.KeptBoth;
    if (incoming.SameAs(folder.Value(local))) return CloudApplyStatus.AlreadyPresent;
    // The app's own copy (never his): the newest from his other device replaces it, so a changed key arrives.
    folder.Put(local, incoming);
    return CloudApplyStatus.Applied;
  }
  public Task<bool> VerifyAsync(CloudSecretRecord record, CloudApplyStatus outcome)
  {
    var incoming = Value(record);
    if (outcome != CloudApplyStatus.Applied) return Task.FromResult(true);
    return Task.FromResult(LocalId(record.RecordId) is { } local && incoming.SameAs(folder.Value(local)));
  }
  /// The delete rule: only the app's own copy is removed. His own key here is never changed, so on the PC where it is
  /// his own the server keeps working with it, and the delete rule keeps it out of Cloud.
  public Task<bool> RemoveAsync(CloudSecretRecord record)
  {
    var incoming = Value(record);
    if (LocalId(record.RecordId) is not { } local || folder.Value(local) is not { } held) return Task.FromResult(true);
    if (!held.SameAs(incoming)) return Task.FromResult(false);
    folder.Remove(local);
    return Task.FromResult(true);
  }
  public static string Name(CloudSecretRecord record)
  {
    string? name = null;
    try { name = CloudKeysSshValue.Decode(record.Payload).Server.Name; } catch (Exception) { }
    return "Server key · " + (name ?? "server");
  }
  /// This store under the saved passwords' delete rule; Put back goes through the same arrival rules.
  public CloudSecretsDeleteOwner DeleteRuleOwner(string stateRoot, Func<bool> gate, Func<string, string?>? deviceName = null, Func<long?>? serviceClock = null, Func<long>? now = null) =>
    new(this, stateRoot, gate, Name, RemoveAsync, MergeAsync, deviceName, serviceClock, now);
}
