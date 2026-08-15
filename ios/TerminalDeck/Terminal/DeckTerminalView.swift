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
final class DeckTerminalView: TerminalView {

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
            // SwiftTerm's selection pan, or its mouse-reporting pan. See the
            // header: the only one worth letting through is the one a program
            // has actually asked for.
            return getTerminal().mouseMode != .off
        }
        if gestureRecognizer is UILongPressGestureRecognizer {
            // SwiftTerm's, which only opens a menu. This app's long press is
            // claimed above and does the selecting.
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
