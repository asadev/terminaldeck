/**
 * One finger, on a terminal, scrolls.
 *
 * This is the only test in the suite that can make that claim, and it exists
 * because the ones that could not were green the whole time it was false.
 * `TerminalGesturesTests` asks the delegate which recogniser may begin and gets
 * sensible answers to every question; what it cannot do is put a finger on the
 * glass, and the bug was entirely in what a finger did. Asad reported it in
 * three consecutive recordings — *"if I scroll, it's coming blue. It's not
 * scrolling, it's selecting"* — against builds whose gesture unit tests all
 * passed.
 *
 * ## The gesture that was broken, exactly
 *
 * A finger that **rests before it moves**. Not a flick: a flick always worked,
 * because it crosses the long press's allowable movement long before the press
 * can fire. What failed is the way somebody scrolls a wall of text they are
 * reading — put the finger down, look for a second, then drag. Measured in the
 * Simulator against a live session: 0.65 s of stillness then a slow drag
 * selected eleven lines, raised the copy callout and the keyboard, and moved the
 * terminal by nothing at all.
 *
 * So the gesture below is that one, deliberately, with the hold written as a
 * constant that is *shorter* than `TerminalGestures.selectionHold`. If somebody
 * lowers that constant back towards half a second, this goes red.
 *
 * The mirror-image test — a deliberate press that *does* select — is not here,
 * and the block halfway down this file says why with the measurements. Short
 * version: XCUITest cannot hold a finger still for longer than about six tenths
 * of a second, whatever it is asked for.
 *
 * ## What it asserts, and why the callout is the witness
 *
 * Two things: the terminal **moved**, and nothing is **selected**. The second is
 * the one that names the bug, and a UI test cannot read the terminal's pixels or
 * ask SwiftTerm for its selection — the terminal is one opaque element. What it
 * can see is the system edit menu, which this app puts up the instant a
 * selection gesture ends (`TerminalGestures.offerCopy`). A "Copy" callout over
 * the terminal *is* a selection, visible to the accessibility tree. No callout
 * and a screen that changed is a scroll.
 *
 * ## It needs a real desktop
 *
 * There is no fixture behind it. Start `ios/Harness/run.sh host`, pair the phone
 * with the six digits in `ios/Harness/.build/pairing.txt`, and it will run;
 * without that it skips, like every other live suite here. A session with more
 * scrollback than screen is required for the same reason — a `UIScrollView` with
 * nothing to scroll refuses the pan, and then this would be measuring the wrong
 * thing.
 */

import XCTest

final class TerminalScrollUITests: XCTestCase {

    /// How long the finger rests before it drags. Comfortably longer than a real
    /// hesitation and shorter than `TerminalGestures.selectionHold`, which is the
    /// relationship under test.
    private static let hesitation: TimeInterval = 0.65

