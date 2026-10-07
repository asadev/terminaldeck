import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsTourTests: XCTestCase {
    private func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    private func stop(quote: String = "the build failed", why: String = "files-changed") -> NativeRPCValue {
        o([("kind", .string("screen")), ("sessionId", .string("s1")), ("quote", .string(quote)), ("note", .string("it failed")), ("why", .string(why))])
    }
    private func plan(_ stops: [NativeRPCValue]) -> NativeRPCValue { o([("question", .string("what happened?")), ("headline", .string("this happened")), ("stops", .array(stops))]) }
    struct Evidence: BackendDeckToolsTourEvidence {
        let factsByID: [String: NativeRPCValue]
        func facts(sessionID: String) async throws -> NativeRPCValue? { factsByID[sessionID] }
        func supports(reason: String, importance: NativeRPCValue, median: Double?, sample: Int) async throws -> Bool {
            reason == "decision" || reason == "files-changed" && (importance["changedFiles"].number ?? 0) > 0
        }
    }
    private func evidence() -> Evidence {
        Evidence(factsByID: ["s1": o([("title", .string("api")), ("session", o([("cwd", .string("/work/api"))])), ("screen", .string("\u{1b}[31mthe build failed\u{1b}[m\n")), ("changed", .array([.string("a.ts")])), ("importance", o([("changedFiles", .number(1)), ("attention", .string("quiet"))]))])])
    }
    func testBudgetsAreRefusedRatherThanTrimmed() throws {
        XCTAssertEqual(try BackendDeckToolsTour.parse(plan(Array(repeating: stop(), count: 12)))["stops"].elements?.count, 12)
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(plan(Array(repeating: stop(), count: 13)))) { XCTAssertTrue(($0 as? NativeRPCError)?.message.contains("refused rather than trimmed") == true) }
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(plan([stop(quote: String(repeating: "x", count: 601))])))
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(plan([])))
        // 301 emoji are 602 JavaScript characters, not 301 budget characters.
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(plan([stop(quote: String(repeating: "😀", count: 301))])))
    }
    func testRemovedMessageStopsAndUnknownReasonsAreRefused() {
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(plan([stop().setting("kind", .string("message"))]))) { XCTAssertTrue(($0 as? NativeRPCError)?.message.contains("Chat mode has been removed") == true) }
        XCTAssertThrowsError(try BackendDeckToolsTour.parse(plan([stop(why: "looks-bad")])))
    }
    func testQuotesAreCheckedAndDropsHaveReasons() async throws {
        let value = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop(), stop(quote: "never printed")])), evidence: evidence())
        XCTAssertEqual(value.plan["stops"].elements?.count, 1)
        XCTAssertEqual(value.dropped.first?["why"], .string("quote-not-found"))
    }
    func testSessionGoneAndUnsupportedClaimAreDifferent() async throws {
        let value = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop().setting("sessionId", .string("ghost")), stop(why: "blocked-on-you")])), evidence: evidence())
        XCTAssertEqual(value.dropped.map { $0["why"].string! }, ["session-gone", "reason-unsupported"])
    }
    func testOnlyOneDecisionPerSessionAndQuoteStillRequired() async throws {
        let value = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop(why: "decision"), stop(why: "decision")])), evidence: evidence())
        XCTAssertEqual(value.plan["stops"].elements?.count, 1); XCTAssertEqual(value.dropped.first?["why"], .string("over-budget"))
    }
    func testWindowCannotRewriteCheckedText() async throws {
        let checked = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop()])), evidence: evidence())
        let record = BackendDeckToolsTour.openRecord(checked, at: 5000), original = record["stops"].elements![0]
        let malicious = original.setting("quote", .string("made up")).setting("note", .string("made up"))
            .setting("shownAt", .number(55)).setting("dwellMs", .number(900))
        let merged = BackendDeckToolsTour.mergeProgress(record, update: o([("stops", .array([malicious])), ("stoppedAfter", .number(0))]))
        XCTAssertEqual(merged["stops"].elements![0]["quote"], .string("the build failed"))
        XCTAssertEqual(merged["stops"].elements![0]["note"], .string("it failed"))
        XCTAssertEqual(merged["stops"].elements![0]["shownAt"], .number(55))
        XCTAssertEqual(merged["stops"].elements![0]["cwd"], .string("/work/api"))
    }
    actor Window: BackendDeckToolsTourWindow {
        let available: Bool
        var sent = 0
        var watchers: [@Sendable () -> Void] = []
        var offerWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        init(_ available: Bool) { self.available = available }
        func send(_ tour: TourMessage) async -> Bool {
            sent += 1
            let ready = offerWaiters.filter { $0.0 <= sent }; offerWaiters.removeAll { $0.0 <= sent }
            ready.forEach { $0.1.resume() }; return available
        }
        func waitForOffers(_ count: Int) async { if sent >= count { return }; await withCheckedContinuation { offerWaiters.append((count, $0)) } }
        func watch(_ gone: @escaping @Sendable () -> Void) async -> UUID { watchers.append(gone); return UUID() }
        func unwatch(_ id: UUID) async {}
        func signalOldWindowGone() { watchers.first?() }
    }
    func testNoWindowAndNoAcknowledgementNeverLatchDriving() async throws {
        let checked = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop()])), evidence: evidence())
        for available in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsTourTests-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let clock = BackendDeckToolsRootPortTourSupport.Clock(), window = Window(available)
            let stage = BackendDeckToolsTourStage(logDirectory: directory, window: window, now: { 1000 }, clock: clock, writeFailure: { _ in })
            let task = Task { await stage.play(checked) }
            await window.waitForOffers(1)
            if available { clock.advance(4000) }
            let outcome = await task.value
            XCTAssertEqual(outcome["why"], .string(available ? "no-answer" : "no-window"))
            let driving = await stage.driving(); XCTAssertFalse(driving)
            let records = await stage.list(); XCTAssertEqual(records.first?["endedAt"], .number(1000))
            let badForget = await stage.forget("../../etc/passwd"); XCTAssertFalse(badForget)
        }
    }
    func testOldWindowAndCancellationCannotStopNewTour() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsTourTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = Window(true), stage = BackendDeckToolsTourStage(logDirectory: directory, window: window, now: { 1000 }, writeFailure: { _ in })
        let first = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop()])), evidence: evidence())
        let firstID = first.plan["id"].string!, firstPlay = Task { await stage.play(first) }
        await window.waitForOffers(1)
        let firstAcknowledged = await stage.acknowledge(firstID); XCTAssertTrue(firstAcknowledged)
        _ = await firstPlay.value
        _ = await stage.end(firstID)
        let second = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop()])), evidence: evidence())
        let secondID = second.plan["id"].string!, secondPlay = Task { await stage.play(second) }
        await window.waitForOffers(2)
        let secondAcknowledged = await stage.acknowledge(secondID); XCTAssertTrue(secondAcknowledged)
        _ = await secondPlay.value
        await window.signalOldWindowGone()
        await stage.stop(tourID: firstID)
        let driving = await stage.driving(), current = await stage.current()
        XCTAssertTrue(driving); XCTAssertEqual(current["id"], .string(secondID))
        await stage.stop()
    }
    actor SlowWindow: BackendDeckToolsTourWindow {
        let slowSend: Bool
        let clock: BackendDeckToolsRootPortTourSupport.Clock
        var reached = false, waiter: CheckedContinuation<Void, Never>?
        init(slowSend: Bool, clock: BackendDeckToolsRootPortTourSupport.Clock) { self.slowSend = slowSend; self.clock = clock }
        func waitUntilStep() async { if reached { return }; await withCheckedContinuation { waiter = $0 } }
        private func suspend() async {
            reached = true; waiter?.resume(); waiter = nil
            await withCheckedContinuation { continuation in _ = clock.schedule(after: 30_000) { continuation.resume() } }
        }
        func send(_ tour: TourMessage) async -> Bool { if slowSend { await suspend() }; return true }
        func watch(_ gone: @escaping @Sendable () -> Void) async -> UUID { if !slowSend { await suspend() }; return UUID() }
        func unwatch(_ id: UUID) async {}
    }
    func testAsyncWindowCannotRemoveAcknowledgementDeadline() async throws {
        let checked = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop()])), evidence: evidence())
        for slowSend in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsTourTests-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let clock = BackendDeckToolsRootPortTourSupport.Clock(), window = SlowWindow(slowSend: slowSend, clock: clock)
            let stage = BackendDeckToolsTourStage(logDirectory: directory, window: window, clock: clock, writeFailure: { _ in })
            let task = Task { await stage.play(checked) }; await window.waitUntilStep(); clock.advance(4000)
            let result = await task.value; clock.advance(30_000)
            XCTAssertEqual(result["why"], .string("no-answer"))
            let driving = await stage.driving(); XCTAssertFalse(driving)
        }
    }
    func testCancelledCallerCannotAdmitNewOffer() async throws {
        let checked = try await BackendDeckToolsTour.validate(BackendDeckToolsTour.parse(plan([stop()])), evidence: evidence())
        let cancellation = BackendMCPCancellation(); cancellation.cancel()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsTourTests-" + UUID().uuidString)
        let stage = BackendDeckToolsTourStage(logDirectory: directory, window: Window(true), writeFailure: { _ in })
        let result = await stage.play(checked, cancellation: cancellation)
        XCTAssertEqual(result["why"], .string("caller-gone"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
