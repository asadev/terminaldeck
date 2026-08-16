/**
 * The four things Asad asked for about the connection indicator, one test each,
 * and nothing here sleeps.
 *
 * He specified this one precisely, which is rare enough to be worth quoting in
 * full next to the tests that hold it:
 *
 * > *"when we just open the application, it shows connecting actually — let it
 * > just not show that kind of yellow thing. Let it give a few seconds; after
 * > five seconds if it is still not connected, then show. Otherwise it will just
 * > load, so they will not even feel that it takes time for connecting. And no
 * > need to show connected all the time. Also if it gets disconnected for more
 * > than five seconds, then start showing connecting, so they feel like okay it's
 * > trying to connect. But less than five seconds — if it's disconnected less
 * > than five seconds, let's not show anything."*
 *
 * ## Why the clock is a variable
 *
 * A test that proved a five-second rule by waiting five seconds would add five
 * seconds to every future run of this suite, and a test that proved it by
 * shortening the rule to fifty milliseconds would be proving a different rule.
 * `ConnectionGrace` takes the instant as a parameter and `ConnectionNotice` takes
 * a clock and a scheduler, so the whole thing runs in microseconds against a
 * `Date` this file makes up — and the number under test is the number that ships.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class ConnectionGraceTests: XCTestCase {

    // MARK: - Fixtures

    private let launch = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        launch.addingTimeInterval(seconds)
    }

    private var connecting: ConnectionState {
        ConnectionState(phase: .connecting, detail: "Connecting…", retryAt: nil, attempts: 0)
    }

    private var connected: ConnectionState {
        ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
    }

    private var reconnecting: ConnectionState {
        ConnectionState(phase: .waiting, detail: "Connection lost.", retryAt: nil, attempts: 1)
    }

    // MARK: - The four cases

    /**
     * **1. Launch shows nothing for five seconds.**
     *
     * This is the one he was looking at when he said it: the app opens, the
     * transport says `.offline` and then `.connecting` within a frame of each
     * other, and the old code drew a yellow bar for both. Nothing may be drawn
     * until the fifth second, and at the fifth second — if it is still not
     * connected — the state appears.
     */
    func testALaunchSaysNothingForFiveSecondsAndThenSaysWhatIsHappening() {
        var grace = ConnectionGrace()
        grace.observe(.offline, at: launch)
        grace.observe(connecting, at: at(0.05))

        XCTAssertFalse(grace.isShowing(at: launch), "the first frame must be quiet")
        XCTAssertFalse(grace.isShowing(at: at(1)))
        XCTAssertFalse(grace.isShowing(at: at(4.9)),
                       "four and a bit seconds of dialling is not worth a yellow bar")
        XCTAssertTrue(grace.isShowing(at: at(5)),
                      "still not connected after five seconds — now say so")
        XCTAssertTrue(grace.isShowing(at: at(30)))
    }

    /**
     * **2. Connected says nothing at all, ever.**
     *
     * *"no need to show connected all the time."* There is no timer here and no
     * later moment at which a connected phone starts announcing itself — the
     * pill's own accessibility label still carries the truth for anyone who asks
     * (see `ConnectionPillTests`), but the screen stays quiet.
     */
    func testAConnectedPhoneNeverShowsAnything() {
        var grace = ConnectionGrace()
        grace.observe(connecting, at: launch)
        grace.observe(connected, at: at(0.8))

        XCTAssertFalse(grace.isShowing(at: at(0.8)))
        XCTAssertFalse(grace.isShowing(at: at(5)), "five seconds of being connected is still connected")
        XCTAssertFalse(grace.isShowing(at: at(3600)))
        XCTAssertNil(grace.deadline(at: at(0.8)), "nothing is pending, so nothing needs waking up")
    }

    /**
     * **3. A drop shorter than five seconds shows nothing.**
     *
     * This is the point of the whole feature. A carrier NAT reclaims a socket,
     * the reconnect takes two seconds, and the person reading their agent's
     * output never learns that it happened — because there is nothing they could
     * have done about it and nothing they needed to know.
     */
    func testADropShorterThanFiveSecondsIsInvisible() {
        var grace = ConnectionGrace()
        grace.observe(connected, at: launch)

        grace.observe(reconnecting, at: at(10))
        XCTAssertFalse(grace.isShowing(at: at(10)))
        XCTAssertFalse(grace.isShowing(at: at(12)))

        grace.observe(connected, at: at(13))
        XCTAssertFalse(grace.isShowing(at: at(13)))
        // And the clock is genuinely reset rather than merely hidden: the moment
        // that would have been the deadline passes without anything appearing.
        XCTAssertFalse(grace.isShowing(at: at(15)),
                       "a drop that ended must not surface five seconds after it started")
        XCTAssertFalse(grace.isShowing(at: at(60)))
    }

    /**
     * **4. A drop longer than five seconds says it is trying.**
     *
     * *"if it gets disconnected for more than five seconds, then start showing
     * connecting, so they feel like okay it's trying to connect."* He said
     * "connected" once in the middle of that sentence and plainly meant
     * "connecting"; the state on screen is the transport's own, which in this
     * case reads *Reconnecting*.
     */
    func testADropLongerThanFiveSecondsStartsSayingSo() {
        var grace = ConnectionGrace()
        grace.observe(connected, at: launch)
        grace.observe(reconnecting, at: at(10))

        XCTAssertFalse(grace.isShowing(at: at(14.9)))
        XCTAssertTrue(grace.isShowing(at: at(15)))
        XCTAssertEqual(reconnecting.label, "Reconnecting",
                       "what appears has to read as an attempt in progress, not as a verdict")

        // …and it goes away again the moment the socket is back, without a
        // second grace period on the way out.
        grace.observe(connected, at: at(20))
        XCTAssertFalse(grace.isShowing(at: at(20)))
    }

    // MARK: - The cases that would have broken the four above

    /**
     * A reconnect walks through several states, and none of them may restart the
     * clock.
     *
     * This is the bug the rule would naturally have: `offline → connecting →
     * waiting → connecting → waiting` arrives every couple of hundred
     * milliseconds while a machine is unreachable, and a grace period that began
     * again on each one would never expire. The outage would be silent forever,
     * which is the opposite of the fourth case.
     */
    func testAFlappingReconnectDoesNotKeepRestartingTheClock() {
        var grace = ConnectionGrace()
        grace.observe(connected, at: launch)

        grace.observe(.offline, at: at(1))
        grace.observe(connecting, at: at(1.5))
        grace.observe(reconnecting, at: at(2.5))
        grace.observe(connecting, at: at(4))
        grace.observe(reconnecting, at: at(5.5))

        XCTAssertEqual(grace.unsettledSince, at(1), "the earliest moment, not the latest")
        XCTAssertTrue(grace.isShowing(at: at(6)),
                      "five seconds of trying is five seconds of trying, however many states it took")
    }

    /**
     * A refused credential is not a wait, so it is not delayed.
     *
     * Nothing is retrying in `.rejected` or `.incompatible` — no attempt is
     * scheduled and none would help — so five seconds of silence there is not
     * "wait and see", it is five seconds of withholding the only thing the person
     * can act on.
     */
    func testAFinalAnswerIsShownImmediately() {
        var grace = ConnectionGrace()
        grace.observe(connected, at: launch)

        let rejected = ConnectionState(phase: .rejected, detail: "This device was removed.",
                                       retryAt: nil, attempts: 0)
        grace.observe(rejected, at: at(10))
        XCTAssertTrue(grace.isShowing(at: at(10)), "a verdict is not a wait")
        XCTAssertNil(grace.deadline(at: at(10)), "already showing, so nothing is pending")

        let incompatible = ConnectionState(phase: .incompatible, detail: "Version mismatch.",
                                           retryAt: nil, attempts: 0)
        var second = ConnectionGrace()
        second.observe(incompatible, at: launch)
        XCTAssertTrue(second.isShowing(at: launch))
    }

    /**
     * `.online` with `verified == false` is doubt, and doubt is unsettled.
     *
     * `ConnectionState.verified` exists because a phone that was suspended in a
     * pocket comes back holding `.online` against a socket that died twenty
     * minutes ago — the relay was measured reporting no guest attached while the
     * app showed *Connected*. Counting it as settled here would put the grace
     * period on the wrong side of exactly that bug: nothing would ever be drawn,
     * because the state says online.
     */
    func testAnUnverifiedConnectionIsNotTreatedAsConnected() {
        var grace = ConnectionGrace()
        var checking = connected
        checking.verified = false

        grace.observe(checking, at: launch)
        XCTAssertEqual(checking.label, "Checking")
        XCTAssertFalse(grace.isShowing(at: at(4.9)), "a probe that answers quickly is invisible")
        XCTAssertTrue(grace.isShowing(at: at(5)), "a probe that does not answer is worth saying")

        // A probe that comes back inside the window takes it away again.
        grace.observe(connected, at: at(2))
        XCTAssertFalse(grace.isShowing(at: at(9)))
    }

    /// The deadline is the single future moment the answer changes on its own,
    /// which is what lets the driver be one sleep rather than a poll.
    func testTheDeadlineIsTheOnlyMomentWorthWakingUpFor() {
        var grace = ConnectionGrace()
        XCTAssertNil(grace.deadline(at: launch), "nothing has happened yet")

        grace.observe(connecting, at: launch)
        XCTAssertEqual(grace.deadline(at: launch), at(5))
        XCTAssertEqual(grace.deadline(at: at(3)), at(5), "the deadline is absolute, not a countdown")
        XCTAssertNil(grace.deadline(at: at(5)), "it has already happened")

        grace.observe(connected, at: at(2))
        XCTAssertNil(grace.deadline(at: at(2)), "settled, so nothing is coming")
    }

    // MARK: - The driver

    /**
     * A clock and a timer this test owns, so five seconds can pass without five
     * seconds passing.
     */
    private final class FakeClock {
        var now: Date

        init(_ start: Date) { now = start }

        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    @MainActor
    private final class ManualScheduler: NoticeScheduler {
        private(set) var delay: TimeInterval?
        private var body: (() -> Void)?

        func schedule(after delay: TimeInterval, _ body: @escaping () -> Void) {
            self.delay = delay
            self.body = body
        }

        func cancel() {
            delay = nil
            body = nil
        }

        /// Be the timer. Synchronous on purpose: nothing in this file awaits.
        func fire() {
            let pending = body
            cancel()
            pending?()
        }
    }

    /**
     * The driver asks for exactly one wake-up, at the deadline, and flips when it
     * arrives.
     *
     * The three states it walks through here — offline, connecting, waiting — are
     * one wake-up between them, not three. A driver that scheduled per state
     * would still produce the right answer and would wake a sleeping radio four
     * times to do it.
     */
    func testTheDriverSchedulesOneWakeUpAndFlipsAtIt() {
        let clock = FakeClock(launch)
        let scheduler = ManualScheduler()
        let notice = ConnectionNotice(now: { clock.now }, scheduler: scheduler)

        notice.observe(.offline)
        XCTAssertFalse(notice.isShowing)
        XCTAssertEqual(scheduler.delay, 5)

        clock.advance(1)
        notice.observe(connecting)
        XCTAssertFalse(notice.isShowing)
        XCTAssertEqual(scheduler.delay, 4, "the deadline did not move, so the wait got shorter")

        clock.advance(4)
        scheduler.fire()
        XCTAssertTrue(notice.isShowing)
        XCTAssertNil(scheduler.delay, "showing already — there is nothing left to wake up for")
    }

    /// Connecting inside the window cancels the wake-up rather than letting it
    /// fire into a connected app.
    func testTheDriverCancelsItsWakeUpWhenTheSocketComesBack() {
        let clock = FakeClock(launch)
        let scheduler = ManualScheduler()
        let notice = ConnectionNotice(now: { clock.now }, scheduler: scheduler)

        notice.observe(connecting)
        XCTAssertEqual(scheduler.delay, 5)

        clock.advance(2)
        notice.observe(connected)
        XCTAssertFalse(notice.isShowing)
        XCTAssertNil(scheduler.delay, "a timer left armed here is a yellow bar over a working app")
    }

    /**
     * Coming back from the background recomputes rather than trusting the timer.
     *
     * A suspended app runs no timers. A phone that went into a pocket connected
     * and came out disconnected has a wake-up that was due two minutes ago and
     * has not happened, so `refresh` is what notices — and `DeckModel.resume`
     * calls it on every machine for exactly this reason.
     */
    func testRefreshCatchesUpOnADeadlineThatPassedWhileTheAppWasAsleep() {
        let clock = FakeClock(launch)
        let scheduler = ManualScheduler()
        let notice = ConnectionNotice(now: { clock.now }, scheduler: scheduler)

        notice.observe(reconnecting)
        XCTAssertFalse(notice.isShowing)

        // Two minutes in a pocket. The scheduler never fired.
        clock.advance(120)
        XCTAssertFalse(notice.isShowing, "nothing has asked yet")

        notice.refresh()
        XCTAssertTrue(notice.isShowing)
    }
}
