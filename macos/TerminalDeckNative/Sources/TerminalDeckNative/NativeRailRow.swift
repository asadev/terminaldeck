import SwiftUI

/// The grey list row of the Store rail and the Apps screens: a light tint on
/// hover, a stronger one when selected (grey, no blue: Asad, 2026-10-07).
/// One copy, so a look change reaches every list that uses it.
private struct NativeRailRow: ViewModifier {
    let selected: Bool
    let leading: CGFloat
    let vertical: CGFloat
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, leading)
            .padding(.trailing, 8)
            .padding(.vertical, vertical)
            .background(selected ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : .clear,
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onHover { hover = $0 }
    }
}

extension View {
    func nativeRailRow(selected: Bool = false, leading: CGFloat = 8, vertical: CGFloat = 5) -> some View {
        modifier(NativeRailRow(selected: selected, leading: leading, vertical: vertical))
    }
}
