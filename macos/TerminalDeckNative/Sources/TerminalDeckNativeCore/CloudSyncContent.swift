import Foundation
import CryptoKit
import zlib

/// Brain keys are supplied by A's authenticated/protected owner. This object never persists keys.
public actor CloudSyncContent: CloudContentPort {
  public typealias KeyProvider = @Sendable (Int) async throws -> Data
  private let subject: String
  private let epoch: Int
  private let keyProvider: KeyProvider
  private var sealedIDs = Set<String>()

  public init(subject: String, epoch: Int, keyProvider: @escaping KeyProvider) throws {
    _ = try CloudSyncBytes.uuid(subject)
    guard epoch > 0 else { throw CloudFailure.invalidRequest }
    self.subject = subject
    self.epoch = epoch
    self.keyProvider = keyProvider
  }
  public func state(storageClass: CloudStorageClass) async -> CloudContentState {
    guard storageClass == .brain else { return .init(available: false, epoch: 0, reason: "Cloud secrets needs its protected content provider.") }
    do {
      let key = try await keyProvider(epoch)
      return .init(available: key.count == 32, epoch: epoch, reason: key.count == 32 ? nil : "The Cloud key is unavailable.")
    } catch { return .init(available: false, epoch: epoch, reason: "The Cloud key is unavailable.") }
  }
  public func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec) async throws -> CloudContentEnvelope {
    guard !sealedIDs.contains(blobId.lowercased()) else { throw CloudFailure.idReused }
    sealedIDs.insert(blobId.lowercased())
    return try Self.seal(bytes, blobId: blobId, storageClass: storageClass, purpose: purpose, epoch: epoch, codec: codec,
      subject: subject, rootKey: await keyProvider(epoch), nonce: Data(AES.GCM.Nonce()))
  }
  // Internal deterministic seam for cross-language fixtures; never a production nonce option.
  static func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int,
                   codec: CloudContentCodec, subject: String, rootKey: Data, nonce: Data) throws -> CloudContentEnvelope {
    guard storageClass == .brain, purpose.permits(storageClass), epoch > 0, bytes.count <= CloudWire.maximumPlainChunkBytes,
      rootKey.count == 32, nonce.count == 12 else { throw CloudFailure.invalidRequest }
    try CloudSyncBytes.transportID(blobId)
    let zipped = codec == .gzip ? try CloudSyncGzip.transform(bytes, compress: true) : bytes
    let selected: CloudContentCodec = codec == .gzip && zipped.count < bytes.count ? .gzip : .identity
    let template = CloudContentEnvelope(v: 1, suite: "A256GCM-HKDF-SHA256", storageClass: storageClass, purpose: purpose,
      epoch: epoch, blobId: blobId, codec: selected, plainBytes: Int64(bytes.count), nonce: "", ciphertext: "", tag: "")
    let box = try AES.GCM.seal(selected == .gzip ? zipped : bytes, using: objectKey(rootKey, blobId: blobId, epoch: epoch),
      nonce: AES.GCM.Nonce(data: nonce), authenticating: aad(template, subject: subject))
    return .init(v: 1, suite: template.suite, storageClass: storageClass, purpose: purpose, epoch: epoch, blobId: blobId,
      codec: selected, plainBytes: template.plainBytes, nonce: CloudSyncBytes.base64(nonce),
      ciphertext: CloudSyncBytes.base64(box.ciphertext), tag: CloudSyncBytes.base64(box.tag))
  }
  public func open(_ envelope: CloudContentEnvelope) async throws -> Data {
    guard envelope.v == 1, envelope.suite == "A256GCM-HKDF-SHA256" else { throw CloudFailure.unsupportedFormat }
    guard envelope.storageClass == .brain, envelope.purpose.permits(.brain), envelope.epoch > 0,
      envelope.plainBytes >= 0, envelope.plainBytes <= CloudWire.maximumPlainChunkBytes,
      envelope.ciphertext.count <= CloudWire.maximumBlobBytes else { throw CloudFailure.invalidRequest }
    try CloudSyncBytes.transportID(envelope.blobId)
    let nonce = try CloudSyncBytes.unbase64(envelope.nonce), tag = try CloudSyncBytes.unbase64(envelope.tag)
    guard nonce.count == 12, tag.count == 16 else { throw CloudFailure.checksumMismatch }
    let root = try await keyProvider(envelope.epoch)
    guard root.count == 32 else { throw CloudFailure.unavailable }
    let plain: Data
    do {
      let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: CloudSyncBytes.unbase64(envelope.ciphertext), tag: tag)
      plain = try AES.GCM.open(box, using: Self.objectKey(root, blobId: envelope.blobId, epoch: envelope.epoch), authenticating: Self.aad(envelope, subject: subject))
    } catch { throw CloudFailure.checksumMismatch }
    let result = envelope.codec == .gzip ? try CloudSyncGzip.transform(plain, compress: false, limit: Int(envelope.plainBytes)) : plain
    guard result.count == envelope.plainBytes else { throw CloudFailure.checksumMismatch }
    return result
  }
  static func objectKey(_ root: Data, blobId: String, epoch: Int) throws -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: root), salt: try CloudSyncBytes.uuid(blobId),
      info: Data("TD-CLOUD-OBJECT-1\nbrain\n\(epoch)".utf8), outputByteCount: 32)
  }
  static func aad(_ envelope: CloudContentEnvelope, subject: String) throws -> Data {
    let raw = try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(envelope))
    guard case .object(let fields) = raw else { throw CloudFailure.invalidRequest }
    return Data("TD-CLOUD-CONTENT-1\n\(subject)\n".utf8) + (try CloudSyncCanonical.encode(CloudValue(.object(fields.filter { !["nonce", "ciphertext", "tag"].contains($0.key) }))))
  }
}

enum CloudSyncGzip {
  static func transform(_ input: Data, compress: Bool, limit: Int = CloudWire.maximumPlainChunkBytes) throws -> Data {
    var stream = z_stream()
    let initialized = compress
      ? deflateInit2_(&stream, 1, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
      : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initialized == Z_OK else { throw CloudFailure.unavailable }
    defer { if compress { deflateEnd(&stream) } else { inflateEnd(&stream) } }
    return try input.withUnsafeBytes { buffer in
      stream.next_in = UnsafeMutablePointer(mutating: buffer.bindMemory(to: Bytef.self).baseAddress)
      stream.avail_in = uInt(input.count)
      var result = Data()
      var status: Int32 = Z_OK
      repeat {
        var chunk = [UInt8](repeating: 0, count: 32_768)
        let used = chunk.withUnsafeMutableBytes { output -> Int in
          stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
          stream.avail_out = uInt(output.count)
          status = compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
          return output.count - Int(stream.avail_out)
        }
        guard status == Z_OK || status == Z_STREAM_END else { throw CloudFailure.checksumMismatch }
        guard result.count + used <= (compress ? CloudWire.maximumBlobBytes : limit) else { throw CloudFailure.checksumMismatch }
        result.append(contentsOf: chunk.prefix(used))
      } while status != Z_STREAM_END
      guard stream.avail_in == 0 else { throw CloudFailure.checksumMismatch }
      return result
    }
  }
}
