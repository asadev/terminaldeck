import Foundation
import XCTest
@testable import TerminalDeckNativeCore

/// Ledger-level proofs of design D1–D3. Fixture data only; files only under ~/Deck Dev/notes/cloud-test-20261112/a2.
final class CloudBrainAgentsLedgerTests: XCTestCase, @unchecked Sendable {
  private let deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  private let subjectX = String(repeating: "1", count: 64), subjectY = String(repeating: "2", count: 64)

  /// A fixture owner: a dictionary store, the shared archive helper and an optional shape.
  private final class Owner {
    var store: [String: NativeRPCValue] = [:]
    var archive: CloudBrainAgentsArchive
    var shape: CloudBrainAgentsShape = .identity
    init(_ account: CloudBrainAgentsAccount, directory: URL? = nil) throws {
      archive = CloudBrainAgentsArchive(ownerDirectory: directory, namespace: "fixture", domains: ["fixture"])
      try archive.attach(account)
    }
    func records() -> [CloudBrainAgentsRecord] {
      store.keys.sorted().map { CloudBrainAgentsRecord(domain: "fixture", id: String($0.dropFirst("fixture:".count)), value: store[$0]!) }
    }
    @discardableResult func save(_ id: String, _ value: NativeRPCValue?) throws -> [CloudOperation] {
      store["fixture:" + id] = value
      return try archive.capture(records(), sourceID: "fixture", complete: true, shape: shape).operations
    }
    func receive(_ incoming: [CloudOperation], refuse: Set<String> = []) throws -> [CloudItemResult] {
      let current = store
      return try archive.importing(incoming, current: { current[$0] }, shape: shape,
        validate: { items in Dictionary(items.filter { refuse.contains($0.entityID) }.map { ($0.key, "fixture refusal") }, uniquingKeysWith: { a, _ in a }) },
        write: { items in
          var written: [String: NativeRPCValue?] = [:]
          for item in items { store[item.key] = item.image; written[item.key] = item.image }
          return written
        })
    }
  }
  private func account(_ device: String, _ subject: String? = nil) throws -> CloudBrainAgentsAccount { try .init(subjectHash: subject ?? subjectX, deviceID: device) }
  private func directory() throws -> URL {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/a2/" + UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func row(_ title: String, _ extra: [NativeRPCValue.Field] = []) -> NativeRPCValue { .object([.init("title", .string(title))] + extra) }
  private func viaCloud(_ ops: [CloudOperation]) throws -> [CloudOperation] { try CloudSyncPack.decode(try CloudSyncPack.encode(ops)) }

  /// Finding 1: B already holds A's record; A's later edit becomes current on B and is reported applied.
  func testLaterEditFromAnotherMacIsShownWhereTheRecordIsUnchanged() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    let first = try a.save("t", row("First"))
    XCTAssertEqual(try b.receive(viaCloud(first)).map(\.status), [.applied])
    let second = try a.save("t", row("Edited on A"))
    XCTAssertEqual(second.first?.parents, [first[0].opId])
    XCTAssertEqual(try b.receive(viaCloud(second)).map(\.status), [.applied])
    XCTAssertEqual(b.store["fixture:t"]?["title"].string, "Edited on A")
    XCTAssertTrue(try b.save("t", row("Edited on A")).isEmpty, "Showing the edit is not a new edit on B")
  }

