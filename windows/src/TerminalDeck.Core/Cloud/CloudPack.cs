using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Cloud;

// The td-ops-1 pack, its sealed envelope and its signed descriptor, byte for byte as the Mac makes them
// (CloudContract.swift CloudOperation / CloudSegmentDescriptor / CloudContentEnvelope, CloudSyncSupport.swift
// CloudSyncPack and syncSigningBytes / syncSignatureCheck, CloudSyncContent.swift). Signatures are ES256 (P-256,
// SHA-256, raw r||s, 64 bytes): they differ per call, so a port verifies them and never compares its own.

public sealed record CloudSourceReference(string SourceId, string RecordId, long? Offset = null, string? RawHash = null)
{
  public CloudJson ToJson() => CloudJson.Obj(("sourceId", CloudJson.From(SourceId)), ("recordId", CloudJson.From(RecordId)),
    ("offset", Offset is { } o ? CloudJson.From(o) : null), ("rawHash", RawHash is { } r ? CloudJson.From(r) : null));
}

/// One record change. `Kind` is put, append, archive or supersede.
public sealed record CloudOperation(int V, string OpId, string OriginDevice, string Domain, string EntityId, string Revision,
  IReadOnlyList<string> Parents, string Kind, string? ProjectId, string? RootId, CloudSourceReference Source, long CreatedAt,
  CloudJson Payload, string PayloadHash)
{
  public static readonly IReadOnlySet<string> Kinds = new HashSet<string> { "put", "append", "archive", "supersede" };
  public static readonly IReadOnlySet<string> Keys = new HashSet<string> { "v", "opId", "originDevice", "domain", "entityId", "revision", "parents", "kind", "projectId", "rootId", "source", "createdAt", "payload", "payloadHash" };
  /// A new record: fresh random opId (= revision), payloadHash computed from the canonical payload.
  public static CloudOperation Create(string originDevice, string domain, string entityId, IReadOnlyList<string> parents, string kind,
    CloudSourceReference source, long createdAt, CloudJson payload, string? projectId = null, string? rootId = null)
  {
    var id = CloudBytes.NewTransportId();
    return new(1, id, originDevice, domain, entityId, id, parents, kind, projectId, rootId, source, createdAt, payload, PayloadHashOf(payload));
  }
  public static string PayloadHashOf(CloudJson payload) => CloudBytes.Sha256Hex(CloudCanonical.Encode(payload));

  public CloudJson ToJson() => CloudJson.Obj(("v", CloudJson.From(V)), ("opId", CloudJson.From(OpId)), ("originDevice", CloudJson.From(OriginDevice)),
    ("domain", CloudJson.From(Domain)), ("entityId", CloudJson.From(EntityId)), ("revision", CloudJson.From(Revision)),
    ("parents", CloudJson.Arr(Parents.Select(p => CloudJson.From(p)))), ("kind", CloudJson.From(Kind)),
    ("projectId", ProjectId is { } p ? CloudJson.From(p) : null), ("rootId", RootId is { } r ? CloudJson.From(r) : null),
    ("source", Source.ToJson()), ("createdAt", CloudJson.From(CreatedAt)), ("payload", Payload), ("payloadHash", CloudJson.From(PayloadHash)));

  public static CloudOperation FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o || o.Members.Any(m => !Keys.Contains(m.Key))) throw new CloudFailure("unsupported_format");
    if (o["source"] is not CloudJson.Object s || s.Members.Any(m => m.Key is not ("sourceId" or "recordId" or "offset" or "rawHash"))) throw new CloudFailure("unsupported_format");
    if (o["parents"] is not CloudJson.Array parents || o["payload"] is not { } payload) throw new CloudFailure("invalid_request");
    var kind = CloudFields.Text(o, "kind");
    if (!Kinds.Contains(kind)) throw new CloudFailure("invalid_request");
    return new((int)CloudFields.Integer(o, "v"), CloudFields.Text(o, "opId"), CloudFields.Text(o, "originDevice"), CloudFields.Text(o, "domain"),
      CloudFields.Text(o, "entityId"), CloudFields.Text(o, "revision"), parents.Items.Select(p => p.AsString ?? throw new CloudFailure("invalid_request")).ToArray(),
      kind, CloudFields.OptionalText(o, "projectId"), CloudFields.OptionalText(o, "rootId"),
      new(CloudFields.Text(s, "sourceId"), CloudFields.Text(s, "recordId"), CloudFields.OptionalInteger(s, "offset"), CloudFields.OptionalText(s, "rawHash")),
      CloudFields.Integer(o, "createdAt"), payload, CloudFields.Text(o, "payloadHash"));
  }
}

