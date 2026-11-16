using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Asn1.X9;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Crypto.Signers;
using Org.BouncyCastle.Utilities;
using BigInteger = Org.BouncyCastle.Math.BigInteger;

namespace TerminalDeck.Core.Cloud;

/// P-256 as CryptoKit uses it. Point checks, the public point of a raw 32-byte private scalar and the ECDH shared
/// secret (the 32-byte x coordinate, CryptoKit's SharedSecret) run in BouncyCastle, so they are the same managed code
/// on Windows and on this Mac; ES256 signing and verifying use .NET's ECDsa (Windows CNG), raw r||s.
public static class CloudP256
{
  private static readonly X9ECParameters Curve = ECNamedCurveTable.GetByName("P-256");
  private static readonly ECDomainParameters Domain = new(Curve);

  /// The point of a JWK, or null unless it is EC / P-256 with two strict 32-byte base64url coordinates on the curve.
  private static Org.BouncyCastle.Math.EC.ECPoint? Point(CloudPublicJwk key)
  {
    if (key.Kty != "EC" || key.Crv != "P-256" || key.Y is null) return null;
    try
    {
      var x = CloudBytes.Unbase64(key.X, 32); var y = CloudBytes.Unbase64(key.Y, 32);
      var point = Curve.Curve.DecodePoint([0x04, .. x, .. y]);
      return point.IsValid() && !point.IsInfinity ? point : null;
    }
    catch (Exception ex) when (ex is CloudFailure or ArgumentException or InvalidOperationException) { return null; }
  }
  public static bool IsPublicKey(CloudPublicJwk key) => Point(key) is not null;

  /// A verifying key, or null for anything that is not a real P-256 public key.
  public static ECDsa? ImportPublic(CloudPublicJwk key)
  {
    if (Point(key) is null) return null;
    try { return ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = CloudBytes.Unbase64(key.X, 32), Y = CloudBytes.Unbase64(key.Y!, 32) } }); }
    catch (CryptographicException) { return null; }
  }
  private static BigInteger Scalar(ReadOnlySpan<byte> privateScalar)
  {
    if (privateScalar.Length != 32) throw new CloudFailure("invalid_request");
    var d = new BigInteger(1, privateScalar.ToArray());
    if (d.SignValue <= 0 || d.CompareTo(Curve.N) >= 0) throw new CloudFailure("invalid_request");
    return d;
  }
  /// The public JWK of a raw 32-byte private scalar (CryptoKit rawRepresentation).
  public static CloudPublicJwk PublicKey(ReadOnlySpan<byte> privateScalar)
  {
    var q = Curve.G.Multiply(Scalar(privateScalar)).Normalize();
    return new("EC", "P-256", CloudBytes.Base64Url(q.AffineXCoord.GetEncoded()), CloudBytes.Base64Url(q.AffineYCoord.GetEncoded()));
  }
  /// An ES256 signer for a raw private scalar.
  public static ECDsa Signer(ReadOnlySpan<byte> privateScalar)
  {
    var jwk = PublicKey(privateScalar);
    return ECDsa.Create(new ECParameters
    {
      Curve = ECCurve.NamedCurves.nistP256, D = privateScalar.ToArray(),
      Q = new ECPoint { X = CloudBytes.Unbase64(jwk.X, 32), Y = CloudBytes.Unbase64(jwk.Y!, 32) }
    });
  }
  /// ECDH: the x coordinate of d·Peer, 32 bytes big-endian (CryptoKit sharedSecretFromKeyAgreement).
  public static byte[] SharedSecret(ReadOnlySpan<byte> privateScalar, CloudPublicJwk peer)
  {
    var point = Point(peer) ?? throw new CloudFailure("invalid_request");
    var agreement = new ECDHBasicAgreement();
    agreement.Init(new ECPrivateKeyParameters(Scalar(privateScalar), Domain));
    return BigIntegers.AsUnsignedByteArray(32, agreement.CalculateAgreement(new ECPublicKeyParameters(point, Domain)));
  }
  public static CloudJson Json(CloudPublicJwk key) => CloudJson.Obj(("crv", CloudJson.From(key.Crv)), ("kty", CloudJson.From(key.Kty)),
    ("x", CloudJson.From(key.X)), ("y", key.Y is { } y ? CloudJson.From(y) : null));
  public static CloudPublicJwk FromJson(CloudJson value) => value is CloudJson.Object o
    ? new(CloudFields.Text(o, "kty"), CloudFields.Text(o, "crv"), CloudFields.Text(o, "x"), CloudFields.OptionalText(o, "y"))
    : throw new CloudFailure("invalid_request");
}

