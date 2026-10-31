import SwiftUI

/// The actual owl's layout bounds, used by the offscreen test target. No mark
/// artwork or animation is duplicated here; HootMark remains the shared owner.
struct NativeFIXESIslandOwlFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
