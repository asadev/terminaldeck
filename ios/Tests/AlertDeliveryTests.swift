/**
 * The two pieces between "something happened" and "the person knows": the tap
 * that comes back, and the half-minute of life after the phone goes in a pocket.
 *
 * Neither is about what is *worth* saying — that is `SessionAlertsTests`. These
 * are about the plumbing being there when it is needed, and both are here
 * because their failure mode is silence: a notification tapped on a locked phone
 * that opens the app on the wrong screen, and an assertion that was never taken
 * so nothing was listening when the session finished.
 */

import UIKit
import XCTest
@testable import TerminalDeck

@MainActor
final class AlertDeliveryTests: XCTestCase {

    // MARK: - The tap that comes back

    /// A fresh router per case. The shared one is a singleton because the app
    /// delegate cannot reach the model any other way; the *type* is testable
    /// without it, which is the point of it having no other state.
    private func router() -> NotificationRouter {
        let router = NotificationRouter.shared
        router.open = nil
        return router
    }

    private let session = "sess-bc2dab3e94a2"
    private let host = "M9G95TNJT64Q928VW3HVRYDR8J"

    func testATapOpensTheSessionItWasAbout() {
        let router = router()
        var opened: (String, String)?
        router.open = { host, session in opened = (host, session) }

        router.deliver(userInfo: [NotificationRouter.hostKey: host,
                                  NotificationRouter.sessionKey: session])

        XCTAssertEqual(opened?.0, host)
        XCTAssertEqual(opened?.1, session)
    }

    /**
     * A tap that arrives before the app has wired itself up is kept.
     *
     * This is the normal case rather than the edge one: a notification tapped
     * while the app is **not running** launches it, and the delegate is handed
     * the response during launch — before the root view's `task` has run. A
     * router that dropped it would open the app on the session list and leave
     * somebody guessing which machine had been asking.
     */
    func testATapThatArrivesBeforeTheAppIsReadyIsNotLost() {
        let router = router()

        router.deliver(userInfo: [NotificationRouter.hostKey: host,
                                  NotificationRouter.sessionKey: session])

        var opened: (String, String)?
        router.open = { host, session in opened = (host, session) }

        XCTAssertEqual(opened?.0, host, "the tap should have been delivered as soon as it could be")
        XCTAssertEqual(opened?.1, session)
    }

    /// And it is delivered once. A pending tap that fired again on every later
    /// assignment would reopen a session somebody had navigated away from.
    func testAKeptTapIsDeliveredOnlyOnce() {
        let router = router()
        router.deliver(userInfo: [NotificationRouter.hostKey: host,
                                  NotificationRouter.sessionKey: session])

        var count = 0
        router.open = { _, _ in count += 1 }
        router.open = { _, _ in count += 1 }

        XCTAssertEqual(count, 1)
    }

    /// The payload is this app's own, and it is still checked. It has been
    /// round-tripped through the system, and `DeckModel.open` refuses a
    /// malformed id anyway — this is the same rule one layer earlier.
    func testAMalformedPayloadOpensNothing() {
        let router = router()
        var opened = false
        router.open = { _, _ in opened = true }

        router.deliver(userInfo: [:])
        router.deliver(userInfo: [NotificationRouter.hostKey: host])
        router.deliver(userInfo: [NotificationRouter.hostKey: host,
                                  NotificationRouter.sessionKey: "not a session id!"])
        router.deliver(userInfo: [NotificationRouter.hostKey: "",
                                  NotificationRouter.sessionKey: session])

        XCTAssertFalse(opened)
    }

    // MARK: - The half-minute after the phone goes down

    func testTheGraceIsHeldAndGivenBack() {
        let grace = BackgroundGrace()
        XCTAssertFalse(grace.isHeld)

        grace.begin()
        XCTAssertTrue(grace.isHeld)

        grace.end()
        XCTAssertFalse(grace.isHeld)
    }

    /**
     * Twice is once.
     *
     * Not tidiness: a second assertion taken while the first is held leaks the
     * first, and iOS kills an app that is still holding one when the time runs
     * out. Two scene-phase changes in a row is an ordinary thing to happen.
     */
    func testAskingTwiceDoesNotLeakAnAssertion() {
        let grace = BackgroundGrace()
        grace.begin()
        grace.begin()

        grace.end()

        XCTAssertFalse(grace.isHeld, "one end should have released everything that was taken")
    }

    func testEndingWithoutBeginningIsHarmless() {
        let grace = BackgroundGrace()
        grace.end()
        XCTAssertFalse(grace.isHeld)
    }
}
