using System.Text.Json;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.Core.Cloud;

/// One setting of this PC that is on the Mac's list of settings about the person (CloudBrainSettings.travels), under the
/// Mac's record id: `setting:<key>` (the Mac's settings file) or `preference:<key>` (the Mac's app preferences).
/// `Default`: the value it has when he never chose one, the SAME as the Mac's shipped default. `Accepts`: the shape a value
/// from another device must have. `Widening`: it could change which AI runs a new session (applied only under automatic trust).
public sealed record CloudSetting(string Entity, CloudJson Default, Func<CloudJson, bool> Accepts, Func<CloudJson> Read, Action<CloudJson> Write, bool Widening = false)
{
  public string Key => Entity[(Entity.IndexOf(':') + 1)..];
}

/// A family of settings named by a prefix (15 Nov 2026: WhatsApp agents, `setting:whatsapp.agent.<id>`, any number of them,
/// the Mac's settings-file keys that all travel). Each member travels as soon as it exists (no default, always chosen).
/// `Read`: setting key -> value. `Write`: a value from another device for that key. `Accepts`: (key, value) usable here.
public sealed record CloudSettingFamily(string EntityPrefix, Func<IReadOnlyDictionary<string, CloudJson>> Read, Action<string, CloudJson> Write,
  Func<string, CloudJson, bool> Accepts)
{
  public string KeyPrefix => EntityPrefix[(EntityPrefix.IndexOf(':') + 1)..];
}

// The settings that are about HIM (row I21, domain `settings`), the Mac's BackendCloudKindsSettings on Windows.
// - Only settings on the Mac's travelling list that this PC also has travel, under the Mac's names (default deny): reopen
//   sessions, name sessions from the conversation, copy on select, the default coding AI, the terminal's colours, font
//   and font size. Everything about this PC (keep awake, the shell, permissions, debug switches, launch models) stays.
// - First sync (CLOUD-KINDS-2): a setting still at its default and never chosen here is not this PC's record at all
//   (nothing is sent), so the account's value applies at once. Two CHOSEN values both stay: a first copy from another
//   device never replaces a value chosen here, in either direction, and nothing is listed for it. The next change
//   anywhere travels as usual. Once a setting was chosen or applied here it always travels, also when set back.
// - The default coding AI from another device is applied only under "Automatically, with my account".
// - The value replaced here is kept 30 days on this PC (CloudKindsKept). Removals do not travel.
public sealed class CloudSettingsOwner : ICloudRecordOwner
{
  public const string DomainName = "settings", InventoryRowName = "I21", SourceIdName = "app-settings-personal";
  public static readonly CloudRecordKind AppKind = new("setting:", CloudMergeTables.Setting, "", new HashSet<string>(StringComparer.Ordinal) { "value" });
  public static readonly CloudRecordKind PreferenceKind = new("preference:", CloudMergeTables.Setting, "", new HashSet<string>(StringComparer.Ordinal) { "value" });
  public static readonly IReadOnlyList<string> Exclusions =
  [
    "Settings about this PC stay on it: folders, the terminal shell, window sizes, keep-awake and debug switches.",
    "Sign-ins, accounts, keys, permission, hook and MCP settings, Hoot's own settings and limits never travel.",
  ];
  public const string WideningHeld = "The default AI chosen on another device is applied here only while devices are trusted automatically with your account.";
  public const string NotUsable = "The value set on another device is not one this PC can use.";
  public const string NotListed = "This setting is not one this PC has; it stays on your other devices.";

  private readonly IReadOnlyDictionary<string, CloudSetting> settings;
  private readonly Func<bool?> fullAccess;
  private readonly CloudKindsKept? kept;
  private readonly CloudKindsSettle settle;
  private readonly string? chosenFile;
  private readonly HashSet<string> chosen;
  private readonly Action changed;
  private readonly IReadOnlyList<CloudSettingFamily> families;
  /// This account's record store, read only: tells a first copy (a baseline) from a real change.
  public CloudRecordStore? Records { get; set; }

  public CloudSettingsOwner(IEnumerable<CloudSetting> settings, Func<bool?>? fullAccess = null, CloudKindsKept? kept = null, CloudKindsSettle? settle = null,
    string? chosenFile = null, Action? changed = null, IEnumerable<CloudSettingFamily>? families = null)
  {
    this.families = families?.ToArray() ?? [];
    this.settings = settings.ToDictionary(s => s.Entity, StringComparer.Ordinal);
    this.fullAccess = fullAccess ?? (() => false); this.kept = kept; this.chosenFile = chosenFile; this.changed = changed ?? (() => { });
    this.settle = settle ?? new CloudKindsSettle(0, () => 0);
    chosen = new(StringComparer.Ordinal);
    if (chosenFile is not null && File.Exists(chosenFile))
      try { chosen.UnionWith(JsonSerializer.Deserialize<List<string>>(File.ReadAllBytes(chosenFile)) ?? []); } catch (JsonException) { }
  }
  private void SaveChosen() { if (chosenFile is not null) new CloudFileSlot(chosenFile).Write(JsonSerializer.SerializeToUtf8Bytes(chosen.Order(StringComparer.Ordinal).ToList())); }

