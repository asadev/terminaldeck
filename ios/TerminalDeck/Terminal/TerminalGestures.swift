/**
 * One finger scrolls. A long press selects, and dragging extends the selection.
 * Letting go offers Copy.
 *
 * Asad: *"let it scroll with one finger and copy with longpress and drag"*. That
 * is the iOS convention — Safari, Notes and Mail already behave this way — so
 * nobody has to be taught it, and it puts the cheap gesture on the common act.
 *
 * ## What this installs, and what it leaves alone
 *
 * **Scrolling is not implemented here.** `TerminalView` is a `UIScrollView`, so
 * a one-finger drag already scrolls with momentum and rubber-band, exactly like
 * every other scroll view on the system. The work was never adding a scroll — it
 * was stopping the two recognisers that were taking the drag away from it, which
 * `DeckTerminalView` does.
 *
 * What is installed is three recognisers, all claimed so the view knows they are
 * this app's rather than the library's:
 *
 *  1. **A long press that selects.** Half a second, then the word under the
 *     finger is selected and dragging extends it a character at a time.
 *     SwiftTerm's own long press is refused; it only opened a menu with a
 *     *Select* item in it, which is a second tap for something the press itself
 *     should have done.
 *  2. **A pan that adjusts a selection by its ends.** It begins only when a
 *     selection is on screen and the finger came down within a couple of cells
 *     of one of its ends — anywhere else and the drag is a scroll.
 *  3. **A tap that closes the grid.** Harmless and non-blocking: it recognises
 *     alongside SwiftTerm's own tap rather than replacing it, because that tap
 *     is what dismisses a selection and raises the keyboard.
 *
 * ## Why the Copy affordance is the system callout and nothing else
 *
 * **A selection dies when you touch outside the terminal.** SwiftTerm calls
 * `selectNone()` from its own touch handling, so any control that is not part of
 * the terminal destroys the selection on the way to being pressed. This app has
 * already lost a "Copy Selection" menu item to exactly that: it opened, honestly
 * reported that nothing was selected, and left the pasteboard untouched — with a
 * screenshot from the same run showing the whole screen selected.
 *
 * So the copy that acts on a *selection* is the system's own callout, shown here
 * over the selection at the moment the finger lifts, because a callout is the
 * one place a selection survives being acted on. The other survivor is the key
 * bar, which is the terminal's own `inputAccessoryView`, and its grid, which is
 * the terminal's own `inputView` — both are inside, which is why `copy` is
 * allowed to live there.
 *
 * ## Why the geometry is recomputed rather than read
 *
 * A touch has to become a row and a column. SwiftTerm computes that from
 * `cellDimension`, which is `internal` — not reachable from this module — so the
 * same two numbers are derived here from the font, with the same formula and the
 * same pixel snapping the library uses. `TerminalGeometryTests` checks the
 * result against the one public number that depends on it, the scroll view's own
 * `contentSize`, because a cell size that drifts by a point would put selections
 * on the wrong character in a way no one would think to test for.
 */

import SwiftTerm
import UIKit

@MainActor
final class TerminalGestures: NSObject, UIGestureRecognizerDelegate {

    /// Raised when a gesture happened that should put the key grid away and
    /// bring the keyboard back. Tapping into the terminal means "I want to
    /// type", and a grid covering the keyboard is the wrong answer to that.
    var onTapped: (() -> Void)?

    /**
     * A two-finger pinch, reported as the scale since the gesture began.
     *
     * Three callbacks rather than one because the size has to be applied against
     * where the pinch *started*: `UIPinchGestureRecognizer.scale` is cumulative
     * from the beginning of the gesture, so multiplying the current size by it
     * on every update compounds — a gentle spread crosses the whole range in
     * about a fifth of a second and lands on the maximum every time.
     *
     * Two fingers is also what makes this free of the arrangement above: the
     * scroll is one finger, the selection press is one finger, and nothing else
     * on this view claims a second one.
     */
    var onPinchBegan: (() -> Void)?
    var onPinch: ((CGFloat) -> Void)?
    var onPinchEnded: (() -> Void)?

    private unowned let terminal: DeckTerminalView

    /**
     * The terminal's selection, named once.
     *
     * SwiftTerm declares this implicitly unwrapped because it is built during
     * the view's `setup()` and is never nil afterwards. Stating the type here is
     * what makes the dozen uses below read as a selection rather than as a dozen
     * unwraps of something that might not exist — and it keeps the promise in
     * one place, where it can be wrong once rather than everywhere.
     */
    private var selection: SelectionService { terminal.selection }

