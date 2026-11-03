import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsRootPortTourStageTests: XCTestCase {
    private typealias S = BackendDeckToolsRootPortTourSupport
    private func start(_ r: S.Rig) async throws -> (Task<NativeRPCValue, Never>, String) {
        let checked = try await S.checked([S.stop()]); let playing = Task { await r.stage.play(checked) }; let offered = await r.window.offered(); return (playing, offered.record.id)
    }
    private func playing(_ r: S.Rig) async throws -> String {
        let (task, id) = try await start(r); let accepted = await r.stage.acknowledge(id); XCTAssertTrue(accepted); _ = await task.value; return id
    }
    func testNoTourIsNotDriving() async { let r = S.rig(); defer { r.dispose() }; let driving = await r.stage.driving(); XCTAssertFalse(driving) }
    func testUnacknowledgedOfferNeverLatchesDriving() async throws {
        let r = S.rig(); defer { r.dispose() }; let (task, id) = try await start(r)
        let waiting = await r.stage.driving(); XCTAssertFalse(waiting)
        _ = await r.stage.acknowledge(id); _ = await task.value; let running = await r.stage.driving(); XCTAssertTrue(running); await r.stage.stop()
    }
    func testAcknowledgedWindowReturnsRecord() async throws {
        let r = S.rig(); defer { r.dispose() }; let (task, id) = try await start(r); _ = await r.stage.acknowledge(id); let result = await task.value
        XCTAssertEqual(result["ok"], .bool(true)); XCTAssertEqual(result["record"]["question"], .string("what happened?")); await r.stage.stop()
    }
    func testSecondTourWhileDrivingIsRefused() async throws {
        let r = S.rig(); defer { r.dispose() }; _ = try await playing(r); let checked = try await S.checked([S.stop()]); let result = await r.stage.play(checked)
        XCTAssertEqual(result, S.o([("ok", .bool(false)), ("why", .string("already-driving"))])); await r.stage.stop()
    }
    func testNoWindowReportsNoWindowAndClosedRecord() async throws {
        let r = S.rig(window: .init(available: false)); defer { r.dispose() }; let checked = try await S.checked([S.stop()]); let result = await r.stage.play(checked)
        XCTAssertEqual(result["why"], .string("no-window")); let driving = await r.stage.driving(); XCTAssertFalse(driving)
        let records = await r.stage.list(); XCTAssertEqual(records.first?["endedAt"], .number(1000)); XCTAssertTrue(records.first?["stops"].elements?.allSatisfy { $0["shownAt"] == .null } == true)
    }
    func testSilentWindowExpiresWithFakeClock() async throws {
        let r = S.rig(); defer { r.dispose() }; let (task, _) = try await start(r); r.clock.advance(4000)
        let result = await task.value; XCTAssertEqual(result["why"], .string("no-answer")); let driving = await r.stage.driving(); XCTAssertFalse(driving)
    }
    func testReloadEndsAndUnsubscribesTour() async throws {
        let r = S.rig(); defer { r.dispose() }; _ = try await playing(r)
        await r.window.gone()
        // The actual callback must remove its subscription. No manual end,
        // polling or real time is used to manufacture a passing transition.
        await r.window.waitForUnwatch()
        let driving = await r.stage.driving(); XCTAssertFalse(driving)
        let unwatches = await r.window.unwatchCount(); XCTAssertEqual(unwatches, 1)
    }
    func testShutdownClosesRecordAtClockTime() async throws {
        let r = S.rig(); defer { r.dispose() }; _ = try await playing(r); await r.stage.stop(); let record = await r.stage.list().first
        XCTAssertEqual(record?["endedAt"], .number(1000))
    }
    func testUnrelatedAcknowledgementIsIgnored() async throws {
        let r = S.rig(); defer { r.dispose() }; let (task, id) = try await start(r)
        let wrong = await r.stage.acknowledge("tour_1_deadbeef"); XCTAssertFalse(wrong)
        _ = await r.stage.acknowledge(id); _ = await task.value; let driving = await r.stage.driving(); XCTAssertTrue(driving); await r.stage.stop()
    }
    func testRecordWrittenBeforeWindowOffer() async throws {
        let r = S.rig(); defer { r.dispose() }
        await r.window.setBeforeSend { offered in
            let file = r.directory.appendingPathComponent("tours/" + offered.record.id + ".json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        let (task, id) = try await start(r)
        _ = await r.stage.acknowledge(id); _ = await task.value; await r.stage.stop()
    }
    func testDiskRecordsListNewestFirst() async throws {
        let r = S.rig(); defer { r.dispose() }; _ = try await playing(r); await r.stage.stop()
        let dir = r.directory.appendingPathComponent("tours")
        for (id, at) in [("tour_1700000000001_aaaaaaaa", 5.0), ("tour_1700000000002_bbbbbbbb", 9.0)] {
            let record = S.o([("v", .number(1)), ("id", .string(id)), ("startedAt", .number(at)), ("stops", .array([]))]); try record.encodedJSON().write(to: dir.appendingPathComponent(id + ".json"))
        }
        let records = await r.stage.list(); XCTAssertEqual(records.first?["startedAt"], .number(1000))
    }
    func testUnreadableRecordDoesNotLoseOthers() async throws {
        let r = S.rig(); defer { r.dispose() }; _ = try await playing(r); await r.stage.stop()
        try Data("not json at all".utf8).write(to: r.directory.appendingPathComponent("tours/tour_9_cccccccc.json")); let records = await r.stage.list(); XCTAssertEqual(records.count, 1)
    }
    func testDeleteOnlyTourIDsAndAbsentIDIsSuccess() async {
        let r = S.rig(); defer { r.dispose() }
        let path = await r.stage.forget("../../etc/passwd"), absent = await r.stage.forget("tour_1_ab")
        XCTAssertFalse(path); XCTAssertTrue(absent)
    }
    func testMaximumKeptIsFifty() { XCTAssertEqual(BackendDeckToolsTourStage.maxToursKept, 50) }
    func testWindowProgressFieldsAreAccepted() async throws {
        let checked = try await S.checked([S.stop()]); let record = BackendDeckToolsTour.openRecord(checked, at: 1), row = record["stops"].elements!.first!
        let update = row.setting("shownAt", .number(55)).setting("dwellMs", .number(900)).setting("degraded", .bool(true)).setting("degradedWhy", .string("in vim"))
        let value = BackendDeckToolsTour.mergeProgress(record, update: S.o([("stops", .array([update])), ("stoppedAfter", .number(0))]))
        XCTAssertEqual(value["stops"].elements![0]["shownAt"], .number(55)); XCTAssertEqual(value["stops"].elements![0]["dwellMs"], .number(900)); XCTAssertEqual(value["stops"].elements![0]["degraded"], .bool(true)); XCTAssertEqual(value["stoppedAfter"], .number(0))
    }
    func testWindowCannotReplaceCheckedQuoteOrNote() async throws {
        let checked = try await S.checked([S.stop(quote: "the build failed", note: "the checked note")]); let record = BackendDeckToolsTour.openRecord(checked, at: 1), row = record["stops"].elements![0]
        let value = BackendDeckToolsTour.mergeProgress(record, update: S.o([("stops", .array([row.setting("quote", .string("something else entirely")).setting("note", .string("and a different note"))]))]))
        XCTAssertEqual(value["stops"].elements![0]["quote"], row["quote"]); XCTAssertEqual(value["stops"].elements![0]["note"], row["note"])
    }
    func testUnknownStopIndexIsIgnored() async throws {
        let checked = try await S.checked([S.stop()]); let record = BackendDeckToolsTour.openRecord(checked, at: 1), row = record["stops"].elements![0]
        let value = BackendDeckToolsTour.mergeProgress(record, update: S.o([("stops", .array([row.setting("index", .number(7)).setting("shownAt", .number(55))]))]))
        XCTAssertEqual(value["stops"].elements![0]["shownAt"], .null)
    }
}
