import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Mac 0.23.4 hotfix: project folders filled `sync.sqlite` on the Mac mini (faults 2 and 4 of
/// notes/release-20261120/DISK-CLOUD-FOLDER.md).
final class CloudSyncGiveBack0234Tests: XCTestCase, @unchecked Sendable {
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-0234-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
  /// A piece-like record: `size` characters of data (incompressible enough to fill pages).
  func op(domain: String, size: Int = 30_000) throws -> CloudOperation {
    let id = UUID().uuidString.lowercased()
    var generator = SystemRandomNumberGenerator()
    let data = Data((0..<(size * 3 / 4)).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    let payload = CloudValue(.object([.init("data", .string(data))]))
    return .init(v: 1, opId: id, originDevice: device, domain: domain, entityId: id, revision: id, parents: [], kind: .put, projectId: nil,
      source: .init(sourceId: "files/I26/projects", recordId: id), createdAt: 1000, payload: payload,
      payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
  }
  func makeStore(_ root: URL) throws -> CloudSyncStore { try .init(root: root, subject: .init(issuer: "https://identity.test", sub: subject)) }
  func engine(root: URL, server: CloudSyncFixtureServer, freeDisk: Int64 = 100 << 30) async throws -> (CloudSyncEngine, CloudSyncStore) {
    let store = try makeStore(root)
    try store.set("baseline", "feed")
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let key = Data(0..<32)
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: try CloudSyncContent(subject: subject, epoch: 1, keyProvider: { _ in key }),
      budget: CloudSyncBudget(store: store), subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory", "notes", pieces],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { descriptor, _ in
        guard descriptor.signature == CloudSyncBytes.base64(Data(repeating: 7, count: 64)) else { throw CloudFailure.checksumMismatch }
      }, staging: CloudSyncStaging(freeBytes: { _ in freeDisk }))
    try await engine.register(adapter: adapter)
    return (engine, store)
  }
  func count(_ store: CloudSyncStore, _ sql: String, _ args: [String] = []) throws -> Int {
    Int(String(decoding: try store.rows(sql, args.map { Data($0.utf8) })[0][0], as: UTF8.self)) ?? -1
  }

  /// Fault 2: a handover's receipt no longer sums the whole queue; fault 1: the queue is measured by kind, bounded.
  func testHandoverCountsOnlyItsOwnBytesAndTheQueueIsMeasuredByKind() throws {
    let store = try makeStore(try scratch())
    let first = try op(domain: pieces), second = try op(domain: pieces), memory = try op(domain: "memory", size: 2_000)
    _ = try store.enqueue([first])
    let receipt = try store.enqueue([second])
    let secondBytes = Int64(try CloudSyncCanonical.encode(second).count)
    XCTAssertEqual(receipt.bytes, secondBytes, "only this call's record, not the whole queue")
    XCTAssertEqual(receipt.queued, 2)
    _ = try store.enqueue([memory])
    let both = Int64(try CloudSyncCanonical.encode(first).count) + secondBytes
    XCTAssertEqual(try store.queuedBytes(domain: pieces, stopAfter: .max), both)
    XCTAssertEqual(try store.queuedBytes(domain: "memory", stopAfter: .max), Int64(try CloudSyncCanonical.encode(memory).count))
    XCTAssertEqual(try store.queuedBytes(domain: nil, stopAfter: .max), both + Int64(try CloudSyncCanonical.encode(memory).count))
    // The waiting rows have their own index, used by the measure.
    let plan = try store.rows("EXPLAIN QUERY PLAN SELECT o.rowid,length(r.bytes) FROM outbox o JOIN records r ON r.opId=o.opId WHERE o.state='queued' AND o.domain=? AND o.rowid>0 ORDER BY o.rowid LIMIT 512", [Data(pieces.utf8)])
    XCTAssertTrue(plan.contains { String(decoding: $0.last ?? Data(), as: UTF8.self).contains("outbox_queued_domain") })
  }

  /// Fault 4a: acknowledged project-folder pieces and their sealed pack leave their content at once (other kinds keep
  /// theirs until read back), and the feed's read-back of such an own pack settles without a download.
  func testAcknowledgedPiecesReleaseAtOnceAndTheReadBackDownloadsNothing() async throws {
    let serverRoot = try scratch(), clientRoot = try scratch()
    let server = try CloudSyncFixtureServer(root: serverRoot, device: device)
    let (engine, store) = try await engine(root: clientRoot, server: server)
    // `notes` has no adapter on this Mac, so its own pack is never applied here and the older rule (release after
    // the read-back applied it) cannot release it: what it keeps shows what an acknowledgement alone releases.
    let piece = try op(domain: pieces), memory = try op(domain: "notes", size: 2_000)
    _ = try await engine.enqueue([piece])
    _ = try await engine.enqueue([memory])
    _ = try await engine.flush()
    XCTAssertEqual(try count(store, "SELECT count(*) FROM outbox WHERE state='acknowledged'"), 2)
    let pieceBytes = try XCTUnwrap(store.rows("SELECT bytes FROM records WHERE opId=?", [Data(piece.opId.utf8)]).first?[0])
    XCTAssertEqual(pieceBytes, try CloudSyncCanonical.encode(CloudSyncStore.skeleton(piece)), "the piece keeps only its skeleton")
    let memoryBytes = try XCTUnwrap(store.rows("SELECT bytes FROM records WHERE opId=?", [Data(memory.opId.utf8)]).first?[0])
    XCTAssertEqual(memoryBytes, try CloudSyncCanonical.encode(memory), "other kinds are unchanged")
    let sealed = try store.rows("SELECT bytes FROM segments").map { try JSONDecoder().decode(CloudSegment.self, from: $0[0]) }
    XCTAssertEqual(sealed.filter { $0.descriptor.domains == [pieces] }.map(\.ciphertext), [""], "the piece's pack keeps no sealed copy")
    XCTAssertTrue(sealed.filter { $0.descriptor.domains == ["notes"] }.allSatisfy { !$0.ciphertext.isEmpty })
    _ = try await engine.pull()
    let pieceSegment = try XCTUnwrap(sealed.first { $0.descriptor.domains == [pieces] }).descriptor.segmentId
    XCTAssertEqual(try count(store, "SELECT count(*) FROM applied WHERE segmentId=?", [pieceSegment]), 1, "the own pack is settled")
    XCTAssertEqual(try count(store, "SELECT count(*) FROM verified_ops WHERE opId=?", [piece.opId]), 1)
    XCTAssertEqual(try count(store, "SELECT count(*) FROM kind_waiting_packs"), 1, "only the other kind's pack waits for its kind")
    // Each pack was read back once before its acknowledgement; the feed brought neither down again (the other kind's
    // pack waits for its kind without a download, the piece's pack settled without one).
    let downloads = await server.segmentDownloads
    XCTAssertEqual(downloads, sealed.count)
    XCTAssertEqual(try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(piece.opId.utf8)]).first?[0], pieceBytes, "not filled again")
  }

  /// Fault 4a (an earlier build's backlog) and 4c: once, acknowledged pieces left full are released, and at a quiet
  /// moment the file gives the empty pages back to the disk (not when the disk lacks twice the live data plus 5 GB).
  func testBacklogReleasesOnceAndTheFileShrinksOnlyWithRoomOnDisk() async throws {
    let serverRoot = try scratch(), clientRoot = try scratch()
    let server = try CloudSyncFixtureServer(root: serverRoot, device: device)
    var (engine, store) = try await engine(root: clientRoot, server: server, freeDisk: 1 << 30)
    for _ in 0..<60 { _ = try await engine.enqueue([try op(domain: pieces, size: 40_000)]) }
    // An earlier build: acknowledged, content kept (no release at acknowledgement then).
    try store.execute("UPDATE outbox SET state='acknowledged'")
    let before = try store.fileSpace()
    XCTAssertEqual(try store.releaseAcknowledgedBacklog(), 60)
    XCTAssertEqual(try count(store, "SELECT count(*) FROM record_stubs"), 60)
    XCTAssertEqual(try store.releaseAcknowledgedBacklog(), 0, "once")
    let freed = try store.fileSpace()
    XCTAssertGreaterThan(freed.free, before.free + 500_000)
    await engine.setCompactMinimumFreeBytes(100_000)
    let refused = await engine.compactIfDue()
    XCTAssertFalse(refused, "1 GB free is less than twice the live data plus 5 GB")
    XCTAssertEqual(try store.fileSpace().file, freed.file)
    (engine, store) = try await self.engine(root: clientRoot, server: server)
    await engine.setCompactMinimumFreeBytes(100_000)
    let compacted = await engine.compactIfDue()
    XCTAssertTrue(compacted)
    let after = try store.fileSpace()
    XCTAssertLessThan(after.file, freed.file / 2)
    XCTAssertLessThan(after.free, 100_000)
    XCTAssertEqual(try count(store, "SELECT count(*) FROM records"), 60, "nothing lost; the store's own connection still works")
    let again = await engine.compactIfDue()
    XCTAssertFalse(again, "not again within 7 days")
  }
}
