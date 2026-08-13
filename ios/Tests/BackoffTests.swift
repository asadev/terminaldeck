/**
 * The reconnect schedule, tested by handing it a fake random rather than by
 * waiting — the same reason the browser client injects its clock.
 */

import XCTest
@testable import TerminalDeck

final class BackoffTests: XCTestCase {

    func testFirstDelayIsShortEnoughThatABlipIsInvisible() {
        // No jitter: the first wait is exactly the configured floor.
        XCTAssertEqual(backoffDelay(attempt: 0, random: { 0 }), 0.4, accuracy: 0.001)
    }

    func testDelayGrowsAndThenStops() {
        let delays = (0 ..< 12).map { backoffDelay(attempt: $0, random: { 0 }) }
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier, later)
        }
        XCTAssertEqual(delays.last!, 20, accuracy: 0.001)
    }

    func testJitterOnlyEverShortensADelay() {
        // Additive jitter would let a wait exceed the cap, and the cap is a
        // promise about the longest the app can look broken after the network
        // comes back.
        for attempt in 0 ..< 12 {
            let full = backoffDelay(attempt: attempt, random: { 0 })
            let jittered = backoffDelay(attempt: attempt, random: { 1 })
            XCTAssertLessThanOrEqual(jittered, full)
            XCTAssertLessThanOrEqual(jittered, 20)
        }
    }

    func testResetGoesBackToTheTop() {
        let backoff = Backoff(random: { 0 })
        _ = backoff.next()
        _ = backoff.next()
        _ = backoff.next()
        XCTAssertEqual(backoff.attempts, 3)
        backoff.reset()
        XCTAssertEqual(backoff.attempts, 0)
        XCTAssertEqual(backoff.next(), 0.4, accuracy: 0.001)
    }

    func testCloseReasonSaysSomethingDifferentBeforeAndAfterTheHandshake() {
        let normal = { (beforeReady: Bool) in
            CarrierClose(code: WireClose.normal, detail: nil, beforeReady: beforeReady)
        }
        XCTAssertNotEqual(closeReason(normal(false), greeted: true),
                          closeReason(normal(true), greeted: false))
        XCTAssertEqual(closeReason(CarrierClose(code: WireClose.policyViolation, detail: nil, beforeReady: false),
                                   greeted: true),
                       "The desktop refused this device.")
    }

    func testACarrierThatKnowsWhyItClosedIsBelievedOverTheCloseCode() {
        // The relay carrier knows that a close before the handshake means the
        // Mac is not attached to the relay; a close code cannot say that, and
        // guessing from 1006 would produce "check your wifi" for a Mac that is
        // asleep.
        let close = CarrierClose(code: -1, detail: "That Mac is not connected to the relay right now.",
                                 beforeReady: true)
        XCTAssertEqual(closeReason(close, greeted: false), close.detail)
    }
}
