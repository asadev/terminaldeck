import Foundation

/// SYNC supplies verified local ciphertext by BlobRef. This reader has no URL or network access.
public actor CloudRestoreReader {
  public typealias Fetch = @Sendable (CloudBlobRef) async throws -> Data
  private struct Page: Decodable { let v: Int; let entries: [CloudBackupEntry]; let children: [CloudBlobRef] }
  private struct Root: Decodable {
    let v: Int
    let snapshotId: String
    let projectId: String
    let rootId: String
    let deviceId: String
    let eventCursor: String
    let parentSnapshotId: String?
    let at: Int64
    let ordinary: CloudBlobRef?
    let protected: CloudBlobRef?
    let entryCount: Int
    let blockedCount: Int
    let inventoryDigest: String
    let exclusions: [CloudBackupExclusion]
    let markers: [CloudBackupMarker]
  }
  private let fetch: Fetch
  private let brain: any CloudContentPort
  private let secrets: any CloudContentPort
  public init(fetch: @escaping Fetch, brain: any CloudContentPort, secrets: any CloudContentPort) {
    self.fetch = fetch; self.brain = brain; self.secrets = secrets
  }
  public func bytes(_ ref: CloudBlobRef) async throws -> Data {
    guard ref.purpose == .backup, ref.bytes > 0, ref.bytes <= CloudWire.maximumBlobBytes else { throw CloudBackupError.limitExceeded }
    let sealed = try await fetch(ref)
    guard sealed.count == ref.bytes, CloudBackupDigest.sha256(sealed) == ref.sha256 else { throw CloudBackupError.readbackFailed }
    let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: sealed, maximumBytes: CloudWire.maximumBlobBytes)
    guard envelope.v == 1, envelope.blobId == ref.blobId, envelope.storageClass == ref.storageClass,
      envelope.purpose == ref.purpose, envelope.epoch == ref.keyEpoch, envelope.codec == .identity,
      envelope.plainBytes >= 0, envelope.plainBytes <= CloudWire.maximumPlainChunkBytes else { throw CloudBackupError.limitExceeded }
    let port = ref.storageClass == .brain ? brain : secrets
    let bytes = try await port.open(envelope)
    guard bytes.count == envelope.plainBytes else { throw CloudBackupError.readbackFailed }
    return bytes
  }
  public func manifest(_ reference: CloudBlobRef, includeSecrets: Bool = true) async throws -> CloudBackupManifest {
    guard reference.storageClass == .brain else { throw CloudBackupError.invalidManifest }
    let root = try CloudWire.decode(Root.self, from: await bytes(reference), maximumBytes: CloudWire.maximumPlainChunkBytes)
    guard root.v == 1, root.entryCount >= 0, root.entryCount <= 1_000_000, root.blockedCount >= 0, root.blockedCount <= 1_000_000 else { throw CloudBackupError.limitExceeded }
    var pending: [(CloudBlobRef, Int)] = []
    if let ordinary = root.ordinary { guard ordinary.storageClass == .brain else { throw CloudBackupError.invalidManifest }; pending.append((ordinary, 0)) }
    if includeSecrets, let protected = root.protected { guard protected.storageClass == .secrets else { throw CloudBackupError.invalidManifest }; pending.append((protected, 0)) }
    var visited = Set<String>(), entries: [CloudBackupEntry] = []
    while let (reference, depth) = pending.popLast() {
      guard depth <= 16, visited.count < 20_000, visited.insert(reference.blobId).inserted else { throw CloudBackupError.invalidManifest }
      let page = try CloudWire.decode(Page.self, from: await bytes(reference), maximumBytes: CloudWire.maximumPlainChunkBytes)
      guard page.v == 1, page.entries.count <= 64, page.children.count <= 64,
        page.entries.isEmpty || page.children.isEmpty,
        page.entries.allSatisfy({ $0.storageClass == reference.storageClass }),
        page.children.allSatisfy({ $0.storageClass == reference.storageClass }) else { throw CloudBackupError.invalidManifest }
      entries += page.entries
      guard entries.count <= root.entryCount else { throw CloudBackupError.limitExceeded }
      pending += page.children.map { ($0, depth + 1) }
    }
    let ordered = entries.sorted { CloudBackupPaths.precedes($0.relativePath, $1.relativePath) }
    let digest = try CloudBackupDigest.of(ordered)
    var blocked = (0..<root.blockedCount).map { "Source blocked item \($0 + 1)." }
    if !includeSecrets && root.protected != nil { blocked += (0..<(root.entryCount - entries.count)).map { "Locked protected entry \($0 + 1)." } }
    else {
      guard entries.count == root.entryCount, digest == root.inventoryDigest else { throw CloudBackupError.readbackFailed }
    }
    return .init(v: 1, snapshotId: root.snapshotId, projectId: root.projectId, rootId: root.rootId, deviceId: root.deviceId,
      parentSnapshotId: root.parentSnapshotId, at: root.at, eventCursor: root.eventCursor, scanComplete: blocked.isEmpty,
      entries: ordered, exclusions: root.exclusions, markers: root.markers, blocked: blocked, inventoryDigest: digest)
  }
}
