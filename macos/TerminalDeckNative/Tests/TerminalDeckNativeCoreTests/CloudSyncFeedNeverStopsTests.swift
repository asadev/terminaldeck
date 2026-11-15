import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// MAC-NEXT-6 (13 Nov 13:21, the owner's two real Macs on 2c85b326). The Mac mini sat at 404 of 407 with
/// "fetch failed: idReused" every 60 s: the MacBook had re-sent 250 of the Mac mini's own notes under its own store id
/// (an echo), the memory adapter refused them with a plain CloudFailure, and that error left the feed loop; the staged
/// journal replayed it each minute and, since a scheduled step fetched before it sent, the Mac mini's own changes
/// stopped going up as well. These tests rebuild that shape on two devices: overlapping record ids with the same and
/// with different content, records the adapter refuses, and text that barely compresses.
extension CloudSyncTests {
  private final class Lines: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    func add(_ line: String) { lock.withLock { all.append(line) } }
    func snapshot() -> [String] { lock.withLock { all } }
  }
  private func sender(_ server: CloudSyncFixtureServer) async throws -> CloudSyncEngine {
    let (engine, _, _) = try await feedEngine(root: scratch(), server: server, deviceId: secondMac)
    return engine
  }
  /// One pack as a sync core seals it, committed under the server's current device.
  private func commitPack(_ server: CloudSyncFixtureServer, _ operations: [CloudOperation]) async throws {
    let id = UUID().uuidString.lowercased()
    let envelope = try await makeContent().seal(try CloudSyncCanonical.encode(operations), blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope)
    let descriptor = CloudSegmentDescriptor(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .brain, purpose: .brain,
      domains: ["memory"], keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count), opCount: operations.count,
      format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64)))
    _ = try await server.commit(.init(descriptor: descriptor, ciphertext: CloudSyncBytes.base64(bytes)))
  }
  private func waitUntil(_ seconds: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if try await condition() { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }
  /// Waits for the feed to reach its head with nothing queued. It gives up only when the feed STOPS: no change in
  /// position or queue for `stallSeconds` (or after `capSeconds` in all). A fixed 20 s for the whole download failed
  /// once in a busy full run (62 records not yet read at the deadline) while the feed was still moving.
  private func waitForFeedLevel(_ store: CloudSyncStore, stallSeconds: Double = 20, capSeconds: Double = 300) async throws -> Bool {
    let cap = Date().addingTimeInterval(capSeconds)
    var lastSeq: CloudSequence?, lastHead: CloudSequence?, lastQueued = -1, lastMove = Date()
    while Date() < cap {
      let head: CloudSequence? = try store.value("headSeq"), seq: CloudSequence? = try store.value("brainSeq")
      let queued = try store.queuedCount()
      if queued == 0, head != nil, seq == head { return true }
      if seq != lastSeq || head != lastHead || queued != lastQueued { lastSeq = seq; lastHead = head; lastQueued = queued; lastMove = Date() }
      else if Date().timeIntervalSince(lastMove) > stallSeconds { return false }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  func testX1EchoedAndRefusedRecordsNeverStopTheFeedEveryRecordLandsOnceAndSendingGoesOn() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (mini, miniStore, miniAdapter) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    let miniRecords = try (0..<40).map { try incompressible("mini-\($0)") }
    _ = try await mini.bootstrap([feedSetup(miniRecords)])

    // The MacBook sends, in packs of barely compressing text: 10 of the Mac mini's records again (same id, same
    // bytes: the echo), 10 records the Mac mini's adapter refuses (idReused, as memory did), 5 records under ids
    // the Mac mini already holds with OTHER content, and 60 new ones.
    await server.switchDevice(secondMac)
    let book = try await sender(server)
    let fresh = try (0..<60).map { try incompressible("book-\($0)", origin: secondMac) }
    let refused = try (0..<10).map { try incompressible("echo-note-\($0)", origin: secondMac) }
    let clashing = try miniRecords[10..<15].map { try op(id: $0.opId, entity: $0.entityId, text: "other words " + UUID().uuidString, origin: secondMac) }
    _ = try await book.bootstrap([feedSetup([fresh[0]])])
    _ = try await book.enqueue(Array(fresh[1...]))
    _ = try await book.flush()
    await book.stop()
    // The echo, the refused and the clashing records come as the MacBook's packs too (sealed as its sync core seals).
    try await commitPack(server, Array(miniRecords[0..<10]) + refused[0..<5])
    try await commitPack(server, Array(refused[5...]) + clashing)
    let packs = await server.segmentCount()
    XCTAssertGreaterThan(packs, 3, "the MacBook's records travel in several packs")

    // The Mac mini has its own new records queued while those packs come in.
    await server.switchDevice(device)
    await miniAdapter.refuseWithIdReused(Set(refused.map(\.entityId)))
    let own = try (0..<5).map { try incompressible("mini-new-\($0)") }
    _ = try await mini.enqueue(own)
    let before = await server.segmentCount()
    await mini.startEvents()
    let reached = try await waitForFeedLevel(miniStore)
    XCTAssertTrue(reached, "the feed reached its head and the Mac mini's own records went up")
    let after = await server.segmentCount()
    XCTAssertGreaterThan(after, before, "sending went on")
    // Every record landed exactly once: the Mac mini's 40, the MacBook's 60 new ones; the echo applied nothing twice.
    let rows = await miniAdapter.rows, effects = await miniAdapter.effectCount()
    XCTAssertEqual(effects, rows.count, "no record applied twice")
    for record in miniRecords + fresh { XCTAssertNotNil(rows[record.opId], record.entityId) }
    for record in refused { XCTAssertNil(rows[record.opId], record.entityId) }
    for record in clashing { XCTAssertEqual(rows[record.opId], miniRecords.first { $0.opId == record.opId }, "the Mac mini keeps its own content") }
    // The refused and the clashing ones are parked and listed, nothing was refused as a whole pack.
    let parked = Int(String(decoding: try miniStore.rows("SELECT count(*) FROM parked_ops")[0][0], as: UTF8.self)) ?? 0
    XCTAssertEqual(parked, 15)
    let conflicts = Int(String(decoding: try miniStore.rows("SELECT count(*) FROM parked_ops WHERE conflict=1")[0][0], as: UTF8.self)) ?? 0
    XCTAssertEqual(conflicts, 5)
    XCTAssertTrue(try miniStore.rows("SELECT seq FROM refused_packs").isEmpty)
    XCTAssertTrue(try miniStore.rows("SELECT segmentId FROM prepare_journal").isEmpty, "no journal is left to replay a failure")
    await mini.stop()
  }

  /// A pack that cannot be opened (its bytes are damaged) is tried again; after three tries it is listed with its
  /// reason and the packs after it are fetched. One try still stops the pull and keeps the position (S06).
  func testX1APackThatCannotBeOpenedIsListedAfterThreeTriesAndThePacksAfterItArrive() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let content = try makeContent()
    let id = UUID().uuidString.lowercased()
    let envelope = try await content.seal(try CloudSyncCanonical.encode([try op()]), blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope).dropLast(8)
    let descriptor = CloudSegmentDescriptor(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .brain, purpose: .brain,
      domains: ["memory"], keyEpoch: 1, sha256: CloudSyncBytes.hash(Data(bytes)), bytes: Int64(bytes.count), opCount: 1,
      format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64)))
    _ = try await server.commit(.init(descriptor: descriptor, ciphertext: CloudSyncBytes.base64(Data(bytes))))
    await server.switchDevice(secondMac)
    let book = try await sender(server)
    let good = try (0..<3).map { try incompressible("after-\($0)", origin: secondMac) }
    _ = try await book.bootstrap([feedSetup(good)])
    await book.stop()
    await server.switchDevice(device)
    let (mini, miniStore, adapter) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    for attempt in 1...2 {
      do { _ = try await mini.pull(); XCTFail("attempt \(attempt) should stop") } catch {}
      XCTAssertEqual((try miniStore.value("brainSeq") as CloudSequence?) ?? .zero, .zero)
    }
    _ = try await mini.pull()
    XCTAssertEqual(try miniStore.value("brainSeq") as CloudSequence?, try miniStore.value("headSeq") as CloudSequence?)
    XCTAssertEqual(try miniStore.rows("SELECT seq FROM refused_packs").count, 1)
    let count = await adapter.count()
    XCTAssertEqual(count, 3)
    await mini.stop()
  }

  /// X2: a scheduled step sends this Mac's queued records BEFORE it reads the feed (the MacBook's 56 waited 6.5 min
  /// behind its download), and a long download never holds them.
  func testX2QueuedRecordsGoBeforeTheDownload() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (mini, miniStore, _) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    _ = try await mini.bootstrap([feedSetup([try incompressible("baseline")])])
    await server.switchDevice(secondMac)
    let book = try await sender(server)
    _ = try await book.bootstrap([feedSetup([try incompressible("book-setup", origin: secondMac)])])
    for index in 0..<30 {
      _ = try await book.enqueue([try incompressible("book-\(index)", origin: secondMac)])
      _ = try await book.flush()
    }
    await book.stop()
    await server.switchDevice(device)
    _ = try await mini.enqueue((0..<3).map { try! incompressible("mine-\($0)") })
    let mark = await server.log().count
    await mini.startEvents()
    let level = try await waitUntil {
      let head: CloudSequence? = try miniStore.value("headSeq"), seq: CloudSequence? = try miniStore.value("brainSeq")
      return try miniStore.queuedCount() == 0 && head != nil && seq == head
    }
    XCTAssertTrue(level)
    let log = Array(await server.log().dropFirst(mark))
    let firstCommit = try XCTUnwrap(log.firstIndex(of: "commit:" + device))
    let firstRead = try XCTUnwrap(log.firstIndex(of: "changes:" + device))
    XCTAssertLessThan(firstCommit, firstRead, "\(log.prefix(6))")
    await mini.stop()
  }

  /// X3: the route only, never what follows it; and the start-up wait is not called a pause by the person.
  func testX3LogLinesSayTheRouteOnlyAndStartingUpIsNoPause() async throws {
    XCTAssertEqual(CloudSyncDiagnostics.plainPath(URL(string: "https://api.test/v1/transfers/eyJibG9iIjpudWxsLCJkZXZpY2VJZCI6ImY0NjVi")!), "/v1/transfers/…")
    XCTAssertEqual(CloudSyncDiagnostics.plainPath(URL(string: "https://api.test/v1/changes")!), "/v1/changes")
    XCTAssertEqual(CloudSyncDiagnostics.plainPath(URL(string: "https://api.test/v1/changes?after=12")!), "/v1/changes")
    XCTAssertEqual(CloudSyncDiagnostics.plainPath(URL(string: "https://api.test/auth/v1/token")!), "/auth/v1/token")
    XCTAssertEqual(CloudSyncDiagnostics.plainPath(URL(string: "https://bucket.test/objects/abc")!), "storage link")

    let lines = Lines()
    CloudSyncDiagnostics.shared.setSink { lines.add($0) }
    defer { CloudSyncDiagnostics.shared.setSink(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store) = try await stallEngine(root: scratch(), server: server)
    _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
    try await engine.holdForStartup()
    _ = try await engine.enqueue([try incompressible("waits-for-start")])
    do { _ = try await engine.flush(); XCTFail("held while starting up") } catch {}
    await engine.startEvents()
    let said = try await waitUntil(5) { lines.snapshot().contains { $0.contains("waiting: Cloud is starting up on this Mac") } }
    XCTAssertTrue(said, "\(lines.snapshot())")
    XCTAssertEqual(try store.queuedCount(), 1)
    XCTAssertFalse(lines.snapshot().contains { $0.contains("paused by the person") })
    XCTAssertNotEqual(try store.value("paused") as Bool?, true, "starting up writes no pause")
    try await engine.setPaused(false)
    try await drainWithoutHelp(engine, store)
    await engine.stop()
  }

  /// X4: while records wait, every waiting line says how many.
  func testX4AWaitingLineCountsTheRecordsThatWait() async throws {
    let lines = Lines()
    CloudSyncDiagnostics.shared.setSink { lines.add($0) }
    defer { CloudSyncDiagnostics.shared.setSink(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store) = try await stallEngine(root: scratch(), server: server)
    _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
    await server.setFailure(.unavailable)
    _ = try await engine.enqueue((0..<3).map { try! incompressible("held-\($0)") })
    await engine.startEvents()
    let said = try await waitUntil(10) { lines.snapshot().contains { $0.contains("waiting:") && $0.contains("3 records of this Mac wait to go up") } }
    XCTAssertTrue(said, "\(lines.snapshot())")
    await server.setFailure(nil)
    try await drainWithoutHelp(engine, store, seconds: 30)
    await engine.stop()
  }

  /// X5: requests are spread evenly under the service's per-device limits (600 bulk reads and 240 sends a sliding
  /// minute): bulk reads 8 a second, sends 3 a second, a 429 halves the pace for a minute. Clock and sleep injected.
  func testX5RequestsAreSpreadEvenlyUnderTheServiceLimitsAndA429HalvesThePace() async throws {
    final class Clock: @unchecked Sendable {
      private let lock = NSLock(); private var at = Date(timeIntervalSince1970: 1000); private var waits: [TimeInterval] = []
      func now() -> Date { lock.withLock { at } }
      func sleep(_ seconds: TimeInterval) { lock.withLock { at = at.addingTimeInterval(seconds); waits.append(seconds) } }
      func slept() -> [TimeInterval] { lock.withLock { waits } }
    }
    XCTAssertLessThanOrEqual(CloudSyncServicePace.bulkReadsPerSecond * 60, Double(CloudSyncServicePace.serviceBulkReadsPerMinute) * 0.8)
    XCTAssertLessThanOrEqual(CloudSyncServicePace.sendsPerSecond * 60, Double(CloudSyncServicePace.serviceSendsPerMinute) * 0.8)
    let clock = Clock()
    let bulk = CloudSyncTransferPacer(perSecond: CloudSyncServicePace.bulkReadsPerSecond, now: { clock.now() }, sleep: { clock.sleep($0) })
    for _ in 0..<480 { try await bulk.take() }
    let gap = 1 / CloudSyncServicePace.bulkReadsPerSecond
    XCTAssertEqual(clock.slept().count, 479, "the first read goes at once")
    XCTAssertTrue(clock.slept().allSatisfy { abs($0 - gap) < 0.0001 }, "every wait is one even gap")
    XCTAssertEqual(clock.now().timeIntervalSince1970 - 1000, 479 * gap, accuracy: 0.01, "480 reads take one minute: never a burst")
    // A 429: the pace halves for a minute, then returns.
    await bulk.slowDown()
    let slowed = try await bulk.take()
    let next = try await bulk.take()
    XCTAssertEqual(next, gap * 2, accuracy: 0.0001)
    _ = slowed
    clock.sleep(61)
    let after = try await bulk.take()
    XCTAssertEqual(after, 0)
    let again = try await bulk.take()
    XCTAssertEqual(again, gap, accuracy: 0.0001)
  }

  /// 14 Nov (owner: "remove this counter thing completely"): no daily allowance on this Mac. A day's block stored by
  /// an earlier build is gone at launch, and an old service's `budget_paused` is a short "try again later".
  private func allowanceEngine(root: URL, server: CloudSyncFixtureServer, store: CloudSyncStore? = nil) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncBudget) {
    let store = try store ?? makeStore(root)
    let budget = CloudSyncBudget(store: store)
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: budget,
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in })
    try await engine.register(adapter: try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain")))
    return (engine, store, budget)
  }
  func testOldDailyBlockIsDroppedAtLaunchAndBudgetPausedIsAShortWait() async throws {
    let lines = Lines()
    CloudSyncDiagnostics.shared.setSink { lines.add($0) }
    defer { CloudSyncDiagnostics.shared.setSink(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let root = try scratch()
    let (engine, store, budget) = try await allowanceEngine(root: root, server: server)
    _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
    // The exact block an earlier build stored: "used up for today", until the next UTC day, with its counters.
    var old = CloudSyncBudgetSnapshot(day: CloudSyncBytes.now() / 86_400_000)
    old.blocked = "budget"; old.retryAt = (old.day + 1) * 86_400_000; old.http = 6000; old.frames = 300; old.packs = 4000; old.failures = 1
    try store.set("budget", old)
    let cleared = try await budget.status()
    XCTAssertNil(cleared.blocked, "the old day's block is dropped at the first read (launch)")
    XCTAssertEqual(cleared.retryAt, 0)
    XCTAssertEqual(cleared.http + cleared.frames + cleared.packs, 0)
    let kept: CloudSyncBudgetSnapshot? = try store.value("budget")
    XCTAssertNil(kept?.blocked, "and stays dropped on disk")
    _ = try await engine.enqueue((0..<2).map { try! incompressible("after-old-block-\($0)") })
    await engine.startEvents()
    let sent = try await waitUntil(10) { try store.queuedCount() == 0 }
    XCTAssertTrue(sent, "sync went on at once, no probe, no day change")
    await engine.stop()
    XCTAssertFalse(lines.snapshot().contains { $0.localizedCaseInsensitiveContains("allowance") }, "\(lines.snapshot())")

    // An old service's `budget_paused` asking for a day: an ordinary short wait, never more than 5 minutes.
    // These rules are checked on a store of their own: `stop()` cancels the scheduler's step but cannot interrupt one
    // already running, and that step (its pull after the send) ends with `budget.succeeded()`, which set failures back
    // to 0 between the two reads below when the machine was busy ("0" is not equal to "1").
    let alone = CloudSyncBudget(store: try makeStore(scratch()))
    let paused = CloudFailure.remote(.init(code: "budget_paused", message: "Fixture allowance.", retryable: true,
      requestId: UUID().uuidString.lowercased()))
    try await alone.failed(paused, httpStatus: 429, retryAfter: CloudSyncBytes.now() + 86_400_000)
    let wait = try await alone.status()
    XCTAssertEqual(wait.failures, 1)
    XCTAssertEqual(wait.blocked, "rate")
    XCTAssertLessThanOrEqual(wait.retryAt - CloudSyncBytes.now(), 300_000)
    // This Mac's own local "wait" is not an answer and stores nothing new.
    try await alone.failed(CloudFailure.budgetPaused)
    let same = try await alone.status()
    XCTAssertEqual(same.failures, wait.failures)
    XCTAssertEqual(same, wait, "nothing new is stored")
  }
}