    private var app: XCUIApplication!
    private static var reachable: Bool?

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 10)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    private static let notRunning =
        "This phone is not connected to a running harness. Start ios/Harness/run.sh host, "
        + "then type the six digits in ios/Harness/.build/pairing.txt into the pairing field "
        + "and approve the device."

    func testAFingerThatRestsBeforeItMovesStillScrolls() throws {
        let terminal = try openATerminal()
        // Let the replay land and the view settle. A screenshot taken while the
        // scrollback is still arriving would differ from the next one for a
        // reason that has nothing to do with the gesture.
        sleep(3)
        let before = XCUIScreen.main.screenshot().pngRepresentation

        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: Self.hesitation, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0)
        sleep(2)

        XCTAssertFalse(isSelecting, "the drag selected instead of scrolling — the whole bug")
        XCTAssertNotEqual(before, XCUIScreen.main.screenshot().pngRepresentation,
                          "the terminal did not move")
    }

    /// And a finger put down on content that is still coasting stops it, rather
    /// than selecting the line it landed on.
    func testAFingerOnCoastingContentDoesNotSelect() throws {
        let terminal = try openATerminal()
        sleep(3)

        // Flick hard enough to leave it decelerating, then press into it.
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.01,
                   thenDragTo: terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: Self.hesitation + 0.4)
        sleep(1)

        XCTAssertFalse(isSelecting, "a finger on moving content means stop, not select")
    }

    /*
     * ------------------------------------------------------------------
     * The test that is deliberately not here: "a long press still selects"
     * ------------------------------------------------------------------
     *
     * It was written, it failed, and it failed for a reason that has nothing to
     * do with the app: **XCUITest cannot synthesise a stationary hold longer
     * than about six tenths of a second.** Asking for more does not produce
     * more. Bisected against a live session, one variable at a time:
     *
     *   selectionHold  press(forDuration:thenDragTo:)   selects?
     *   0.5            0.65 s                            yes
     *   0.5            1.1 s                             yes
     *   0.7            1.1 s                             no
     *   0.7            2.0 s                             no
     *   0.75           2.0 s                             no
     *
     * The only edit between the passing and failing rows is the constant, so the
     * selection path itself is intact — a press that reaches the threshold still
     * selects the word, extends on the drag and offers the callout, exactly as
     * it did at 0.5. What moved is the threshold, past what the tool can reach.
     *
     * Two things guard it instead, and neither pretends to be this test:
     * `TerminalGesturesTests.testTheSelectionPressIsLongerThanAHesitation`
     * refuses a hold above 0.8 s so it stays a gesture a hand can make, and the
     * gesture is on the list of things to try by hand on a device before a
     * release (`ios/WhatToTest.md`). Writing a green test here by lowering the
     * constant until the tool could reach it would be testing the tool.
     */

    // MARK: - Reading the screen

    /**
     * Whether a selection is on the terminal, as far as anything outside the app
     * can tell.
     *
     * The system callout. `offerCopy` puts it up when a selection gesture ends
     * and it is the only part of a selection that reaches the accessibility
     * tree — the terminal itself is one opaque element with no text in it. Both
     * spellings are checked because the callout is a `UIMenuController` and
     * lands in the tree as menu items on some releases and as plain buttons on
     * others.
     */
    private var isSelecting: Bool {
        for name in ["Copy", "Select All"] {
            if app.menuItems[name].exists || app.buttons[name].exists { return true }
        }
        return false
    }

    /**
     * Open a session and wait for it to stop printing.
     *
     * The wait is not politeness. Attaching sends this phone's viewport, the
     * desktop resizes the pty, and whatever is running repaints — so a session
     * is `working` for a second or so *because this test opened it*. That
     * matters here for a reason specific to SwiftTerm: with mouse reporting
     * allowed, `linefeed` calls `selection.selectNone()`, so a line of output
     * silently destroys a selection a gesture had just made. Measured: the same
     * long press selected and showed the callout on an idle session and produced
     * nothing at all on a session that was still repainting.
     *
     * The header is the status, so waiting for it to stop saying `working` is
     * waiting for the terminal to be still.
     *
     * **Not `idle` specifically, and that correction cost the first real run of
     * this file.** It was written against `ios/Harness/run.sh host`, whose
     * sessions sit at `idle`, and it failed on both cases against the product's
     * own host with *"the session never stopped printing"* while the screen
     * plainly showed a settled shell — because the desktop's classifier had
     * called a shell sitting at its prompt `waiting`, which is a fourth word this
     * assertion had never heard of. A shell at a prompt genuinely is waiting for
     * somebody, so the classification is defensible and is the desktop's
     * business; what was wrong was a precondition that named one of the three
     * settled statuses and treated the other two as failure.
     *
     * So the wait is for the absence of `working`, which is the only status that
     * means output is arriving — and output is the thing that matters here, for a
     * reason specific to SwiftTerm: with mouse reporting allowed, `linefeed`
     * calls `selection.selectNone()`, so a line of output silently destroys a
     * selection a gesture had just made.
     */
    private func openATerminal() throws -> XCUIElement {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "no session rows arrived")
        rows.firstMatch.tap()

        let terminal = app.descendants(matching: .any)["terminal.view"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 15), "the terminal screen never appeared")
        XCTAssertTrue(waitUntilSettled(timeout: 30),
                      "the session never stopped printing; output clears a selection as it arrives")
        return terminal
    }

    /**
     * Whether the session header has stopped saying `working`.
     *
     * A poll rather than `waitForExistence` on a label, because what is being
     * waited for is a word going *away* — and `working` is drawn by the same
     * `staticText` that later draws `waiting`, `input` or `idle`, so there is no
     * element whose appearance marks the moment.
     */
    private func waitUntilSettled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for settled in ["idle", "waiting", "input"] where app.staticTexts[settled].exists {
                return true
            }
            usleep(500_000)
        }
        return false
    }

    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }
}
