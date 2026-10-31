import AppKit
import SwiftUI
import TerminalDeckNativeCore

@MainActor enum NativeCatalogProjectColour {
    static func value(_ name: String) -> Color {
        Color(nsColor: DeckTokens.projectColourNS(name))
    }
}

// Catalog surfaces use the shared shell components.
typealias NativeCatalogPage = NativeCatalogCorePage
typealias NativeCatalogTokens = NativeCatalogCoreTokens
typealias NativeCatalogRowStyle = DeckRowStyle
typealias NativeCatalogProjectPicker = NativeCatalogCoreProjectPicker
typealias NativeCatalogSettingsFrame = NativeCatalogCoreSettingsFrame
@MainActor enum NativeCatalogCoreTokens {
    static let page = DeckTokens.page
    static let card = DeckTokens.card
    static let hover = DeckTokens.cardHover
    static let selection = DeckTokens.selection
    static let hairline = DeckTokens.hairline
    static let switchOn = Color.accentColor
}
struct NativeCatalogCorePage<Actions: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let content: () -> Content
    var body: some View {
        DeckPage(title: title, subtitle: subtitle,
                 actions: { HStack(spacing: DeckTokens.Spacing.s8) { actions() } }) { content() }
    }
}
struct NativeCatalogCoreProjectPicker: View {
    @Binding var selection: String?
    let projects: [PROJProject]
    var body: some View {
        ProjectPicker(projects: projects, selection: $selection, openProject: { AppModel.shared.openProject() })
    }
}
struct NativeCatalogCoreSettingsFrame<Switcher: View, Content: View>: View {
    let title: String
    @ViewBuilder let switcher: () -> Switcher
    @ViewBuilder let content: () -> Content
    var body: some View { DeckSettingsFrame(title: title, switcher: switcher) { content() } }
}
