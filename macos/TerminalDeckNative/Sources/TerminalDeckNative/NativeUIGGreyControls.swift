import AppKit
import SwiftUI

/// The same quiet grey used by the side lists, scoped to selectable controls.
/// Apply to segmented pickers and button-style toggles, including their label.
struct NativeUIGGreyControl: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Color(nsColor: .secondaryLabelColor))
            .accentColor(Color(nsColor: .secondaryLabelColor))
    }
}

extension View {
    func nativeUIGGreyControl() -> some View {
        modifier(NativeUIGGreyControl())
    }

    /// Custom capsule selectors need a grey fill as well as neutral text.
    func nativeUIGSelection(_ selected: Bool, capsule: Bool = true) -> some View {
        foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(selected ? Color(nsColor: .quaternaryLabelColor) : Color.clear,
                        in: RoundedRectangle(cornerRadius: capsule ? 14 : 6))
            .nativeUIGGreyControl()
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
