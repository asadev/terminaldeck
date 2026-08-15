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
}
