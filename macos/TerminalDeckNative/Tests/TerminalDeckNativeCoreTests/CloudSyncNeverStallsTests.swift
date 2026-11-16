import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// MAC-NEXT-5 (13 Nov, the owner's two real Macs): queued records sat for 244 s on the Mac mini, and for ever on the
/// joining MacBook, with `blocked=true`, no failure counted and no log line. The scheduler cleared its request before
/// the step ran, and only a COUNTED network failure armed a retry: a busy refusal, a local refusal (idReused), a lost
/// answer or a cancel dropped the send silently. Invariant now: whenever records are queued, sync is not paused by
/// the person and no named wait applies, a send is running or a timer is armed.
extension CloudSyncTests {
  final class FaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(CloudSyncKillPoint, Error)] = []
    func add(_ point: CloudSyncKillPoint, _ error: Error) { lock.withLock { pending.append((point, error)) } }
    func take(_ point: CloudSyncKillPoint) throws {
      let error: Error? = lock.withLock {
        guard let index = pending.firstIndex(where: { $0.0 == point }) else { return nil }
        return pending.remove(at: index).1
      }
      if let error { throw error }
    }
  }
  /// A record that barely compresses (like the owner's memory files).
  func incompressible(_ entity: String, origin: String? = nil) throws -> CloudOperation {
    try op(entity: entity, text: (0..<120).map { _ in UUID().uuidString }.joined(separator: " "), origin: origin)
  }
  func stallEngine(root: URL, server: CloudSyncFixtureServer, store: CloudSyncStore? = nil, domains: Set<String> = ["memory"],
                   faults: FaultBox = FaultBox()) async throws -> (CloudSyncEngine, CloudSyncStore) {
    let store = try store ?? makeStore(root)
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: domains,
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in },
      fault: { point in try faults.take(point) })
    try await engine.register(adapter: adapter)
    return (engine, store)
  }
  /// Polls until nothing is queued; the invariant must hold at EVERY look on the way (nothing injected meanwhile).
  func drainWithoutHelp(_ engine: CloudSyncEngine, _ store: CloudSyncStore, seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      let check = await engine.debugSyncInvariant()
      if let broken = check.broken { XCTFail("invariant broken: " + broken, file: file, line: line); return }
      if try store.queuedCount() == 0, check.idle { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("records still queued after \(seconds) s: \(try store.queuedCount())", file: file, line: line)
  }

  func testEveryLocalFailureLeavesTheSendPendingWithATimerUntilItGoes() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let faults = FaultBox()
    let (engine, store) = try await stallEngine(root: scratch(), server: server, faults: faults)
    _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
    await engine.startEvents()   // one "hello"; no other event is sent below
    try await drainWithoutHelp(engine, store)
    var packs = await server.segmentCount()

    // 1. The answer to a stored pack is lost (a local "unavailable": no failure counted, so no timer before).
    await server.setLostACK()
    _ = try await engine.enqueue([try incompressible("lost-answer")])
    try await drainWithoutHelp(engine, store)
    // 2. A local refusal after the commit (idReused, as the owner's Mac logged): no failure counted either.
    faults.add(.afterCommit, CloudFailure.idReused)
    _ = try await engine.enqueue([try incompressible("id-reused")])
    try await drainWithoutHelp(engine, store)
    // 3. Cancelled in the middle.
    faults.add(.afterCommit, CancellationError())
    _ = try await engine.enqueue([try incompressible("cancelled")])
    try await drainWithoutHelp(engine, store)
    // 4. Busy: steps from outside the scheduler (the Cloud page, the setup wiring) race the scheduler's own.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask { _ = try? await engine.pull() }
        group.addTask { _ = try await engine.enqueue([try self.incompressible("busy-\(index)")]) }
        group.addTask { _ = try? await engine.flush() }
      }
      try await group.waitForAll()
    }
    try await drainWithoutHelp(engine, store)
    let after = await server.segmentCount()
    XCTAssertGreaterThanOrEqual(after - packs, 4)
    packs = after
    // Nothing is left blocked.
    XCTAssertEqual(try store.value("blocked") as Bool?, false)
    await engine.stop()
  }

  /// MAC-NEXT-12b: a stored "network" pause (five failed tries) and a stored sign-in block each end by themselves:
  /// the network pause at its own time, the sign-in block at the next signed status read that the service answers.
  /// No help: no wake, no network change, no "Sync now", no relaunch.
  func testNetworkAndSignInBlocksEndByThemselvesWithoutHelp() async throws {
    for blocked in ["network", "auth"] {
      let server = try CloudSyncFixtureServer(root: scratch(), device: device)
      let (engine, store) = try await stallEngine(root: scratch(), server: server)
      await engine.setAllowanceProbe(seconds: 0.3)
      _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
      var state = CloudSyncBudgetSnapshot(day: CloudSyncBytes.now() / 86_400_000)
      state.blocked = blocked; state.failures = 5; state.retryAt = blocked == "network" ? CloudSyncBytes.now() + 400 : 0
      try store.set("budget", state)
      _ = try await engine.enqueue([try incompressible("after-" + blocked)])
      await engine.startEvents()
      try await drainWithoutHelp(engine, store)
      let after = try await CloudSyncBudget(store: store).status()
      XCTAssertNil(after.blocked, blocked)
      await engine.stop()
    }
  }

  /// A restart between a send and its answer: the next launch finds the pack in flight and sends it by itself.
  func testARestartBetweenSendAndAnswerSendsByItselfAfterLaunch() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let root = try scratch()
    let (first, store) = try await stallEngine(root: root, server: server)
    _ = try await first.bootstrap([feedSetup([try incompressible("baseline")])])
    await server.setLostACK()
    _ = try await first.enqueue([try incompressible("in-flight")])
    _ = try? await first.flush()
    XCTAssertEqual(try store.queuedCount(), 1)
    await first.stop()
    let (second, _) = try await stallEngine(root: root, server: server, store: store)
    await second.startEvents()
    try await drainWithoutHelp(second, store)
    let stored = await server.segmentCount()
    XCTAssertEqual(stored, 2, "the pack in flight was not sent twice")
    await second.stop()
  }

  /// G: projects and agents go up before memory that names them, whatever order they were queued in.
  func testProjectsAndAgentsAreSentBeforeMemory() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store) = try await stallEngine(root: scratch(), server: server, domains: ["memory", "projects", "agents"])
    _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
    var memory: [CloudOperation] = []
    for index in 0..<300 { memory.append(try incompressible("memory-\(index)")) }
    _ = try await engine.enqueue(memory)
    func record(_ domain: String, _ entity: String) throws -> CloudOperation {
      let base = try op(entity: entity)
      return .init(v: base.v, opId: base.opId, originDevice: base.originDevice, domain: domain, entityId: entity, revision: base.revision,
        parents: [], kind: .put, projectId: nil, source: .init(sourceId: domain + "-source", recordId: entity), createdAt: base.createdAt,
        payload: base.payload, payloadHash: base.payloadHash)
    }
    _ = try await engine.enqueue([try record("projects", "deck"), try record("agents", "builder")])
    _ = try await engine.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    let page = try await server.changes(after: .zero, limit: 128)
    let order = page.segments.compactMap { $0.domains?.first }
    // After the setup's pack: the two record kinds first, then memory.
    XCTAssertEqual(Array(order.dropFirst().prefix(2)).sorted(), ["agents", "projects"])
    XCTAssertTrue(order.dropFirst(3).allSatisfy { $0 == "memory" })
  }

  /// E: the first copy's page notes go when it completes, and once at launch for a store an earlier build left
  /// them in; the Cloud page's 2-second reads write nothing when nothing changed.
  func testFirstCopyPageNotesGoAndTheProgressReadWritesNothing() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let root = try scratch()
    let (engine, store) = try await stallEngine(root: root, server: server)
    _ = try await engine.bootstrap([feedSetup((0..<40).map { try! incompressible("page-\($0)") })])
    XCTAssertEqual(try store.value("baseline") as String?, "feed")
    for prefix in ["snapshot-page:", "snapshot-pages:", "snapshot-page-stored:", "snapshot-replay:"] {
      XCTAssertTrue(try store.prefixed(prefix).isEmpty, prefix)
    }
    // A store carried over from the previous build: its first copy complete, its notes still there.
    for index in 0..<500 { try store.set("snapshot-page:old-cut:0:\(index)", "digest-\(index)") }
    try store.set("snapshot-pages:old-cut:0", 500)
    try store.set("sent-once:keep-me", true)
    await engine.stop()
    let (relaunched, _) = try await stallEngine(root: root, server: server, store: store)
    XCTAssertTrue(try store.prefixed("snapshot-page:").isEmpty)
    XCTAssertTrue(try store.prefixed("snapshot-pages:").isEmpty)
    XCTAssertEqual(try store.value("sent-once:keep-me") as Bool?, true, "other notes are kept")
    // The page's read, twice per tick, many ticks: no write at all once nothing changes.
    _ = try await relaunched.restoreProgress(); _ = try await relaunched.baselineProgress()
    let before = try store.rows("SELECT total_changes()")[0][0]
    for _ in 0..<10 { _ = try await relaunched.restoreProgress(); _ = try await relaunched.baselineProgress() }
    XCTAssertEqual(try store.rows("SELECT total_changes()")[0][0], before)
  }
}