/// The per-account saved-password root key wrapped for one device by another (CloudDeviceKeyEnvelope).
public sealed record CloudDeviceKeyEnvelope(int V, int Epoch, string TargetDeviceId, CloudPublicJwk EphemeralPublicJwk, string Salt, string Nonce,
  string Ciphertext, string Tag, string AuthorDeviceId, string Signature)
{
  public CloudJson.Object ToJson() => CloudJson.Obj(("v", CloudJson.From(V)), ("epoch", CloudJson.From(Epoch)), ("targetDeviceId", CloudJson.From(TargetDeviceId)),
    ("ephemeralPublicJwk", CloudP256.Json(EphemeralPublicJwk)), ("salt", CloudJson.From(Salt)), ("nonce", CloudJson.From(Nonce)),
    ("ciphertext", CloudJson.From(Ciphertext)), ("tag", CloudJson.From(Tag)), ("authorDeviceId", CloudJson.From(AuthorDeviceId)), ("signature", CloudJson.From(Signature)));
  public static CloudDeviceKeyEnvelope FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o || o["ephemeralPublicJwk"] is not { } jwk) throw new CloudFailure("invalid_request");
    return new((int)CloudFields.Integer(o, "v"), (int)CloudFields.Integer(o, "epoch"), CloudFields.Text(o, "targetDeviceId"), CloudP256.FromJson(jwk),
      CloudFields.Text(o, "salt"), CloudFields.Text(o, "nonce"), CloudFields.Text(o, "ciphertext"), CloudFields.Text(o, "tag"),
      CloudFields.Text(o, "authorDeviceId"), CloudFields.Text(o, "signature"));
  }
  public static CloudDeviceKeyEnvelope Parse(ReadOnlySpan<byte> utf8) => FromJson(CloudJson.Parse(utf8));
  /// What the AES-GCM AAD and the author's signature cover: the canonical envelope without ciphertext, tag and signature.
  public byte[] Aad() => CloudCanonical.Encode(ToJson().Without("ciphertext", "tag", "signature"));
}

/// The body a device wrap carries (CloudSecretsUnwrapped). The root key and canary stay base64url text here; callers
/// zero what they decode.
public sealed record CloudSecretsUnwrapped(int Epoch, string RootKey, string RecoveryVersion, string Canary)
{
  public override string ToString() => "<Cloud unwrapped key, epoch " + Epoch + ">";
}

public sealed record CloudApproval(string ApprovalId, string TargetDeviceId, string TargetKeyHash, string Challenge, long ExpiresAt)
{
  public CloudJson ToJson() => CloudJson.Obj(("approvalId", CloudJson.From(ApprovalId)), ("targetDeviceId", CloudJson.From(TargetDeviceId)),
    ("targetKeyHash", CloudJson.From(TargetKeyHash)), ("challenge", CloudJson.From(Challenge)), ("expiresAt", CloudJson.From(ExpiresAt)));
}

