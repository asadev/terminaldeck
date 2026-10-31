import SwiftUI

/// The visible row and its click target share the same full-width bounds.
/// This is a regular ButtonStyle: Button retains its callback, disabled state,
/// keyboard activation and accessibility. No gesture or custom click forwarding.
struct DeckRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckRowBody(configuration: configuration)
    }

    private struct DeckRowBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return DeckTokens.cardHover }
            return hovering ? DeckTokens.cardHover : .clear
        }

        var body: some View {
            configuration.label
                .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, minHeight: DeckTokens.Metrics.rowMin,
                       alignment: .leading)
                .contentShape(Rectangle())
                .background(fill,
                            in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
                .onHover { hovering = $0 }
        }
    }
}

// A row owner keeps its existing content padding and action:
// Button(action: open) { RowContent() }.buttonStyle(DeckRowStyle())
// List owners instead use List(selection:) + .tag. A row with separate Copy,
// toggle or menu controls must keep those as sibling Buttons with their own
// styles; do not wrap them inside a navigation Button or apply this style to
// their common ancestor. No segmented-picker or icon-button style is changed.
