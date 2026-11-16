import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only: what the sync core is to a lane A2 adapter, without a service. It keeps what was handed over so a
/// test can carry it to another Mac's adapter. Never used by a production target.
actor CloudLeanFixtureOutbox: CloudOutboxPort {
  private var sent: [CloudOperation] = []
  private var taken = 0
  private(set) var registered = 0
  private(set) var pulls = 0
  /// Everything handed over since the last call: what the sync core would send as signed packs.
  func take() -> [CloudOperation] {
    let fresh = Array(sent[taken...])
    taken = sent.count
    return fresh
  }
  func all() -> [CloudOperation] { sent }
  func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
    sent += operations
    return .init(operationIds: operations.map { $0.opId }, queued: operations.count, bytes: 0, savedAt: 0)
  }
  func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
  func flush() async throws -> [CloudReceipt] { [] }
  func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
  func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
  func register(adapter: any CloudDomainAdapter) async throws { registered += 1 }
  func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
  func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt {
    for source in sources {
      let page = try await source.snapshot(cut: cut)
      sent += page.operations
    }
    return .init(checkpointId: "", throughSeq: .zero, verifiedBy: [], published: false)
  }
  func pull() async throws -> [CloudImportReceipt] { pulls += 1; return [] }
  func setPaused(_ paused: Bool) async throws {}
}

/// One Mac of a lean test: its own data folder, its own bookkeeping for one account, its own outbox.
struct CloudLeanFixtureMac: Sendable {
  let root: URL
  let device: String
  let subject: String
  let account: CloudBrainAgentsAccount
  let store: CloudBrainAgentsStore
  let origins: CloudBrainRecordOrigins
  let outbox: CloudLeanFixtureOutbox
}

enum CloudLeanFixture {
  static let deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  static let deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  /// Two unrelated Cloud accounts (fixture subject hashes, not real identities).
  static let subjectX = String(repeating: "1", count: 64)
  static let subjectY = String(repeating: "2", count: 64)

  /// One clock for every Mac of a test, as the service's clock is: each reading is one second later than the last.
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_760_000_000_000
    func read() -> Int64 { lock.withLock { value += 1_000; return value } }
  }
  /// A counter a test hands to a callback that must (or must never) be called.
  final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
  }
  /// A value a test changes while an owner reads it (this Mac's project list, its trusted list).
  final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }
  /// Files only under ~/Deck Dev/notes/cloud-test-20261112/a2.
  static func folder() throws -> URL {
    let folder = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Deck Dev/notes/cloud-test-20261112/a2/lean-" + UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  /// A Mac signed in to `subject`. `root`: an existing data folder (the same Mac signing in to another account).
  static func mac(_ device: String, clock: Clock, subject: String = subjectX, root existing: URL? = nil) throws -> CloudLeanFixtureMac {
    let root = try existing ?? folder()
    let account = try CloudBrainAgentsAccount(subjectHash: subject, deviceID: device)
    let cloud = root.appendingPathComponent("cloud")
    let store = try CloudBrainAgentsStore(directory: cloud.appendingPathComponent(subject).appendingPathComponent("a2"), account: account,
      clock: CloudBrainMergeClock(read: { clock.read() }))
    let origins = try CloudBrainRecordOrigins(cloudFolder: cloud, account: subject)
    return .init(root: root, device: device, subject: subject, account: account, store: store, origins: origins, outbox: CloudLeanFixtureOutbox())
  }
  /// The enabling step as lane A's wiring runs it; returns the activation and what this Mac's setup sent.
  static func start(_ adapters: [CloudBrainRecordAdapter], on mac: CloudLeanFixtureMac) async throws -> (activation: CloudBrainRecordActivation, sent: [CloudOperation]) {
    let activation = try CloudBrainRecordActivation(adapters: adapters, store: mac.store, every: nil)
    try await activation.start(outbox: mac.outbox)
    let sent = await mac.outbox.take()
    return (activation, sent)
  }
  /// One capture pass and hand-over; returns what went to the sync core.
  static func sync(_ activation: CloudBrainRecordActivation, on mac: CloudLeanFixtureMac) async throws -> [CloudOperation] {
    try await activation.sync(outbox: mac.outbox)
    return await mac.outbox.take()
  }
  /// Delivers records as one pack signed by `device`, a device trusted on the receiving Mac.
  @discardableResult
  static func deliver(_ operations: [CloudOperation], from device: String, to adapter: CloudBrainRecordAdapter) async throws -> CloudImportReceipt {
    let domain = adapter.domain
    let mine = operations.filter { $0.domain == domain }
    let prepared = try await adapter.validateIncoming(mine, files: [])
    return try await adapter.applyPrepared(prepared, origin: .init(deviceId: device, sequence: .zero))
  }
  /// As the sync core does after a refusal: one record at a time. A refused record is parked (returned with its
  /// reason), later versions of the same record wait behind it, everything else applies.
  static func deliverParking(_ operations: [CloudOperation], from device: String, to adapter: CloudBrainRecordAdapter) async throws -> [String: String] {
    var parked: [String: String] = [:], blocked = Set<String>()
    let domain = adapter.domain
    for operation in operations where operation.domain == domain {
      if blocked.contains(operation.entityId) { parked[operation.opId] = "waiting"; continue }
      do { try await deliver([operation], from: device, to: adapter) }
      catch let refusal as CloudRecordRefusal { parked[operation.opId] = refusal.reason; blocked.insert(operation.entityId) }
    }
    return parked
  }
  /// The whole of what was sent, as text, for "this never travels" checks.
  static func text(_ operations: [CloudOperation]) -> String {
    operations.map { $0.entityId + " " + $0.payload.raw.compact }.joined(separator: "\n")
  }
}
