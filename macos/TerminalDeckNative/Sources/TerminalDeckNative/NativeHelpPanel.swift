import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// HelpPanel.tsx, drawn natively: a search field, the section list (Getting started,
/// The views, Shortcuts, Troubleshooting, About), each section's hint and topics, the
/// shortcut table, and the About card with "Copy version details". The words are the
/// page's own (native-help.ts); the versions come from the engine (settings:about).
///
/// Lane G uses it for Settings › Help › How it works:
///   NativeHelpPanel(hideSections: ["shortcuts", "about"], onOpenDebug: { … }, autoFocus: false)
struct NativeHelpPanel: View {
    var initialSection = "start"
    var hideSections: Set<String> = []
    var initialQuery = ""
    var onOpenDebug: (() -> Void)? = nil
    var autoFocus = true

    @State private var content: HelpContent?
    @State private var about: AboutInfo?
    @State private var section = ""
    @State private var query = ""
    @State private var copied = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let sections = (content?.sections ?? []).filter { !hideSections.contains($0.id) }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let current = sections.contains { $0.id == section } ? section : (sections.first?.id ?? "start")
        let shown = (content?.topics ?? []).filter { topic in sections.contains { $0.id == topic.section } }
        let matches = Help.search(query, in: shown)
        let visible = searching ? matches : matches.filter { $0.section == current }
        let hasShortcuts = sections.contains { $0.id == "shortcuts" }
        let hasAbout = sections.contains { $0.id == "about" }
        let shortcutMatches = searching ? Keymap.search(query).count : Keymap.all.count
        let showShortcuts = hasShortcuts && (searching ? shortcutMatches > 0 : current == "shortcuts")
        let showAbout = hasAbout && (searching ? Help.matchesAbout(query) : current == "about")
        let nothing = visible.isEmpty && !showShortcuts && !showAbout
        let resultCount = visible.count + (showShortcuts ? shortcutMatches : 0) + (showAbout ? 1 : 0)
        let appName = about?.name ?? "This app"

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(hasShortcuts ? "Search help and shortcuts" : "Search help", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search help")
                if searching {
                    Text(Help.resultLabel(resultCount)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(0.6)))

            if content == nil {
                NativePageNote("Loading…", busy: true)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    if !searching && sections.count > 1 {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sections, id: \.id) { entry in
                                Button { section = entry.id } label: {
                                    Text(entry.label)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(entry.id == current ? Color.accentColor.opacity(0.16) : .clear))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(entry.id == current ? .isSelected : [])
                            }
                        }
                        .frame(width: 170)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Help sections")
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !searching, let hint = sections.first(where: { $0.id == current })?.hint {
                                Text(hint).foregroundStyle(.secondary)
                            }
                            if nothing {
                                Text("Nothing in the help matches “\(query.trimmingCharacters(in: .whitespaces))”.").foregroundStyle(.secondary)
                            }
                            ForEach(visible) { topic in topicView(topic, appName: appName) }
                            if !searching && current == "trouble", let onOpenDebug {
                                Button("Open the Debug panel", action: onOpenDebug).buttonStyle(.link)
                            }
                            if showShortcuts {
                                if searching { Text("Shortcuts").font(.headline) }
                                shortcutTable(searching ? query : "")
                            }
                            if showAbout { aboutCard }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .task {
            section = initialSection
            query = initialQuery
            if autoFocus { searchFocused = true }
            content = await NativeHelpContent.load()
            about = await NativeHelpContent.about()
        }
    }

    private func topicView(_ topic: HelpTopic, appName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(topic.title).font(.headline)
            ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text): filled(text, appName)
                case .note(let text): filled(text, appName).font(.callout).foregroundStyle(.secondary)
                case .code(let code):
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                case .steps(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(index + 1).").monospacedDigit(); filled(item, appName) }
                    }
                case .bullets(let items):
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); filled(item, appName) }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func filled(_ text: String, _ appName: String) -> Text {
        Help.fill(text, appName: appName).reduce(Text("")) { result, run in
            result + (run.code ? Text(run.text).font(.system(.body, design: .monospaced)) : Text(run.text))
        }
    }

    private func shortcutTable(_ query: String) -> some View {
        let groups = Keymap.grouped(Keymap.search(query))
        return VStack(alignment: .leading, spacing: 14) {
            if groups.isEmpty { Text("No shortcut matches that.").foregroundStyle(.secondary) }
            ForEach(groups, id: \.scope) { group in
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.title).font(.subheadline.weight(.semibold))
                    Text(group.hint).font(.caption).foregroundStyle(.secondary)
                    ForEach(group.bindings) { binding in
                        HStack(alignment: .firstTextBaseline) {
                            Text(binding.label)
                            if binding.passthrough { Text("passes through").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            ForEach(Array(binding.formatted().enumerated()), id: \.offset) { index, chord in
                                if index > 0 { Text("or").font(.caption).foregroundStyle(.tertiary) }
                                KeyCap(chord)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var aboutCard: some View {
        if let about {
            VStack(alignment: .leading, spacing: 8) {
                Text(about.name).font(.title3.weight(.semibold))
                Text(about.tagline).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(about.rows, id: \.0) { label, value in
                        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
                    }
                }
                Button("Copy version details") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(about.copyText, forType: .string)
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                }
                if copied { Text("Copied.").font(.callout).foregroundStyle(.secondary) }
                Text("Filing a bug? The Debug panel builds a support bundle with all of this plus the recent log, with credentials and your home directory stripped out.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Version information is not available in this window.").foregroundStyle(.secondary)
        }
    }
}

/// The help's words, read once from the page (native-help.ts), and the versions.
@MainActor
enum NativeHelpContent {
    private static var cached: HelpContent?

    static func load() async -> HelpContent? {
        if let cached { return cached }
        let raw = try? await AppModel.shared.web.webView.evaluateJavaScript("JSON.stringify(window.tdHelp || null)") as? String
        guard let data = raw?.data(using: .utf8), let content = try? JSONDecoder().decode(HelpContent.self, from: data) else { return nil }
        cached = content
        return content
    }

    static func about() async -> AboutInfo? {
        guard let answer = try? await EngineBridge.shared.invoke("settings:about"), JSONSerialization.isValidJSONObject(answer),
              let data = try? JSONSerialization.data(withJSONObject: answer) else { return nil }
        return try? JSONDecoder().decode(AboutInfo.self, from: data)
    }
}

/// HelpDialog: "Help — How this works, and what to do when it does not."
struct NativeHelpSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Help").font(.headline)
                    Text("How this works, and what to do when it does not.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            NativeHelpPanel()
        }
        .padding(20)
        .frame(width: 760, height: 600)
    }
}
