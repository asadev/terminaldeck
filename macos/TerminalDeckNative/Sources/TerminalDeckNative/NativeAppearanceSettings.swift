import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Appearance (`AppearanceSection.tsx`): Theme and Density, then the
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
            Section {
                NativeSettingsList(section: "appearance", omit: SettingsAppearance.terminalSettings)
            }
            Section("Terminal") {
                NativeTerminalColours() // lane T (web: TerminalColours.tsx)
                if let fontSize = SettingsSchema.setting("appearance.terminalFontSize") {
                    NativeSettingControl(setting: fontSize)
                }
                VStack(alignment: .leading, spacing: 8) {
                    NativeSettingRow(label: "Terminal font", help: choice.help, more: SettingsAppearance.fontMore) {
                        Picker("Terminal font", selection: Binding(
                            get: { family },
                            set: { store.save([SettingsAppearance.fontSetting: .string($0)]) })
                        ) {
                            Text("App default").tag("")
                            ForEach(choice.options, id: \.self) { name in
                                Text(choice.title(name, chosen: family)).tag(name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(store.loading)
                    }
                    Text(SettingsAppearance.previewLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("❯").foregroundStyle(Color.accentColor)
                        Text(SettingsAppearance.previewText)
                    }
                    .font(NativeAppearanceFonts.preview(family: choice.missing ? "" : family, size: size))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    .accessibilityLabel("Font preview")
                }
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
