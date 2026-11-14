using System.Globalization;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// Device trust on this PC (the Mac's BackendCloudTrust.swift, design cloud-device-trust-design.md revision 2).
// Every device keeps its OWN list of the device keys the person trusted ON THAT DEVICE. A pack is used only when its
// signature checks against a key on that list: the signer decides, never a field inside the pack and never the
// service's word. The list grows only by this PC's own sign-in (its own key, `AddSelf`), by the person's press in
// this PC's own window (`Trust`) and, in "Automatically, with my account" (owner, 13 Nov), by the account's own device
// list read at sign-in and every later check (`TrustByAccount`, CloudTrustStore.Account.cs). Nothing here is reachable
// from a tool, a pipe or a settings key.

/// The sync core's question, asked at the moment of applying each pack.
public interface ICloudDeviceTrust
{
  /// The signing key stored on this PC for `deviceId`, only while that entry is trusted. Null for an unknown or stopped
  /// device and when the list cannot be read (its packs then wait: fail safe).
  CloudPublicJwk? TrustedSigningKey(string deviceId);
}

/// Where the list lives. Windows: `WindowsCloudTrustStore` (a DPAPI file whose HMAC key sits in Credential Manager).
/// `Read` returns null only when nothing was ever saved; a damaged or foreign record throws.
public interface ICloudTrustSlot
{
  byte[]? Read();
  void Write(byte[] bytes);
}

public sealed record CloudTrustedDevice(string DeviceId, CloudPublicJwk SignKey, string KeyId, string Name, string Trust, string How, long TrustedAt,
  long? StoppedAt = null, string? StopReason = null)
{
  /// Only "trusted" lets a pack apply ("stopped" does not).
  public bool Trusted => Trust == "trusted";
  public CloudJson ToJson() => CloudJson.Obj(("deviceId", CloudJson.From(DeviceId)), ("signKey", CloudP256.Json(SignKey)), ("keyId", CloudJson.From(KeyId)),
    ("name", CloudJson.From(Name)), ("trust", CloudJson.From(Trust)), ("how", CloudJson.From(How)), ("trustedAt", CloudJson.From(TrustedAt)),
    ("stoppedAt", StoppedAt is { } s ? CloudJson.From(s) : null), ("stopReason", StopReason is { } r ? CloudJson.From(r) : null));
  public static CloudTrustedDevice FromJson(CloudJson value) => value is CloudJson.Object o && o["signKey"] is { } key
    ? new(CloudFields.Text(o, "deviceId"), CloudP256.FromJson(key), CloudFields.Text(o, "keyId"), CloudFields.Text(o, "name"), CloudFields.Text(o, "trust"),
      CloudFields.Text(o, "how"), CloudFields.Integer(o, "trustedAt"), CloudFields.OptionalInteger(o, "stoppedAt"), CloudFields.OptionalText(o, "stopReason"))
    : throw new CloudFailure("invalid_request");
}

/// One per account on each device. Kept at sign-out. Never synced.
public sealed record CloudTrustedList(int V, string Issuer, string Subject, long Revision, IReadOnlyList<CloudTrustedDevice> Devices)
{
  public byte[] Canonical() => CloudCanonical.Encode(CloudJson.Obj(("v", CloudJson.From(V)),
    ("subject", CloudJson.Obj(("issuer", CloudJson.From(Issuer)), ("sub", CloudJson.From(Subject)))), ("revision", CloudJson.From(Revision)),
    ("devices", CloudJson.Arr(Devices.Select(d => d.ToJson())))));
  public static CloudTrustedList Parse(byte[] bytes)
  {
    if (bytes.Length > 409_600 || CloudJson.Parse(bytes) is not CloudJson.Object o || o["subject"] is not CloudJson.Object subject || o["devices"] is not CloudJson.Array devices)
      throw new CloudFailure("invalid_request");
    return new((int)CloudFields.Integer(o, "v"), CloudFields.Text(subject, "issuer"), CloudFields.Text(subject, "sub"), CloudFields.Integer(o, "revision"),
      devices.Items.Select(CloudTrustedDevice.FromJson).ToArray());
  }
}

