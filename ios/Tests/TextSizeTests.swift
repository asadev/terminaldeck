/**
 * The terminal's text size, and the thing that makes it worth having: the
 * column count really changes.
 *
 * A zoom would have been easy and useless — the far end would still be writing
 * eighty columns into fifty. So the test that matters here is the one against a
 * real `TerminalBridge`: smaller text has to produce *more columns*, which is
 * what makes an agent's table stop wrapping. Everything else is the arithmetic
 * around it, which is worth pinning because it is what stops a pinch putting a
 * one-point terminal on somebody's screen.
 *
 * ## And the second thing that matters, added 2026-08-26
 *
 * > *"this bigger and smaller should be going to inside the settings page for
 * > the all of the terminals with one setting we can just change this for
 * > overall appearance page."*
 *
 * The controls moved to Settings → Appearance, which turned a claim that had
 * always been half true into one this file has to hold up: **one setting, every
 * terminal, including the ones already open.** See the last two cases.
 */

import UIKit
import XCTest
@testable import TerminalDeck

@MainActor
final class TextSizeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "terminaldeck.textSize.v1")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "terminaldeck.textSize.v1")
        super.tearDown()
    }

    // MARK: - The arithmetic

    func testTheBoundsHold() {
        XCTAssertEqual(TextSize.clamp(2), TextSize.minimum)
        XCTAssertEqual(TextSize.clamp(400), TextSize.maximum)
        XCTAssertEqual(TextSize.clamp(-3), TextSize.minimum)
    }

    /// Whole points only. Two sizes that look identical and behave differently
    /// is the thing a fractional size would buy.
    func testASizeIsAWholeNumberOfPoints() {
        XCTAssertEqual(TextSize.clamp(12.4), 12)
        XCTAssertEqual(TextSize.clamp(12.6), 13)
    }

    func testAPinchScalesWhereItStartedFrom() {
        XCTAssertEqual(TextSize.scaled(12, by: 1.5), 18)
        XCTAssertEqual(TextSize.scaled(12, by: 0.5), 9)
        // And a spread past the top lands on the top rather than anywhere else.
        XCTAssertEqual(TextSize.scaled(12, by: 8), TextSize.maximum)
    }

    func testTheStepsStopAtTheEnds() {
        XCTAssertEqual(TextSize.larger(TextSize.maximum), TextSize.maximum)
        XCTAssertEqual(TextSize.smaller(TextSize.minimum), TextSize.minimum)
        XCTAssertFalse(TextSize.canGoLarger(TextSize.maximum))
        XCTAssertFalse(TextSize.canGoSmaller(TextSize.minimum))
        XCTAssertTrue(TextSize.canGoLarger(TextSize.standard))
        XCTAssertTrue(TextSize.canGoSmaller(TextSize.standard))
    }

    func testItStartsWhereItAlwaysDrewAndRemembersAChange() {
        XCTAssertEqual(TextSize.stored, TextSize.standard)

        TextSize.save(15)

        XCTAssertEqual(TextSize.stored, 15)
    }

    /// A stored value from a build with different bounds — or a corrupted
    /// defaults file — must not produce a one-point terminal.
    func testAStoredValueOutsideTheBoundsIsBroughtBackIn() {
        UserDefaults.standard.set(1.0, forKey: "terminaldeck.textSize.v1")
        XCTAssertEqual(TextSize.stored, TextSize.minimum)
    }

    func testTheLabelIsAMeasurement() {
        XCTAssertEqual(TextSize.label(12), "12 pt")
        XCTAssertEqual(TextSize.label(9.4), "9 pt")
    }

    // MARK: - Against a real terminal

    private func bridge() -> TerminalBridge {
        let bridge = TerminalBridge()
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()
        return bridge
    }

    /**
     * The whole point of the feature, in one assertion.
     *
     * Smaller text is more columns, and the columns are what the far end is told
     * about — so this is also the test that says the session really reflows
     * rather than the pixels being magnified.
     */
    func testSmallerTextIsMoreColumns() {
        let bridge = bridge()
        let before = bridge.view.getTerminal().getDims().cols

        bridge.setTextSize(TextSize.minimum)

        let after = bridge.view.getTerminal().getDims().cols
        XCTAssertGreaterThan(after, before,
                             "\(TextSize.minimum)pt gave \(after) columns and \(before) was the start")
    }

    func testLargerTextIsFewerColumns() {
        let bridge = bridge()
        let before = bridge.view.getTerminal().getDims().cols

        bridge.setTextSize(TextSize.maximum)

        XCTAssertLessThan(bridge.view.getTerminal().getDims().cols, before)
    }

    /// The far end has to hear about it, or the phone is drawing a width the
    /// session does not know it has.
    func testTheNewSizeIsReportedForTheWire() {
        let bridge = bridge()
        var reported: (Int, Int)?
        bridge.onResize = { cols, rows in reported = (cols, rows) }

        bridge.setTextSize(16)

        // SwiftTerm reports a size change to its delegate on the next turn of
        // the main run loop, which is where `sizeChanged` dispatches it.
        let waited = expectation(description: "resize reported")
        DispatchQueue.main.async { waited.fulfill() }
        wait(for: [waited], timeout: 2)

        XCTAssertEqual(reported?.0, bridge.view.getTerminal().getDims().cols)
        XCTAssertEqual(reported?.1, bridge.view.getTerminal().getDims().rows)
    }

    /**
     * Setting the size it already has must do nothing at all.
     *
     * Not an optimisation. Assigning `font` makes SwiftTerm soft-reset the
     * emulator, which drops application-cursor mode — so a redundant set would
     * make the arrow keys on the key bar send the wrong bytes inside vim until
     * the program repainted.
     */
    func testSettingTheSameSizeIsNotAReset() {
        let bridge = bridge()
        // DECCKM, which every full-screen program sets.
        bridge.feed("\u{1b}[?1h")
        XCTAssertTrue(bridge.view.getTerminal().applicationCursor)

        bridge.setTextSize(bridge.textSize)

        XCTAssertTrue(bridge.view.getTerminal().applicationCursor,
                      "the terminal was reset by a size change that was not a change")
    }

    func testANewTerminalComesUpAtTheStoredSize() {
        TextSize.save(17)

        let bridge = bridge()

        XCTAssertEqual(bridge.textSize, 17)
        XCTAssertEqual(bridge.view.font.pointSize, 17)
    }

    func testATerminalBuiltBeforeTheChangeCatchesUp() {
        let bridge = bridge()
        XCTAssertEqual(bridge.textSize, TextSize.standard)

        TextSize.save(10)
        bridge.applyStoredTextSize()

        XCTAssertEqual(bridge.textSize, 10)
    }

    // MARK: - One setting, every terminal

    /**
     * *"one setting we can just change this for … all of them"* — and *all of
     * them* includes the sessions that are already open.
     *
     * This is the assertion that would have failed against what shipped before
     * the Appearance page. The size was stored per phone and always had been, so
     * a *new* terminal came up right; a terminal that already existed kept the
     * font it was handed until `applyStoredTextSize` was called on it, which
     * happened when the session was next opened. With the controls inside the
     * session's own menu that was invisible — you were looking at the terminal
     * you had just changed. With the controls in Settings it is the whole of the
     * experience: you set the size, you go back to what you were reading, and it
     * is the size it always was.
     *
     * **Two bridges, not one.** One would pass on the bridge that made the
     * change, which is exactly the case that never needed fixing. The claim is
     * that a phone with several sessions open has one size across all of them.
     */
    func testChangingTheSizeReachesEveryTerminalAlreadyOpen() {
        let one = bridge()
        let two = bridge()
        XCTAssertEqual(one.textSize, TextSize.standard)
        XCTAssertEqual(two.textSize, TextSize.standard)

        TextSize.save(16)

        // The observers are registered against the main queue, so the change may
        // land on this turn of the run loop or the next one depending on how
        // Foundation dispatches it. Spun rather than assumed — a fixed
        // `DispatchQueue.main.async` fence is ordered against one of those two
        // and not the other.
        settle { one.textSize == 16 && two.textSize == 16 }

        XCTAssertEqual(one.textSize, 16, "the first terminal did not follow the setting")
        XCTAssertEqual(two.textSize, 16, "the second terminal did not follow the setting")
        XCTAssertEqual(one.view.font.pointSize, 16)
        XCTAssertEqual(two.view.font.pointSize, 16)
    }

    /**
     * Saving the size it already has must not reach the terminals at all.
     *
     * The same reason `testSettingTheSameSizeIsNotAReset` exists, one layer up.
     * Assigning `font` soft-resets SwiftTerm's emulator and drops
     * application-cursor mode, so a broadcast on a write that changed nothing
     * would break the arrow keys in **every other open session** — a session
     * nobody was touching, from a stepper press that did nothing. `TextSize.save`
     * only announces a real change.
     */
    func testSavingTheSameSizeDoesNotResetOtherTerminals() {
        let bridge = bridge()
        // DECCKM, which every full-screen program sets.
        bridge.feed("\u{1b}[?1h")
        XCTAssertTrue(bridge.view.getTerminal().applicationCursor)

        TextSize.save(bridge.textSize)
        // Nothing to wait *for* — the point is that nothing arrives — so this is
        // long enough for a notification that was going to be delivered to have
        // been, and no longer.
        settle(0.2) { false }

        XCTAssertTrue(bridge.view.getTerminal().applicationCursor,
                      "a save that changed nothing still reset a terminal")
    }

    /// Turn the run loop until `done` or `timeout` has gone by. A fixed sleep
    /// would be either flaky or slow, and this suite has both a notification and
    /// SwiftTerm's own next-turn delegate call to wait on.
    private func settle(_ timeout: TimeInterval = 1, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