/// td-ops-1: the canonical array of records (CloudSyncPack). No timestamp takes part in merging.
public static class CloudPackFormat
{
  public const string Name = "td-ops-1";
  public const int MaximumPlainChunkBytes = 8 * 1024 * 1024, MaximumBlobBytes = 12 * 1024 * 1024, MaximumPayloadBytes = 65_536;

  public static byte[] Encode(IReadOnlyList<CloudOperation> operations, int maximumBytes = MaximumPlainChunkBytes)
  {
    Validate(operations);
    if (operations.Select(o => o.OpId).Distinct(StringComparer.Ordinal).Count() != operations.Count) throw new CloudFailure("invalid_request");
    var bytes = CloudCanonical.Encode(CloudJson.Arr(operations.Select(o => o.ToJson())));
    if (bytes.Length > maximumBytes) throw new CloudFailure("invalid_request");
    return bytes;
  }
  public static IReadOnlyList<CloudOperation> Decode(ReadOnlySpan<byte> bytes)
  {
    if (bytes.Length > MaximumPlainChunkBytes) throw new CloudFailure("invalid_request");
    if (CloudJson.Parse(bytes) is not CloudJson.Array rows) throw new CloudFailure("invalid_request");
    var operations = rows.Items.Select(CloudOperation.FromJson).ToArray();
    Validate(operations);
    if (operations.Select(o => o.OpId).Distinct(StringComparer.Ordinal).Count() != operations.Length) throw new CloudFailure("invalid_request");
    return operations;
  }
  /// CloudSyncPack.validate: shape, ids, parents, sizes and each payload's hash.
  public static void Validate(IEnumerable<CloudOperation> operations)
  {
    var ids = new Dictionary<string, byte[]>(StringComparer.Ordinal);
    foreach (var op in operations)
    {
      if (op.V != 1) throw new CloudFailure("unsupported_format");
      CloudBytes.TransportId(op.OpId);
      CloudBytes.TransportId(op.OriginDevice);
      if (op.Revision != op.OpId || op.Parents.Contains(op.Revision) || op.Parents.Distinct(StringComparer.Ordinal).Count() != op.Parents.Count
        || op.Domain.Length == 0 || Characters(op.Domain) > 256 || op.EntityId.Length == 0 || Characters(op.EntityId) > 256
        || op.Source.SourceId.Length == 0 || op.Source.RecordId.Length == 0 || op.Source.Offset is < 0 || !CloudOperation.Kinds.Contains(op.Kind))
        throw new CloudFailure("invalid_request");
      foreach (var parent in op.Parents) CloudBytes.TransportId(parent);
      var payload = CloudCanonical.Encode(op.Payload);
      if (payload.Length > MaximumPayloadBytes) throw new CloudFailure("unsupported_format");
      if (CloudBytes.Sha256Hex(payload) != op.PayloadHash) throw new CloudFailure("checksum_mismatch");
      var bytes = CloudCanonical.Encode(op.ToJson());
      if (ids.TryGetValue(op.OpId, out var old) && !old.AsSpan().SequenceEqual(bytes)) throw new CloudFailure("id_reused");
      ids[op.OpId] = bytes;
    }
  }
  /// Swift's String.count: user-perceived characters (extended grapheme clusters).
  private static int Characters(string text) => new StringInfo(text).LengthInTextElements;
}

/// The sealed object (CloudContentEnvelope). Members as on the wire: v, suite, class, purpose, epoch, blobId, codec,
/// plainBytes, nonce, ciphertext, tag.
public sealed record CloudContentEnvelope(int V, string Suite, string StorageClass, string Purpose, int Epoch, string BlobId, string Codec,
  long PlainBytes, string Nonce, string Ciphertext, string Tag)
{
  public const string SuiteName = "A256GCM-HKDF-SHA256";
  public CloudJson.Object ToJson() => CloudJson.Obj(("v", CloudJson.From(V)), ("suite", CloudJson.From(Suite)), ("class", CloudJson.From(StorageClass)),
    ("purpose", CloudJson.From(Purpose)), ("epoch", CloudJson.From(Epoch)), ("blobId", CloudJson.From(BlobId)), ("codec", CloudJson.From(Codec)),
    ("plainBytes", CloudJson.From(PlainBytes)), ("nonce", CloudJson.From(Nonce)), ("ciphertext", CloudJson.From(Ciphertext)), ("tag", CloudJson.From(Tag)));
  public byte[] Canonical() => CloudCanonical.Encode(ToJson());
  public static CloudContentEnvelope FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o) throw new CloudFailure("invalid_request");
    var envelope = new CloudContentEnvelope((int)CloudFields.Integer(o, "v"), CloudFields.Text(o, "suite"), CloudFields.Text(o, "class"), CloudFields.Text(o, "purpose"),
      (int)CloudFields.Integer(o, "epoch"), CloudFields.Text(o, "blobId"), CloudFields.Text(o, "codec"), CloudFields.Integer(o, "plainBytes"),
      CloudFields.Text(o, "nonce"), CloudFields.Text(o, "ciphertext"), CloudFields.Text(o, "tag"));
    if (!CloudStorage.Classes.Contains(envelope.StorageClass) || !CloudStorage.Purposes.Contains(envelope.Purpose) || envelope.Codec is not ("identity" or "gzip"))
      throw new CloudFailure("invalid_request");
    return envelope;
  }
  public static CloudContentEnvelope Parse(ReadOnlySpan<byte> utf8) => FromJson(CloudJson.Parse(utf8));
}

