/**
 * The hold that keeps a replay off the screen, driven by a fake clock.
 *
 * Every timer this type sets goes through its injected scheduler, so a test
 * fires them itself and nothing here waits. That is the whole reason the policy
 * is a type of its own rather than four fields on `TerminalBridge` — a `UIView`
 * cannot be reasoned about without a simulator, and this can.
 *
 * The property the last case pins is the one that matters most: **this can only
 * ever delay a terminal, never hide one.**
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class TerminalBackfillTests: XCTestCase {

    /// A scheduler that hands the test the blocks instead of running them.
    private final class FakeClock {
        private(set) var pending: [(delay: TimeInterval, work: () -> Void, cancelled: Bool)] = []

        var schedule: TerminalBackfill.Scheduler {
            { [weak self] delay, work in
                guard let self else { return {} }
                let at = self.pending.count
                self.pending.append((delay, work, false))
                return { [weak self] in
                    guard let self, at < self.pending.count else { return }
                    self.pending[at].cancelled = true
                }
            }
        }

        /// Run the newest live block scheduled for `delay`, the way the clock would.
        func fire(after delay: TimeInterval) {
            guard let at = pending.lastIndex(where: { $0.delay == delay && !$0.cancelled }) else {
                return XCTFail("nothing was scheduled for \(delay)s")
            }
            pending[at].cancelled = true
            pending[at].work()
        }

        var liveCount: Int { pending.filter { !$0.cancelled }.count }
    }

    private struct Screen {
        var written: [String] = []
        var visible = true
        var scrolled = 0
    }

    private func make(_ clock: FakeClock, _ screen: Screenshot) -> TerminalBackfill {
        TerminalBackfill(
            write: { screen.value.written.append($0) },
            scrollToBottom: { screen.value.scrolled += 1 },
            setVisible: { screen.value.visible = $0 },
            schedule: clock.schedule,
        )
    }

    /// A box, so the closures above write somewhere the test can read.
    private final class Screenshot {
        var value = Screen()
    }

    func testTheScreenIsHiddenWhileTheBacklogArrivesAndShownOnceAtTheBottom() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        XCTAssertFalse(screen.value.visible, "the surface has to be hidden before the first chunk")

        backfill.feed("one", replay: true)
        backfill.feed("two", replay: true)
        XCTAssertEqual(screen.value.written, [], "nothing may reach the terminal while it is held")
        XCTAssertFalse(screen.value.visible)

        // Silence: the far machine has finished replaying.
        clock.fire(after: TerminalBackfill.quiet)

        XCTAssertEqual(screen.value.written, ["onetwo"], "the backlog goes in as one write")
        XCTAssertEqual(screen.value.scrolled, 1)
        XCTAssertTrue(screen.value.visible)
    }

    func testLiveOutputEndsTheHoldAndArrivesAfterTheBacklog() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        backfill.feed("history", replay: true)
        backfill.feed("$ now", replay: false)

        // Order is the point: what was held is older than the frame that ended
        // the hold, so it cannot be appended after it.
        XCTAssertEqual(screen.value.written, ["history", "$ now"])
        XCTAssertTrue(screen.value.visible)
        XCTAssertFalse(backfill.isHolding)
    }

    func testAfterTheHoldEndsBytesGoStraightThrough() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        clock.fire(after: TerminalBackfill.limit)
        screen.value.written.removeAll()

        backfill.feed("typed", replay: false)
        backfill.feed("more", replay: true)
        XCTAssertEqual(screen.value.written, ["typed", "more"],
                       "a replay frame after the hold is still output; it is not dropped")
    }

    func testEachChunkPostponesTheSilenceButNotTheCeiling() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        backfill.feed("a", replay: true)
        backfill.feed("b", replay: true)
        backfill.feed("c", replay: true)

        // Two quiet timers were replaced rather than left to fire: the live ones
        // are the ceiling and the newest silence.
        XCTAssertEqual(clock.liveCount, 2)
        clock.fire(after: TerminalBackfill.quiet)
        XCTAssertEqual(screen.value.written, ["abc"])
    }

    func testTheCeilingRevealsWhateverHasArrived() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        backfill.feed("half a backlog", replay: true)
        // Nothing else ever comes — a machine that stopped mid-replay, a socket
        // that went quiet without closing.
        clock.fire(after: TerminalBackfill.limit)

        XCTAssertTrue(screen.value.visible, "the ceiling is what makes this a delay rather than a disappearance")
        XCTAssertEqual(screen.value.written, ["half a backlog"])
    }

    func testStoppingPutsTheSurfaceBack() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        backfill.feed("held", replay: true)
        backfill.stop()

        // The bridge is reused when the session is opened again, so a teardown
        // that left it at alpha 0 would be a terminal that never comes back.
        XCTAssertTrue(screen.value.visible)
        XCTAssertFalse(backfill.isHolding)
    }

    func testReleasingTwiceWritesOnce() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        backfill.feed("once", replay: true)
        backfill.release()
        backfill.release()

        XCTAssertEqual(screen.value.written, ["once"])
        XCTAssertEqual(screen.value.scrolled, 1)
    }

    func testASecondAttachStartsItsOwnHold() {
        let clock = FakeClock()
        let screen = Screenshot()
        let backfill = make(clock, screen)

        backfill.begin()
        backfill.feed("first", replay: true)
        clock.fire(after: TerminalBackfill.quiet)

        backfill.begin()
        XCTAssertFalse(screen.value.visible, "a re-attach replays again, so it hides again")
        backfill.feed("second", replay: true)
        clock.fire(after: TerminalBackfill.quiet)
        XCTAssertEqual(screen.value.written, ["first", "second"])
    }
}
