import XCTest
import Foundation
@testable import TerminalDeckBackend

/// plan-limit.test.ts: the tracker, how old a reading is, in-process watching and the billing of a
/// watched session (the 8 cases the parser file could not reach). A short settle interval stands in
/// for the 600 ms timer; nothing else differs.
final class BackendFoundationTestsS6C1PlanTracker: XCTestCase {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock(); private var values: [BackendPlanLimitSnapshot] = []
        func add(_ value: BackendPlanLimitSnapshot) { lock.lock(); values.append(value); lock.unlock() }
        var all: [BackendPlanLimitSnapshot] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private func tracker(_ id: String, _ sink: Sink = Sink()) -> BackendPlanLimitTracker {
        BackendPlanLimitTracker(sessionID: id, cols: 80, rows: 24) { sink.add($0) }
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }

    // 'reads limits off a repainted screen and keeps them when the panel closes'
    func testReadsLimitsOffARepaintedScreenAndKeepsThemWhenThePanelCloses() async throws {
        let sink = Sink(), t = tracker("s1", sink)
        // Written the way a TUI writes: the bar and the number arrive separately.
        t.push("Current week (all models)\r\n"); t.push("████████████████"); t.push("           80% used\r\n")
        t.push("Resets Aug 14 at 2pm (Asia/Dubai)\r\n")
        await t.flush()
        XCTAssertTrue(t.capture())
        XCTAssertTrue(t.current.available)
        XCTAssertEqual(t.current.limits.first?.id, "week"); XCTAssertEqual(t.current.limits.first?.percent, 80)
        XCTAssertEqual(sink.all.map { $0.limits.count }, [1])
        // The panel is closed most of the time. Its absence is not news.
        t.push("\u{1B}[2J\u{1B}[H❯ \r\n")
        await t.flush()
        XCTAssertFalse(t.capture())
        XCTAssertEqual(t.current.limits.first?.percent, 80)
        XCTAssertEqual(sink.all.map { $0.limits.count }, [1])
        t.dispose()
    }

    // 'tells a watcher its reading is over instead of dropping it silently'
    func testTellsAWatcherItsReadingIsOverInsteadOfDroppingItSilently() async throws {
        let limits = BackendPlanLimits(), sink = Sink()
        for i in 0..<9 { try await limits.watch("evict-\(i)", key: "w") { sink.add($0) } }
        try await settle()
        let told = sink.all
        XCTAssertEqual(told.map(\.sessionID), ["evict-0"])
        XCTAssertEqual(told.first?.available, false)
        XCTAssertTrue(told.first?.reason?.contains("released to make room") == true)
        for i in 0..<9 { await limits.drop("evict-\(i)") }
    }

    // MARK: how old a reading is
    func testKeepsTheFirstSeenTimeWhileTheNumbersOnScreenDoNotChange() async throws {
        let t = tracker("age-1")
        t.push("Current session\r\n██▌   5% used\r\nResets 4am (Asia/Dubai)\r\n")
        await t.flush()
        t.capture(at: 1_000)
        XCTAssertEqual(t.current.firstSeenAt, 1_000)
        // Read again much later with the same panel still up: this app looked again; the CLI did not speak again.
        t.capture(at: 3_600_000)
        XCTAssertEqual(t.current.capturedAt, 3_600_000); XCTAssertEqual(t.current.firstSeenAt, 1_000)
        t.dispose()
    }
    func testMovesTheFirstSeenTimeWhenTheNumberItselfChanges() async throws {
        let t = tracker("age-2")
        t.push("Current session\r\n██▌   5% used\r\n")
        await t.flush(); t.capture(at: 1_000)
        t.push("\u{1B}[2J\u{1B}[HCurrent session\r\n████   9% used\r\n")
        await t.flush(); t.capture(at: 2_000)
        XCTAssertEqual(t.current.firstSeenAt, 2_000)
        t.dispose()
    }
    func testTreatsAReadingItJustAskedForAsFreshEvenWhenItRepeats() async throws {
        let t = tracker("age-3")
        t.push("Current session\r\n██▌   5% used\r\n")
        await t.flush(); t.capture(at: 1_000)
        t.capture(at: 9_000, confirmed: true)
        XCTAssertEqual(t.current.firstSeenAt, 9_000)
        t.dispose()
    }

    // MARK: watching from inside the process
    func testHandsOverTheCurrentReadingAndThenEveryChange() async throws {
        let limits = BackendPlanLimits(settleMilliseconds: 50), sink = Sink()
        let held = try await limits.watch("inproc-1", key: "a") { sink.add($0) }
        XCTAssertFalse(held.available); XCTAssertTrue(held.reason?.contains("has not printed") == true)
        await limits.noteOutput("inproc-1", "Current week (all models)\n████   80% used\nResets Aug 14 at 2pm\n")
        try await settle()
        XCTAssertEqual(sink.all.last?.limits.first?.id, "week"); XCTAssertEqual(sink.all.last?.limits.first?.percent, 80)
        await limits.unwatch("inproc-1", key: "a")
    }
    func testDoesNotReportASessionThatHasNeverPrintedAnythingAsUnwatched() async throws {
        let limits = BackendPlanLimits()
        let nobody = await limits.snapshot("nobody-home")
        XCTAssertTrue(nobody.reason?.contains("No live session is being watched") == true)
        try await limits.watch("inproc-2", key: "a") { _ in }
        let quiet = await limits.snapshot("inproc-2")
        XCTAssertTrue(quiet.reason?.contains("has not printed") == true)
        await limits.unwatch("inproc-2", key: "a")
    }
    func testKeepsTheTrackerAliveForAListenerAfterTheLastWindowLetsGo() async throws {
        let limits = BackendPlanLimits(settleMilliseconds: 50), sink = Sink()
        try await limits.watch("inproc-3", key: "window") { _ in }
        try await limits.watch("inproc-3", key: "chrome") { sink.add($0) }
        // The window closes its tab; the chrome is still watching, so the shadow terminal must survive.
        await limits.unwatch("inproc-3", key: "window")
        await limits.noteOutput("inproc-3", "Current session\n██   7% used\n")
        try await settle()
        XCTAssertEqual(sink.all.last?.limits.first?.id, "session"); XCTAssertEqual(sink.all.last?.limits.first?.percent, 7)
        await limits.unwatch("inproc-3", key: "chrome")
        // Stopping the last listener releases it for real.
        let after = await limits.snapshot("inproc-3")
        XCTAssertTrue(after.reason?.contains("No live session is being watched") == true)
    }

    // 'reports a watched session’s billing, and says nothing about one it has not seen'
    func testReportsAWatchedSessionsBillingAndSaysNothingAboutOneItHasNotSeen() async throws {
        let limits = BackendPlanLimits()
        var none = await limits.billing("billing-1"); XCTAssertNil(none)
        try await limits.watch("billing-1", key: "w") { _ in }
        none = await limits.billing("billing-1"); XCTAssertNil(none)
        await limits.noteOutput("billing-1", "Claude Code v2.1.224 · Opus 5 with xhigh effort · Claude API\n❯\n")
        let seen = await limits.billing("billing-1"); XCTAssertEqual(seen, "api")
        await limits.drop("billing-1")
        none = await limits.billing("billing-1"); XCTAssertNil(none)
    }
}
