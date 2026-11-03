using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Generators;

namespace TerminalDeck.Core.Remote;

public enum PhoneAccess { Look, Work, Full, Hoot }
public sealed record ApprovedDevice(string Id, string Name, string Platform, PhoneAccess Access, DateTimeOffset? PairedAt = null, DateTimeOffset? LastSeen = null, bool Connected = false);

// Verification material contains salted hashes, never a reusable bearer token.
public sealed class StoredDevice
{
  public required string Id { get; init; }
  public required string Name { get; set; }
  public required string Platform { get; init; }
  public required byte[] PublicKey { get; init; }
  public bool LocalWeb { get; init; }
  public required byte[] Salt { get; init; }
  public required byte[] CredentialHash { get; init; }
  public DateTimeOffset? PairedAt { get; init; }
  public DateTimeOffset? LastSeen { get; set; }
  public bool Approved { get; set; }
  public bool Revoked { get; set; }
  public PhoneAccess Access { get; set; }
  public override string ToString() => "<paired device>";
}

public interface IDeviceTrustPersistence
{
  IReadOnlyList<StoredDevice> Load();
  void Save(IReadOnlyList<StoredDevice> devices);
}

public sealed class PairingReceipt(string id, string name, string credential)
{
  public string DeviceId { get; } = id;
  public string DeviceName { get; } = name;
  public string Credential { get; } = credential;
  public override string ToString() => "<pairing receipt>";
}

public sealed partial class DeviceTrust
{
  private readonly IDeviceTrustPersistence persistence;
  private readonly TimeProvider clock;
  private readonly object gate = new();
  private List<StoredDevice> devices;
  private readonly Dictionary<string, string> connectedChannels = [];
  private readonly Dictionary<string, (int Count, DateTimeOffset Until)> failures = [];
  private readonly byte[] decoySalt = RandomNumberGenerator.GetBytes(16);
  public PairingWindow Pairing { get; }
  public event Action? Changed;
  public IReadOnlyList<ApprovedDevice> Pending()
  {
    lock (gate) return devices.Where(d => !d.Approved && !d.Revoked).Select(View).ToArray();
  }

  public DeviceTrust(IDeviceTrustPersistence persistence, TimeProvider? clock = null)
  {
    this.persistence = persistence;
    this.clock = clock ?? TimeProvider.System;
    Pairing = new PairingWindow(this.clock);
    devices = Clone(persistence.Load());
    if (devices.Count > 64 || devices.Select(d => d.Id).Distinct().Count() != devices.Count ||
      devices.Any(d => !ValidId(d.Id) || d.PublicKey.Length != 32 || d.Salt.Length != 16 || d.CredentialHash.Length != 32 || !Enum.IsDefined(d.Access)))
      throw new ProtocolException("The paired-device file could not be read safely.");
  }

  public IReadOnlyCollection<byte[]> KnownPeers
  {
    get { lock (gate) return devices.Where(d => !d.Revoked && !d.LocalWeb).Select(d => (byte[])d.PublicKey.Clone()).ToArray(); }
  }

  public IReadOnlyList<ApprovedDevice> List()
  {
    lock (gate) return devices.Where(d => d.Approved && !d.Revoked).Select(View).ToArray();
  }

  public PairingReceipt Redeem(string code, string name, string platform, ReadOnlySpan<byte> publicKey)
  {
    lock (gate)
    {
      if (!Pairing.Consume(code)) throw new ProtocolException("That pairing code is not right or has expired.");
      if (publicKey.Length != 32) throw Refused();
      var clean = Clean(name, 60);
      if (clean.Length == 0) throw new ProtocolException("Choose a device name.");
      var key = publicKey.ToArray();
      var previous = devices.FirstOrDefault(d => !d.Revoked && CryptographicOperations.FixedTimeEquals(d.PublicKey, key));
      if (previous is null && devices.Count(d => !d.Revoked) >= 64) throw new ProtocolException("This computer has too many paired devices.");
      var secret = RandomNumberGenerator.GetBytes(32);
      var salt = RandomNumberGenerator.GetBytes(16);
      try
      {
        var id = previous?.Id ?? Encode(RandomNumberGenerator.GetBytes(16));
        var row = new StoredDevice
        {
          Id = id, Name = clean, Platform = Clean(platform, 40), PublicKey = key,
          Salt = salt, CredentialHash = Hash(secret, salt), Approved = previous?.Approved ?? false,
          Access = previous?.Access ?? PhoneAccess.Full, Revoked = false, PairedAt = previous?.PairedAt ?? clock.GetUtcNow(), LastSeen = previous?.LastSeen
        };
        var next = Clone(devices.Where(d => !d.Revoked && d.Id != id).ToArray());
        next.Add(row);
        Commit(next);
        return new PairingReceipt(id, clean, id + "." + Encode(secret));
      }
      finally { CryptographicOperations.ZeroMemory(secret); }
    }
  }

  public void Approve(string id, PhoneAccess access)
  {
    lock (gate)
    {
      if (!Enum.IsDefined(access)) throw Refused();
      var next = Clone(devices);
      var row = next.FirstOrDefault(d => d.Id == id && !d.Revoked) ?? throw Refused();
      row.Access = access; row.Approved = true;
      Commit(next);
    }
  }

  public void Rename(string id, string name)
  {
    if (string.IsNullOrWhiteSpace(name) || name.Length > 128 || name != Clean(name, 128))
      throw new ArgumentException("Choose a device name with 1–128 characters and no control characters.");
    lock (gate)
    {
      var next = Clone(devices);
      var row = next.FirstOrDefault(d => d.Id == id && !d.Revoked) ?? throw Refused();
      row.Name = name;
      Commit(next);
    }
  }

