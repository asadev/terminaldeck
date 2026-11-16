import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// "See what is in your Cloud": the sync store's one local read, from a fixture store with items of two devices,
/// one going up, one not sent, one waiting here, a held device and a refused pack.
final class CloudSyncContentsTests: XCTestCase, @unchecked Sendable {
    let mac = "33333333-3333-4333-8333-333333333333"
    let other = "44444444-4444-4444-8444-444444444444"
    let stranger = "55555555-5555-4555-8555-555555555555"
    var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    func store() throws -> CloudSyncStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudContents-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111"))
    }
    func op(_ record: String, device: String, time: Int64, parents: [String] = [], part: Int64? = nil) throws -> CloudOperation {
        let id = UUID().uuidString.lowercased()
        let payload = CloudValue(.object([.init("bytes", .string("2048")), .init("text", .string("fixture"))]))
        return .init(v: 1, opId: id, originDevice: device, domain: "memory", entityId: record + (part.map { "-\($0)" } ?? ""), revision: id,
                     parents: parents, kind: .put, projectId: "fixture-project", source: .init(sourceId: "memory/I01", recordId: record, offset: part),
                     createdAt: time, payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
    }

    func testContentsFromAFixtureStore() throws {
        let s = try store()
        // From the other device: two parts of one version of "file/notes.md", applied here at feed position 5.
        let a1 = try op("file/notes.md", device: other, time: 1_000, part: 0), a2 = try op("file/notes.md", device: other, time: 1_000, part: 1)
        try s.finishApply(id: "segment-5", seq: CloudSequence(5), digest: "d5", operations: [a1, a2], committedAt: 1_100)
        // This Mac changed it later and that went up (position 6, committed 2_100).
        let mine = try op("file/notes.md", device: mac, time: 2_000, parents: [a1.opId], part: 0)
        _ = try s.enqueue([mine])
        try s.finishApply(id: "segment-6", seq: CloudSequence(6), digest: "d6", operations: [mine], committedAt: 2_100)
        // Going up now.
        let going = try op("file/plan.md", device: mac, time: 3_000)
        _ = try s.enqueue([going])
        // Refused on the send side.
        let refused = try op("file/big.md", device: mac, time: 3_500)
        _ = try s.enqueue([refused])
        try s.execute("UPDATE outbox SET state='parked' WHERE opId=?", [Data(refused.opId.utf8)])
        try s.execute("INSERT INTO parked_sends(opId,reason,parkedAt) VALUES (?,?,CAST(? AS INTEGER))",
                      [Data(refused.opId.utf8), Data("This edit is larger than one upload can carry; it is kept here.".utf8), Data("3600".utf8)])
        // From the other device, kept here but not used yet.
        let waiting = try op("file/todo.md", device: other, time: 4_000)
        try s.execute("INSERT INTO parked_ops(opId,domain,entityId,sourceId,projectId,bytes,origin,reason,conflict,attempts,nextAt,parkedAt) VALUES (?,?,?,?,?,?,?,?,0,0,0,4100)",
                      [Data(waiting.opId.utf8), Data("memory".utf8), Data(waiting.entityId.utf8), Data("memory/I01".utf8), Data("fixture-project".utf8),
                       try CloudSyncCanonical.encode(waiting), Data("{}".utf8), Data("Its project is not on this Mac yet.".utf8)])
        try s.hold(deviceId: stranger, seq: CloudSequence(7), storageClass: .brain, domains: ["memory"], operations: 2)
        try s.recordRefused(seq: CloudSequence(8), storageClass: .brain, deviceId: other, reason: "signature")

        let contents = try s.contents(thisDevice: mac, held: [])
        XCTAssertEqual(contents.thisDevice, mac)
        XCTAssertEqual(contents.queued, 1)
        let byRecord = Dictionary(uniqueKeysWithValues: contents.items.map { ($0.key.recordId, $0) })
        XCTAssertEqual(Set(byRecord.keys), ["file/notes.md", "file/plan.md", "file/big.md", "file/todo.md"])
        // Two versions, newest first; the two parts of one version count once; times are the service's commit times.
        let notes = try XCTUnwrap(byRecord["file/notes.md"])
        XCTAssertEqual(notes.changes, [.init(deviceId: mac, at: 2_100), .init(deviceId: other, at: 1_100)])
        XCTAssertEqual(notes.standing, .inCloud)
        XCTAssertEqual(notes.bytes, 2048)
        XCTAssertEqual(byRecord["file/plan.md"]?.standing, .sending)
        XCTAssertEqual(byRecord["file/big.md"]?.standing, .notSent)
        XCTAssertEqual(byRecord["file/big.md"]?.reason, "This edit is larger than one upload can carry; it is kept here.")
        XCTAssertEqual(byRecord["file/todo.md"]?.standing, .waitingHere)
        XCTAssertEqual(contents.notSent.map(\.count), [1])
        // Packs: the other device's arrived here (its arrival time was recorded); this Mac's own has none.
        XCTAssertEqual(contents.packs.count, 2)
        let theirs = try XCTUnwrap(contents.packs.first { $0.deviceId == other })
        XCTAssertNotNil(theirs.arrivedAt)
        XCTAssertEqual(theirs.count, ["memory": 1])
        XCTAssertEqual(theirs.keys.map(\.recordId), ["file/notes.md"])
        XCTAssertNil(contents.packs.first { $0.deviceId == mac }?.arrivedAt)
        XCTAssertEqual(contents.refused.count, 1)
        // The held device is the engine's list, passed through.
        let held = CloudHeldDevice(deviceId: stranger, firstHeldSeq: CloudSequence(7), firstHeldSecretsSeq: nil, packs: 1, operations: 2, byDomain: [], firstSeenAt: 4_200, counting: false)
        XCTAssertEqual(try s.contents(thisDevice: mac, held: [held]).held, [held])
    }

    func testAnEmptyStoreKnowsNothingAndTheArrivalIsRecordedOnce() throws {
        let s = try store()
        let contents = try s.contents(thisDevice: mac, held: [])
        XCTAssertTrue(contents.items.isEmpty)
        XCTAssertTrue(contents.packs.isEmpty)
        try s.noteArrival(CloudSequence(3), at: 10)
        try s.noteArrival(CloudSequence(3), at: 20)
        XCTAssertEqual(try s.rows("SELECT arrivedAt FROM pack_arrivals").map { String(decoding: $0[0], as: UTF8.self) }, ["10"])
    }
}