/// What a trust sheet showed when it was drawn (R1): the device, the key and the code computed from that key. This,
/// and nothing fetched later, is what a press stores.
public sealed record CloudTrustCapture(string DeviceId, string Name, CloudPublicJwk SignKey, string KeyId, string Code)
{
  /// The capture for a row as the sheet draws it; null for a row no sheet may offer (no readable key, a bad id).
  public static CloudTrustCapture? Shown(string deviceId, string name, CloudPublicJwk signKey) =>
    CloudDeviceCode.KeyId(signKey) is { } keyId && CloudDeviceCode.Code(deviceId, keyId) is { } code ? new(deviceId, name, signKey, keyId, code) : null;
}

/// The newest device list read after the press: it can only cancel a press, never supply a key.
public sealed record CloudTrustLatestRow(string DeviceId, string? KeyId, bool SameCode, bool SameKey, bool Removed);

public enum CloudTrustRefusalKind { RemoteInput, ListChanged, SameCode, SameKey, ListFull, Unreadable, NotSaved }

/// Why a trust press changed nothing. `Words` are shown on the Cloud page as they are.
public sealed class CloudTrustRefusal(CloudTrustRefusalKind kind) : Exception("Cloud trust refused: " + kind)
{
  public CloudTrustRefusalKind Kind { get; } = kind;
  public string Words => Kind switch
  {
    CloudTrustRefusalKind.RemoteInput => "This PC was just being controlled from another device, so nothing was trusted. Wait a moment and choose Trust again yourself.",
    CloudTrustRefusalKind.ListChanged => "Cloud's device list changed, so nothing was trusted. Compare the code again.",
    CloudTrustRefusalKind.SameCode => "Two devices show the same code. Do not trust either.",
    CloudTrustRefusalKind.SameKey => "Two devices use the same key. Do not trust either.",
    CloudTrustRefusalKind.ListFull => "This PC's device list is full.",
    CloudTrustRefusalKind.Unreadable => "This PC's trusted-device list could not be read, so changes from other devices wait.",
    _ => "This PC could not save its trusted-device list. Nothing was changed."
  };
}

/// The one owner of this PC's trusted list for one account (BackendCloudTrustStore). Thread-safe.
public sealed partial class CloudTrustStore : ICloudDeviceTrust
{
  public const int Limit = 256;
  public string Issuer { get; }
  public string Subject { get; }
  private readonly ICloudTrustSlot slot;
  private readonly Func<long> now;
  /// R3: true while a press cannot be taken as the person's own (the app's own remote-input path acted just now; on
  /// Windows the two-second guard). No default: whoever builds a list must say how a press is checked.
  private readonly Func<bool> pressRefused;
  private readonly object gate = new();
  private CloudTrustedList? cached;

  public CloudTrustStore(string issuer, string subject, ICloudTrustSlot slot, Func<bool> pressRefused, Func<long>? now = null)
  {
    Issuer = issuer; Subject = subject; this.slot = slot; this.pressRefused = pressRefused;
    this.now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
  }

