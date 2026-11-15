using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// "No device ever receives a record it does not understand", the Mac's own mechanism (td-mac-next2
// DeckMemoryStoreFeatureUnderstands.swift, the understands helpers of DeckMemoryStoreOneRule.swift, CloudDeleteGate).
// Each device announces, per feature, one SHARED memory setting `onerule.understands.<feature>.<device id>` =
// `v<format>:<service ms>` (or `none` for the delete rule: "applies no removals, sends none", J-1). It travels with the
// memory settings (I05). Renewed at start and every 12 hours; it counts while at most 3 days old and not more than an
// hour ahead. A feature sends only while the account's computer list is known, holds this PC, and EVERY computer in it
// announced. A lane announces a feature ONLY in the commit that makes Windows take that kind (the gate means "can take
// it"). Memory's own key `onerule.understands.<device id>` (no feature) is never written by Windows.

public sealed class CloudAnnounce
{
  public const string Prefix = DeckMemoryCloudSchema.SharedSettingPrefix;
  public const long FreshFor = 3L * 86_400_000, RenewAfter = 12L * 3_600_000, AheadAllowed = 3_600_000;

  public static string FeatureKey(string feature, string device) => Prefix + feature + "." + device.ToLowerInvariant();
  public static string Value(int format, long at) => "v" + format.ToString(CultureInfo.InvariantCulture) + ":" + at.ToString(CultureInfo.InvariantCulture);
  public static (int Format, long At)? Parse(string? raw)
  {
    if (raw is null || !raw.StartsWith('v') || raw.Length >= 40 || raw.IndexOf(':') is not (> 1 and var colon)) return null;
    if (!int.TryParse(raw[1..colon], NumberStyles.None, CultureInfo.InvariantCulture, out var format)
      || !long.TryParse(raw[(colon + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var at) || format <= 0 || at <= 0) return null;
    return (format, at);
  }
  /// Fresh = this format or newer, renewed within the last 3 days, not more than an hour ahead.
  public static bool Fresh(string? raw, int format, long now) =>
    Parse(raw) is { } v && v.Format >= format && v.At <= now + AheadAllowed && now - v.At <= FreshFor;

  private readonly IDeckMemoryCloudStore memory;
  private readonly Func<string?> deviceId;
  private readonly Func<long?> serviceNow;
  private readonly Func<IReadOnlyCollection<string>?> computers;
  private readonly ICloudLedgerSlot pendingSlot;
  private readonly Action? changed;
  private Dictionary<string, string> pending;

  /// `computers`: the account's computers (active, not a viewer, not superseded; the Mac's oneRuleAccountMacs), null
  /// while not known. `serviceNow`: the service clock, null while not known. `pending`: where an announcement that waits
  /// for the clock is remembered. `changed`: called after a setting was written (the memory capture picks it up).
  public CloudAnnounce(IDeckMemoryCloudStore memory, Func<string?> deviceId, Func<long?> serviceNow, Func<IReadOnlyCollection<string>?> computers,
    ICloudLedgerSlot pending, Action? changed = null, bool send = true)
  {
    Sends = send;
    this.memory = memory; this.deviceId = deviceId; this.serviceNow = serviceNow; this.computers = computers; pendingSlot = pending; this.changed = changed;
    this.pending = pending.Read() is { } bytes ? JsonSerializer.Deserialize<Dictionary<string, string>>(bytes) ?? [] : [];
  }

  private static readonly DeckMemoryTable Settings = DeckMemoryCloudSchema.Table("settings");
  public string? Setting(string key) =>
    memory.Find("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(key)]) is { } row ? row.Cells[Settings.Index("value")] is { Type: "text", Value: var v } ? v : null : null;
  private void Write(string key, string value, long at)
  {
    var existing = memory.Find("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(key)]);
    memory.PutRow(new DeckMemoryRow("settings", [DeckMemoryCell.Text(""), DeckMemoryCell.Text(key), DeckMemoryCell.Text(value), DeckMemoryCell.Real(at / 1000.0)]),
      existing is null ? null : [DeckMemoryCell.Text(""), DeckMemoryCell.Text(key)]);
    memory.Flush();
    changed?.Invoke();
  }
  private void SavePending() => pendingSlot.Write(JsonSerializer.SerializeToUtf8Bytes(pending));

  /// This PC understands `feature` records of `format`, as of now. Renewed after 12 hours (always when `force`). Waits
  /// while the service clock or this PC's device id is not known: remembered and written by `RetryPending` as soon as
  /// it is. True when a setting was written.
  public bool Announce(string feature, int format, bool force = false) => Put(feature, format.ToString(CultureInfo.InvariantCulture), force);

  /// J-1: "this PC applies no removals and sends none" for the delete rule. Never waited for by the other devices.
  public bool AnnounceNone(string feature) => Put(feature, CloudDeleteGate.None, force: false);

  /// False: this PC writes no announcement at all (none, v1 or a renewal) and remembers none for later; the other
  /// devices see this PC as not having announced anything. The App's one switch (AppRuntime.CloudAnnouncementsOn).
  public bool Sends { get; }

  private bool Put(string feature, string what, bool force)
  {
    if (!Sends) return false;
    if (feature.Length == 0 || feature.Contains('.')) return false;
    if (what != CloudDeleteGate.None && (!int.TryParse(what, NumberStyles.None, CultureInfo.InvariantCulture, out var f) || f <= 0)) return false;
    if (deviceId() is not { } id || !CloudDeleteText.IsUuid(id) || serviceNow() is not { } now || now <= 0)
    {
      pending[feature] = what; SavePending();
      return false;
    }
    if (pending.Remove(feature)) SavePending();
    var key = FeatureKey(feature, id);
    var held = Setting(key);
    if (what == CloudDeleteGate.None)
    {
      if (held == CloudDeleteGate.None) return false;
      Write(key, CloudDeleteGate.None, now);
      return true;
    }
    var format = int.Parse(what, CultureInfo.InvariantCulture);
    if (!force && Parse(held) is { } h && h.Format == format && h.At <= now && now - h.At < RenewAfter) return false;
    Write(key, Value(format, now), now);
    return true;
  }

  /// Announcements that waited for the clock: written now (forced, as a start-up announcement is).
  public void RetryPending()
  {
    foreach (var (feature, what) in pending.ToArray())
      if (what == CloudDeleteGate.None) AnnounceNone(feature);
      else Put(feature, what, force: true);
  }

  /// The account's list is known, holds this PC, and every computer in it has a fresh announcement of `feature` at
  /// `format` or newer. False whenever anything is unknown.
  public bool EveryDeviceUnderstands(string feature, int format)
  {
    if (computers() is not { Count: > 0 } list || deviceId() is not { } me || !list.Contains(me.ToLowerInvariant()) || serviceNow() is not { } now) return false;
    return list.All(d => Fresh(Setting(FeatureKey(feature, d)), format, now));
  }
  /// The computers with no fresh announcement of `feature` (a page line names them). Empty when nothing is known.
  public IReadOnlyList<string> DevicesWaiting(string feature, int format)
  {
    if (computers() is not { } list || serviceNow() is not { } now) return [];
    return list.Where(d => !Fresh(Setting(FeatureKey(feature, d)), format, now)).ToArray();
  }

  /// The delete-rule gate (J-1's `none` counts as announced): "Cloud" deletes and the new form travel only while open.
  public bool DeleteRuleIsOpen()
  {
    if (computers() is not { Count: > 0 } list || deviceId() is not { } me || !list.Contains(me.ToLowerInvariant())) return false;
    var announcements = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var d in list) if (Setting(CloudDeleteGate.Key(d)) is { } raw) announcements[CloudDeleteGate.Key(d)] = raw;
    return CloudDeleteGate.IsOpen(list, announcements, serviceNow());
  }
  /// Has `device` announced the delete rule (`v1` or `none`)? Reads an arriving removal that has no about-record.
  public bool DeleteRuleAnnounced(string device) => CloudDeleteGate.Announced(Setting(CloudDeleteGate.Key(device)));
}