/// Storage classes and purposes (CloudStorageClass, CloudPurpose.permits).
public static class CloudStorage
{
  public static readonly IReadOnlySet<string> Classes = new HashSet<string> { "brain", "secrets" };
  public static readonly IReadOnlySet<string> Purposes = new HashSet<string> { "brain", "secret", "backup", "artifact", "database", "browser", "ai-subscription" };
  public static bool Permits(string purpose, string storageClass) => purpose switch
  {
    "brain" => storageClass == "brain",
    "secret" or "browser" or "ai-subscription" => storageClass == "secrets",
    "backup" or "artifact" or "database" => Classes.Contains(storageClass),
    _ => false
  };
}

/// The content crypto both classes share: HKDF-SHA256(root, salt = the blob id's 16 UUID bytes, info =
/// "TD-CLOUD-OBJECT-1\n{class}\n{epoch}") to an AES-256-GCM key; AAD = "TD-CLOUD-CONTENT-1\n{subject}\n" + the canonical
/// envelope without nonce, ciphertext and tag. .NET's HKDF and AesGcm are RFC 5869 and NIST GCM with a 12-byte nonce and
/// 16-byte tag, the same as CryptoKit's HKDF<SHA256> and AES.GCM.
public static class CloudContentCrypto
{
  public static byte[] ObjectKey(ReadOnlySpan<byte> root, string blobId, string storageClass, int epoch) =>
    HKDF.DeriveKey(HashAlgorithmName.SHA256, root.ToArray(), 32, CloudBytes.Uuid(blobId), Encoding.UTF8.GetBytes($"TD-CLOUD-OBJECT-1\n{storageClass}\n{epoch.ToString(CultureInfo.InvariantCulture)}"));
  public static byte[] Aad(CloudContentEnvelope envelope, string subject) =>
    [.. Encoding.UTF8.GetBytes($"TD-CLOUD-CONTENT-1\n{subject}\n"), .. CloudCanonical.Encode(envelope.ToJson().Without("nonce", "ciphertext", "tag"))];
  public static (byte[] Ciphertext, byte[] Tag) Seal(ReadOnlySpan<byte> plain, byte[] key, byte[] nonce, byte[] aad)
  {
    if (key.Length != 32 || nonce.Length != 12) throw new CloudFailure("invalid_request");
    var ciphertext = new byte[plain.Length]; var tag = new byte[16];
    using var gcm = new AesGcm(key, 16);
    gcm.Encrypt(nonce, plain, ciphertext, tag, aad);
    return (ciphertext, tag);
  }
  /// Any failure (wrong key, AAD, nonce, tag) is "checksum_mismatch", as on the Mac.
  public static byte[] Open(byte[] key, byte[] nonce, byte[] ciphertext, byte[] tag, byte[] aad)
  {
    if (key.Length != 32 || nonce.Length != 12 || tag.Length != 16) throw new CloudFailure("checksum_mismatch");
    var plain = new byte[ciphertext.Length];
    try { using var gcm = new AesGcm(key, 16); gcm.Decrypt(nonce, ciphertext, tag, plain, aad); }
    catch (CryptographicException) { CryptographicOperations.ZeroMemory(plain); throw new CloudFailure("checksum_mismatch"); }
    return plain;
  }
  /// gzip, compression level 1 like the Mac's deflateInit2(level 1). Its bytes vary by library: never compared,
  /// only opened again.
  public static byte[] Gzip(ReadOnlySpan<byte> bytes)
  {
    using var output = new MemoryStream();
    using (var zip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true)) zip.Write(bytes);
    if (output.Length > CloudPackFormat.MaximumBlobBytes) throw new CloudFailure("checksum_mismatch");
    return output.ToArray();
  }
  /// Inflates at most `expected` bytes and requires exactly that many (CloudSyncGzip / CloudSecretsCompression.decode).
  public static byte[] Gunzip(byte[] bytes, long expected)
  {
    if (expected is < 0 or > CloudPackFormat.MaximumPlainChunkBytes) throw new CloudFailure("invalid_request");
    var output = new byte[expected + 1]; var total = 0;
    try
    {
      using var zip = new GZipStream(new MemoryStream(bytes, writable: false), CompressionMode.Decompress);
      int read;
      while (total < output.Length && (read = zip.Read(output, total, output.Length - total)) > 0) total += read;
    }
    catch (InvalidDataException) { throw new CloudFailure("checksum_mismatch"); }
    if (total != expected) throw new CloudFailure("checksum_mismatch");
    return output[..total];
  }
}

