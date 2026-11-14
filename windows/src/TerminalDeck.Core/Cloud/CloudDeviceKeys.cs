using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

/// This device's own identity: a random device id, a P-256 signing key and a P-256 key-agreement key, made on this
/// device at the person's first sign-in. The private halves exist only inside the protected record
/// (`ICloudSecretStore`) and in memory while used; nothing here prints or returns them.
public sealed class CloudDeviceKeys
{
  public string DeviceId { get; }
  private readonly byte[] signing;
  private readonly byte[] wrapping;
  private CloudDeviceKeys(string deviceId, byte[] signing, byte[] wrapping) { DeviceId = deviceId; this.signing = signing; this.wrapping = wrapping; }
  public override string ToString() => "<Cloud device keys " + DeviceId + ">";

  public static CloudDeviceKeys Fresh()
  {
    using var sign = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    using var wrap = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
    return new(Guid.NewGuid().ToString("D"), sign.ExportPkcs8PrivateKey(), wrap.ExportPkcs8PrivateKey());
  }
  internal static CloudDeviceKeys Load(string deviceId, string signing, string wrapping)
  {
    if (!CloudDeviceCode.IsDeviceId(deviceId)) throw new CloudFailure("invalid_request");
    var keys = new CloudDeviceKeys(deviceId, CloudWire.FromBase64Url(signing) ?? throw new CloudFailure("invalid_request"), CloudWire.FromBase64Url(wrapping) ?? throw new CloudFailure("invalid_request"));
    _ = keys.Registration("check", "0"); // Refuses a record whose keys do not open.
    return keys;
  }
  internal (string Signing, string Wrapping) Sealed() => (CloudWire.Base64Url(signing), CloudWire.Base64Url(wrapping));

  public CloudDeviceRegistration Registration(string label, string appVersion, string platform = "windows")
  {
    using var sign = ECDsa.Create(); sign.ImportPkcs8PrivateKey(signing, out _);
    using var wrap = ECDiffieHellman.Create(); wrap.ImportPkcs8PrivateKey(wrapping, out _);
    return new(DeviceId, label, platform, appVersion, Jwk(sign.ExportParameters(false).Q), Jwk(wrap.ExportParameters(false).Q));
  }
  private static CloudPublicJwk Jwk(ECPoint q) => new("EC", "P-256", CloudWire.Base64Url(q.X), CloudWire.Base64Url(q.Y));

  /// The service's device proof (user.ts): `TD-CLOUD-1\n{method}\n{path and query}\n{time ms}\n{request id}\n{sha256 hex of
  /// the body}`, ECDSA P-256 / SHA-256, the 64-byte r||s form, base64url.
  public IReadOnlyDictionary<string, string> Proof(string method, string pathAndQuery, byte[] body, long timeMs, string requestId)
  {
    if (method is not ("GET" or "POST") || !pathAndQuery.StartsWith("/v1/", StringComparison.Ordinal) || pathAndQuery.Contains('\n') || pathAndQuery.Contains('\r'))
      throw new CloudFailure("invalid_request");
    var message = Encoding.UTF8.GetBytes($"TD-CLOUD-1\n{method}\n{pathAndQuery}\n{timeMs}\n{requestId}\n{CloudWire.Sha256Hex(body)}");
    using var sign = ECDsa.Create(); sign.ImportPkcs8PrivateKey(signing, out _);
    var signature = sign.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    return new Dictionary<string, string> { ["X-TD-Device"] = DeviceId, ["X-TD-Time"] = timeMs.ToString(System.Globalization.CultureInfo.InvariantCulture), ["X-TD-Request"] = requestId, ["X-TD-Signature"] = CloudWire.Base64Url(signature) };
  }
}

/// The 80-bit code a person compares between devices, computed as the Mac computes it (BackendCloudDeviceCode).
public static class CloudDeviceCode
{
  public static bool IsDeviceId(string text) => text.Length == 36 && text.Select((c, i) => i is 8 or 13 or 18 or 23 ? c == '-' : c is >= '0' and <= '9' or >= 'a' and <= 'f').All(ok => ok);
  /// SHA-256 hex of `{"crv":"P-256","kty":"EC","x":…,"y":…}`; null unless the key is a real P-256 point written canonically.
  public static string? KeyId(CloudPublicJwk key)
  {
    if (key.Kty != "EC" || key.Crv != "P-256" || key.Y is null) return null;
    var x = CloudWire.FromBase64Url(key.X); var y = CloudWire.FromBase64Url(key.Y);
    if (x is not { Length: 32 } || y is not { Length: 32 } || CloudWire.Base64Url(x) != key.X || CloudWire.Base64Url(y) != key.Y) return null;
    try { using var check = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = x, Y = y } }); check.ExportParameters(false); }
    catch (CryptographicException) { return null; }
    return CloudWire.Sha256Hex(Encoding.UTF8.GetBytes("{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"" + key.X + "\",\"y\":\"" + key.Y + "\"}"));
  }
  /// The first 80 bits of SHA-256("TD-CLOUD-DEVICE-CODE-1\n" + deviceId + "\n" + keyId) as `XXXX XXXX XXXX XXXX XXXX`.
  public static string? Code(string deviceId, CloudPublicJwk key)
  {
    if (!IsDeviceId(deviceId) || KeyId(key) is not { } keyId) return null;
    var hex = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("TD-CLOUD-DEVICE-CODE-1\n" + deviceId + "\n" + keyId)).AsSpan(0, 10));
    return string.Join(' ', Enumerable.Range(0, 5).Select(i => hex.Substring(i * 4, 4)));
  }
}
