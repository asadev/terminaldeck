import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// scan.test.ts against injected times (no clock). Skipped: the final guard that reads renderer/copilot/driving *.ts files
/// (a TypeScript source-tree check; the TS reading-time model has no Swift counterpart to guard).
final class BackendFoundationTestsS6C5Scan: XCTestCase {
    private func play(_ count: Int = 3, _ at: Double = 0) -> ScanState { Scan.reduce(ScanState(), .play(at: at, count: count)) }
    private func run(_ state: ScanState, _ events: [ScanEvent]) -> ScanState { events.reduce(state) { Scan.reduce($0, $1) } }
    private func stop(_ id: String, _ title: String, _ note: String, _ shownAt: Double?) -> TourStopRecord {
        TourStopRecord(index: 0, sessionId: id, sessionTitle: title, kind: "screen", cwd: "", why: "finished",
                       quote: "q", note: note, shownAt: shownAt, degraded: false)
    }

    func testHoldsEveryStopForExactlyTheSameTime() {
        var state = run(play(3, 0), [.arrive(at: 0)])
        XCTAssertEqual(state.status, .scanning)
        state = Scan.reduce(state, .tick(at: Scan.holdMs - 1))
        XCTAssertEqual(state.index, 0)
        state = Scan.reduce(state, .tick(at: Scan.holdMs))
        XCTAssertEqual(state.index, 1)
        XCTAssertEqual(state.status, .travelling)
    }

    func testHoldIsFastEnoughToBeWatchedAndSlowEnoughToBeSeen() {
        XCTAssertGreaterThanOrEqual(Scan.holdMs, 150)
        XCTAssertLessThanOrEqual(Scan.holdMs, 400)
    }

    func testDoesNotStartTheClockUntilTheBoxIsDrawn() {
        var state = play(2, 0)
        XCTAssertEqual(state.status, .travelling)
        state = Scan.reduce(state, .tick(at: 900))
        XCTAssertEqual(state.index, 0)
        XCTAssertEqual(state.status, .travelling)
    }

    func testStopsOnAnythingTheyDidAndStaysStopped() {
        let state = run(play(3, 0), [.arrive(at: 0), .pause(at: 10, reason: .clicked), .tick(at: 10 + Scan.holdMs * 4)])
        XCTAssertEqual(state.status, .paused)
        XCTAssertEqual(state.index, 0)
    }

    func testHandsOverWhenTheyStepBack() {
        let forward = run(play(3, 0), [.arrive(at: 0), .next(at: 5, travel: true)])
        XCTAssertEqual(forward.status, .travelling)
        let back = run(forward, [.arrive(at: 6), .back(at: 7, travel: true)])
        XCTAssertEqual(back.status, .paused)
        XCTAssertEqual(back.pausedBy, .steppedBack)
    }

    func testDiscardsAGapThatMeansTheRendererWasNotRunning() {
        let state = run(play(4, 0), [.arrive(at: 0), .tick(at: Scan.maxTickGapMs + 1)])
        XCTAssertEqual(state.status, .paused)
        XCTAssertEqual(state.pausedBy, .stalled)
        XCTAssertEqual(state.index, 0)
        XCTAssertEqual(state.stalls, 1)
    }

    func testRecordsEveryStopTheBoxWasDrawnAtOnce() {
        let state = run(play(3, 0), [.arrive(at: 0), .next(at: 1, travel: true), .arrive(at: 2),
                                     .back(at: 3, travel: true), .arrive(at: 4)])
        XCTAssertEqual(state.seen, [0, 1])
        XCTAssertEqual(state.arrivals, 3)
    }

    func testDropsTraceEntriesARecountHasRenumbered() {
        let state = run(play(5, 0), [.arrive(at: 0), .next(at: 1, travel: true), .arrive(at: 2),
                                     .next(at: 3, travel: true), .arrive(at: 4), .recount(at: 5, count: 2, index: 1)])
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.seen, [0, 1])
    }

    func testMeasuresProgressAcrossTheFleetNotOneStop() {
        let start = run(play(4, 0), [.arrive(at: 0)])
        XCTAssertEqual(Scan.progress(start), 0, accuracy: 1e-5)
        let third = run(start, [.next(at: 1, travel: true), .arrive(at: 2), .next(at: 3, travel: true), .arrive(at: 4)])
        XCTAssertEqual(Scan.progress(third), 0.5, accuracy: 1e-5)
    }

    func testNeverLeavesARunningScanWithNothingToSay() {
        for status in [ScanStatus.travelling, .scanning, .paused] {
            var state = play(3, 0); state.status = status
            XCTAssertNotEqual(Scan.statusSentence(state), "")
        }
        var done = play(3, 0); done.status = .finished
        XCTAssertTrue(Scan.statusSentence(done).contains("answer"))
    }

    func testNamesEveryReasonItCouldHaveStoppedFor() {
        let reasons: [PauseReason] = [.asked, .scrolled, .clicked, .typed, .selected, .leftWindow, .hidden, .steppedBack, .consent, .stalled]
        for reason in reasons { XCTAssertNotEqual(Scan.pauseSentence(reason), "", reason.rawValue) }
    }

    func testNotRunningBeforePlayOrAfterFinish() {
        XCTAssertFalse(Scan.isScanning(ScanState()))
        XCTAssertFalse(Scan.isScanning(play(0, 0)))
        XCTAssertTrue(Scan.isScanning(play(2, 0)))
    }

    func testGroupsBySessionKeepingFirstStopOrder() {
        let grouped = Scan.groupBySession([stop("a", "api", "one", 1), stop("b", "web", "two", 2), stop("a", "api", "three", 3)])
        XCTAssertEqual(grouped.map(\.sessionId), ["a", "b"])
        XCTAssertEqual(grouped[0].lines.map(\.note), ["one", "three"])
    }

    func testCountsWhatWasShownNeverWhatWasPlanned() {
        let grouped = Scan.groupBySession([stop("a", "api", "one", 1), stop("b", "web", "two", nil), stop("c", "db", "three", nil)])
        XCTAssertEqual(Scan.answerSummary(grouped), "1 thing across 1 session.")
    }

    func testSaysSoPlainlyWhenNothingWasShown() {
        XCTAssertEqual(Scan.answerSummary(Scan.groupBySession([stop("a", "api", "one", nil)])), "Nothing was shown.")
    }
}
