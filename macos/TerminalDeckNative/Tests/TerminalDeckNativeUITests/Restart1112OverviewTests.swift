import Foundation
import Observation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

private final class Restart1112Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor private final class ReviewListReply {
    var pending: CheckedContinuation<[[String: String]], Never>?
    var started: CheckedContinuation<Void, Never>?
    func read() async -> [[String: String]] {
        await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitUntilReading() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ rows: [[String: String]]) { pending?.resume(returning: rows); pending = nil }
}

final class Restart1112OverviewTests: XCTestCase {
    @MainActor func testItem5InflightListMergesLatestEventsIncludingUnlistedRowsAndClearsRemovedStatus() async {
        let gate = ReviewListReply()
        var pause = false
        var handlers: [String: ([Any]) -> Void] = [:]
        let old = [["id": "one", "status": "working"], ["id": "new", "status": "working"]]
        let model = PROJPAGEOverviewModel(read: { channel, _ in
            if channel == "session:list" { return pause ? await gate.read() : old }
            return [String: String]()
        }, observe: { channel, handler in handlers[channel] = handler; return {} },
            retainWatch: { _ in }, releaseWatch: { _ in }, sessionStatuses: { ["one": "working", "new": "working"] })
        await model.load(project: PROJProject(id: "fixture", name: "Fixture", folders: ["/fixture"]), folder: "/fixture")
        model.cards["sessions"] = .array([.object([.init("id", .string("one")), .init("status", .string("working"))])])
        pause = true
        let reply = Task { await model.reload("sessions") }
        await gate.waitUntilReading()
        handlers["session:status"]?(["one", "idle"])
        handlers["session:status"]?(["new", "waiting"])
        gate.finish(old)
        await reply.value
        XCTAssertEqual(model.cards["sessions"]?.elements?.first?["status"].string, "idle")
        XCTAssertEqual(model.cards["sessions"]?.elements?.last?["status"].string, "waiting")
        model.acceptSessionRemoval("one")
        XCTAssertFalse(model.cards["sessions"]?.elements?.contains { $0["id"].string == "one" } ?? true)
        pause = false
        handlers["session:created"]?([["id": "one"]])
        await model.reload("sessions")
        XCTAssertEqual(model.cards["sessions"]?.elements?.first?["status"].string, "working", "Removed event state must not leak into a new row")
        model.stop()
    }

    @MainActor func testRepeatedReadFailuresDoNotRedrawAndNewFailuresStillArrive() async {
        var message = "Unavailable"
        let model = PROJPAGEOverviewModel(read: { channel, _ in
            if channel == "cost:project" { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            return [String: String]()
        }, observe: { _, _ in {} }, retainWatch: { _ in }, releaseWatch: { _ in }, sessionStatuses: { [:] })
        await model.load(project: PROJProject(id: "fixture", name: "Fixture", folders: ["/fixture"]), folder: "/fixture")
        let changes = Restart1112Changes()
        withObservationTracking { _ = model.cards; _ = model.failures } onChange: { changes.note() }
        await model.reload("usage")
        XCTAssertEqual(changes.count, 0)
        message = "A different failure"
        await model.reload("usage")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(model.failures["usage"], message)
        model.stop()
    }

    @MainActor func testRepeatedStatusEventsDoNotReadTheSessionListOrRedrawUnchangedCards() async {
        var reads = 0
        var handlers: [String: ([Any]) -> Void] = [:]
        let model = PROJPAGEOverviewModel(read: { channel, _ in
            if channel == "session:list" { reads += 1; return [["id": "one", "status": "idle", "cwd": "/fixture"]] }
            return [String: String]()
        }, observe: { channel, handler in handlers[channel] = handler; return {} },
            retainWatch: { _ in }, releaseWatch: { _ in }, sessionStatuses: { [:] })
        await model.load(project: PROJProject(id: "fixture", name: "Fixture", folders: ["/fixture"]), folder: "/fixture")
        let changes = Restart1112Changes()
        withObservationTracking { _ = model.cards } onChange: { changes.note() }
        for _ in 0..<1_000 { handlers["session:status"]?(["one", "idle"]) }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(changes.count, 0)
        handlers["session:status"]?(["one", "working"])
        XCTAssertEqual(model.cards["sessions"]?.elements?.first?["status"].string, "working")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(reads, 1)
        model.stop()
        handlers["session:status"]?(["one", "idle"])
        XCTAssertEqual(model.cards["sessions"]?.elements?.first?["status"].string, "working")
    }

    @MainActor func testIdenticalReadsDoNotInvalidateTheOverviewAndChangedReadsStillArrive() async {
        var rows = [["id": "one", "status": "idle", "cwd": "/fixture"]]
        let model = PROJPAGEOverviewModel(read: { channel, _ in
            if channel == "session:list" { return rows }
            return [String: String]()
        }, observe: { _, _ in {} }, retainWatch: { _ in }, releaseWatch: { _ in }, sessionStatuses: { [:] })
        await model.load(project: PROJProject(id: "fixture", name: "Fixture", folders: ["/fixture"]), folder: "/fixture")
        let changes = Restart1112Changes()
        withObservationTracking { _ = model.cards } onChange: { changes.note() }
        await model.reload("sessions")
        XCTAssertEqual(changes.count, 0)
        rows.append(["id": "two", "status": "idle", "cwd": "/fixture"])
        await model.reload("sessions")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(model.cards["sessions"]?.elements?.count, 2)
        model.stop()
    }
}
