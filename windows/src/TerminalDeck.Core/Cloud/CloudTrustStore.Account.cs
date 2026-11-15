namespace TerminalDeck.Core.Cloud;

// "Automatically, with my account" (owner, 13 Nov; the Mac's trustByAccount / stopTrusting / trustChangedKey).
public sealed partial class CloudTrustStore
{
  /// Every row a dialog could offer (new, readable key, no same-code or same-key alarm, not removed) that this PC has
  /// NEVER listed is added with the key the service reports, `how: account`. A device already listed (trusted, or
  /// stopped by the person's Remove) is never touched: a changed key is not re-trusted here and a removed device does
  /// not come back. Returns the ids added. Only the account's own status read calls it, and only in automatic mode.
  public IReadOnlyList<string> TrustByAccount(IReadOnlyList<CloudTrustRow> rows)
  {
    lock (gate)
    {
      var old = List();
      var devices = old.Devices.ToList();
      var added = new List<string>();
      foreach (var row in rows.Where(r => r.CanBeTrusted))
      {
        if (row.SignKey is not { } key || CloudDeviceCode.KeyId(key) is not { } keyId || keyId != row.KeyId || !CloudDeviceCode.IsDeviceId(row.DeviceId)) continue;
        if (devices.Any(d => d.DeviceId == row.DeviceId || d.KeyId == keyId) || devices.Count >= Limit) continue;
        devices.Add(new(row.DeviceId, key, keyId, PlainName(row.Name), "trusted", "account", now()));
        added.Add(row.DeviceId);
      }
      if (added.Count == 0) return [];
      Save(devices, old);
      return added;
    }
  }

  /// Automatic mode: a device the account itself now reports as removed stops being trusted here (removed devices leave
  /// the list). Only entries the account added; this PC itself and devices the person trusted by a press are left as
  /// they are. Takes trust away only, so no press is needed. Returns the ids stopped.
  public IReadOnlyList<string> StopRemovedFromAccount(IEnumerable<string> removedIds)
  {
    lock (gate)
    {
      var removed = removedIds.ToHashSet(StringComparer.Ordinal);
      var old = List();
      var devices = old.Devices.ToList();
      var stopped = new List<string>();
      for (var i = 0; i < devices.Count; i++)
      {
        var was = devices[i];
        if (!was.Trusted || was.How != "account" || !removed.Contains(was.DeviceId)) continue;
        devices[i] = was with { Trust = "stopped", StoppedAt = now(), StopReason = "left account" };
        stopped.Add(was.DeviceId);
      }
      if (stopped.Count == 0) return [];
      Save(devices, old);
      return stopped;
    }
  }

  /// "Remove" on the notice of a device that joined by itself: this PC stops taking its changes. The entry stays,
  /// stopped, so automatic trust never adds it again. A press in this PC's window only; never this PC itself.
  public void StopTrusting(string deviceId)
  {
    lock (gate)
    {
      RequirePress();
      var old = List();
      var index = old.Devices.ToList().FindIndex(d => d.DeviceId == deviceId);
      if (index < 0 || old.Devices[index].How == "self") throw new CloudFailure("invalid_request");
      var was = old.Devices[index];
      if (!was.Trusted) return;
      var devices = old.Devices.ToList();
      devices[index] = was with { Trust = "stopped", StoppedAt = now(), StopReason = "removed" };
      Save(devices, old);
    }
  }

  /// "Trust it again" for a device whose reported key CHANGED (automatic mode): the person's press stores the key the
  /// row showed when it was drawn (R1), in place of the old one. A press in this PC's window only.
  public void TrustChangedKey(CloudTrustRow row)
  {
    lock (gate)
    {
      RequirePress();
      if (!row.KeyChanged || row.SameKey || row.SameCode || row.Removed || row.SignKey is not { } key || CloudDeviceCode.KeyId(key) is not { } keyId || keyId != row.KeyId)
        throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
      var old = List();
      var index = old.Devices.ToList().FindIndex(d => d.DeviceId == row.DeviceId);
      if (index < 0 || old.Devices[index].How == "self" || !old.Devices[index].Trusted) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
      if (old.Devices.Any(d => d.DeviceId != row.DeviceId && d.KeyId == keyId)) throw new CloudTrustRefusal(CloudTrustRefusalKind.SameKey);
      var devices = old.Devices.ToList();
      devices[index] = new(row.DeviceId, key, keyId, PlainName(row.Name), "trusted", "click", now());
      Save(devices, old);
    }
  }
}
