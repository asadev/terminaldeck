import SwiftUI

/// The Coding AI control; the surrounding model owns reading and saving.
struct NativeHootProviderSelection: View {
    @Binding var provider: String
    var disabled = false

    var body: some View {
        // A segmented Picker on macOS drops the pictures (M3, 11 Oct): three buttons in one capsule instead.
        HStack(spacing: 2) {
            ForEach([("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini")], id: \.0) { id, name in
                Button { provider = id } label: {
                    HStack(spacing: 5) { Image(nsImage: DeckRowIcon.provider(id)); Text(name).lineLimit(1) }
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(provider == id ? DeckTokens.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(provider == id ? .isSelected : [])
            }
        }
        .padding(2).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckTokens.hairline))
        .fixedSize().disabled(disabled).accessibilityLabel("Coding AI")
    }
}
