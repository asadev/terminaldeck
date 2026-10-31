import SwiftUI
import TerminalDeckNativeCore

/// A retained/deep-linked Memory panel cannot fall through to the old page.
/// The implementation and saved notes remain untouched for the future graph.
struct NativeUIGMemoryUnavailable: View {
    var body: some View {
        NativePageEmpty(title: UIGMemoryVisibility.unavailableTitle) {
            Text(UIGMemoryVisibility.unavailableMessage)
        }
    }
}
