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
  /// the body}`, ECDSA P-256 / SHA-256, the 64-byte r||s form, base64url. PUT is a file upload to its granted transfer link.
  public IReadOnlyDictionary<string, string> Proof(string method, string pathAndQuery, byte[] body, long timeMs, string requestId)
  {
    if (method is not ("GET" or "POST" or "PUT") || !pathAndQuery.StartsWith("/v1/", StringComparison.Ordinal) || pathAndQuery.Contains('\n') || pathAndQuery.Contains('\r'))
      throw new CloudFailure("invalid_request");
    var message = Encoding.UTF8.GetBytes($"TD-CLOUD-1\n{method}\n{pathAndQuery}\n{timeMs}\n{requestId}\n{CloudWire.Sha256Hex(body)}");
    using var sign = ECDsa.Create(); sign.ImportPkcs8PrivateKey(signing, out _);
    var signature = sign.SignData(message, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    return new Dictionary<string, string> { ["X-TD-Device"] = DeviceId, ["X-TD-Time"] = timeMs.ToString(System.Globalization.CultureInfo.InvariantCulture), ["X-TD-Request"] = requestId, ["X-TD-Signature"] = CloudWire.Base64Url(signature) };
  }

  /// This device's ES256 signature (raw r||s, 64 bytes) over `bytes`: the signed pack descriptor of the sync engine.
  public byte[] Sign(byte[] bytes)
  {
    using var sign = ECDsa.Create(); sign.ImportPkcs8PrivateKey(signing, out _);
    return sign.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
  }
}
