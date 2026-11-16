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

    var body: some View {
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
            NativeShortcutsList(hidden: hidden)
        }
        .frame(width: 560, height: 560)
    }
}

/// The search field and the grouped list, shared by the sheet and Settings → Shortcuts.
struct NativeShortcutsList: View {
    let hidden: Set<String>
    /// The sheet puts the keyboard in its search field; the Settings page leaves it with the sidebar.
    var autoFocus = true
    /// The sheet's own side margin; the Settings page uses the page's (0 here).
    var inset: CGFloat = 20
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let live = Keymap.live(hidden: hidden)
        let matches = Keymap.search(query, in: live)
        let groups = Keymap.grouped(matches)
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, inset)
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
                .padding(.vertical, 20).padding(.horizontal, inset)
            }
        }
        .onAppear { if autoFocus { searchFocused = true } }
    }
}

/// Settings → Shortcuts (owner, 14 Nov: the foot's Shortcuts button became a page). The commands whose feature is off
/// are left out, as the sheet did.
struct NativeShortcutsSettings: View {
    /// Pictures pass the hidden set; the app reads it from the page.
    var fixtureHidden: Set<String>?
    @State private var hidden: Set<String> = []
    var body: some View {
        DeckSettingsFrame(title: "Shortcuts") {
            NativeShortcutsList(hidden: fixtureHidden ?? hidden, autoFocus: false)
                .padding(.top, DeckTokens.Spacing.s8)
        }
        .onAppear { if fixtureHidden == nil { NativeSettingsShortcuts.hidden { hidden = $0 } } }
    }
}

/// The page's feature state (`features.v2`) decides which commands are hidden (lane G). Read once per visit.
@MainActor
enum NativeSettingsShortcuts {
    static func hidden(_ done: @escaping @MainActor (Set<String>) -> Void) {
        let model = AppModel.shared
        guard !model.isUITestFixture else { done([]); return }
        model.web.webView.evaluateJavaScript("localStorage.getItem('features.v2')") { value, _ in
            MainActor.assumeIsolated {
                var state: [String: Any] = [:]
                if let text = value as? String, let data = text.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { state = parsed }
                done(FeatureCommands.hidden(featureState: state))
            }
        }
    }
}