  /// S04 + finding 1: a record changed on both Macs keeps both versions and says so; nothing is overwritten.
  func testLocalEditMakesSiblingsThatAreKeptBothWithAReason() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    _ = try b.receive(viaCloud(try a.save("t", row("Base"))))
    let fromA = try a.save("t", row("A's change"))
    try b.save("t", row("B's change"))
    let results = try b.receive(viaCloud(fromA))
    XCTAssertEqual(results.map(\.status), [.keptBoth])
    XCTAssertNotNil(results[0].reason)
    XCTAssertEqual(b.store["fixture:t"]?["title"].string, "B's change")
    XCTAssertEqual(b.archive.ledger?.heads("fixture:t").count, 2)
    XCTAssertTrue(b.archive.attention().contains { $0.contains("two versions") })
  }

  /// Finding 15: a version this Mac refuses is kept with its reason; the rest of the batch applies and nothing throws.
  func testRefusedVersionIsKeptAndTheBatchContinues() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    try a.save("good", row("Good")); let ops = try a.save("bad", row("Not valid here"))
    let all = try a.archive.ownOperations(); XCTAssertEqual(ops.count, 1)
    let results = try b.receive(viaCloud(all), refuse: ["bad"])
    XCTAssertEqual(Set(results.map(\.status)), [.applied, .keptBoth])
    XCTAssertFalse(results.contains { $0.status == .blocked })
    XCTAssertEqual(b.store["fixture:good"]?["title"].string, "Good")
    XCTAssertNil(b.store["fixture:bad"])
    XCTAssertTrue(b.archive.ledger?.retained(all) == true)
  }

  /// Finding 2: a record far above 64 KiB travels as bounded parts and arrives byte-identical; capture keeps working.
  func testOversizedRecordTravelsAsBoundedPartsAndArrivesWhole() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    let urdu = String(repeating: "یہ ایک لمبا کام ہے۔ ", count: 12_000)
    let big = row("Big", [.init("details", .string(urdu)), .init("notes", .array((0..<100).map { .string("note \($0) " + String(repeating: "ن", count: 2_000)) }))])
    let ops = try a.save("big", big)
    XCTAssertGreaterThan(ops.count, 10)
    for op in ops { XCTAssertLessThanOrEqual(try CloudSyncCanonical.encode(op.payload).count, 65_536) }
    _ = try b.receive(viaCloud(ops))
    XCTAssertEqual(b.store["fixture:big"], big)
    XCTAssertEqual(try a.save("small", row("Still captured")).count, 1)
  }

  /// Finding 10: an edit made on the Mac that received a stripped copy changes only what it changed there.
  func testEditOfRestoredCopyCarriesStrippedOriginFieldsForward() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    b.shape = .init(show: { _, value in value.setting("assignee", .string("none")).setting("stopped", .bool(true)).removing("project") })
    let original = row("Task", [.init("assignee", .string("worker")), .init("stopped", .bool(false)), .init("project", .string("/origin/app"))])
    _ = try b.receive(viaCloud(try a.save("t", original)))
    XCTAssertEqual(b.store["fixture:t"]?["assignee"].string, "none")
    let edited = try XCTUnwrap(b.store["fixture:t"]).setting("title", .string("Renamed on B"))
    let shared = try XCTUnwrap(try b.save("t", edited).first).payload.raw
    XCTAssertEqual(shared["title"].string, "Renamed on B")
    XCTAssertEqual(shared["assignee"].string, "worker")
    XCTAssertEqual(shared["stopped"].bool, false)
    XCTAssertEqual(shared["project"].string, "/origin/app")
  }

  /// Finding 8: ledgers are per account; a value received from account X is not captured into account Y,
  /// and the change feed never offers imported revisions.
  func testAccountsStaySeparateAndOnlyOwnRevisionsAreOffered() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    var a = try Owner(account(deviceA))
    var bx = try Owner(account(deviceB, subjectX), directory: root)
    _ = try bx.receive(viaCloud(try a.save("t", row("From X"))))
    XCTAssertTrue(try bx.archive.ownOperations().isEmpty, "Imported revisions are never re-sent")
    bx.archive.detach()
    var by = try Owner(account(deviceB, subjectY), directory: root)
    by.store = bx.store
    let captured = try by.archive.capture(by.records(), sourceID: "fixture", complete: true)
    XCTAssertTrue(captured.operations.isEmpty)
    XCTAssertEqual(captured.foreign, 1)
    XCTAssertTrue(by.archive.attention().contains { $0.contains("another Cloud account") })
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("cloud/" + subjectX + "/fixture/ledger.log").path))
    XCTAssertThrowsError(try by.archive.attach(account(deviceB, subjectX)), "One owner cannot write two accounts' ledgers at once") { _ in }
  }

  /// Finding 17: an unchanged save writes nothing; one changed record appends only its own revision.
  func testLedgerGrowsOnlyByWhatChanged() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    var a = try Owner(account(deviceA), directory: root)
    for index in 0..<200 { a.store["fixture:r\(index)"] = row(String(repeating: "x", count: 400) + "\(index)") }
    _ = try a.archive.capture(a.records(), sourceID: "fixture", complete: true)
    let file = root.appendingPathComponent("cloud/" + subjectX + "/fixture/ledger.log")
    let full = try Data(contentsOf: file).count
    XCTAssertTrue(try a.archive.capture(a.records(), sourceID: "fixture", complete: true).operations.isEmpty)
    XCTAssertEqual(try Data(contentsOf: file).count, full)
    try a.save("r7", row("changed"))
    let growth = try Data(contentsOf: file).count - full
    XCTAssertGreaterThan(growth, 0)
    XCTAssertLessThan(growth, full / 50)
  }

  /// A crash can tear the last line; the ledger reopens without it and cuts it before appending again.
  func testTornFinalLineIsIgnoredAndCutBeforeTheNextAppend() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    var a = try Owner(account(deviceA), directory: root)
    try a.save("t", row("One"))
    let file = root.appendingPathComponent("cloud/" + subjectX + "/fixture/ledger.log")
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"t\":\"capt".utf8)); try handle.close()
    var reopened = try Owner(account(deviceA), directory: root)
    reopened.store = a.store
    XCTAssertTrue(try reopened.archive.capture(reopened.records(), sourceID: "fixture", complete: true).operations.isEmpty)
    try reopened.save("t", row("Two"))
    let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
    XCTAssertFalse(text.contains("{\"t\":\"capt\n") || text.contains("capt{"))
    XCTAssertNoThrow(try Owner(account(deviceA), directory: root))
  }

  /// S03/S06: repeated ids apply once; the same id with different bytes, or a cycle, refuses before anything is kept.
  func testDuplicateIDsApplyOnceAndDifferentBytesOrCyclesRefuse() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    let ops = try a.save("t", row("One"))
    _ = try b.receive(viaCloud(ops))
    XCTAssertEqual(try b.receive(viaCloud(ops)).map(\.status), [.alreadyPresent])
    let op = ops[0], changed = CloudValue(row("Other bytes"))
    let forged = CloudOperation(v: 1, opId: op.opId, originDevice: op.originDevice, domain: op.domain, entityId: op.entityId, revision: op.revision,
      parents: [], kind: .put, source: op.source, createdAt: op.createdAt, payload: changed, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(changed)))
    XCTAssertThrowsError(try b.receive([forged]))
    let x = UUID().uuidString.lowercased(), y = UUID().uuidString.lowercased(), value = CloudValue(row("cycle")), hash = CloudSyncBytes.hash(try CloudSyncCanonical.encode(value))
    let cycle = [x, y].enumerated().map { index, id in CloudOperation(v: 1, opId: id, originDevice: deviceA, domain: "fixture", entityId: "c", revision: id,
      parents: [index == 0 ? y : x], kind: .put, source: .init(sourceId: "fixture", recordId: "c"), createdAt: 1, payload: value, payloadHash: hash) }
    var c = try Owner(account(deviceB))
    XCTAssertThrowsError(try c.receive(cycle))
    XCTAssertTrue(c.store.isEmpty)
  }

  /// D1 crash rule: an interrupted projection is finished when the owner holds the projected value, and is not
  /// mistaken for a local edit; when the owner never wrote it, the next import shows it again.
  func testInterruptedProjectionResolvesFromTheStoredValue() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    var a = try Owner(account(deviceA))
    var b = try Owner(account(deviceB), directory: root)
    let ops = try viaCloud(try a.save("t", row("Remote")))
    _ = try XCTUnwrap(b.archive.ledger)
    XCTAssertThrowsError(try b.archive.importing(ops, current: { _ in nil }, shape: .identity, write: { _ in throw CloudFailure.unavailable }))
    var reopened = try Owner(account(deviceB), directory: root)
    XCTAssertEqual(try reopened.receive(ops).map(\.status), [.applied], "Retained before the failed write; shown now")
    XCTAssertEqual(reopened.store["fixture:t"]?["title"].string, "Remote")
    XCTAssertTrue(try reopened.archive.capture(reopened.records(), sourceID: "fixture", complete: true).operations.isEmpty)
  }

  /// S15 + D1: removing locally adds a marker; a Mac that still shows the record keeps its copy.
  func testRemovalIsAMarkerAndNeverDeletesAnotherMacsCopy() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    _ = try b.receive(viaCloud(try a.save("t", row("Keep"))))
    let removal = try a.save("t", nil)
    XCTAssertEqual(removal.map(\.kind), [.archive])
    let results = try b.receive(viaCloud(removal))
    XCTAssertEqual(results.map(\.status), [.keptBoth])
    XCTAssertEqual(b.store["fixture:t"]?["title"].string, "Keep")
    XCTAssertEqual(b.archive.ledger?.versions("fixture:t").count, 2)
  }

  /// The same content made on two Macs is adopted, not reported as a conflict.
  func testIdenticalExistingContentIsAdopted() throws {
    var a = try Owner(account(deviceA)), b = try Owner(account(deviceB))
    b.store["fixture:t"] = row("Same")
    XCTAssertEqual(try b.receive(viaCloud(try a.save("t", row("Same")))).map(\.status), [.applied])
    XCTAssertTrue(try b.archive.capture(b.records(), sourceID: "fixture", complete: true).operations.isEmpty)
  }
}