/// CloudSecretsCrypto.wrapDevice / unwrapDevice / keyHash / matchingCode / transferCode.
/// ECDH(ephemeral, target's wrap key) -> HKDF-SHA256(shared, salt, "TD-CLOUD-DEVICE-1\n{subject}\n{target}\n{epoch}") ->
/// AES-256-GCM over the canonical body, AAD = the canonical envelope without ciphertext, tag and signature; the author
/// signs AAD + ciphertext + tag with its P-256 device key.
public static class CloudKeyWrap
{
  private static byte[] DeviceKey(byte[] shared, byte[] salt, string subject, string targetDeviceId, int epoch) =>
    HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, salt, Encoding.UTF8.GetBytes($"TD-CLOUD-DEVICE-1\n{subject}\n{targetDeviceId}\n{epoch.ToString(CultureInfo.InvariantCulture)}"));
  private static bool IsSequence(string text) => text.Length > 0 && text.All(char.IsAsciiDigit) && (text == "0" || text[0] != '0') && ulong.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out _);

  /// Wraps `root` for `target`. In the app the ephemeral key, salt, nonce and canary are fresh random values (leave them
  /// null); fixed values are only for the golden vectors. `sign` returns the author device's 64-byte ES256 signature.
  public static (CloudDeviceKeyEnvelope Envelope, string CanaryHash) Wrap(byte[] root, string subject, CloudDeviceRegistration target, int epoch,
    string recoveryVersion, string author, Func<byte[], byte[]> sign, byte[]? ephemeralScalar = null, byte[]? salt = null, byte[]? nonce = null, byte[]? canary = null)
  {
    CloudBytes.Uuid(subject);
    ephemeralScalar ??= NewScalar(); salt ??= RandomNumberGenerator.GetBytes(32); nonce ??= RandomNumberGenerator.GetBytes(12); canary ??= RandomNumberGenerator.GetBytes(32);
    if (root.Length != 32 || canary.Length != 32 || salt.Length != 32 || nonce.Length != 12 || epoch <= 0 || !IsSequence(recoveryVersion)) throw new CloudFailure("invalid_request");
    CloudBytes.Uuid(target.DeviceId);
    var shared = CloudP256.SharedSecret(ephemeralScalar, target.WrapPublicJwk);
    var key = DeviceKey(shared, salt, subject, target.DeviceId, epoch);
    var header = new CloudDeviceKeyEnvelope(1, epoch, target.DeviceId, CloudP256.PublicKey(ephemeralScalar), CloudBytes.Base64Url(salt), CloudBytes.Base64Url(nonce),
      "", "", author, "");
    var aad = header.Aad();
    var plain = CloudCanonical.Encode(CloudJson.Obj(("epoch", CloudJson.From(epoch)), ("rootKey", CloudJson.From(CloudBytes.Base64Url(root))),
      ("recoveryVersion", CloudJson.From(recoveryVersion)), ("canary", CloudJson.From(CloudBytes.Base64Url(canary)))));
    try
    {
      var (ciphertext, tag) = CloudContentCrypto.Seal(plain, key, nonce, aad);
      var signature = sign([.. aad, .. ciphertext, .. tag]);
      if (signature.Length != 64) throw new CloudFailure("invalid_request");
      return (header with { Ciphertext = CloudBytes.Base64Url(ciphertext), Tag = CloudBytes.Base64Url(tag), Signature = CloudBytes.Base64Url(signature) },
        CloudBytes.Sha256Hex(canary));
    }
    finally { CryptographicOperations.ZeroMemory(plain); CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(shared); }
  }
  private static byte[] NewScalar()
  {
    using var key = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
    return key.ExportParameters(true).D!;
  }

  /// Opens a wrap addressed to this device. The author's signature is checked FIRST, under `authorKey` (P-256; Ed25519
  /// only for the "recovery" author); `sharedSecret` is this device's ECDH with the envelope's ephemeral key (for a raw
  /// wrap scalar: `peer => CloudP256.SharedSecret(scalar, peer)`).
  public static CloudSecretsUnwrapped Unwrap(CloudDeviceKeyEnvelope envelope, string subject, string targetDeviceId, int epoch, string version,
    string author, CloudPublicJwk authorKey, Func<CloudPublicJwk, byte[]> sharedSecret)
  {
    CloudBytes.Uuid(subject);
    if (envelope.V != 1 || envelope.Epoch != epoch || epoch <= 0 || envelope.TargetDeviceId != targetDeviceId || envelope.AuthorDeviceId != author
      || envelope.Ciphertext.Length >= 8192 || (author == "recovery" ? authorKey.Crv != "Ed25519" : authorKey.Crv != "P-256")) throw new CloudFailure("invalid_request");
    var aad = envelope.Aad();
    Verify(envelope.Signature, [.. aad, .. CloudBytes.Unbase64(envelope.Ciphertext), .. CloudBytes.Unbase64(envelope.Tag, 16)], authorKey);
    var shared = sharedSecret(envelope.EphemeralPublicJwk);
    var key = DeviceKey(shared, CloudBytes.Unbase64(envelope.Salt, 32), subject, targetDeviceId, epoch);
    byte[] plain = [];
    try
    {
      plain = CloudContentCrypto.Open(key, CloudBytes.Unbase64(envelope.Nonce, 12), CloudBytes.Unbase64(envelope.Ciphertext), CloudBytes.Unbase64(envelope.Tag, 16), aad);
      if (CloudJson.Parse(plain) is not CloudJson.Object body) throw new CloudFailure("invalid_request");
      var result = new CloudSecretsUnwrapped((int)CloudFields.Integer(body, "epoch"), CloudFields.Text(body, "rootKey"), CloudFields.Text(body, "recoveryVersion"), CloudFields.Text(body, "canary"));
      if (!IsSequence(result.RecoveryVersion)) throw new CloudFailure("invalid_request");
      if (result.Epoch != epoch || result.RecoveryVersion != version) throw new CloudFailure("version_changed");
      CryptographicOperations.ZeroMemory(CloudBytes.Unbase64(result.RootKey, 32)); CryptographicOperations.ZeroMemory(CloudBytes.Unbase64(result.Canary, 32));
      return result;
    }
    finally { CryptographicOperations.ZeroMemory(plain); CryptographicOperations.ZeroMemory(key); CryptographicOperations.ZeroMemory(shared); }
  }

  /// CloudSecretsCrypto.verify: a 64-byte signature; Ed25519 for an OKP key, otherwise ES256 raw r||s.
  public static void Verify(string signature, byte[] bytes, CloudPublicJwk key)
  {
    var raw = CloudBytes.Unbase64(signature, 64);
    if (key.Kty == "OKP" && key.Crv == "Ed25519" && key.Y is null)
    {
      var verifier = new Ed25519Signer();
      verifier.Init(false, new Ed25519PublicKeyParameters(CloudBytes.Unbase64(key.X, 32)));
      verifier.BlockUpdate(bytes, 0, bytes.Length);
      if (!verifier.VerifySignature(raw)) throw new CloudFailure("checksum_mismatch");
      return;
    }
    using var publicKey = CloudP256.ImportPublic(key) ?? throw new CloudFailure("invalid_request");
    if (!publicKey.VerifyData(bytes, raw, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)) throw new CloudFailure("checksum_mismatch");
  }

  /// sha256 hex of the canonical {signPublicJwk, wrapPublicJwk}; both must be real P-256 keys.
  public static string KeyHash(CloudDeviceRegistration device)
  {
    if (!CloudP256.IsPublicKey(device.SignPublicJwk) || !CloudP256.IsPublicKey(device.WrapPublicJwk)) throw new CloudFailure("invalid_request");
    return CloudBytes.Sha256Hex(CloudCanonical.Encode(CloudJson.Obj(("signPublicJwk", CloudP256.Json(device.SignPublicJwk)), ("wrapPublicJwk", CloudP256.Json(device.WrapPublicJwk)))));
  }
  public static CloudJson RegistrationJson(CloudDeviceRegistration device) => CloudJson.Obj(("deviceId", CloudJson.From(device.DeviceId)), ("label", CloudJson.From(device.Label)),
    ("platform", CloudJson.From(device.Platform)), ("appVersion", CloudJson.From(device.AppVersion)),
    ("signPublicJwk", CloudP256.Json(device.SignPublicJwk)), ("wrapPublicJwk", CloudP256.Json(device.WrapPublicJwk)));
  public static CloudDeviceRegistration RegistrationFromJson(CloudJson value) => value is CloudJson.Object o && o["signPublicJwk"] is { } sign && o["wrapPublicJwk"] is { } wrap
    ? new(CloudFields.Text(o, "deviceId"), CloudFields.Text(o, "label"), CloudFields.Text(o, "platform"), CloudFields.Text(o, "appVersion"), CloudP256.FromJson(sign), CloudP256.FromJson(wrap))
    : throw new CloudFailure("invalid_request");

  /// The short code both devices show before any root is wrapped: the target's id and key fingerprint only.
  public static string MatchingCode(CloudApproval approval) =>
    Groups(CloudBytes.Sha256Hex(Encoding.UTF8.GetBytes($"TD-CLOUD-APPROVAL-TARGET-2\n{approval.TargetDeviceId}\n{approval.TargetKeyHash}"))[..32]);
  /// The second code, binding the delivered key envelope. Both devices compute it from their own bytes.
  public static string TransferCode(string issuer, string subject, CloudApproval approval, CloudDeviceRegistration target, CloudPublicJwk authorKey, CloudDeviceKeyEnvelope envelope)
  {
    var binding = CloudJson.Obj(("subject", CloudJson.Obj(("issuer", CloudJson.From(issuer)), ("sub", CloudJson.From(subject)))), ("approval", approval.ToJson()),
      ("targetDeviceId", CloudJson.From(target.DeviceId)), ("targetKeyHash", CloudJson.From(KeyHash(target))), ("authorKey", CloudP256.Json(authorKey)),
      ("epoch", CloudJson.From(envelope.Epoch)), ("envelope", envelope.ToJson()));
    return Groups(CloudBytes.Sha256Hex([.. Encoding.UTF8.GetBytes("TD-CLOUD-APPROVAL-TRANSFER-2\n"), .. CloudCanonical.Encode(binding)])[..20]);
  }
  private static string Groups(string hex) => string.Join(' ', hex.ToUpperInvariant().Chunk(4).Select(c => new string(c)));
}
