/**
 * The few lines that put a UIKit terminal inside SwiftUI.
 *
 * `makeUIView` hands back a container holding the bridge's existing terminal
 * rather than building a terminal, so the scrollback survives every reason
 * SwiftUI has to rebuild this node — see the note in `TerminalBridge`. The
 * container is owned there too, for the same reason: a fresh one per rebuild
 * would work, because it re-adopts the same terminal, but it would also throw
 * away the safe-area measurement UIKit had already made and lay the terminal out
 * at full height for one frame before being told again.
 *
 * `updateUIView` is empty on purpose. SwiftTerm's `layoutSubviews` already calls
 * `processSizeChange` when the bounds change, which is what recomputes the
 * column count and fires `sizeChanged` on the delegate. Doing it again from here
 * would resize the terminal twice per rotation and send two `resize` frames.
 *
 * The container, not the terminal, is what SwiftUI lays out — it is the thing
 * that keeps the last line off the home indicator, and `TerminalContainerView`
 * is where the whole argument for that lives.
 */

import SwiftUI

struct TerminalHostView: UIViewRepresentable {
    let bridge: TerminalBridge

    func makeUIView(context: Context) -> TerminalContainerView {
        bridge.container
    }

    func updateUIView(_ uiView: TerminalContainerView, context: Context) {}
}