/// The brain (memory) class: CloudSyncContent.seal / open.
public static class CloudBrainContent
{
  /// `nonce` must be 12 fresh random bytes in the app (`Seal` without a nonce does that); a fixed nonce is only for
  /// the golden vectors.
  public static CloudContentEnvelope Seal(ReadOnlySpan<byte> bytes, string blobId, string purpose, int epoch, string codec, string subject, byte[] rootKey, byte[]? nonce = null)
  {
    nonce ??= RandomNumberGenerator.GetBytes(12);
    if (!CloudStorage.Permits(purpose, "brain") || epoch <= 0 || bytes.Length > CloudPackFormat.MaximumPlainChunkBytes || rootKey.Length != 32 || nonce.Length != 12
      || codec is not ("identity" or "gzip")) throw new CloudFailure("invalid_request");
    CloudBytes.TransportId(blobId);
    var zipped = codec == "gzip" ? CloudContentCrypto.Gzip(bytes) : null;
    var selected = zipped is not null && zipped.Length < bytes.Length ? "gzip" : "identity";
    var template = new CloudContentEnvelope(1, CloudContentEnvelope.SuiteName, "brain", purpose, epoch, blobId, selected, bytes.Length, "", "", "");
    var key = CloudContentCrypto.ObjectKey(rootKey, blobId, "brain", epoch);
    try
    {
      var (ciphertext, tag) = CloudContentCrypto.Seal(selected == "gzip" ? zipped!.AsSpan() : bytes, key, nonce, CloudContentCrypto.Aad(template, subject));
      return template with { Nonce = CloudBytes.Base64Url(nonce), Ciphertext = CloudBytes.Base64Url(ciphertext), Tag = CloudBytes.Base64Url(tag) };
    }
    finally { CryptographicOperations.ZeroMemory(key); }
  }
  public static byte[] Open(CloudContentEnvelope envelope, string subject, byte[] rootKey)
  {
    if (envelope.V != 1 || envelope.Suite != CloudContentEnvelope.SuiteName) throw new CloudFailure("unsupported_format");
    if (envelope.StorageClass != "brain" || !CloudStorage.Permits(envelope.Purpose, "brain") || envelope.Epoch <= 0
      || envelope.PlainBytes is < 0 or > CloudPackFormat.MaximumPlainChunkBytes || envelope.Ciphertext.Length > CloudPackFormat.MaximumBlobBytes)
      throw new CloudFailure("invalid_request");
    CloudBytes.TransportId(envelope.BlobId);
    var nonce = CloudBytes.Unbase64(envelope.Nonce); var tag = CloudBytes.Unbase64(envelope.Tag);
    if (nonce.Length != 12 || tag.Length != 16) throw new CloudFailure("checksum_mismatch");
    if (rootKey.Length != 32) throw new CloudFailure("unavailable");
    var key = CloudContentCrypto.ObjectKey(rootKey, envelope.BlobId, "brain", envelope.Epoch);
    byte[] plain;
    try { plain = CloudContentCrypto.Open(key, nonce, CloudBytes.Unbase64(envelope.Ciphertext), tag, CloudContentCrypto.Aad(envelope, subject)); }
    finally { CryptographicOperations.ZeroMemory(key); }
    var result = envelope.Codec == "gzip" ? CloudContentCrypto.Gunzip(plain, envelope.PlainBytes) : plain;
    if (result.LongLength != envelope.PlainBytes) throw new CloudFailure("checksum_mismatch");
    return result;
  }
}

public enum CloudSignatureCheck { Valid, BadKey, BadSignature }