  public CloudRecordAdapter Adapter(CloudRecordStore store, string account, string deviceId, CloudRecordOrigins origins)
  {
    Records = store;
    return new(DomainName, InventoryRowName, SourceIdName, [AppKind, PreferenceKind], store, account, deviceId, this, origins, Exclusions);
  }

  // ---- the settings this PC has, by the Mac's names ----

  private static readonly HashSet<string> Providers = new(StringComparer.Ordinal) { "claude", "codex", "gemini", "shell" };
  private static bool Bool(CloudJson v) => v is CloudJson.Bool;
  private static Func<CloudJson, bool> Number(double min, double max) => v => CloudRecordJson.Number(v) is { } n && double.IsFinite(n) && n >= min && n <= max;
  private static Func<CloudJson, bool> Text(int maximum) => v => CloudRecordJson.Text(v) is { } s && s.Length <= maximum && !s.Any(char.IsControl);

  /// This PC's settings on the Mac's list, with the Mac's defaults (SettingsSchema / NativeStateStore.defaults).
  public static IReadOnlyList<CloudSetting> ForWindows(GeneralSettings general, TerminalAppearanceService appearance) =>
  [
    new("preference:restoreSessions", CloudJson.From(true), Bool, () => CloudJson.From(general.Read().RestoreSessions),
      v => general.Save(general.Read() with { RestoreSessions = CloudRecordJson.Bool(v) == true })),
    new("setting:general.autoNameSessions", CloudJson.From(true), Bool, () => CloudJson.From(general.Read().AutoNameSessions),
      v => general.Save(general.Read() with { AutoNameSessions = CloudRecordJson.Bool(v) == true })),
    new("setting:general.copyOnSelect", CloudJson.From(false), Bool, () => CloudJson.From(general.Read().CopyOnSelect),
      v => general.Save(general.Read() with { CopyOnSelect = CloudRecordJson.Bool(v) == true })),
    new("preference:defaultProvider", CloudJson.From("claude"), v => CloudRecordJson.Text(v) is { } p && Providers.Contains(p),
      () => CloudJson.From(general.Read().DefaultProvider), v => general.Save(general.Read() with { DefaultProvider = CloudRecordJson.Text(v)! }), Widening: true),
    new("setting:appearance.terminalScheme", CloudJson.From("follow-app"),
      v => Text(128)(v) && (CloudRecordJson.Text(v) == "follow-app" || appearance.Palettes().Any(p => p.Id == CloudRecordJson.Text(v))),
      () => CloudJson.From(appearance.Preferences().Scheme), v => appearance.Set(scheme: CloudRecordJson.Text(v))),
    new("setting:appearance.terminalFontFamily", CloudJson.From(""), Text(128), () => CloudJson.From(appearance.Preferences().FontFamily),
      v => appearance.Set(fontFamily: CloudRecordJson.Text(v))),
    new("setting:appearance.terminalFontSize", CloudJson.From(13), v => Number(9, 24)(v) && CloudRecordJson.Exact(CloudRecordJson.Number(v)!.Value) is not null,
      () => CloudJson.From(appearance.Preferences().FontSize), v => appearance.Set(fontSize: (int)CloudRecordJson.Number(v)!.Value)),
  ];

  private static CloudJson.Object Record(string key, CloudJson value) => CloudRecordJson.Object([("key", CloudJson.From(key)), ("value", value)]);
  /// CLOUD-KINDS-2, rule 1: a setting still at its default here and never handed on is not this PC's record at all.
  private Dictionary<string, CloudJson.Object> Visible()
  {
    var result = new Dictionary<string, CloudJson.Object>(StringComparer.Ordinal);
    var added = false;
    foreach (var setting in settings.Values)
    {
      CloudJson value;
      try { value = setting.Read(); } catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { continue; }
      if (!chosen.Contains(setting.Entity))
      {
        if (CloudRecordAdapter.Equal(value, setting.Default)) continue;
        chosen.Add(setting.Entity); added = true;
      }
      result[setting.Entity] = Record(setting.Key, value);
    }
    if (added) SaveChosen();
    foreach (var family in families)
    {
      IReadOnlyDictionary<string, CloudJson> members;
      try { members = family.Read(); } catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { continue; }
      foreach (var (key, value) in members)
        if (key.StartsWith(family.KeyPrefix, StringComparison.Ordinal)) result[family.EntityPrefix + key[family.KeyPrefix.Length..]] = Record(key, value);
    }
    return result;
  }
  /// CLOUD-KINDS-2, rule 2: the Cloud's value of this setting is a first copy (a baseline: some device's setting as it was
  /// when Cloud was switched on there), never a change he made.
  private bool IsFirstCopy(string entity)
  {
    if (Records is not { } records) return false;
    var key = CloudRecordKey.Of(DomainName, entity);
    if (records.View(key, CloudMergeTables.Setting) is not { } view || !view.Stamps.TryGetValue("value", out var stamp)) return false;
    return records.GraphOf(key).IsBaseline(stamp.Op);
  }