    /// Where the selection is being dragged *from* — the end that is not
    /// moving. Nil when no selection drag is in flight.
    private var anchor: Position?

    init(terminal: DeckTerminalView) {
        self.terminal = terminal
        super.init()

        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPress))
        // Half a second rather than SwiftTerm's 0.7. The press is now doing the
        // selecting rather than opening a menu, so it is on the critical path of
        // copying anything at all; 0.5s is what `UITextView` uses.
        press.minimumPressDuration = 0.5
        // The scroll view's pan begins the moment the finger moves past its
        // slop, so a press that has not fired yet cannot block a scroll. This is
        // what makes the two gestures live together without either being made to
        // wait for the other.
        press.allowableMovement = 10
        press.delegate = self
        install(press)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(adjust))
        drag.delegate = self
        install(drag)
        selectionDrag = drag

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        install(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        // Both false, and both deliberate: this recogniser exists only to notice
        // that a tap happened. Cancelling touches would take the tap away from
        // SwiftTerm, whose own tap is what dismisses a selection and raises the
        // keyboard.
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        install(tap)
    }

    private var selectionDrag: UIPanGestureRecognizer?

    private func install(_ recognizer: UIGestureRecognizer) {
        terminal.claim(recognizer)
        terminal.addGestureRecognizer(recognizer)
    }

    // MARK: - The gestures

    @objc private func longPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            /*
             * The **word** under the finger, then character-precise from there.
             *
             * Two decisions in three lines. Selecting the word is what every
             * other iOS surface does on a long press, and it is also the only
             * thing that gives the gesture a visible result when the finger does
             * not move — a zero-width selection would show nothing, offer no
             * callout, and read as a press that did not work.
             *
             * Dropping straight back to `.character` mode is the second. Left in
             * word mode, `dragExtend` snaps both ends to word boundaries, and a
             * terminal is the one place where selecting *part* of a token — half
             * a path, a hash without its prefix — is a normal thing to want. So
             * the press gives a word and the drag gives exactly what it touches.
             */
            selection.selectWordOrExpression(at: position(of: recognizer),
                                             in: terminal.getTerminal().buffer)
            selection.selectionMode = .character
            // The finger now owns the drag. Without this the scroll view takes
            // the movement and the selection never grows past the first word.
            terminal.isSelecting = true
            selectionFeedback()
        case .changed:
            // No redraw is asked for here and none is needed: extending the
            // selection notifies the terminal's delegate, which is the view
            // itself, and its `selectionChanged` coalesces one repaint per turn
            // of the run loop. Asking again would be a second repaint per
            // millimetre of finger travel.
            selection.dragExtend(bufferPosition: position(of: recognizer))
        case .ended, .cancelled, .failed:
            terminal.isSelecting = false
            if recognizer.state == .ended { offerCopy() }
        default:
            break
        }
    }

    @objc private func adjust(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let anchor else { return }
            selection.pivot = anchor
            terminal.isSelecting = true
        case .changed:
            guard anchor != nil else { return }
            selection.pivotExtend(bufferPosition: position(of: recognizer))
        case .ended, .cancelled, .failed:
            terminal.isSelecting = false
            anchor = nil
            if recognizer.state == .ended { offerCopy() }
        default:
            break
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        onTapped?()
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onPinchBegan?()
        case .changed:
            onPinch?(recognizer.scale)
        case .ended, .cancelled, .failed:
            onPinchEnded?()
        default:
            break
        }
    }

    /**
     * Whether a drag is an adjustment of the selection or a scroll.
     *
     * Only the first: a pan that starts within a couple of cells of one end of
     * an existing selection grabs that end, and every other pan on this view is
     * the scroll view's. Deciding here rather than in the handler is what stops
     * the scroll from being cancelled and then handed back, which reads as the
     * terminal juddering.
     */
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === selectionDrag else { return true }
        guard selection.active else { return false }
        let hit = position(of: gestureRecognizer)
        if near(hit, selection.start) {
            anchor = selection.end
            return true
        }
        if near(hit, selection.end) {
            anchor = selection.start
            return true
        }
        anchor = nil
        return false
    }

    /// Ours may run alongside the library's. Returning true from *this* delegate
    /// is enough — only one side of a pair has to agree — and it is the side
    /// this app owns.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Two cells across and one row up or down, which is about a fingertip. The
    /// same tolerance SwiftTerm's own handle drag used, kept so that a habit
    /// formed against the old build still works.
    private func near(_ one: Position, _ other: Position) -> Bool {
        abs(one.col - other.col) < 3 && abs(one.row - other.row) < 2
    }

    // MARK: - Copy

    /**
     * Put the system's edit menu over the selection.
     *
     * `UIMenuController` rather than `UIEditMenuInteraction`, and that is not
     * laziness about a deprecation: SwiftTerm shows its own menus through
     * `UIMenuController` and answers `canPerformAction(copy:)` from its
     * selection state. Introducing a second menu system on the same view would
     * give one view two edit menus that disagree about what is selected. One
     * menu, and it is the one the library already answers to.
     */
    private func offerCopy() {
        guard selection.active, selection.hasSelectionRange else { return }
        _ = terminal.becomeFirstResponder()
        UIMenuController.shared.showMenu(from: terminal, rect: selectionRect())
    }

    /// The rectangle the callout must not cover — the selection itself, in the
    /// terminal's own coordinates.
    private func selectionRect() -> CGRect {
        let cell = TerminalGeometry.cell(for: terminal.font)
        let top = CGFloat(min(selection.start.row, selection.end.row)) * cell.height
        let bottom = CGFloat(max(selection.start.row, selection.end.row) + 1) * cell.height
        // A multi-line selection is the full width; a single-line one is only as
        // wide as the characters in it, so the menu can sit beside rather than
        // over the thing being copied.
        let left: CGFloat
        let width: CGFloat
        if selection.start.row == selection.end.row {
            let first = CGFloat(min(selection.start.col, selection.end.col))
            let last = CGFloat(max(selection.start.col, selection.end.col) + 1)
            left = first * cell.width
            width = max(cell.width, (last - first) * cell.width)
        } else {
            left = 0
            width = terminal.bounds.width
        }
        return CGRect(x: left, y: top, width: width, height: bottom - top)
    }

    /// A tap of haptics when a selection starts. The gesture has no visible
    /// beginning otherwise — the finger is covering the word it just selected.
    private func selectionFeedback() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Geometry

    /// Where a gesture is, as a position in the buffer.
    private func position(of recognizer: UIGestureRecognizer) -> Position {
        TerminalGeometry.position(of: recognizer.location(in: terminal), in: terminal)
    }
}