  /// The list as stored. Throws `Unreadable` when the slot cannot be read or holds something this PC must not use
  /// (another account's list, an unknown version, a damaged entry): callers then treat every device as not trusted.
  public CloudTrustedList List()
  {
    lock (gate)
    {
      if (cached is not null) return cached;
      byte[]? data;
      try { data = slot.Read(); } catch (Exception) { throw new CloudTrustRefusal(CloudTrustRefusalKind.Unreadable); }
      if (data is null) return cached = new(1, Issuer, Subject, 0, []);
      CloudTrustedList stored;
      try { stored = CloudTrustedList.Parse(data); } catch (CloudFailure) { throw new CloudTrustRefusal(CloudTrustRefusalKind.Unreadable); }
      if (stored.V != 1 || stored.Issuer != Issuer || stored.Subject != Subject || stored.Devices.Count > Limit
        || stored.Devices.Select(d => d.DeviceId).Distinct(StringComparer.Ordinal).Count() != stored.Devices.Count
        || stored.Devices.Select(d => d.KeyId).Distinct(StringComparer.Ordinal).Count() != stored.Devices.Count
        || !stored.Devices.All(d => CloudDeviceCode.IsDeviceId(d.DeviceId) && CloudDeviceCode.KeyId(d.SignKey) == d.KeyId))
        throw new CloudTrustRefusal(CloudTrustRefusalKind.Unreadable);
      return cached = stored;
    }
  }
  private void Save(List<CloudTrustedDevice> devices, CloudTrustedList old)
  {
    var next = old with { Revision = old.Revision + 1, Devices = devices.ToArray() };
    var bytes = next.Canonical();
    try { slot.Write(bytes); } catch (Exception) { cached = null; throw new CloudTrustRefusal(CloudTrustRefusalKind.NotSaved); }
    // Read back: the list is only what the slot really holds.
    byte[]? stored;
    try { stored = slot.Read(); } catch (Exception) { stored = null; }
    if (stored is null || !stored.AsSpan().SequenceEqual(bytes)) { cached = null; throw new CloudTrustRefusal(CloudTrustRefusalKind.NotSaved); }
    cached = next;
  }

