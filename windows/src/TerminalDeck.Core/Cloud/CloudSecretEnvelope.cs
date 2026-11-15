using System.Security.Cryptography;

namespace TerminalDeck.Core.Cloud;

/// A saved password (or other secrets-class object) sealed under the account's secrets root key
/// (CloudSecretsCrypto.sealContent / openContent). Same content crypto as memory packs with class "secrets"; the blob
/// id may be any UUID here. The secrets lane (W5) reads and writes these; W2 proves the bytes.
public static class CloudSecretEnvelope
{
  /// `nonce` must be 12 fresh random bytes in the app (leave it null); a fixed nonce is only for the golden vectors.
  public static CloudContentEnvelope Seal(ReadOnlySpan<byte> bytes, byte[] root, string subject, string blobId, string purpose, int epoch, string codec = "identity", byte[]? nonce = null)
  {
    CloudBytes.Uuid(subject);
    nonce ??= RandomNumberGenerator.GetBytes(12);
    if (root.Length != 32 || epoch <= 0 || !CloudStorage.Permits(purpose, "secrets") || bytes.Length > CloudPackFormat.MaximumPlainChunkBytes || codec is not ("identity" or "gzip"))
      throw new CloudFailure("invalid_request");
    var header = new CloudContentEnvelope(1, CloudContentEnvelope.SuiteName, "secrets", purpose, epoch, blobId, codec, bytes.Length, "", "", "");
    var key = CloudContentCrypto.ObjectKey(root, blobId, "secrets", epoch);
    try
    {
      var (ciphertext, tag) = CloudContentCrypto.Seal(codec == "gzip" ? CloudContentCrypto.Gzip(bytes).AsSpan() : bytes, key, nonce, CloudContentCrypto.Aad(header, subject));
      return header with { Nonce = CloudBytes.Base64Url(nonce), Ciphertext = CloudBytes.Base64Url(ciphertext), Tag = CloudBytes.Base64Url(tag) };
    }
    finally { CryptographicOperations.ZeroMemory(key); }
  }
  /// Opens an envelope sealed for this account at `epoch`. Any tampering, another account or another key fails.
  public static byte[] Open(CloudContentEnvelope envelope, byte[] root, string subject, int epoch)
  {
    CloudBytes.Uuid(subject);
    if (envelope.V != 1 || envelope.Suite != CloudContentEnvelope.SuiteName || envelope.StorageClass != "secrets" || !CloudStorage.Permits(envelope.Purpose, "secrets")
      || envelope.Epoch != epoch || epoch <= 0 || root.Length != 32 || envelope.PlainBytes is < 0 or > CloudPackFormat.MaximumPlainChunkBytes
      || envelope.Ciphertext.Length > CloudPackFormat.MaximumBlobBytes) throw new CloudFailure("unsupported_format");
    var key = CloudContentCrypto.ObjectKey(root, envelope.BlobId, "secrets", epoch);
    byte[] plain;
    try
    {
      plain = CloudContentCrypto.Open(key, CloudBytes.Unbase64(envelope.Nonce, 12), CloudBytes.Unbase64(envelope.Ciphertext), CloudBytes.Unbase64(envelope.Tag, 16),
        CloudContentCrypto.Aad(envelope, subject));
    }
    finally { CryptographicOperations.ZeroMemory(key); }
    if (envelope.Codec == "gzip") { var opened = CloudContentCrypto.Gunzip(plain, envelope.PlainBytes); CryptographicOperations.ZeroMemory(plain); return opened; }
    if (plain.LongLength != envelope.PlainBytes) throw new CloudFailure("checksum_mismatch");
    return plain;
  }
}
