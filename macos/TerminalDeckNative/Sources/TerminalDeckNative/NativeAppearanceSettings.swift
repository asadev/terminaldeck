import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Appearance (owner, 15 Nov; DESIGN.md section 4, items 41, 44, 45): ONE group, three picture tiles side
/// by side (a small drawing of the app's window in that look, the name under it), the chosen one ringed. Nothing else:
/// sessions follow the theme. The terminal colour scheme and the font left the page (the values stay as they
/// are; the text size is General › "Terminal text size").
struct NativeAppearanceSettings: View {
    private let store = NativeSettingsValues.shared
    /// Fixture pictures pass the chosen theme; the app reads it from the stored settings.
    var fixtureTheme: String? = nil
    static let choices: [(value: String, title: String)] = [("system", "Match Mac"), ("light", "Light"), ("dark", "Dark")]
    static let tileSize = CGSize(width: 150, height: 96)

    var body: some View {
        let chosen = fixtureTheme ?? store.string("appearance.theme")
        DeckSettingsScaffold(title: "Appearance") {
            DeckSettingsGroup {
                HStack(alignment: .top, spacing: DeckTokens.Spacing.s16) {
                    ForEach(Self.choices, id: \.value) { choice in
                        Button { if fixtureTheme == nil { store.save(["appearance.theme": .string(choice.value)]) } } label: {
                            VStack(spacing: DeckTokens.Spacing.s8) {
                                NativeAppearanceTile(look: choice.value)
                                    .frame(width: Self.tileSize.width, height: Self.tileSize.height)
                                    .overlay(RoundedRectangle(cornerRadius: 8).inset(by: -3)
                                        .strokeBorder(Color.accentColor, lineWidth: 2).opacity(chosen == choice.value ? 1 : 0))
                                Text(choice.title).font(DeckSettingsLook.rowTitle)
                                    .foregroundStyle(chosen == choice.value ? Color.primary : Color.secondary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.loading && fixtureTheme == nil)
                        .accessibilityLabel(choice.title)
                        .accessibilityAddTraits(chosen == choice.value ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DeckTokens.Spacing.s20)
            }
        }
        .onAppear { if fixtureTheme == nil { store.start() } }
    }
}

/// A small drawing of the app's window in one look: title bar dots, the side panel, a few lines of a page. "Match Mac"
/// is half light, half dark.
struct NativeAppearanceTile: View {
    let look: String
    var body: some View {
        ZStack {
            if look == "system" {
                window(dark: false)
                window(dark: true).mask(GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: geo.size.width * 0.62, y: 0))
                        path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        path.addLine(to: CGPoint(x: geo.size.width * 0.38, y: geo.size.height))
                        path.closeSubpath()
                    }
                })
            } else {
                window(dark: look == "dark")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private func window(dark: Bool) -> some View {
        let desk = dark ? Color(white: 0.22) : Color(red: 0.80, green: 0.86, blue: 0.95)
        let side = dark ? Color(white: 0.17) : Color(white: 0.93)
        let page = dark ? Color(white: 0.11) : Color.white
        let ink = dark ? Color.white.opacity(0.28) : Color.black.opacity(0.14)
        return ZStack {
            desk
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 3) {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 5, height: 5)
                        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 5, height: 5)
                    }
                    .padding(.bottom, 3)
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 30, height: 5)
                    ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 26, height: 4) }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 44)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(side)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(ink).frame(width: 40, height: 5).padding(.bottom, 2)
                    ForEach([62, 54, 66, 40], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.8)).frame(width: CGFloat(width), height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(page)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 0))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
    }
}

/// Which of the web's monospace candidates this Mac really has.
enum NativeAppearanceFonts {
    @MainActor
    static func installed() -> [String] {
        let families = Set(NSFontManager.shared.availableFontFamilies)
        return SettingsAppearance.monoCandidates.filter { families.contains($0) || NSFont(name: $0, size: 12) != nil }
    }

    /// The chosen face at the session size, or the app's own monospace.
    @MainActor
    static func preview(family: String, size: Double) -> Font {
        let points = CGFloat(size > 0 ? size : 13)
        if !family.isEmpty, let font = NSFont(name: family, size: points) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: points) {
            return Font(font)
        }
        return .system(size: points, design: .monospaced)
    }
}
