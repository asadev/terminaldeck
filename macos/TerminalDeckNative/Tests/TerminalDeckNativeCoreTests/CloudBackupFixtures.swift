import Foundation
import Darwin
import XCTest
@testable import TerminalDeckNativeCore

/// Fixture-only: compiled in the test target, impossible to construct from the production app.
actor CloudBackupFixtureContent: CloudContentPort {
  let storageClass: CloudStorageClass
  var sealed: [CloudContentEnvelope] = []
  var locked = false
  func lock() { locked = true }
  init(_ storageClass: CloudStorageClass) { self.storageClass = storageClass }
  func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec) throws -> CloudContentEnvelope {
    guard !locked, storageClass == self.storageClass else { throw CloudFailure.invalidRequest }
    let value = CloudContentEnvelope(v: 1, suite: "FIXTURE-ONLY-NOT-ENCRYPTION", storageClass: storageClass, purpose: purpose, epoch: epoch, blobId: blobId, codec: .identity, plainBytes: Int64(bytes.count), nonce: "fixture", ciphertext: bytes.base64EncodedString(), tag: CloudBackupDigest.sha256(bytes))
    sealed.append(value)
    return value
  }
  func open(_ envelope: CloudContentEnvelope) throws -> Data {
    guard !locked else { throw CloudFailure.secretsLocked }
    guard envelope.storageClass == storageClass, let data = Data(base64Encoded: envelope.ciphertext),
      data.count == envelope.plainBytes, CloudBackupDigest.sha256(data) == envelope.tag else { throw CloudFailure.checksumMismatch }
    return data
  }
  func state(storageClass: CloudStorageClass) -> CloudContentState { .init(available: !locked && storageClass == self.storageClass, epoch: 1) }
}

/// Fixture-only durable-byte capture, not a successful cloud receipt.
actor CloudBackupFixtureOutbox: CloudOutboxPort {
  var bytes: [String: Data] = [:]
  var calls: [[CloudLocalBlob]] = []
  func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) throws -> CloudLocalReceipt {
    guard operations.allSatisfy({ $0.opId == $0.revision }) else { throw CloudFailure.invalidRequest }
    for file in files {
      let data = try Data(contentsOf: file.localURL)
      guard CloudBackupDigest.sha256(data) == file.sha256, data.count == file.bytes else { throw CloudFailure.checksumMismatch }
      bytes[file.blobId] = data
    }
    calls.append(files)
    return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: files.reduce(0) { $0 + $1.bytes }, savedAt: 1)
  }
  func read(_ ref: CloudBlobRef) throws -> Data { guard let data = bytes[ref.blobId] else { throw CloudFailure.unavailable }; return data }
  func corrupt(_ ref: CloudBlobRef) { bytes[ref.blobId] = Data("tampered fixture".utf8) }
  func coverage(sourceId: String) throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
  func flush() throws -> [CloudReceipt] { throw CloudFailure.unsupportedFormat }
  func restoreProgress() throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
  func contextReady(projectId: String) throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
  func register(adapter: any CloudDomainAdapter) throws { throw CloudFailure.unsupportedFormat }
  func bootstrap(_ snapshots: [CloudDomainSnapshot]) throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
  func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
  func pull() throws -> [CloudImportReceipt] { throw CloudFailure.unsupportedFormat }
  func setPaused(_ paused: Bool) throws { throw CloudFailure.unsupportedFormat }
}

struct CloudBackupFixture: Sendable {
  let base: URL
  let source: URL
  let brain = CloudBackupFixtureContent(.brain)
  let secrets = CloudBackupFixtureContent(.secrets)
  let outbox = CloudBackupFixtureOutbox()
  init() throws {
    let notes = try CloudBackupDirectory(path: "/Users/imatch/Deck Dev/notes")
    if mkdirat(notes.fd, "cloud-test-20261112", 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let day = try notes.directory("cloud-test-20261112")
    if mkdirat(day.fd, "bkp", 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let scope = try day.directory("bkp")
    let id = UUID().uuidString
    let owned = try scope.createDirectory(id)
    _ = try owned.createDirectory("source")
    base = URL(fileURLWithPath: "/Users/imatch/Deck Dev/notes/cloud-test-20261112/bkp").appendingPathComponent(id)
    source = base.appendingPathComponent("source")
  }
  func clean() { try? FileManager.default.removeItem(at: base) }
  func write(_ path: String, _ data: Data) throws {
    let url = source.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }
  func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }
  func engine() -> CloudBackupEngine {
    CloudBackupEngine(stateDirectory: base.appendingPathComponent("state"), brain: brain, secrets: secrets, classify: Self.classify, outbox: outbox)
  }
  func root(project: String = "project", rootID: String = "root") -> CloudBackupRoot {
    .init(projectId: project, rootId: rootID, deviceId: "fixture-machine-a", directory: source)
  }
  static func classify(_ path: String, _ source: String) -> CloudSecretClassification {
    let name = (path as NSString).lastPathComponent
    if ["auth.json", ".credentials.json", "oauth_creds.json"].contains(name) { return .init(storageClass: .secrets, purpose: .aiSubscription, rule: "fixture-provider-auth") }
    if name.hasPrefix(".env") || name.hasSuffix(".key") || name.hasSuffix(".pem") { return .init(storageClass: .secrets, purpose: .secret, rule: "fixture-secret") }
    return .init(storageClass: .brain, purpose: .brain, rule: "fixture-work")
  }
}
