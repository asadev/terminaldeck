import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Mac 0.23.6 (Asad, 23 Nov: "why its not syncing properly from this mac"): his other data goes up before the 201,528
/// project-folder pieces 0.23.3 queued, a send step ends after a slice so the fetch runs, and the progress read no
/// longer walks the whole queue once per source (notes/release-20261121/MAC-0236-SYNC.md).
final class CloudSync0236Tests: XCTestCase, @unchecked Sendable {
  let device = "33333333-3333-4333-8333-333333333333"
  let subject = "11111111-1111-4111-8111-111111111111"
  let pieces = "project-folders"
  var roots: [URL] = []
  override func tearDown() {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
    super.tearDown()
  }
  func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-0236-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
  func op(domain: String, size: Int = 30_000) throws -> CloudOperation {
    let id = UUID().uuidString.lowercased()
    var generator = SystemRandomNumberGenerator()
    let data = Data((0..<(size * 3 / 4)).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    let payload = CloudValue(.object([.init("data", .string(data))]))
    return .init(v: 1, opId: id, originDevice: device, domain: domain, entityId: id, revision: id, parents: [], kind: .put, projectId: nil,
      source: .init(sourceId: "files/I26/projects", recordId: id), createdAt: 1000, payload: payload,
      payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
  }
  func engine(root: URL, server: CloudSyncFixtureServer) async throws -> (CloudSyncEngine, CloudSyncStore) {
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: subject))
    try store.set("baseline", "feed")
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let key = Data(0..<32)
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: try CloudSyncContent(subject: subject, epoch: 1, keyProvider: { _ in key }),
      budget: CloudSyncBudget(store: store), subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory", "notes", pieces],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { descriptor, _ in
        guard descriptor.signature == CloudSyncBytes.base64(Data(repeating: 7, count: 64)) else { throw CloudFailure.checksumMismatch }
      }, staging: CloudSyncStaging(freeBytes: { _ in 100 << 30 }))
    try await engine.register(adapter: adapter)
    return (engine, store)
  }
  func count(_ store: CloudSyncStore, _ sql: String) throws -> Int {
    Int(String(decoding: try store.rows(sql)[0][0], as: UTF8.self)) ?? -1
  }

  /// His memory note queued AFTER 40 project-folder pieces goes up in the first pack; the pieces follow, read 16 at a
  /// time while they are large and 256 at a time when they are small.
  func testHisOtherDataGoesUpBeforeProjectFolderPieces() async throws {
    let server = try CloudSyncFixtureServer(root: try scratch(), device: device)
    let (engine, store) = try await engine(root: try scratch(), server: server)
    for _ in 0..<40 { _ = try await engine.enqueue([try op(domain: pieces)]) }
    let note = try op(domain: "memory", size: 2_000)
    _ = try await engine.enqueue([note])
    let kinds: Set<String> = ["memory", "notes", pieces]
    let next = try await engine.nextPending(kinds)
    XCTAssertEqual(next.map(\.opId), [note.opId], "the note first, although 40 pieces were queued before it")
    _ = try await engine.flush()
    let packs = try store.rows("SELECT bytes FROM segments ORDER BY rowid").map { try JSONDecoder().decode(CloudSegment.self, from: $0[0]).descriptor.domains }
    XCTAssertEqual(packs.first, ["memory"], "the first pack sent is his note: \(packs)")
    XCTAssertEqual(try count(store, "SELECT count(*) FROM outbox WHERE state='queued'"), 0)

    // Large pieces only (~41 KB each on the Mac mini; a sealed pack holds about 5): 16 read for a pack, not 256.
    for _ in 0..<20 { _ = try await engine.enqueue([try op(domain: pieces, size: 40_000)]) }
    let large = try await engine.nextPending(kinds)
    XCTAssertEqual(large.count, CloudSyncEngine.sentLastFirstRead)
    // Small pieces (small files): read on, so a pack is filled as before.
    _ = try await engine.flush()
    for _ in 0..<20 { _ = try await engine.enqueue([try op(domain: pieces, size: 1_000)]) }
    let small = try await engine.nextPending(kinds)
    XCTAssertEqual(small.count, 20)
  }

  /// A send step ends after its slice while more waits, and asks for itself again (after a fetch); nothing is lost.
  func testASendStepEndsAfterItsSliceAndTheNextGoesOn() async throws {
    let server = try CloudSyncFixtureServer(root: try scratch(), device: device)
    let (engine, store) = try await engine(root: try scratch(), server: server)
    for _ in 0..<12 { _ = try await engine.enqueue([try op(domain: pieces)]) }
    await engine.setSendSlice(0)
    _ = try await engine.flush()
    let afterOne = try count(store, "SELECT count(*) FROM outbox WHERE state='acknowledged'")
    XCTAssertGreaterThan(afterOne, 0)
    XCTAssertLessThan(afterOne, 12, "one pack, then the step ends")
    var steps = 1
    while try count(store, "SELECT count(*) FROM outbox WHERE state='queued'") > 0, steps < 20 { _ = try await engine.flush(); steps += 1 }
    XCTAssertEqual(try count(store, "SELECT count(*) FROM outbox WHERE state='acknowledged'"), 12)
    XCTAssertGreaterThan(steps, 1)
  }

  /// The progress read's held-for-files check starts from the file links (none on the Mac mini), not from every waiting
  /// row's record; the same answer otherwise.
  func testTheHeldForFilesCheckStartsFromTheFileLinks() throws {
    let store = try CloudSyncStore(root: try scratch(), subject: .init(issuer: "https://identity.test", sub: subject))
    for _ in 0..<3 { _ = try store.enqueue([try op(domain: pieces, size: 1_000)]) }
    let plan = try store.rows("EXPLAIN QUERY PLAN " + CloudSyncEngine.heldForFilesQuery).map { String(decoding: $0.last ?? Data(), as: UTF8.self) }
    XCTAssertTrue(plan.first?.hasPrefix("SCAN f") == true, plan.joined(separator: " | "))
    XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN outbox") || $0.hasPrefix("SCAN r") }, plan.joined(separator: " | "))
    XCTAssertTrue(try store.rows(CloudSyncEngine.heldForFilesQuery).isEmpty)
  }
}
