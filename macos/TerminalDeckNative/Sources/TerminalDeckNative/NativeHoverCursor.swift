import AppKit
import SwiftUI

/// Balance the cursor stack even when a hovered control is removed.
@MainActor
final class NativeHoverCursorState {
    private var pushed = false

    func hover(_ inside: Bool, push: () -> Void, pop: () -> Void) {
        guard inside != pushed else { return }
        pushed = inside
        if inside { push() } else { pop() }
    }

    func disappear(pop: () -> Void) {
        hover(false, push: {}, pop: pop)
    }
}

private struct NativeHoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var state = NativeHoverCursorState()

    func body(content: Content) -> some View {
        content
            .onHover { state.hover($0, push: { cursor.push() }, pop: { NSCursor.pop() }) }
            .onDisappear { state.disappear { NSCursor.pop() } }
    }
}

extension View {
    func nativeHoverCursor(_ cursor: NSCursor) -> some View {
        modifier(NativeHoverCursor(cursor: cursor))
    }
}