/// What the feed states about a pack, and what its author signs (CloudSegmentDescriptor).
public sealed record CloudSegmentDescriptor(string SegmentId, string RequestId, string StorageClass, string Purpose, IReadOnlyList<string> Domains,
  int KeyEpoch, string Sha256, long Bytes, int OpCount, string Format, string Signature)
{
  public CloudJson.Object ToJson() => CloudJson.Obj(("segmentId", CloudJson.From(SegmentId)), ("requestId", CloudJson.From(RequestId)),
    ("class", CloudJson.From(StorageClass)), ("purpose", CloudJson.From(Purpose)), ("domains", CloudJson.Arr(Domains.Select(d => CloudJson.From(d)))),
    ("keyEpoch", CloudJson.From(KeyEpoch)), ("sha256", CloudJson.From(Sha256)), ("bytes", CloudJson.From(Bytes)), ("opCount", CloudJson.From(OpCount)),
    ("format", CloudJson.From(Format)), ("signature", CloudJson.From(Signature)));
  public static CloudSegmentDescriptor FromJson(CloudJson value)
  {
    if (value is not CloudJson.Object o || o["domains"] is not CloudJson.Array domains) throw new CloudFailure("invalid_request");
    var descriptor = new CloudSegmentDescriptor(CloudFields.Text(o, "segmentId"), CloudFields.Text(o, "requestId"), CloudFields.Text(o, "class"), CloudFields.Text(o, "purpose"),
      domains.Items.Select(d => d.AsString ?? throw new CloudFailure("invalid_request")).ToArray(), (int)CloudFields.Integer(o, "keyEpoch"), CloudFields.Text(o, "sha256"),
      CloudFields.Integer(o, "bytes"), (int)CloudFields.Integer(o, "opCount"), CloudFields.Text(o, "format"), CloudFields.Text(o, "signature"));
    if (!CloudStorage.Classes.Contains(descriptor.StorageClass) || !CloudStorage.Purposes.Contains(descriptor.Purpose)) throw new CloudFailure("invalid_request");
    return descriptor;
  }
  public static CloudSegmentDescriptor Parse(ReadOnlySpan<byte> utf8) => FromJson(CloudJson.Parse(utf8));

  /// Exactly what is signed: the canonical descriptor without its signature member, a line break, the account subject.
  public byte[] SigningBytes(string subject) =>
    [.. CloudCanonical.Encode(ToJson().Without("signature")), .. Encoding.UTF8.GetBytes("\n" + subject)];

  /// Whether `Signature` is a P-256 signature by `key` over the signing bytes for this account. Total: every failure is
  /// an answer. `key` must come from this PC's own trusted list, never from the pack or the service.
  public CloudSignatureCheck Check(CloudPublicJwk key, string subject)
  {
    using var publicKey = CloudP256.ImportPublic(key);
    if (publicKey is null) return CloudSignatureCheck.BadKey;
    byte[] raw;
    try { raw = CloudBytes.Unbase64(Signature); } catch (CloudFailure) { return CloudSignatureCheck.BadSignature; }
    if (raw.Length != 64) return CloudSignatureCheck.BadSignature;
    try { return publicKey.VerifyData(SigningBytes(subject), raw, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation) ? CloudSignatureCheck.Valid : CloudSignatureCheck.BadSignature; }
    catch (Exception ex) when (ex is CryptographicException or CloudFailure) { return CloudSignatureCheck.BadSignature; }
  }
  /// This descriptor signed with `signer` (the device's own P-256 key). The signature is random per call.
  public CloudSegmentDescriptor Sign(string subject, ECDsa signer) =>
    this with { Signature = CloudBytes.Base64Url(signer.SignData(SigningBytes(subject), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)) };
}

/// Typed member reads that refuse a wrong type, as Swift's Codable decoding does.
internal static class CloudFields
{
  public static string Text(CloudJson.Object o, string key) => o[key]?.AsString ?? throw new CloudFailure("invalid_request");
  public static string? OptionalText(CloudJson.Object o, string key) => o[key] switch
  {
    null or CloudJson.Null => null,
    CloudJson.String s => s.Value,
    _ => throw new CloudFailure("invalid_request")
  };
  public static long Integer(CloudJson.Object o, string key) => o[key]?.AsInteger ?? throw new CloudFailure("invalid_request");
  public static long? OptionalInteger(CloudJson.Object o, string key) => o[key] switch
  {
    null or CloudJson.Null => null,
    var v => v.AsInteger ?? throw new CloudFailure("invalid_request")
  };
}
