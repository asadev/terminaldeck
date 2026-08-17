/**
 * Which gesture wins, and where a finger lands.
 *
 * Two things here are worth a test and neither is obvious from reading the code.
 *
 * **1. The reconciliation.** SwiftTerm adds recognisers of its own — a long
 * press that opens a menu, and a pan that extends a selection the moment one
 * exists — and the second of those competes with the scroll view's own pan for
 * a one-finger drag. Nothing decides that race, so the same gesture sometimes
 * scrolls and sometimes selects. `DeckTerminalView` refuses the foreign
 * recognisers, and "refuses" is a claim that can be checked by asking it.
 *
 * **2. The geometry.** A touch becomes a row and a column through a cell size
 * this module has to compute for itself, because SwiftTerm keeps its own copy
 * `internal`. If the two ever disagree by a point, selections land on the wrong
 * character — silently, and only for people with a different screen scale than
 * whoever last looked. So the computed cell is checked against the one public
 * number derived from SwiftTerm's own: `getOptimalFrameSize()`, which the
 * library returns as exactly `cellDimension × (cols, rows)`.
 */

import SwiftTerm
import UIKit
import XCTest
@testable import TerminalDeck

@MainActor
final class TerminalGesturesTests: XCTestCase {

    private func terminal() -> DeckTerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = DeckTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), font: font)
        view.layoutIfNeeded()
        return view
    }

    // MARK: - Geometry

    /**
     * The cell size this app computes is the cell size SwiftTerm is drawing
     * with — in both directions.
     *
     * `getOptimalFrameSize()` is the library's own `cellDimension × (cols, rows)`
     * and it is public, so dividing it back out recovers the number this module
     * is not allowed to read and compares it against the one this module works
     * out for itself. Within a tenth of a point: both sides snap to the pixel
     * grid, and this should not fail on the rounding of a rounding.
     *
     * If this ever goes red, selections are landing on the wrong character —
     * silently, and only on screens with a different scale from whoever last
     * looked at it.
     */
    func testTheComputedCellMatchesWhatSwiftTermIsDrawing() throws {
        let view = terminal()
        let dims = view.getTerminal().getDims()
        try XCTSkipIf(dims.cols == 0 || dims.rows == 0, "the terminal has not laid out")

        let optimal = view.getOptimalFrameSize()
        let ours = TerminalGeometry.cell(for: view.font)
        XCTAssertEqual(ours.width, optimal.width / CGFloat(dims.cols), accuracy: 0.1,
                       "a cell width that drifts puts every selection on the wrong column")
        XCTAssertEqual(ours.height, optimal.height / CGFloat(dims.rows), accuracy: 0.1,
                       "a cell height that drifts puts every selection on the wrong row")
    }

    /// A point maps to the character under it, and the first character is at the
    /// origin. Off by one here is off by one everywhere downstream.
    func testAPointBecomesTheCharacterUnderIt() {
        let view = terminal()
        let cell = TerminalGeometry.cell(for: view.font)

        XCTAssertEqual(TerminalGeometry.position(of: .zero, in: view), Position(col: 0, row: 0))
        let third = CGPoint(x: cell.width * 2.5, y: cell.height * 3.5)
        XCTAssertEqual(TerminalGeometry.position(of: third, in: view), Position(col: 2, row: 3))
    }

    /// A finger past the right-hand edge selects the last column rather than a
    /// column that does not exist — which is what a mid-rotation layout or a
    /// rubber-banded drag produces.
    func testAPointOffTheEdgeIsClamped() {
        let view = terminal()
        let columns = view.getTerminal().getDims().cols
        let far = CGPoint(x: 100_000, y: -50)
        let hit = TerminalGeometry.position(of: far, in: view)
        XCTAssertEqual(hit.col, max(0, columns - 1))
        XCTAssertEqual(hit.row, 0)
    }

    // MARK: - Which recogniser may begin

    /**
     * SwiftTerm's selection pan is refused, so a one-finger drag is always a
     * scroll.
     *
     * The library adds one the moment a selection exists — from `select`, from
     * `selectAll` and from its double tap — so this cannot be fixed by removing
     * it once. Refusing it at the point it tries to begin is a decision made
     * fresh every time, which is why it holds.
     */
    func testAForeignPanIsRefusedWhileNothingHasAskedForTheMouse() {
        let view = terminal()
        let foreign = UIPanGestureRecognizer()
        view.addGestureRecognizer(foreign)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(foreign))
    }

    /// …but not when a program has actually asked for mouse events. That is the
    /// same recogniser class doing a completely different job — a finger driving
    /// vim or htop — and refusing it would break mouse reporting to fix
    /// scrolling.
    func testAForeignPanIsAllowedWhenTheProgramAskedForTheMouse() {
        let view = terminal()
        let foreign = UIPanGestureRecognizer()
        view.addGestureRecognizer(foreign)

        // DECSET 1000: send mouse press and release. This is the program on the
        // other end asking, which is the only thing that changes the answer.
        view.feed(text: "\u{1b}[?1000h")
        XCTAssertNotEqual(view.getTerminal().mouseMode, .off, "the terminal did not take the mode")
        XCTAssertTrue(view.gestureRecognizerShouldBegin(foreign))
    }

    /// SwiftTerm's long press only opened a menu offering *Select*. This app's
    /// press does the selecting, so the library's is refused rather than left to
    /// fire underneath it.
    func testAForeignLongPressIsRefused() {
        let view = terminal()
        let foreign = UILongPressGestureRecognizer()
        view.addGestureRecognizer(foreign)
        XCTAssertFalse(view.gestureRecognizerShouldBegin(foreign))
    }

    /// This app's own recognisers are exempt: they are claimed when they are
    /// installed, which is the only way "ours" is a fact rather than a guess.
    func testAClaimedRecogniserIsAllowed() {
        let view = terminal()
        let mine = UILongPressGestureRecognizer()
        view.claim(mine)
        view.addGestureRecognizer(mine)
        XCTAssertTrue(view.gestureRecognizerShouldBegin(mine))
    }

    /**
     * The scroll view's own pan is refused only while a selection drag has the
     * finger.
     *
     * Without this the scroll takes the movement the moment the long press
     * starts to drag, and the selection never grows past the character it began
     * on. With it, scrolling is still the default for every other drag — which
     * is the arrangement this whole file exists to make unambiguous.
     */
    func testTheScrollPanYieldsOnlyToASelectionDrag() {
        let view = terminal()
        XCTAssertTrue(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
        view.isSelecting = true
        XCTAssertFalse(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
        view.isSelecting = false
        XCTAssertTrue(view.gestureRecognizerShouldBegin(view.panGestureRecognizer))
    }

    // MARK: - The relationships, asked one at a time

    /**
     * The scroll and the selection gestures are declared **exclusive**.
     *
     * This is the hole `gestureRecognizerShouldBegin` cannot close. A recogniser
     * that has already begun is never asked whether it may begin, so the refusals
     * above only cover the case where the scroll has not started yet — and the
     * other case is reachable: the long press allows ten points of movement and a
     * scroll view's slop is about the same, so a finger that drifts nine points
     * and then holds still can have the scroll running when the press fires. With
     * a blanket "yes, run together" both then own the finger and the selection
     * grows while the content slides under it.
     *
     * Asked of the delegate directly, because the delegate is where the answer
     * is and a gesture cannot be performed in a unit test.
     */
    func testTheScrollAndTheSelectionGesturesMayNotRunTogether() throws {
        let view = terminal()
        let gestures = TerminalGestures(terminal: view)
        let scroll = view.panGestureRecognizer

        let press = try XCTUnwrap(ours(UILongPressGestureRecognizer.self, on: view),
                                  "the long press that selects")
        let drag = try XCTUnwrap(ours(UIPanGestureRecognizer.self, on: view),
                                 "the pan that adjusts a selection")

        XCTAssertFalse(gestures.gestureRecognizer(press, shouldRecognizeSimultaneouslyWith: scroll),
                       "holding still mid-scroll must not start selecting under the moving text")
        XCTAssertFalse(gestures.gestureRecognizer(scroll, shouldRecognizeSimultaneouslyWith: press),
                       "and the question has to be answered the same way whichever way round it is asked")
        XCTAssertFalse(gestures.gestureRecognizer(drag, shouldRecognizeSimultaneouslyWith: scroll))
    }

    /**
     * …but the tap and the pinch still may.
     *
     * The tap exists only to notice that a tap happened — it does not cancel
     * touches, and SwiftTerm's own tap is what dismisses a selection and raises
     * the keyboard — and the pinch is two fingers, which the scroll can no longer
     * begin with. Denying either would be fixing a problem neither has.
     */
    func testTheTapAndThePinchStillRunAlongsideTheScroll() throws {
        let view = terminal()
        let gestures = TerminalGestures(terminal: view)
        let scroll = view.panGestureRecognizer

        let tap = try XCTUnwrap(ours(UITapGestureRecognizer.self, on: view))
        let pinch = try XCTUnwrap(ours(UIPinchGestureRecognizer.self, on: view))

        XCTAssertTrue(gestures.gestureRecognizer(tap, shouldRecognizeSimultaneouslyWith: scroll))
        XCTAssertTrue(gestures.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: scroll))
    }

    /**
     * The scroll waits for the selection drag to fail.
     *
     * Both are pans with the same threshold, so they reach the moment of decision
     * on the same touch event and the order UIKit asks them in is undefined. Left
     * to chance, dragging the end of a selection scrolls the terminal about half
     * the time. The failure requirement makes it a rule; it costs nothing in the
     * normal case because the selection drag refuses itself in that same event
     * unless the finger came down on a selection's end.
     */
    func testTheScrollWaitsForTheSelectionDragToSayNo() throws {
        let view = terminal()
        let gestures = TerminalGestures(terminal: view)
        let scroll = view.panGestureRecognizer
        let drag = try XCTUnwrap(ours(UIPanGestureRecognizer.self, on: view))
        let press = try XCTUnwrap(ours(UILongPressGestureRecognizer.self, on: view))

        XCTAssertTrue(gestures.gestureRecognizer(drag, shouldBeRequiredToFailBy: scroll))
        // And nothing else claims that relationship — a scroll that had to wait
        // for the long press would stall for half a second before every scroll,
        // which is the exact opposite of the point.
        XCTAssertFalse(gestures.gestureRecognizer(press, shouldBeRequiredToFailBy: scroll))
        XCTAssertFalse(gestures.gestureRecognizer(drag, shouldBeRequiredToFailBy: press))
    }

    // MARK: - The press may not take a drag away from the scroll

    /**
     * The press fails before the scroll begins, rather than at the same moment.
     *
     * This is the inequality the whole gesture hangs on. Both numbers were ten,
     * which is `UIScrollView`'s own hysteresis, so a finger crossing that
     * threshold reached the press's failure and the scroll's start on the *same*
     * touch event — and nothing in UIKit says which is consulted first. The same
     * drag scrolled sometimes and selected sometimes, which is worse than either
     * behaviour chosen on purpose.
     *
     * Below the scroll's slop, a finger on its way to a scroll fails the press
     * first, every time. If somebody ever raises this constant back to ten, this
     * is what says why they must not.
     */
    func testThePressGivesUpBeforeTheScrollTakesOver() {
        XCTAssertLessThan(TerminalGestures.selectionSlop, DeckTerminalView.scrollSlop,
                          "a finger heading for a scroll must fail the press before the scroll begins")
        // …and not so far below it that a resting hand's tremor cancels a
        // deliberate press.
        XCTAssertGreaterThanOrEqual(TerminalGestures.selectionSlop, 4)
    }

    /**
     * A slow start to a scroll is a scroll.
     *
     * Measured, not guessed: in the Simulator against a live session, a finger
     * held for 0.65 s and then dragged selected eleven lines and put the copy
     * callout up, and the terminal did not move. Half a second is how long it
     * takes to *begin* scrolling a wall of text you are reading. The press has to
     * sit on the far side of that.
     */
    func testTheSelectionPressIsLongerThanAHesitation() {
        XCTAssertGreaterThanOrEqual(TerminalGestures.selectionHold, 0.65,
                                    "0.5s is a pause before a scroll, not a long press")
        // And the other end, which is a real constraint rather than symmetry:
        // XCUITest cannot synthesise a stationary hold much past six tenths of a
        // second, so a press pushed far above this is one nothing can exercise.
        // See the constant, and `TerminalScrollUITests`.
        XCTAssertLessThanOrEqual(TerminalGestures.selectionHold, 0.8,
                                 "a press this long is one no test can produce")
    }

    /**
     * Nothing starts a selection on a terminal that is already moving.
     *
     * Two gestures land here and both were turning the screen blue: a slow
     * scroll that stopped to read, and a finger put down to halt a flick — which
     * everywhere else on the phone means *stop*.
     *
     * Asked through a subclass because `isDragging` and `isDecelerating` cannot
     * be set: only UIKit's touch delivery makes them true, so the question is
     * answerable in a unit test and the state is not. The gesture itself is
     * proved with a finger in `TerminalScrollUITests`.
     */
    func testASelectionCannotStartOnMovingContent() throws {
        final class Moving: DeckTerminalView {
            var moving = false
            override var isScrolling: Bool { moving }
        }
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = Moving(frame: CGRect(x: 0, y: 0, width: 390, height: 600), font: font)
        view.layoutIfNeeded()
        let gestures = TerminalGestures(terminal: view)
        let press = try XCTUnwrap(ours(UILongPressGestureRecognizer.self, on: view))

        XCTAssertTrue(gestures.gestureRecognizerShouldBegin(press), "still content: a press is a press")

        view.moving = true
        XCTAssertFalse(gestures.gestureRecognizerShouldBegin(press),
                       "a finger on scrolling content means stop, not select")
    }

    /**
     * One finger scrolls, and only one.
     *
     * `UIScrollView` will drive its pan with any number of fingers, so without
     * this a two-finger pinch also slides the scrollback out from under the text
     * it is resizing. Asad asked for the one-finger rule twice; this is the
     * literal reading of it.
     */
    func testOnlyOneFingerScrolls() {
        let view = terminal()
        _ = TerminalGestures(terminal: view)
        XCTAssertEqual(view.panGestureRecognizer.maximumNumberOfTouches, 1)
    }

    /// This app's recogniser of a given kind, which is the one it claimed.
    /// SwiftTerm attaches its own of the same classes, so a query by class alone
    /// finds the wrong one about half the time.
    private func ours<T: UIGestureRecognizer>(_ kind: T.Type, on view: DeckTerminalView) -> T? {
        (view.gestureRecognizers ?? []).compactMap { $0 as? T }.first { view.owns($0) }
    }

    /// Installing the gestures adds this app's three and nothing else — and, in
    /// particular, does not disturb the taps SwiftTerm uses to dismiss a
    /// selection and raise the keyboard.
    func testInstallingTheGesturesLeavesTheTapsAlone() {
        let view = terminal()
        let tapsBefore = (view.gestureRecognizers ?? []).filter { $0 is UITapGestureRecognizer }.count

        let gestures = TerminalGestures(terminal: view)
        XCTAssertNotNil(gestures)

        let taps = (view.gestureRecognizers ?? []).filter { $0 is UITapGestureRecognizer }
        XCTAssertEqual(taps.count, tapsBefore + 1, "one tap added, none taken away")
        XCTAssertTrue(taps.allSatisfy { $0.isEnabled })
        // And every one of SwiftTerm's own is still attached rather than removed
        // — refusing a gesture is not the same as deleting it, and deleting was
        // the approach that did not hold.
        XCTAssertTrue((view.gestureRecognizers ?? []).contains { $0 is UILongPressGestureRecognizer })
    }

    // MARK: - The grid stands where the keyboard was

    /**
     * Opening the grid must not resign first responder.
     *
     * This is the whole reason the grid is the terminal's `inputView` rather
     * than a panel: a selection dies the moment something outside the terminal
     * is touched, and this app has already lost a Copy control to exactly that.
     * If a future change makes the grid a sheet, this test is what notices.
     */
    func testTheGridDoesNotCostTheTerminalItsSelection() {
        let bridge = TerminalBridge()
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()
        bridge.feed("select me\r\n")

        let accessory = bridge.view.inputAccessoryView as? KeyboardAccessory
        XCTAssertNotNil(accessory, "the bar is the terminal's own accessory view")

        accessory?.onMore?()
        XCTAssertTrue(bridge.isKeyGridOpen, "more must put the grid where the keyboard was")
        // The *input* view, specifically. Anything else on screen would be a
        // touch outside the terminal, and that is what kills a selection.
        XCTAssertTrue(bridge.view.inputView is KeyGridView)

        // And closing it puts the keyboard back rather than leaving a surface
        // with nothing underneath.
        accessory?.onMore?()
        XCTAssertFalse(bridge.isKeyGridOpen)
    }

    /// Dismiss takes the grid with it. "Give me the screen back" is one intent,
    /// and answering half of it leaves a grid standing over a keyboard nobody
    /// asked to keep.
    func testDismissClosesTheGridToo() {
        let bridge = TerminalBridge()
        let accessory = bridge.view.inputAccessoryView as? KeyboardAccessory
        accessory?.onMore?()
        XCTAssertTrue(bridge.isKeyGridOpen)

        accessory?.onDismiss?()
        XCTAssertFalse(bridge.isKeyGridOpen)
    }
}