  /// Sign-in and every later start: this PC's own identity joins the list (`how: self`). This PC made that key, so no
  /// press is needed. Writes nothing when it is there. A stored key is never replaced.
  public void AddSelf(CloudDeviceRegistration registration)
  {
    lock (gate)
    {
      if (!CloudDeviceCode.IsDeviceId(registration.DeviceId) || CloudDeviceCode.KeyId(registration.SignPublicJwk) is not { } keyId) throw new CloudFailure("invalid_request");
      var old = List();
      if (old.Devices.FirstOrDefault(d => d.DeviceId == registration.DeviceId) is { } entry)
      {
        if (entry.KeyId != keyId) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
        return;
      }
      // One key, one device: a key the list already holds for another device is never added again.
      if (old.Devices.Any(d => d.KeyId == keyId)) throw new CloudTrustRefusal(CloudTrustRefusalKind.SameKey);
      if (old.Devices.Count >= Limit) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListFull);
      Save([.. old.Devices, new(registration.DeviceId, registration.SignPublicJwk, keyId, PlainName(registration.Label), "trusted", "self", now())], old);
    }
  }

  /// R3, asked at the moment of the press and before anything is awaited on the network.
  public void RequirePress() { if (pressRefused()) throw new CloudTrustRefusal(CloudTrustRefusalKind.RemoteInput); }

  /// The ONLY way a device other than this PC becomes trusted: the person's press in this PC's own window. `captured`
  /// is what the sheet showed when it was drawn: the key stored is that key. `latest`, a device list read after the
  /// press, can only cancel it. `restore` marks the new-device sheet. After it returns, the caller asks the sync core
  /// to release that device's waiting packs (`CloudJudgedFeed.ReleaseHeldAsync`).
  public void Trust(IReadOnlyList<CloudTrustCapture> captured, bool restore, IReadOnlyList<CloudTrustLatestRow>? latest)
  {
    lock (gate)
    {
      RequirePress();
      if (captured.Count == 0 || captured.Select(c => c.DeviceId).Distinct(StringComparer.Ordinal).Count() != captured.Count) throw new CloudFailure("invalid_request");
      var old = List();
      var devices = old.Devices.ToList();
      foreach (var item in captured)
      {
        // The code the person compared is the code of the key being stored, or nothing is stored.
        if (CloudDeviceCode.KeyId(item.SignKey) is not { } keyId || keyId != item.KeyId || CloudDeviceCode.Code(item.DeviceId, keyId) != item.Code)
          throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
        // Two devices that show one code: neither can be trusted.
        if (devices.Any(d => d.DeviceId != item.DeviceId && CloudDeviceCode.Code(d.DeviceId, d.KeyId) == item.Code)
          || captured.Any(c => c.DeviceId != item.DeviceId && c.Code == item.Code)) throw new CloudTrustRefusal(CloudTrustRefusalKind.SameCode);
        // Two devices with the SAME KEY: a signature could not say which of them made a pack.
        if (devices.Any(d => d.DeviceId != item.DeviceId && d.KeyId == keyId)
          || captured.Any(c => c.DeviceId != item.DeviceId && c.KeyId == item.KeyId)) throw new CloudTrustRefusal(CloudTrustRefusalKind.SameKey);
        if (latest is not null)
        {
          if (latest.FirstOrDefault(r => r.DeviceId == item.DeviceId) is not { } row || row.KeyId != item.KeyId) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
          if (row.SameCode) throw new CloudTrustRefusal(CloudTrustRefusalKind.SameCode);
          if (row.SameKey) throw new CloudTrustRefusal(CloudTrustRefusalKind.SameKey);
          if (row.Removed) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
        }
        var entry = new CloudTrustedDevice(item.DeviceId, item.SignKey, keyId, PlainName(item.Name), "trusted", restore ? "restore" : "click", now());
        var index = devices.FindIndex(d => d.DeviceId == item.DeviceId);
        if (index >= 0)
        {
          // A stored key is never replaced by a press; a device already trusted stays as it was.
          if (devices[index].KeyId != keyId) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListChanged);
          if (!devices[index].Trusted) devices[index] = entry;
        }
        else
        {
          if (devices.Count >= Limit) throw new CloudTrustRefusal(CloudTrustRefusalKind.ListFull);
          devices.Add(entry);
        }
      }
      if (devices.SequenceEqual(old.Devices)) return;
      Save(devices, old);
    }
  }

  public CloudPublicJwk? TrustedSigningKey(string deviceId) => Entry(deviceId) is { Trusted: true } found ? found.SignKey : null;
  /// The stored entry, or null when the device is not on the list or the list cannot be read (fail safe: everything waits).
  public CloudTrustedDevice? Entry(string deviceId)
  {
    try { return List().Devices.FirstOrDefault(d => d.DeviceId == deviceId); }
    catch (CloudTrustRefusal) { return null; }
  }
  /// True only when a trusted entry was made by a press ("click" or "restore") or, since the owner's 13 Nov choice
  /// "Automatically, with my account", by the account ("account"); this PC's own identities never count.
  /// Null when the list cannot be read (never "not confirmed" from a passing read error).
  public bool? HasDeviceTrustedByPress()
  {
    try { return List().Devices.Any(d => d.Trusted && d.How is "click" or "restore" or "account"); }
    catch (CloudTrustRefusal) { return null; }
  }

  public const string Unnamed = "Unnamed device";
  /// A device's name is text THE DEVICE chose, shown next to the code the person compares: one plain short line of
  /// letters, digits, spaces and a little punctuation, no run that reads like a code, at most 40 characters.
  public static string PlainName(string raw)
  {
    var cleaned = new StringBuilder();
    foreach (var rune in raw.EnumerateRunes().Take(400))
    {
      var category = Rune.GetUnicodeCategory(rune);
      var plain = Rune.IsLetter(rune) || category is UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber
        or UnicodeCategory.SpacingCombiningMark || (rune.IsAscii && "-_.,'()&+".Contains((char)rune.Value));
      if (plain) cleaned.Append(rune.ToString()); else cleaned.Append(' ');
    }
    static bool Hex(string word) => word.All(char.IsAsciiHexDigit);
    var words = new List<string>(); var run = new List<string>();
    void Flush() { if (run.Count < 3) words.AddRange(run); run.Clear(); }
    foreach (var word in cleaned.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries))
    {
      if (Hex(word) && word.Length >= 12) { Flush(); continue; }
      if (Hex(word) && word.Length == 4) run.Add(word); else { Flush(); words.Add(word); }
    }
    Flush();
    var line = string.Join(' ', words);
    if (line.Length == 0) return Unnamed;
    var info = new StringInfo(line);
    return info.LengthInTextElements > 40 ? info.SubstringByTextElements(0, 40) + "…" : line;
  }
}