/**
 * Touch points to buffer positions.
 *
 * Split out of the gestures and made static so it can be tested: this is the
 * arithmetic that decides *which character* a finger landed on, and being one
 * cell out is invisible in code review and obvious in use.
 */
enum TerminalGeometry {

    /**
     * The size of one character cell, computed the way SwiftTerm computes it.
     *
     * Height is the font's ascent, descent and leading, rounded up and then
     * snapped to the pixel grid. Width is the advance of a capital W, snapped
     * the same way. Both formulas are `computeFontDimensions` in
     * `AppleTerminalView.swift`, reproduced because the value it stores is
     * `internal` and this module cannot see it.
     *
     * `UIScreen.main.scale` is deprecated and is used anyway, on purpose: the
     * number that matters is not the *correct* scale, it is **the same scale
     * SwiftTerm used**, and SwiftTerm calls exactly this. A more modern reading
     * that disagreed with the library by one pixel would put a selection on the
     * wrong character, which is a worse bug than a deprecation warning.
     */
    static func cell(for font: UIFont) -> CGSize {
        let scale = max(UIScreen.main.scale, 1)
        let height = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        let width = ("W" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(1, (width * scale).rounded() / scale),
                      height: max(1, ceil(height * scale) / scale))
    }

    /**
     * A point in the terminal's coordinates, as a buffer row and column.
     *
     * The point is already in *content* coordinates — the terminal is a scroll
     * view, so `location(in:)` includes however far it has been scrolled — which
     * is why the row that comes out is a buffer row rather than a screen row,
     * and why nothing here has to know about `yDisp`. That is the same thing
     * `calculateTapHit` does with the same arithmetic.
     */
    static func position(of point: CGPoint, in terminal: TerminalView) -> Position {
        let cell = cell(for: terminal.font)
        let columns = terminal.getTerminal().getDims().cols
        let column = min(max(0, Int(point.x / cell.width)), max(0, columns - 1))
        let row = max(0, Int(point.y / cell.height))
        return Position(col: column, row: row)
    }
}
