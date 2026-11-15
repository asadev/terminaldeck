import Foundation
import XCTest
@testable import TerminalDeckNativeCore

/// Fixture-only: a project list as an owner store keeps it. Record id → row, saved to one file in the test folder.
actor CloudBrainRecordProjectStoreFixture: CloudBrainRecordOwner {
  private let file: URL
  private var rows: [String: NativeRPCValue] = [:]
  private(set) var seenFromCloud: [NativeRPCValue] = []
  private(set) var refreshed: [[String]] = []
  private var refusing: Set<String> = []
  private var brokenWrites = 0

  init(file: URL) throws {
    self.file = file
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  private func save() throws {
    let value = NativeRPCValue.object(rows.keys.sorted().map { NativeRPCValue.Field($0, rows[$0] ?? .null) })
    try value.encodedJSON().write(to: file, options: .atomic)
  }
  /// The person's own save on this Mac.
  func put(_ id: String, name: String, colour: String = "blue", folders: [String] = []) throws {
    rows[id] = .object([.init("id", .string(id)), .init("name", .string(name)), .init("icon", .string("folder")), .init("colour", .string(colour)),
      .init("logo", .string("")), .init("folders", .array(folders.map(NativeRPCValue.string)))])
    try save()
  }
  func row(_ id: String) -> NativeRPCValue? { rows[id] }
  func refuse(_ entities: Set<String>) { refusing = entities }
  func breakNextWrite() { brokenWrites = 1 }

  func cloudRecords() async throws -> [String: NativeRPCValue] {
    var result: [String: NativeRPCValue] = [:]
    for (id, row) in rows { result["project:" + id] = row }
    return result
  }
  func cloudPlan(entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan {
    if refusing.contains(entity) { throw CloudRecordRefusal(reason: "Fixture store cannot take this project.") }
    let id = String(entity.dropFirst("project:".count))
    guard let cloud else {
      return .init(store: rows[id].map { CloudBrainRecordAdapter.travelling($0, table: CloudBrainMergeTables.project) })
    }
    seenFromCloud.append(cloud)
    var next: [NativeRPCValue.Field] = []
    for name in ["id", "name", "icon", "colour", "logo"] where cloud.has(name) { next.append(.init(name, cloud[name])) }
    return .init(store: .object(next))
  }
  func cloudWrite(entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws {
    if brokenWrites > 0 { brokenWrites -= 1; throw CloudFailure.unavailable }
    let id = String(entity.dropFirst("project:".count))
    // Folders are this Mac's own: an import never touches them.
    let folders = rows[id]?["folders"] ?? .array([])
    rows[id] = value.setting("folders", folders.isNullish ? .array([]) : folders)
    try save()
  }
  func cloudImported(_ entities: [String]) async { refreshed.append(entities) }
}

/// Lane A2, lean item 1: the thin end-to-end. One record type (the project record) captured from a store, sent
/// through the REAL sync engine over the sync lane's fixture transport, applied on a second store, with the sync
/// lane's trusted-device fixture. Files only under ~/Deck Dev/notes/cloud-test-20261112/a2.
final class CloudBrainRecordSyncTests: XCTestCase, @unchecked Sendable {
  /// One clock for both Macs, as the service's clock is: every reading is one second later than the last.
  final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_760_000_000_000
    func read() -> Int64 { lock.withLock { value += 1_000; return value } }
  }
  struct Mac: Sendable {
    let identity: CloudSyncTestIdentity
    let owner: CloudBrainRecordProjectStoreFixture
    let store: CloudBrainAgentsStore
    let adapter: CloudBrainRecordAdapter
    let trust: CloudSyncFixtureTrust
    let syncRoot: URL
    let engine: CloudSyncEngine
    let activation: CloudBrainRecordActivation
  }
  private let subject = "11111111-1111-4111-8111-111111111111"
  private let subjectHash = String(repeating: "ab", count: 32)
  private let deviceA = "33333333-3333-4333-8333-333333333333"
  private let deviceB = "44444444-4444-4444-8444-444444444444"
  private let clock = Clock()
  private var root: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    root = CloudBrainAgentsMergeTests.fixtureFolder("lean")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws {
    if let root { try? FileManager.default.removeItem(at: root) }
    try super.tearDownWithError()
  }

  private func makeEngine(_ syncRoot: URL, _ identity: CloudSyncTestIdentity, server: CloudSyncFixtureServer, trust: CloudSyncFixtureTrust) throws -> CloudSyncEngine {
    let syncStore = try CloudSyncStore(root: syncRoot, subject: .init(issuer: "https://identity.test", sub: subject))
    let key = Data(0..<32)
    let content = try CloudSyncContent(subject: subject, epoch: 1, keyProvider: { _ in key })
    return try CloudSyncEngine(store: syncStore, transport: server, objects: server, content: content, budget: CloudSyncBudget(store: syncStore),
      subject: subject, deviceId: identity.deviceId, epoch: 1, brainDomains: ["projects"],
      signer: { payload in try identity.sign(payload) }, trust: trust)
  }
  /// One Mac: its own project store, its own bookkeeping, its own trusted list, the real engine.
  private func mac(_ name: String, _ identity: CloudSyncTestIdentity, server: CloudSyncFixtureServer, trusting: [CloudSyncTestIdentity]) throws -> Mac {
    let home = root.appendingPathComponent(name)
    let owner = try CloudBrainRecordProjectStoreFixture(file: home.appendingPathComponent("projects.json"))
    let account = try CloudBrainAgentsAccount(subjectHash: subjectHash, deviceID: identity.deviceId)
    let cloud = home.appendingPathComponent("cloud")
    let trust = try CloudSyncFixtureTrust(trusting)
    let syncRoot = home.appendingPathComponent("sync")
    let engine = try makeEngine(syncRoot, identity, server: server, trust: trust)
    let clock = self.clock
    let store = try CloudBrainAgentsStore(directory: cloud.appendingPathComponent(subjectHash).appendingPathComponent("a2"), account: account,
      clock: CloudBrainMergeClock(read: { clock.read() }))
    let origins = try CloudBrainRecordOrigins(cloudFolder: cloud, account: subjectHash)
    let adapter = try CloudBrainRecordAdapter(domain: "projects", inventoryRow: "I11", sourceId: "project-registry",
      kinds: [.init(prefix: "project:", table: CloudBrainMergeTables.project, listedValues: ["name"])], store: store, account: account,
      owner: owner, origins: origins)
    let activation = try CloudBrainRecordActivation(adapters: [adapter], store: store, every: nil)
    return Mac(identity: identity, owner: owner, store: store, adapter: adapter, trust: trust, syncRoot: syncRoot, engine: engine, activation: activation)
  }

  /// Captured on A, sent as a signed pack, applied on B; then an edit each way. No folder path is in anything that
  /// travels, B's and A's folders stay their own, and an import is never taken for an edit.
  func testAProjectCapturedOnOneMacArrivesOnASecondMacThroughTheRealEngine() async throws {
    let a = CloudSyncTestIdentity(deviceId: deviceA, seed: 7), b = CloudSyncTestIdentity(deviceId: deviceB, seed: 8)
    let server = try CloudSyncFixtureServer(root: root.appendingPathComponent("server"), device: a.deviceId)
    let macA = try mac("a", a, server: server, trusting: [a, b]), macB = try mac("b", b, server: server, trusting: [a, b])
    try await macA.owner.put("deck", name: "Deck", colour: "blue", folders: ["/Users/a/Deck"])

    try await macA.activation.start(outbox: macA.engine)        // A's setup: its project goes up as one signed pack
    await server.switchDevice(b.deviceId)
    try await macB.activation.start(outbox: macB.engine)        // B's setup reads the feed before it cuts anything
    let arrived = await macB.owner.row("deck")
    XCTAssertEqual(arrived?["name"].string, "Deck")
    XCTAssertEqual(arrived?["colour"].string, "blue")
    XCTAssertEqual(arrived?["folders"].elements?.count, 0, "A folder is chosen on each device; none arrives")
    let seen = await macB.owner.seenFromCloud
    XCTAssertFalse(seen.isEmpty)
    XCTAssertTrue(seen.allSatisfy { !$0.has("folders") && !$0.compact.contains("Users") }, "No folder path travels")
    let refreshedB = await macB.owner.refreshed
    XCTAssertEqual(refreshedB, [["project:deck"]], "Screens refresh once, with a display-only signal")
    let runningB = await macB.activation.isRunning
    XCTAssertTrue(runningB)

    // An edit on A arrives on B.
    await server.switchDevice(a.deviceId)
    try await macA.owner.put("deck", name: "Deck Two", colour: "blue", folders: ["/Users/a/Deck"])
    let handedA = try await macA.activation.sync(outbox: macA.engine)
    XCTAssertEqual(handedA, 1)
    _ = try await macA.engine.flush()
    await server.switchDevice(b.deviceId)
    _ = try await macB.engine.pull()
    let renamed = await macB.owner.row("deck")
    XCTAssertEqual(renamed?["name"].string, "Deck Two")
    let listingB = try await macB.adapter.listing()
    XCTAssertTrue(listingB.changes.contains { $0.record == "project:deck" && $0.field == "name" && $0.from == "Deck" && $0.to == "Deck Two" && $0.device == a.deviceId },
      "The rename is listed with the verified signer: \(listingB.changes)")

    // B chooses its own folder and changes the colour: the colour arrives on A, A's folder stays A's.
    try await macB.owner.put("deck", name: "Deck Two", colour: "green", folders: ["/Users/b/work/Deck"])
    let handedB = try await macB.activation.sync(outbox: macB.engine)
    XCTAssertEqual(handedB, 1)
    _ = try await macB.engine.flush()
    await server.switchDevice(a.deviceId)
    _ = try await macA.engine.pull()
    let onA = await macA.owner.row("deck")
    XCTAssertEqual(onA?["colour"].string, "green")
    XCTAssertEqual(onA?["folders"].elements?.compactMap(\.string), ["/Users/a/Deck"], "Adding a folder on one Mac never changes another Mac's folders")
    let echoA = try await macA.activation.sync(outbox: macA.engine)
    XCTAssertEqual(echoA, 0, "An import is not an edit: nothing goes back")
    let keptA = try await macA.adapter.listing()
    XCTAssertEqual(keptA.keptCount, 0)
  }

  /// Error kind 1, "cannot apply this record": the sync core parks that one record, the rest of the pack and
  /// everything after it arrive, and the parked record applies once this Mac can take it.
  func testAProjectThisMacCannotApplyIsParkedAndTheFeedMovesOn() async throws {
    let a = CloudSyncTestIdentity(deviceId: deviceA, seed: 7), b = CloudSyncTestIdentity(deviceId: deviceB, seed: 8)
    let server = try CloudSyncFixtureServer(root: root.appendingPathComponent("server"), device: a.deviceId)
    let macA = try mac("a", a, server: server, trusting: [a, b]), macB = try mac("b", b, server: server, trusting: [a, b])
    try await macA.owner.put("bad", name: "Bad")
    try await macA.owner.put("good", name: "Good")
    await macB.owner.refuse(["project:bad"])

    try await macA.activation.start(outbox: macA.engine)
    await server.switchDevice(b.deviceId)
    try await macB.activation.start(outbox: macB.engine)
    let bad = await macB.owner.row("bad"), good = await macB.owner.row("good")
    XCTAssertNil(bad)
    XCTAssertEqual(good?["name"].string, "Good", "The record beside the refused one applies")
    let parked = try await macB.engine.coverage(sourceId: "project-registry")
    XCTAssertTrue(parked.blockedReasons.contains { $0.contains("could not be applied on this Mac") && $0.contains("Fixture store cannot take this project.") },
      "The parked record is reported with its reason: \(parked.blockedReasons)")

    // The feed is not stalled: a later project arrives while the first still waits.
    await server.switchDevice(a.deviceId)
    try await macA.owner.put("later", name: "Later")
    _ = try await macA.activation.sync(outbox: macA.engine)
    _ = try await macA.engine.flush()
    await server.switchDevice(b.deviceId)
    _ = try await macB.engine.pull()
    let later = await macB.owner.row("later"), stillBad = await macB.owner.row("bad")
    XCTAssertEqual(later?["name"].string, "Later")
    XCTAssertNil(stillBad)

    // This Mac can take it now: the parked record applies.
    await macB.owner.refuse([])
    try await macB.engine.retryParked(domains: ["projects"])
    let healed = await macB.owner.row("bad")
    XCTAssertEqual(healed?["name"].string, "Bad")
    let after = try await macB.engine.coverage(sourceId: "project-registry")
    XCTAssertFalse(after.blockedReasons.contains { $0.contains("could not be applied on this Mac") }, "\(after.blockedReasons)")
  }

  /// Error kind 2, "broken or shutting down": nothing is parked, the pack waits whole and applies on the next try
  /// (here after a restart of the engine on the same stores).
  func testABrokenStoreMakesThePackWaitWholeAndItAppliesAfterARestart() async throws {
    let a = CloudSyncTestIdentity(deviceId: deviceA, seed: 7), b = CloudSyncTestIdentity(deviceId: deviceB, seed: 8)
    let server = try CloudSyncFixtureServer(root: root.appendingPathComponent("server"), device: b.deviceId)
    let macA = try mac("a", a, server: server, trusting: [a, b]), macB = try mac("b", b, server: server, trusting: [a, b])
    try await macB.activation.start(outbox: macB.engine)        // B is set up first, with nothing
    await server.switchDevice(a.deviceId)
    try await macA.owner.put("deck", name: "Deck")
    try await macA.activation.start(outbox: macA.engine)

    await server.switchDevice(b.deviceId)
    await macB.owner.breakNextWrite()
    do {
      _ = try await macB.engine.pull()
      XCTFail("A broken store must stop the pack, not swallow it")
    } catch {}
    let missing = await macB.owner.row("deck")
    XCTAssertNil(missing)
    let coverage = try await macB.engine.coverage(sourceId: "project-registry")
    XCTAssertFalse(coverage.blockedReasons.contains { $0.contains("could not be applied on this Mac") }, "Broken is not a parked record: \(coverage.blockedReasons)")

    // A restart: a new engine on the same sync store, the same adapter and bookkeeping.
    let restarted = try makeEngine(macB.syncRoot, b, server: server, trust: macB.trust)
    let again = try CloudBrainRecordActivation(adapters: [macB.adapter], store: macB.store, every: nil)
    try await again.start(outbox: restarted)
    _ = try await restarted.pull()
    let arrived = await macB.owner.row("deck")
    XCTAssertEqual(arrived?["name"].string, "Deck")
  }

  /// The sync core hands the adapter only packs of devices trusted on this Mac: a project from a device this Mac does
  /// not trust waits untouched, and arrives (as a late arrival) after the trust click.
  func testAProjectFromADeviceThisMacDoesNotTrustWaitsUntilItIsTrusted() async throws {
    let a = CloudSyncTestIdentity(deviceId: deviceA, seed: 7), b = CloudSyncTestIdentity(deviceId: deviceB, seed: 8)
    let server = try CloudSyncFixtureServer(root: root.appendingPathComponent("server"), device: a.deviceId)
    let macA = try mac("a", a, server: server, trusting: [a]), macB = try mac("b", b, server: server, trusting: [b])
    try await macA.owner.put("deck", name: "Deck")
    try await macA.activation.start(outbox: macA.engine)
    await server.switchDevice(b.deviceId)
    try await macB.activation.start(outbox: macB.engine)
    let before = await macB.owner.row("deck")
    XCTAssertNil(before, "Nothing of an untrusted device reaches the adapter")
    let waiting = try await macB.engine.heldDevices()
    XCTAssertEqual(waiting.map(\.deviceId), [a.deviceId])

    try await macB.trust.trust(a)                               // the person's click in B's window
    let keyA = try a.jwk()
    _ = try await macB.engine.trustDevice(deviceId: a.deviceId, signKey: keyA)
    let after = await macB.owner.row("deck")
    XCTAssertEqual(after?["name"].string, "Deck")
  }

  /// Sign-out: final. Every adapter call answers "shutting down", nothing more is captured, nothing is deleted.
  func testAfterStopNothingIsCapturedImportedOrDeleted() async throws {
    let a = CloudSyncTestIdentity(deviceId: deviceA, seed: 7)
    let server = try CloudSyncFixtureServer(root: root.appendingPathComponent("server"), device: a.deviceId)
    let macA = try mac("a", a, server: server, trusting: [a])
    try await macA.owner.put("deck", name: "Deck")
    try await macA.activation.start(outbox: macA.engine)
    await macA.activation.stop()

    try await macA.owner.put("deck", name: "Changed after sign-out")
    let handed = try await macA.activation.sync(outbox: macA.engine)
    XCTAssertEqual(handed, 0)
    do { _ = try await macA.adapter.captureLocal(); XCTFail("A capture after sign-out") } catch { XCTAssertEqual(error as? CloudFailure, .gateClosed) }
    do { _ = try await macA.adapter.validateIncoming([], files: []); XCTFail("An import after sign-out") } catch { XCTAssertEqual(error as? CloudFailure, .gateClosed) }
    let unsent = try macA.store.ownUnhanded(domain: "projects", limit: 16)
    XCTAssertTrue(unsent.isEmpty, "No version was made after sign-out")
    let kept = await macA.owner.row("deck")
    XCTAssertEqual(kept?["name"].string, "Changed after sign-out", "Sign-out deletes nothing on this Mac")
    XCTAssertTrue(FileManager.default.fileExists(atPath: macA.store.file.path))
  }
}