  // ---- ICloudRecordOwner ----

  public IReadOnlyDictionary<string, CloudJson.Object> CloudRecords() => settle.Pass(Visible(), (a, b) => CloudRecordAdapter.Equal(a, b));

  public CloudRecordPlan CloudPlan(string entity, CloudJson.Object? cloud)
  {
    if (AppKind.IdOf(entity) is null && PreferenceKind.IdOf(entity) is null) throw new CloudRecordRefusal("This is not a setting record.");
    var mine = Visible().GetValueOrDefault(entity);
    if (Family(entity) is { } family)
    {
      // A member of a family: newest wins, removals do not travel (a member is marked removed inside its own value).
      if (cloud is null) return new(mine);
      var key = entity[(entity.IndexOf(':') + 1)..];
      if (CloudRecordJson.Text(CloudRecordJson.Get(cloud, "key")) != key) return new(mine, Waiting: NotUsable);
      var member = CloudRecordJson.Get(cloud, "value") ?? CloudJson.Null.Value;
      if (!family.Accepts(key, member)) return new(mine, new Dictionary<string, string>(StringComparer.Ordinal) { ["value"] = NotUsable });
      return new(Record(key, member));
    }
    if (!settings.TryGetValue(entity, out var setting)) return new(mine, Waiting: NotListed);
    // Set back to its default on another device: nothing changes here.
    if (cloud is null) return new(mine);
    if (CloudRecordJson.Text(CloudRecordJson.Get(cloud, "key")) != setting.Key) return new(mine, Waiting: NotUsable);
    var value = CloudRecordJson.Get(cloud, "value") ?? CloudJson.Null.Value;
    // Rule 2: a first copy never replaces a value chosen here, in either direction, and nothing is listed for it.
    if (mine is not null && !CloudRecordAdapter.Equal(CloudRecordJson.Get(mine, "value"), value) && IsFirstCopy(entity)) return new(mine);
    string? reason = null;
    if (!setting.Accepts(value)) reason = NotUsable;
    else if (setting.Widening && (mine is null || !CloudRecordAdapter.Equal(CloudRecordJson.Get(mine, "value"), value)) && fullAccess() != true) reason = WideningHeld;
    if (reason is not null) return new(mine, new Dictionary<string, string>(StringComparer.Ordinal) { ["value"] = reason });
    return new(Record(setting.Key, value));
  }

  private CloudSettingFamily? Family(string entity) => families.FirstOrDefault(f => entity.StartsWith(f.EntityPrefix, StringComparison.Ordinal) && entity.Length > f.EntityPrefix.Length);

  public void CloudWrite(string entity, CloudJson.Object value, CloudJson.Object? expecting)
  {
    if (Family(entity) is { } family)
    {
      var key = entity[(entity.IndexOf(':') + 1)..];
      if (CloudRecordJson.Text(CloudRecordJson.Get(value, "key")) != key) throw new CloudFailure("invalid_request");
      if (!CloudRecordAdapter.Equal(Visible().GetValueOrDefault(entity), expecting))
        throw new CloudRecordRefusal("This setting changed on this PC while a change from another device was being applied; it is applied on the next try.");
      try { family.Write(key, CloudRecordJson.Get(value, "value") ?? CloudJson.Null.Value); }
      catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { throw new CloudRecordRefusal("Not applied on this PC: " + error.Message); }
      settle.Wrote(entity, value);
      return;
    }
    if (!settings.TryGetValue(entity, out var setting) || CloudRecordJson.Text(CloudRecordJson.Get(value, "key")) != setting.Key) throw new CloudFailure("invalid_request");
    var before = Visible().GetValueOrDefault(entity);
    if (!CloudRecordAdapter.Equal(before, expecting))
      throw new CloudRecordRefusal("This setting changed on this PC while a change from another device was being applied; it is applied on the next try.");
    try { setting.Write(CloudRecordJson.Get(value, "value") ?? CloudJson.Null.Value); }
    catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { throw new CloudRecordRefusal("Not applied on this PC: " + error.Message); }
    if (before is not null && !CloudRecordAdapter.Equal(before, value)) kept?.Keep(entity, before);
    if (chosen.Add(entity)) SaveChosen();
    settle.Wrote(entity, value);
  }

  public void CloudImported(IReadOnlyList<string> entities) { if (entities.Count > 0) changed(); }

  /// A change of the device-trust setting looks at held default-AI choices again.
  public string CloudContext() => fullAccess() switch { true => "access:full", false => "access:ask", null => "access:?" };
}
