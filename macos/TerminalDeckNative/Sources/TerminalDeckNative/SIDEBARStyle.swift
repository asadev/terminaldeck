import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Side-panel rows use the shared full-width row style (SHELL-CORE).
typealias SIDEBARRowStyle = DeckRowStyle

@MainActor
enum SIDEBARChrome {
    static var frame: Color { DeckTokens.frame }
    static var switchOn: Color { DeckTokens.switchOn }
    static var cardHover: Color { DeckTokens.cardHover }
    static var selection: Color { DeckTokens.selection }
    static func dot(_ hex: String) -> Color {
        Color(nsColor: TerminalColour(hex: hex)?.nsColor ?? .secondaryLabelColor)
    }
    static func status(_ value: String?) -> Color {
        switch StatusMeaning(value) {
        case .working: .green
        case .needsInput: .orange
        case .failed: .red
        case .ready, .completed, .exited: .secondary
        }
    }
}
