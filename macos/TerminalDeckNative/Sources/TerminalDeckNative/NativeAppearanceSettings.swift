import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Appearance (`AppearanceSection.tsx`): Theme, then the
/// "Terminal" group — Terminal colours, Terminal font size, and the Terminal
/// font picker (only fonts this Mac has, a font chosen elsewhere kept and
/// marked) with a preview at the size sessions use.
struct NativeAppearanceSettings: View {
    @State private var installed = NativeAppearanceFonts.installed()
    private let store = NativeSettingsValues.shared

    var body: some View {
        let family = store.string(SettingsAppearance.fontSetting).trimmingCharacters(in: .whitespacesAndNewlines)
        let size = store.number("appearance.terminalFontSize")
        let choice = SettingsAppearance.fontChoice(chosen: family, installed: installed)
        NativeSettingsPage(sectionId: "appearance") {
            Section("Window") {
                NativeSettingRow(label: "Theme") {
                    Picker("Theme", selection: Binding(get: { store.string("appearance.theme") },
                        set: { store.save(["appearance.theme": .string($0)]) })) {
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                        Text("Match Mac").tag("system")
                    }.pickerStyle(.segmented).frame(width: 240).disabled(store.loading)
                }
            }
            Section("Sessions") {
                NativeTerminalColours() // lane T (web: TerminalColours.tsx)
                NativeSettingRow(label: "Font and size", more: SettingsAppearance.fontMore) {
                    HStack(spacing: 8) {
                        Picker("Font", selection: Binding(get: { family },
                            set: { store.save([SettingsAppearance.fontSetting: .string($0)]) })) {
                            Text("App default").tag("")
                            ForEach(choice.options, id: \.self) { name in Text(choice.title(name, chosen: family)).tag(name) }
                        }.labelsHidden().frame(maxWidth: 180)
                        Stepper("\(Int(size)) pt", value: Binding(get: { Int(size) },
                            set: { store.save(["appearance.terminalFontSize": .number(Double($0))]) }), in: 9...24)
                            .fixedSize()
                    }.disabled(store.loading)
                }
                Text(SettingsAppearance.previewText)
                    .font(NativeAppearanceFonts.preview(family: choice.missing ? "" : family, size: size))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Font preview")
            }
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
