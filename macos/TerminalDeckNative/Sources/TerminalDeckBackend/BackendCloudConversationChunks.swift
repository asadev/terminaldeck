import Foundation
import TerminalDeckNativeCore

/// New sealed staging files only; existing provider files never pass through this writer.
public actor BackendCloudConversationChunks: CloudConversationChunkPort {
  public nonisolated let subjectHash: String
  private let persistence: BackendTaskPersistence
  private let content: any CloudContentPort
  public init(directory: URL, content: any CloudContentPort, subjectHash: String) throws {
    try BackendCloudConversationAccount.check(directory, subjectHash: subjectHash)
    self.subjectHash = subjectHash
    persistence = try .init(directory: directory, ownership: .exclusive); self.content = content
  }
  public func seal(_ bytes: Data, blobID: String, sourceID: String) async throws -> CloudLocalBlob {
    try CloudSyncBytes.transportID(blobID)
    let name = blobID + ".envelope"
    let data: Data
    if let existing = try persistence.readOwnedBytes(name, maximumBytes: CloudWire.maximumBlobBytes) {
      // The id binds file, offset and plain hash, so an existing sealed file already holds these bytes.
      // Only its structure is checked here; it is never decrypted again on a later pass.
      let envelope = try JSONDecoder().decode(CloudContentEnvelope.self, from: existing)
      guard envelope.blobId == blobID, envelope.storageClass == .brain, envelope.purpose == .brain,
            envelope.plainBytes == Int64(bytes.count) else { throw CloudFailure.idReused }
      data = existing
    } else {
      let state = await content.state(storageClass: .brain)
      guard state.available else { throw CloudFailure.unavailable }
      let envelope = try await content.seal(bytes, blobId: blobID, storageClass: .brain, purpose: .brain, epoch: state.epoch, codec: .identity)
      data = try CloudSyncCanonical.encode(envelope)
      try persistence.writeBytes(name, data: data, replace: false)
    }
    let envelope = try JSONDecoder().decode(CloudContentEnvelope.self, from: data)
    let ref = CloudSyncBytes.blob(data, envelope: envelope)
    return .init(blobId: blobID, sourceId: sourceID, localURL: try persistence.file(name), bytes: ref.bytes,
      sha256: ref.sha256, md5: ref.md5, keyEpoch: ref.keyEpoch, storageClass: .brain, purpose: .brain)
  }
}
