/**
 * `TerminalView`, with its gesture recognisers reconciled rather than fought.
 *
 * ## Why a subclass exists at all
 *
 * SwiftTerm ships its own opinion about what a finger does on a terminal, and it
 * is not the iOS convention:
 *
 *  - A long press opens a menu offering *Select* and *Select All*. It does not
 *    select anything, so selecting text costs a press, a read and a second tap.
 *  - A pan is added to the view **as soon as a selection exists**
 *    (`enableSelectionPanGesture`, called from `select`, `selectAll` and the
 *    double tap) and it extends the selection. That recogniser and the scroll
 *    view's own pan then both claim a one-finger drag, and which one wins is not
 *    decided anywhere — so the same gesture sometimes scrolls and sometimes
 *    selects, which is worse than either behaviour chosen consistently.
 *
 * The convention this app wants is Safari's, Notes' and Mail's, and it is what
 * Asad asked for: **one finger drags to scroll, a long press starts a selection,
 * dragging extends it, and letting go offers Copy.** Scrolling is the common act
 * by a wide margin so it gets the cheapest gesture; selecting is deliberate, so
 * it gets the deliberate one.
 *
 * Stacking new recognisers on top of SwiftTerm's would produce exactly the
 * ambiguity described above with one more claimant in it. So the reconciliation
 * happens at the only place it can be made reliably: this view decides which
 * recognisers are allowed to begin.
 *
 * ## Why `gestureRecognizerShouldBegin` and not removing them
 *
 * Removing SwiftTerm's recognisers does not hold. `enableSelectionPanGesture` is
 * called from three different places inside the library and would silently add
 * one back the next time anybody used the system's Select All. Refusing to let a
 * foreign pan *begin* is a decision this view makes fresh on every gesture, so
 * there is no window in which the library can put the ambiguity back.
 *
 * The refusal is a rule rather than an identity check, because SwiftTerm adds two
 * plain `UIPanGestureRecognizer`s that cannot be told apart by class: one for
 * selection and one for **mouse reporting**, which is how a finger drives vim or
 * htop. The rule is therefore *what the program on the other end asked for*: a
 * foreign pan may begin only while mouse reporting is on. With it off, a
 * one-finger drag belongs to the scroll view — always, with no exceptions and
 * nothing to notice.
 */

import SwiftTerm
import UIKit

@MainActor
class DeckTerminalView: TerminalView {

    /**
     * Roughly how far a finger travels before `UIScrollView` claims it.
     *
     * UIKit does not publish the number and there is no API for it; it is about
     * ten points and has been for as long as anyone has measured it. It is named
     * here because one thing in this app has to be **strictly smaller** than it —
     * `TerminalGestures.selectionSlop` — and a relationship between two numbers
     * that only exists in somebody's head is a relationship that gets broken by
     * the next person to tidy a constant. `TerminalGesturesTests` asserts it.
     */
    static let scrollSlop: CGFloat = 10

    /**
     * Whether the content is already moving under the finger.
     *
     * A selection may not start on a terminal that is scrolling. Both halves
     * matter and each one is a gesture that was going wrong: `isDragging` is the
     * slow scroll that paused — the finger crept a few points, the scroll view
     * took the pan, and then it stopped moving for half a second while he read
     * — and `isDecelerating` is the finger put down to stop a flick, which on
     * every other iOS surface means *stop*, not *select this line*.
     *
     * Computed rather than stored, and not `final`, for one reason: neither
     * `isDragging` nor `isDecelerating` can be set. Only UIKit's own touch
     * delivery makes them true, so a unit test can ask the delegate the question
     * but cannot create the state to ask it in — and it is answered by
     * overriding this in a subclass. The gesture itself is proved for real in
     * `TerminalScrollUITests`, with a finger.
     */
    var isScrolling: Bool { isDragging || isDecelerating }

    /// Recognisers this app installed, by identity. Ours are exempt from the
    /// refusal below; everything else on this view came from the library.
    private var owned: Set<ObjectIdentifier> = []

    /// True while a selection drag has the finger. Set by `TerminalGestures`,
    /// read here to keep the scroll view out of a gesture it is not part of.
    var isSelecting = false

    /// Register a recogniser as this app's own. Called by `TerminalGestures`
    /// rather than inferred, because "added after setup" is not a property
    /// anything can read back off a view.
    func claim(_ recognizer: UIGestureRecognizer) {
        owned.insert(ObjectIdentifier(recognizer))
    }

    /// Whether a recogniser is this app's. Readable rather than private because
    /// SwiftTerm attaches recognisers of the same *classes* this app does — a
    /// long press and two pans — so a test that wants "ours" cannot ask for it by
    /// class, and the claim is the only thing that tells them apart.
    func owns(_ recognizer: UIGestureRecognizer) -> Bool {
        owned.contains(ObjectIdentifier(recognizer))
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            // The scroll view's own pan. Refused only while a selection drag
            // owns the finger — otherwise this is the gesture that scrolls, and
            // it must never be the one that loses.
            return !isSelecting && super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        if owned.contains(ObjectIdentifier(gestureRecognizer)) {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        if gestureRecognizer is UIPanGestureRecognizer {
            /*
             * SwiftTerm's selection pan, or its mouse-reporting pan — **always
             * refused**, so one finger always scrolls and a plain drag never
             * copies.
             *
             * > *"scrolling with one finger in terminal is still not working btw
             * > — it starts copying instead. It should copy on long press only."*
             * > (said twice; the second time on a build that still copied.)
             *
             * The earlier attempt allowed this pan on the alternate screen when a
             * program had mouse reporting on — the idea being a full-screen app
             * should get the drag. But **Claude Code's TUI is exactly that: the
             * alternate screen with mouse reporting on**, so the one thing he uses
             * this app for fell straight through the exception and kept selecting.
             * There is no test at `shouldBegin` time that separates "this drag is
             * a mouse-report the program wants" from "this drag is him trying to
             * scroll", so the honest thing is to obey the rule he gave, without an
             * exception: one finger scrolls, a long press selects. A program that
             * genuinely needs a drag still gets taps (clicks) through SwiftTerm's
             * own tap; only the *drag* is the phone's to scroll with. If a
             * mouse-drag-driven full-screen app ever matters, that is a separate,
             * named ask — not a reason to keep breaking scroll.
             */
            return false
        }
        if gestureRecognizer is UILongPressGestureRecognizer {
            // SwiftTerm's, which only opens a menu. This app's long press is
            // claimed above and does the selecting.
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