  public bool DenyPending(string id)
  {
    lock (gate)
    {
      var next = Clone(devices);
      var row = next.FirstOrDefault(d => d.Id == id && !d.Approved && !d.Revoked);
      if (row is null) return false;
      row.Revoked = true;
      Commit(next); return true;
    }
  }

  public void Revoke(string id)
  {
    lock (gate)
    {
      var next = Clone(devices);
      var row = next.FirstOrDefault(d => d.Id == id) ?? throw Refused();
      row.Revoked = true; row.Approved = false;
      Commit(next);
    }
  }

  public ApprovedDevice Authenticate(string credential, ReadOnlySpan<byte> peerKey)
  {
    lock (gate)
    {
      if (credential.Length > 200 || peerKey.Length != 32) throw Refused();
      var address = Convert.ToHexString(peerKey);
      var now = clock.GetUtcNow();
      foreach (var expired in failures.Where(p => p.Value.Until <= now).Select(p => p.Key).ToArray()) failures.Remove(expired);
      if (failures.TryGetValue(address, out var strikes) && strikes.Count >= 5) throw Refused();
      var parts = credential.Split('.');
      var row = parts.Length == 2 ? devices.FirstOrDefault(d => d.Id == parts[0]) : null;
      byte[] secret = [];
      try
      {
        if (parts.Length != 2 || !ValidId(parts[0])) throw new FormatException();
        secret = Decode(parts[1]);
        if (secret.Length != 32) throw new FormatException();
        var actual = Hash(secret, row?.Salt ?? decoySalt);
        if (row is null || !CryptographicOperations.FixedTimeEquals(actual, row.CredentialHash) || row.Revoked ||
          !CryptographicOperations.FixedTimeEquals(peerKey, row.PublicKey)) throw new FormatException();
        if (!row.Approved) throw new ProtocolException("This device is waiting for approval. Approve it on this computer, then reconnect.");
        failures.Remove(address);
        return View(row);
      }
      catch (FormatException)
      {
        if (failures.Count >= 256) failures.Remove(failures.Keys.First());
        failures[address] = (strikes.Count + 1, now.AddMinutes(1));
        throw Refused();
      }
      finally { CryptographicOperations.ZeroMemory(secret); }
    }
  }

  /// The approved device a sealed connection's key belongs to, or null (pending, revoked, unknown, local web).
  public ApprovedDevice? ApprovedFor(ReadOnlySpan<byte> peerKey)
  {
    lock (gate)
    {
      StoredDevice? match = null;
      foreach (var row in devices)
        if (row.Approved && !row.Revoked && !row.LocalWeb && row.PublicKey.Length == peerKey.Length && CryptographicOperations.FixedTimeEquals(row.PublicKey, peerKey)) match = row;
      return match is null ? null : View(match);
    }
  }

  public ApprovedDevice RequireCurrent(string id, ReadOnlySpan<byte> peerKey)
  {
    lock (gate)
    {
      var row = devices.FirstOrDefault(d => d.Id == id && d.Approved && !d.Revoked);
      if (row is null || !CryptographicOperations.FixedTimeEquals(row.PublicKey, peerKey)) throw Refused();
      return View(row);
    }
  }

  internal void Connected(string id, string channel)
  {
    lock (gate)
    {
      if (!devices.Any(d => d.Id == id && d.Approved && !d.Revoked)) throw Refused();
      connectedChannels[channel] = id;
      ObserveSeen(id);
    }
  }
  internal void Disconnected(string channel)
  {
    lock (gate) if (connectedChannels.Remove(channel, out var id)) ObserveSeen(id);
  }
  private void ObserveSeen(string id)
  {
    var next = Clone(devices);
    var row = next.FirstOrDefault(d => d.Id == id);
    if (row is null) return;
    row.LastSeen = clock.GetUtcNow();
    // Presence is observational. A full disk must not turn a valid login into an authentication failure.
    try { persistence.Save(Clone(next)); }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException) { }
    devices = next; Changed?.Invoke();
  }

  private void Commit(List<StoredDevice> next) { persistence.Save(Clone(next)); devices = next; Changed?.Invoke(); }
  private static List<StoredDevice> Clone(IReadOnlyList<StoredDevice> rows) =>
    JsonSerializer.Deserialize<List<StoredDevice>>(JsonSerializer.SerializeToUtf8Bytes(rows)) ?? [];
  private static byte[] Hash(byte[] secret, byte[] salt) => SCrypt.Generate(secret, salt, 16384, 8, 1, 32);
  private ApprovedDevice View(StoredDevice d) => new(d.Id, d.Name, d.Platform, d.Access, d.PairedAt, d.LastSeen, connectedChannels.Values.Contains(d.Id));
  private static string Clean(string text, int limit) => new string(text.Where(c => !char.IsControl(c) && c is not (>= '\u2028' and <= '\u202e') && c is not (>= '\u2066' and <= '\u2069')).Take(limit).ToArray()).Trim();
  private static bool ValidId(string id) => id.Length is > 0 and <= 128 && id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
  private static string Encode(byte[] value) => Convert.ToBase64String(value).TrimEnd('=').Replace('+', '-').Replace('/', '_');
  private static byte[] Decode(string value)
  {
    if (!ValidId(value)) throw new FormatException();
    return Convert.FromBase64String(value.Replace('-', '+').Replace('_', '/').PadRight((value.Length + 3) / 4 * 4, '='));
  }
  private static ProtocolException Refused() => new("This device is not allowed in.");
}
