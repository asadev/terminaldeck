import SwiftUI
import TerminalDeckNativeCore

/// ShortcutsSheet.tsx / ShortcutsPopover.tsx, drawn natively: a search field with its
/// count, then Anywhere / In a session / In a dialog, each binding with its chords
/// ("or" between them) and "passes through" where the app never intercepts it.
struct NativeShortcutsSheet: View {
    /// Commands whose feature is off (FeatureCommands.hidden).
    let hidden: Set<String>
    /// The Settings flavour (ShortcutsPopover): "They cannot be changed yet."
    var fromSettings = false
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let live = Keymap.live(hidden: hidden)
        let matches = Keymap.search(query, in: live)
        let groups = Keymap.grouped(matches)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Keyboard shortcuts").font(.headline)
                    Text(fromSettings ? "They cannot be changed yet." : "Every shortcut this window answers to.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search shortcuts")
                Text(Keymap.countLabel(query: query, matches: matches.count, live: live.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6)))
            .padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if groups.isEmpty {
                        Text(Keymap.emptyLabel(query: query)).foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.scope) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.subheadline.weight(.semibold))
                            Text(group.hint).font(.caption).foregroundStyle(.secondary)
                            ForEach(group.bindings) { binding in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(binding.label)
                                    if binding.passthrough {
                                        Text("passes through")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .help("Deck never intercepts this")
                                    }
                                    Spacer()
                                    ForEach(Array(binding.formatted().enumerated()), id: \.offset) { index, chord in
                                        if index > 0 { Text("or").font(.caption).foregroundStyle(.tertiary) }
                                        KeyCap(chord)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .frame(width: 560, height: 560)
        .onAppear { searchFocused = true }
    }
}

/// For the native Settings window (lane G): show the shortcuts over Settings, as the
/// page's ShortcutsPopover did. The feature state is the page's own (`features.v2`).
@MainActor
enum NativeSettingsShortcuts {
    static func present() {
        let model = AppModel.shared
        model.web.webView.evaluateJavaScript("localStorage.getItem('features.v2')") { value, _ in
            MainActor.assumeIsolated {
                var state: [String: Any] = [:]
                if let text = value as? String, let data = text.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { state = parsed }
                model.showSettingsShortcuts(hidden: FeatureCommands.hidden(featureState: state))
            }
        }
    }
}
