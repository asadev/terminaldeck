import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only stores and content. Never imported by a production target.
enum CloudBrainAgentsFixture {
  static let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  static let deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  static let deviceC = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  /// Two unrelated Cloud accounts (fixture subject hashes, not real identities).
  static let subjectX = String(repeating: "1", count: 64)
  static let subjectY = String(repeating: "2", count: 64)
  static let cut = CloudSnapshotCut(snapshotId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", at: 1, watermarks: [:])
  static func account(_ device: String, subject: String = subjectX) -> CloudBrainAgentsAccount {
    try! CloudBrainAgentsAccount(subjectHash: subject, deviceID: device)
  }
  static func directory() throws -> URL {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/a2")
    let directory = root.appendingPathComponent(UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
  static func write(_ data: Data, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .withoutOverwriting)
  }
  static func copyToFixtureCloud(_ files: [CloudLocalBlob], directory: URL) throws -> [CloudLocalBlob] {
    try files.map { file in
      let url = directory.appendingPathComponent(file.blobId + ".sealed")
      if !FileManager.default.fileExists(atPath: url.path) { try write(Data(contentsOf: file.localURL), to: url) }
      return .init(blobId: file.blobId, sourceId: file.sourceId, localURL: url, bytes: file.bytes, sha256: file.sha256,
        md5: file.md5, keyEpoch: file.keyEpoch, storageClass: file.storageClass, purpose: file.purpose)
    }
  }
  /// Sends operations through the real pack encoder/decoder (the fixture cloud) into an adapter, as SYNC would.
  @discardableResult
  static func deliver(_ operations: [CloudOperation], to adapter: any CloudDomainAdapter, sequence: UInt64 = 1) async throws -> CloudImportReceipt {
    for op in operations { XCTAssertLessThanOrEqual(try CloudSyncCanonical.encode(op.payload).count, 65_536, "Every payload stays below 64 KiB") }
    let incoming = try CloudSyncPack.decode(try CloudSyncPack.encode(operations))
    let prepared = try await adapter.validateIncoming(incoming, files: [])
    let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: device, sequence: CloudSequence(sequence)))
    XCTAssertFalse(receipt.results.contains { $0.status == .blocked }, "SYNC treats a blocked result as a failed batch")
    let verified = try await adapter.verify(receipt)
    XCTAssertTrue(verified.verified)
    return receipt
  }
  /// A's snapshot (own revisions only) delivered to B.
  @discardableResult
  static func roundTrip(_ a: any CloudDomainAdapter, _ b: any CloudDomainAdapter) async throws -> CloudDomainSnapshot {
    let snapshot = try await a.snapshot(cut: cut)
    try await deliver(snapshot.operations, to: b)
    return snapshot
  }
  /// Revisions A made after `after` (what A's pump would hand to the outbox next).
  static func ownChanges(_ adapter: CloudBrainAgentsAdapter, after: String?) async throws -> [CloudOperation] {
    try await adapter.owner.ownChanges(after, 256)
  }
  static func ledgerFiles(_ root: URL) -> [URL] {
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
    return files.filter { $0.lastPathComponent == "ledger.log" }
  }
}

struct CloudBrainAgentsFixtureCipher: BackendAccountVaultCipher {
  let usable: Bool
  func available() -> Bool { usable }
  func prepareForWrites(existingVault: Bool) throws { if !usable { throw CloudFailure.secretsLocked } }
  func encrypt(_ text: String, existingVault: Bool) throws -> Data { guard usable else { throw CloudFailure.secretsLocked }; return Data(text.utf8) }
  func decrypt(_ blob: Data) throws -> String { guard usable else { throw CloudFailure.secretsLocked }; return String(decoding: blob, as: UTF8.self) }
}

actor CloudConversationFixtureContent: CloudContentPort {
  func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec) throws -> CloudContentEnvelope {
    guard storageClass == .brain, purpose == .brain else { throw CloudFailure.invalidRequest }
    return .init(v: 1, suite: "fixture-only-not-encryption", storageClass: .brain, purpose: .brain, epoch: epoch,
      blobId: blobId, codec: .identity, plainBytes: Int64(bytes.count), nonce: "fixture-only", ciphertext: bytes.base64EncodedString(), tag: "fixture-only")
  }
  func open(_ envelope: CloudContentEnvelope) throws -> Data {
    guard envelope.suite == "fixture-only-not-encryption", let bytes = Data(base64Encoded: envelope.ciphertext), Int64(bytes.count) == envelope.plainBytes else { throw CloudFailure.checksumMismatch }
    return bytes
  }
  func state(storageClass: CloudStorageClass) -> CloudContentState { .init(available: storageClass == .brain, epoch: 1, reason: nil) }
}

actor CloudBrainAgentsFixtureEffects {
  private(set) var calls = 0
  func called() { calls += 1 }
}

/// Fixture-only outbox: records what an owner pump hands over; every other port method refuses.
actor CloudBrainAgentsFixtureOutbox: CloudOutboxPort {
  private(set) var enqueued: [CloudOperation] = []
  var failNext = false
  func failOnce() { failNext = true }
  func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
    if failNext { failNext = false; throw CloudFailure.unavailable }
    enqueued += operations
    return .init(operationIds: operations.map(\.opId), queued: enqueued.count, bytes: 0, savedAt: 1)
  }
  func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unavailable }
  func flush() async throws -> [CloudReceipt] { throw CloudFailure.unavailable }
  func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unavailable }
  func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unavailable }
  func register(adapter: any CloudDomainAdapter) async throws { throw CloudFailure.unavailable }
  func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
  func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
  func pull() async throws -> [CloudImportReceipt] { throw CloudFailure.unavailable }
  func setPaused(_ paused: Bool) async throws { throw CloudFailure.unavailable }
}
