using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

/// The 80-bit code a person compares between devices, computed as the Mac computes it (BackendCloudTrust.swift
/// BackendCloudDeviceCode). The same key and device id give the same code on every platform.
public static class CloudDeviceCode
{
  /// A device id exactly as it travels: a lower-case UUID. Anything else has no code, so a look-alike id (another case,
  /// extra characters, a line break) can never be shown with another device's code.
  public static bool IsDeviceId(string text) => text.Length == 36 && text.Select((c, i) => i is 8 or 13 or 18 or 23 ? c == '-' : c is >= '0' and <= '9' or >= 'a' and <= 'f').All(ok => ok);

  /// SHA-256, lower-case hex, of `{"crv":"P-256","kty":"EC","x":…,"y":…}`; null unless the key is a real P-256 point
  /// written the one canonical way (32-byte coordinates in strict base64url).
  public static string? KeyId(CloudPublicJwk key)
  {
    if (key.Kty != "EC" || key.Crv != "P-256" || key.Y is null || !CloudP256.IsPublicKey(key)) return null;
    // Sorted names, no spaces; base64url text needs no escaping, so this is the RFC 8785 form.
    return CloudBytes.Sha256Hex(Encoding.UTF8.GetBytes("{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"" + key.X + "\",\"y\":\"" + key.Y + "\"}"));
  }
  /// The first 80 bits of SHA-256("TD-CLOUD-DEVICE-CODE-1\n" + deviceId + "\n" + keyId) as `XXXX XXXX XXXX XXXX XXXX`.
  public static string? Code(string deviceId, string keyId)
  {
    if (!IsDeviceId(deviceId) || keyId.Length != 64 || !keyId.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f')) return null;
    var hex = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("TD-CLOUD-DEVICE-CODE-1\n" + deviceId + "\n" + keyId)).AsSpan(0, 10));
    return string.Join(' ', Enumerable.Range(0, 5).Select(i => hex.Substring(i * 4, 4)));
  }
  public static string? Code(string deviceId, CloudPublicJwk key) => KeyId(key) is { } keyId ? Code(deviceId, keyId) : null;
}
