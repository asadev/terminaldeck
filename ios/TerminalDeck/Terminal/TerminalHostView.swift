/**
 * The four lines that put a UIKit terminal inside SwiftUI.
 *
 * `makeUIView` hands back the bridge's existing view rather than building one,
 * so the scrollback survives every reason SwiftUI has to rebuild this node —
 * see the note in `TerminalBridge`.
 *
 * `updateUIView` is empty on purpose. SwiftTerm's `layoutSubviews` already calls
 * `processSizeChange` when the bounds change, which is what recomputes the
 * column count and fires `sizeChanged` on the delegate. Doing it again from here
 * would resize the terminal twice per rotation and send two `resize` frames.
 */

import SwiftTerm
import SwiftUI

struct TerminalHostView: UIViewRepresentable {
    let bridge: TerminalBridge

    func makeUIView(context: Context) -> TerminalView {
        bridge.view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
