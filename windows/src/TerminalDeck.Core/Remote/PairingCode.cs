using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Org.BouncyCastle.Crypto.Generators;

namespace TerminalDeck.Core.Remote;

public sealed class RendezvousIdentity : IDisposable
{
  internal byte[] HostSecret { get; }
  public string HostId => PairingCode.HostId(HostSecret);
  public NoiseIdentity Keys { get; }
  internal RendezvousIdentity(byte[] secret, NoiseIdentity keys) { HostSecret = secret; Keys = keys; }
  public void Dispose() { CryptographicOperations.ZeroMemory(HostSecret); Keys.Dispose(); }
}

public static class PairingCode
{
  public const string Salt = "terminaldeck-machine-pairing-v1";
  private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

  public static string? Normalize(string raw)
  {
    if (raw.Length > 256) return null;
    var digits = new StringBuilder(6);
    foreach (var rune in raw.EnumerateRunes())
    {
      if (rune.Value is >= '0' and <= '9')
      {
        digits.Append((char)rune.Value);
        if (digits.Length > 6) return null;
      }
      else if (Rune.IsLetter(rune)) return null;
    }
    return digits.Length == 6 ? digits.ToString() : null;
  }

  public static RendezvousIdentity Derive(string raw)
  {
    var code = Normalize(raw) ?? throw new ProtocolException("That is not a pairing code. It is six digits.");
    var seed = SCrypt.Generate(Encoding.ASCII.GetBytes(code), Encoding.ASCII.GetBytes(Salt), 16384, 8, 1, 64);
    try { return new RendezvousIdentity(seed[..32], new NoiseIdentity(seed.AsSpan(32))); }
    finally { CryptographicOperations.ZeroMemory(seed); }
  }

  public static string HostId(ReadOnlySpan<byte> secret) => Base32(SHA256.HashData(secret), 26);
  public static bool IsHostId(string id) => id.Length == 26 && id.All(Alphabet.Contains);
  public static string Fingerprint(ReadOnlySpan<byte> key)
  {
    var digest = SHA256.HashData([..Encoding.ASCII.GetBytes("terminaldeck-fingerprint"), ..key]);
    var text = Base32(digest.AsSpan(0, 15), 24);
    return string.Join('-', Enumerable.Range(0, 6).Select(i => text.Substring(i * 4, 4)));
  }

  private static string Base32(ReadOnlySpan<byte> bytes, int maximum)
  {
    var result = new StringBuilder(maximum);
    uint buffer = 0;
    var bits = 0;
    foreach (var b in bytes)
    {
      buffer = (buffer << 8) | b;
      bits += 8;
      while (bits >= 5)
      {
        bits -= 5;
        result.Append(Alphabet[(int)((buffer >> bits) & 31)]);
        if (result.Length == maximum) return result.ToString();
      }
    }
    return result.ToString();
  }
}

public sealed record MachineOffer(Uri RelayUrl, string HostId, byte[] PublicKey, string Name, string Platform)
{
  public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(new
  {
    t = "machine", relayUrl = RelayUrl.AbsoluteUri.TrimEnd('/'), hostId = HostId,
    publicKey = Convert.ToBase64String(PublicKey), name = Name, platform = Platform
  });

  public static MachineOffer Decode(ReadOnlySpan<byte> payload)
  {
    if (payload.Length > 4096) throw new ProtocolException("The pairing offer is too large.");
    try
    {
      using var document = JsonDocument.Parse(payload.ToArray());
      var root = document.RootElement;
      if (root.GetProperty("t").GetString() != "machine") throw new FormatException();
      var relay = new Uri(root.GetProperty("relayUrl").GetString()!, UriKind.Absolute);
      RelayEndpoint.Validate(relay);
      var hostId = root.GetProperty("hostId").GetString()!;
      if (!PairingCode.IsHostId(hostId)) throw new FormatException();
      var text = root.GetProperty("publicKey").GetString()!;
      if (!Regex.IsMatch(text, "^[A-Za-z0-9+/_-]+={0,2}$", RegexOptions.CultureInvariant)) throw new FormatException();
      var key = Convert.FromBase64String(text.TrimEnd('=').Replace('-', '+').Replace('_', '/').PadRight((text.TrimEnd('=').Length + 3) / 4 * 4, '='));
      if (key.Length != 32) throw new FormatException();
      return new MachineOffer(relay, hostId, key,
        root.TryGetProperty("name", out var name) ? name.GetString() ?? "" : "",
        root.TryGetProperty("platform", out var platform) ? platform.GetString() ?? "unknown" : "unknown");
    }
    catch (Exception ex) when (ex is JsonException or KeyNotFoundException or FormatException or InvalidOperationException or ArgumentException)
    { throw new ProtocolException("The pairing offer is unusable."); }
  }
}

public static class RelayEndpoint
{
  public static readonly Uri Default = new("wss://relay.terminaldeck.dev");
  public static void Validate(Uri uri)
  {
    if (!uri.IsAbsoluteUri || uri.Host.Length == 0 || uri.UserInfo.Length != 0 ||
      (uri.Scheme != "wss" && !(uri.Scheme == "ws" && uri.IsLoopback)))
      throw new ProtocolException("Choose a secure relay address.");
  }
  public static Uri Host(Uri relay) => Build(relay, "/v1/host", "");
  public static Uri Join(Uri relay, string hostId)
  {
    if (!PairingCode.IsHostId(hostId)) throw new ProtocolException("The host address is unusable.");
    return Build(relay, "/v1/join", "host=" + hostId);
  }
  private static Uri Build(Uri relay, string path, string query)
  {
    Validate(relay);
    return new UriBuilder(relay) { Path = path, Query = query, Fragment = "" }.Uri;
  }
}
