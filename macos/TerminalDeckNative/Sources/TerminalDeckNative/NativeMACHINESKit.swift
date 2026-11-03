import AppKit
import SwiftUI

// READY L1-CORE: every Servers/Devices screen draws with the shared shell components.
typealias MACHINESTokens = DeckTokens
typealias MACHINESRowStyle = DeckRowStyle
typealias MACHINESSettingsFrame = DeckSettingsFrame

struct MACHINESPage<Switcher: View, Actions: View, Content: View>: View {
    let title: String
    let subtitle: String
    let back: (() -> Void)?
    let switcher: Switcher
    let actions: Actions
    let content: Content

    init(title: String, subtitle: String = "", back: (() -> Void)? = nil, @ViewBuilder switcher: () -> Switcher,
         @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle
        self.back = back
        self.switcher = switcher(); self.actions = actions(); self.content = content()
    }

    var body: some View {
        if let back {
            DeckPage(title: title, subtitle: subtitle.isEmpty ? nil : subtitle) {
                Button(action: back) { Image(systemName: "chevron.left").foregroundStyle(.secondary).frame(width: 28, height: 28) }
                    .buttonStyle(.borderless).help("Back to Servers").accessibilityLabel("Back to Servers")
            } switcher: { switcher } actions: { HStack(spacing: DeckTokens.Spacing.s8) { actions } } content: { content }
        } else if Switcher.self == EmptyView.self {
            // No views to switch: an empty switch slot would still claim the header's centre.
            DeckPage(title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                     actions: { HStack(spacing: DeckTokens.Spacing.s8) { actions } }) { content }
        } else {
            DeckPage(title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                     switcher: { switcher }, actions: { HStack(spacing: DeckTokens.Spacing.s8) { actions } }) { content }
        }
    }
}

struct MACHINESCard<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var scheme
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(16).background(MACHINESTokens.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MACHINESTokens.hairline, lineWidth: 1))
            .shadow(color: Color.black.opacity(scheme == .light ? 0.04 : 0), radius: 1, x: 0, y: 1)
    }
}

struct MACHINESGlassSwitch: View {
    @Binding var selection: String
    let items: [String]
    var body: some View {
        GlassSwitch(selection: $selection, items: items.map { DeckSwitchItem(id: $0, title: $0) })
    }
}
