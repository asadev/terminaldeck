import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Kinds-state (14 Nov, Mac mini: "Settings: Not complete" for ever while all 7 settings records were acknowledged).
/// The settings adapter registered while a coverage refresh was awaiting another adapter; the refresh then judged it
/// "vanished" and deleted its first-copy coverage, which nothing ever writes again.
extension CloudSyncTests {
  /// An adapter whose inventory can be held mid-call, so a second adapter registers while a refresh awaits it.
  actor KindsStateGatedAdapter: CloudDomainAdapter {
    nonisolated let inventoryRows: [String]
    let domain: String, sourceId: String
    private var gated = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(domain: String, sourceId: String, row: String) { self.domain = domain; self.sourceId = sourceId; inventoryRows = [row] }
    func close() { gated = true }
    func open() { gated = false; waiter?.resume(); waiter = nil }
    var isWaiting: Bool { waiter != nil }
    func sourceInventory() async throws -> [CloudSourceInventory] {
      if gated { await withCheckedContinuation { waiter = $0 } }
      return [.init(sourceId: sourceId, inventoryRow: inventoryRows[0], domain: domain, items: 1, bytes: 0, complete: true, blockedReasons: [], exclusions: [])]
    }
    func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { throw CloudFailure.unavailable }
    func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { AsyncThrowingStream { $0.finish() } }
    func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport { throw CloudFailure.unavailable }
    func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt { throw CloudFailure.unavailable }
    func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { throw CloudFailure.unavailable }
  }

  /// The race itself: an adapter registered while a refresh is inside the inventory loop keeps its coverage.
  func testKindsStateAdapterRegisteredDuringARefreshKeepsItsCoverage() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let root = try scratch(), store = try makeStore(root)
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["tasks", "settings"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in })
    let tasks = KindsStateGatedAdapter(domain: "tasks", sourceId: "task-list", row: "I12")
    let settings = KindsStateGatedAdapter(domain: "settings", sourceId: "app-settings-personal", row: "I21")
    try await engine.register(adapter: tasks)
    await tasks.close()
    let refresh = Task { try await engine.refreshCoverage() }
    var tries = 0
    while tries < 2_000, !(await tasks.isWaiting) { tries += 1; try await Task.sleep(nanoseconds: 1_000_000) }
    let held = await tasks.isWaiting
    XCTAssertTrue(held, "the refresh is inside the tasks adapter's inventory")
    try await engine.register(adapter: settings)
    await tasks.open()
    try await refresh.value
    let kept = try await engine.coverage(sourceId: "app-settings-personal")
    XCTAssertEqual(kept.inventoryRow, "I21", "a source registered during the pass was not asked, so it is not judged gone")
    let local: CloudSourceInventory? = try store.value("coverage-local:app-settings-personal")
    XCTAssertNotNil(local)
  }

  /// The case the Mac mini really hit: its first copy settled (feed), Settings owns a saved "first copy is saved"
  /// statement, and on a later launch Settings registers while a coverage check awaits Tasks. The statement survives.
  func testKindsStateSettledFirstCopyStatementSurvivesARegistrationDuringACheck() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let root = try scratch(), store = try makeStore(root)
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory", "tasks", "settings"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in })
    try await engine.register(adapter: try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain")))
    _ = try await engine.bootstrap([feedSetup([try op(entity: "settled")])])
    XCTAssertEqual(try store.value("baseline") as String?, "feed")
    // What the settled first copy left for Settings on the Mac mini (owner mark and published statement).
    let statement = CloudCoverage(sourceId: "app-settings-personal", inventoryRow: "I21", complete: true, items: 7, bytes: 0, blockedReasons: [], exclusions: [])
    try store.set("coverage-owner:app-settings-personal", true)
    try store.set("coverage-domain:app-settings-personal", "settings")
    try store.set("coverage-published:app-settings-personal", statement)
    // A later launch: Tasks registers, a check starts and waits inside Tasks, Settings registers meanwhile.
    let tasks = KindsStateGatedAdapter(domain: "tasks", sourceId: "task-list", row: "I12")
    let settings = KindsStateGatedAdapter(domain: "settings", sourceId: "app-settings-personal", row: "I21")
    try await engine.register(adapter: tasks)
    await tasks.close()
    let check = Task { try await engine.refreshCoverage() }
    var tries = 0
    while tries < 2_000, !(await tasks.isWaiting) { tries += 1; try await Task.sleep(nanoseconds: 1_000_000) }
    let held = await tasks.isWaiting
    XCTAssertTrue(held, "the check is inside the tasks adapter's inventory")
    try await engine.register(adapter: settings)
    await tasks.open()
    try await check.value
    let survived: CloudCoverage? = try store.value("coverage-published:app-settings-personal")
    XCTAssertEqual(survived, statement, "the first copy's statement survives the check")
    let now = try await engine.coverage(sourceId: "app-settings-personal")
    XCTAssertTrue(now.complete, "\(now.blockedReasons)")
    XCTAssertFalse(now.blockedReasons.contains("Waiting for a verified snapshot."))
  }

  /// The heal for a Mac that already lost it: with no first upload, a source this Mac owns (its first copy settled)
  /// and whose own statement is gone is complete on this Mac's word, never "Waiting for a verified snapshot." for good.
  func testKindsStateOwnedFeedSourceWithoutItsStatementIsComplete() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (mac, store, _) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    _ = try await mac.bootstrap([feedSetup([try op(entity: "settled")])])
    XCTAssertEqual(try store.value("baseline") as String?, "feed")
    XCTAssertEqual(try store.value("coverage-owner:fixture-source") as Bool?, true)
    try store.execute("DELETE FROM metadata WHERE key=?", [Data("coverage-published:fixture-source".utf8)])
    try await mac.refreshCoverage()
    let healed = try await mac.coverage(sourceId: "fixture-source")
    XCTAssertTrue(healed.complete, "\(healed.blockedReasons)")
    XCTAssertFalse(healed.blockedReasons.contains("Waiting for a verified snapshot."))
    let packs = await server.segmentCount()
    XCTAssertEqual(packs, 1, "only the first copy's pack; healing sends nothing")
  }

  /// A source this Mac does not own (no settled first copy here) still waits: the heal is not a blanket "complete".
  func testKindsStateSourceNotOwnedStillWaits() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (mac, store, _) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    try await mac.refreshCoverage()
    XCTAssertNil(try store.value("coverage-owner:fixture-source") as Bool?)
    let waiting = try await mac.coverage(sourceId: "fixture-source")
    XCTAssertFalse(waiting.complete)
    XCTAssertTrue(waiting.blockedReasons.contains("Waiting for a verified snapshot."))
  }
}
