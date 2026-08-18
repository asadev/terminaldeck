/**
 * The strip along the bottom of the phone that the terminal is not allowed to
 * draw its last line into.
 *
 * Asad, on a session with the keyboard down: *"at the bottom we cannot see some
 * stuff because of the mobile's round corners and the running-agents things —
 * whatever is at the most bottom is less visible. So leave a little space when
 * the keyboard is off."*
 *
 * On a phone with a home indicator the last 34 points of the screen are crossed
 * by the indicator and clipped by the display's corner radius. Text drawn there
 * is not covered so much as *half* covered, which is worse: it is legible enough
 * that nobody notices it is wrong, and it is the region an agent puts its status
 * box in — the spinner, the token count, the "esc to interrupt" line — because a
 * full-screen TUI draws its status on the last row by convention. So the rows
 * most worth reading were the ones being clipped.
 *
 * ## Why this is a UIKit view and not a `.safeAreaInset` on the SwiftUI side
 *
 * Because two different things want that same region and only one of them may
 * have it.
 *
 * The first is the floating tab pill. Inside a session it is gone —
 * `DeckChrome` decides that and `DeckTabs` states it at the `TabView` — but
 * `TerminalScreen` also carries `.ignoresSafeArea(.container, edges: .bottom)`,
 * which is what stops SwiftUI reserving the pill's band whether or not anything
 * is drawn in it. That modifier is correct and has to stay.
 *
 * The second is the home indicator, which is a fact about the hardware and has
 * nothing to do with the pill. The trouble is that `.ignoresSafeArea` cannot
 * tell them apart: it takes the whole container inset, and the pass that added
 * it to kill the pill's band took the hardware's inset with it. That is the bug
 * being fixed, and fixing it in SwiftUI would mean adding back an inset by hand
 * with a number — which is how the pill's band would quietly return.
 *
 * So the two levers are separated. SwiftUI keeps ignoring the *container* inset,
 * which is the pill's, and this view — which really does sit against the bottom
 * of the screen, and therefore really does have the hardware's safe area on it —
 * gives that much of itself back. Nothing here knows a number; `safeAreaInsets`
 * is UIKit's own measurement of this view's overlap with the unsafe region, so
 * it is 34 on a phone with an indicator, 21 on an iPad, and **0** on a bezelled
 * iPhone SE where there is nothing to avoid.
 *
 * ## Why the keyboard needs no special case
 *
 * With the keyboard up, SwiftUI's keyboard avoidance — a separate safe-area
 * region from `.container`, and therefore untouched by the modifier above —
 * shrinks this view so its bottom edge sits on top of the key bar. A view whose
 * frame stops short of the unsafe region has **no** bottom safe area, so
 * `safeAreaInsets.bottom` is already 0 and the terminal fills the container. The
 * inset appears and disappears with the keyboard without anything asking whether
 * the keyboard is up, which is the only version of this that cannot drift: a
 * flag would have to be right in every order the two events can arrive in, and
 * a wrong one costs a line of terminal for as long as the keyboard is up.
 *
 * ## Why the terminal's frame shrinks rather than its content inset growing
 *
 * `TerminalView` is a `UIScrollView`, so the obvious lever is
 * `contentInset.bottom` — and it is the wrong one. SwiftTerm computes the
 * session's row count in `processSizeChange` from `bounds.size`, which a content
 * inset does not change, so the emulator would still believe it had the taller
 * screen. Scrollback would look right, because scrolling to the bottom would
 * rest 34 points higher, and a full-screen program would not: `vim` and an
 * agent's TUI paint a fixed number of rows starting at the top, and with the
 * content pushed up by an inset the *top* row would go under the navigation bar
 * while the bottom row still sat on the indicator. Shrinking the frame tells the
 * emulator the truth — one `resize` on the wire, two fewer rows, everything the
 * far end draws lands inside what can be read.
 */

import SwiftTerm
import UIKit

@MainActor
final class TerminalContainerView: UIView {

    let terminal: TerminalView

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        // Frame-driven rather than constrained. The frame is one line in
        // `layoutSubviews` against a number that can change on any layout pass,
        // and a constraint whose constant has to be rewritten from
        // `safeAreaInsetsDidChange` is the same thing with a second place to
        // forget.
        terminal.translatesAutoresizingMaskIntoConstraints = true
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /**
     * How much of the bottom is handed back to the system.
     *
     * UIKit's own measurement of this view's overlap with the unsafe region, not
     * a constant — see the header for why every constant that could stand here
     * is wrong on some device this app runs on.
     */
    var reservedBottom: CGFloat { safeAreaInsets.bottom }

    override func layoutSubviews() {
        super.layoutSubviews()
        terminal.frame = CGRect(x: bounds.minX,
                                y: bounds.minY,
                                width: bounds.width,
                                height: max(0, bounds.height - reservedBottom))
    }

    /// The inset arrives *after* the first layout — a view has no safe area
    /// until it is in a window — so without this the terminal would be laid out
    /// once at the full height and never told.
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
}
