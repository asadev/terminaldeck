namespace TerminalDeck.Core.Cloud;

public enum CloudTrustStanding { ThisPc, Trusted, New }

/// One device of the account seen through this PC's trusted list (the Mac's CloudDeviceTrustRow). It carries the code
/// and key so a press can store exactly what was shown (R1); none of it is drawn on a page except the code inside the
/// compare dialog of "Ask me for each new device".
public sealed record CloudTrustRow(string DeviceId, string Name, CloudTrustStanding Standing, string? Code, string? KeyId, CloudPublicJwk? SignKey,
  long? KnownSince, bool Removed, bool ByAccount = false, bool KeyChanged = false, bool SameCode = false, bool SameKey = false)
{
  /// What a Trust press (ask mode) or automatic trust may add: a new device with a readable key and no alarm.
  public bool CanBeTrusted => Standing == CloudTrustStanding.New && SignKey is not null && Code is not null && KeyId is not null && !SameCode && !SameKey && !Removed;
  public override string ToString() => "<Cloud device trust row>";
}

/// The Mac's BackendCloudTrustRows.build, for this PC.
public static class CloudTrustRows
{
  /// `thisKey` is the signing key THIS PC holds; this PC's row is shown by it, never by the key the service lists under
  /// its id. `list` null means this PC's trusted list could not be read: then no new device carries a key a press could
  /// store. `markKeyChanges` (automatic mode): a trusted device whose reported key differs from the stored one carries
  /// the REPORTED key and is marked, so the one button stores what the person saw; nothing is stored without that press.
  public static IReadOnlyList<CloudTrustRow> Build(IReadOnlyList<CloudDevice> devices, CloudTrustedList? list, string? thisDeviceId, CloudPublicJwk? thisKey, bool markKeyChanges)
  {
    var entries = list?.Devices ?? [];
    var counts = devices.GroupBy(d => d.DeviceId, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Count(), StringComparer.Ordinal);
    var seen = new HashSet<string>(StringComparer.Ordinal);
    var rows = new List<CloudTrustRow>();
    foreach (var device in devices)
    {
      if (!seen.Add(device.DeviceId)) continue;
      var entry = entries.FirstOrDefault(e => e.DeviceId == device.DeviceId && e.Trusted);
      var isThis = device.DeviceId == thisDeviceId;
      var unique = counts[device.DeviceId] == 1;
      var removed = device.Status != "active";
      var name = CloudTrustStore.PlainName(device.Label);
      var standing = isThis ? CloudTrustStanding.ThisPc : entry is null ? CloudTrustStanding.New : CloudTrustStanding.Trusted;
      if (markKeyChanges && !isThis && entry is not null && entry.How != "self" && unique
        && CloudDeviceCode.KeyId(device.SignPublicJwk) is { } reported && reported != entry.KeyId && CloudDeviceCode.Code(device.DeviceId, reported) is { } shown)
      {
        rows.Add(new(device.DeviceId, name, standing, shown, reported, list is null ? null : device.SignPublicJwk, entry.TrustedAt, removed, entry.How == "account", KeyChanged: true));
        continue;
      }
      var key = isThis ? thisKey ?? entry?.SignKey : entry?.SignKey ?? device.SignPublicJwk;
      var keyId = unique && key is not null ? CloudDeviceCode.KeyId(key) : null;
      var code = keyId is not null ? CloudDeviceCode.Code(device.DeviceId, keyId) : null;
      var offered = code is not null && (list is not null || isThis);
      rows.Add(new(device.DeviceId, name, standing, code, code is null ? null : keyId, offered ? key : null, entry?.TrustedAt, removed, markKeyChanges && entry?.How == "account"));
    }
    // Every code and key this PC knows of: the rows, and entries the service no longer lists.
    var codes = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
    var keys = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
    void Own(Dictionary<string, HashSet<string>> map, string value, string id) { if (!map.TryGetValue(value, out var set)) map[value] = set = new(StringComparer.Ordinal); set.Add(id); }
    foreach (var row in rows) { if (row.Code is { } c) Own(codes, c, row.DeviceId); if (row.KeyId is { } k) Own(keys, k, row.DeviceId); }
    foreach (var entry in entries.Where(e => !seen.Contains(e.DeviceId)))
    {
      if (CloudDeviceCode.Code(entry.DeviceId, entry.KeyId) is { } c) Own(codes, c, entry.DeviceId);
      Own(keys, entry.KeyId, entry.DeviceId);
    }
    return rows.Select(row => row with
    {
      SameCode = row.SameCode || row.Code is { } c && codes[c].Count > 1,
      SameKey = row.SameKey || row.KeyId is { } k && keys[k].Count > 1
    }).ToArray();
  }

  /// Does the service list, under this PC's own id, a key other than the one this PC holds?
  public static bool ServiceShowsAnotherKeyForThisPc(IReadOnlyList<CloudDevice> devices, string thisDeviceId, CloudPublicJwk thisKey) =>
    CloudDeviceCode.KeyId(thisKey) is { } mine && devices.Any(d => d.DeviceId == thisDeviceId && CloudDeviceCode.KeyId(d.SignPublicJwk) != mine);

  /// What a device list read after a press says about the pressed device: it can only cancel the press.
  public static IReadOnlyList<CloudTrustLatestRow> Latest(IReadOnlyList<CloudTrustRow> rows) =>
    rows.Select(r => new CloudTrustLatestRow(r.DeviceId, r.KeyId, r.SameCode, r.SameKey, r.Removed)).ToArray();
}
