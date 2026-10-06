import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// CommandPalette.tsx, drawn natively: one field whose prefix is the mode — quick open
/// (":42" for a line), ">" commands, "?" / "??" past sessions — the same ranking (Core
/// Fuzzy), keys, empty messages and footer. Files and past sessions come from the engine
/// on the page's own channels; running a command or opening a file is the page's act.
struct NativeCommandPalette: View {
    let request: PaletteRequest
    let opening: Int
    let model: AppModel

    @State private var query = ""
    @State private var active = 0
    @State private var copied = false
    @State private var files: [String] = []
    @State private var filesLoading = false
    @State private var filesUnavailable = false
    @State private var hits: [SessionHit] = []
    @State private var searching = false
    @State private var sessionsError: String?
    @State private var sessionsUnavailable = false
    @State private var searchRun = 0
    @FocusState private var fieldFocused: Bool

    /// Kept for the app's life, like the page's module-level caches.
    @MainActor static var fileCache: [String: [String]] = [:]
    @MainActor static var recents: [String: [String]] = [:]

    private var root: String? { request.projectRoot }
    private var mode: PaletteMode { Palette.mode(of: query, projectRoot: root) }
    private var scope: String { Palette.sessionScope(query) }
    private var term: (text: String, line: Int?) { Palette.term(of: query, projectRoot: root) }

    enum Row: Identifiable {
        case file(String, [MatchRange])
        case command(PaletteCommand, [MatchRange])
        case session(SessionHit, Int)
        var id: String {
            switch self {
            case .file(let p, _): "f:" + p
            case .command(let c, _): "c:" + c.id
            case .session(let h, let i): "s:\(h.sessionId)-\(h.at)-\(i)"
            }
        }
    }

    private var rows: [Row] {
        switch mode {
        case .sessions:
            return hits.enumerated().map { .session($0.element, $0.offset) }
        case .commands:
            return Fuzzy.rank(request.commands, term.text, limit: Palette.maxResults) { $0.searchText }
                .map { .command($0.item, Fuzzy.clamp($0.ranges, from: 0, to: $0.item.title.utf16.count)) }
        case .files:
            let candidates = term.text.trimmingCharacters(in: .whitespaces).isEmpty
                ? Palette.recentsFirst(files, recents: root.flatMap { Self.recents[$0] } ?? []) : files
            return Fuzzy.rank(candidates, term.text, limit: Palette.maxResults, path: true) { $0 }.map { .file($0.item, $0.ranges) }
        }
    }

    var body: some View {
        let rows = self.rows
        let current = rows.isEmpty ? 0 : min(active, rows.count - 1)
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                field(rows: rows, current: current)
                Divider()
                list(rows, current: current)
                if rows.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                Divider()
                footer
                Text(copied ? "Copied to the clipboard." : (rows.count == 1 ? "1 result" : "\(rows.count) results"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 70)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Palette.label(mode))
        }
        .onAppear(perform: start)
        .onChange(of: opening) { start() }
        .onChange(of: query) { active = 0; copied = false; searchSessions() }
        .onChange(of: active) { copied = false }
    }

    // MARK: Parts

    private func field(rows: [Row], current: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: mode == .sessions ? "text.bubble" : mode == .commands ? "chevron.right.square" : "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField(Palette.placeholder(mode, scope: scope, projectRoot: root), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown, .home, .end, .tab, .return, .escape]) { press in
                    handle(press, rows: rows, current: current)
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "np")) { press in
                    guard press.modifiers == .control else { return .ignored }
                    move(press.characters == "n" ? 1 : -1, wrap: true, count: rows.count)
                    return .handled
                }
            if mode == .files && !files.isEmpty {
                Text("\(rows.count)/\(files.count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            if mode == .sessions && searching {
                Text("…").foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func list(_ rows: [Row], current: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(index == current ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                            .onHover { if $0 { active = index } }
                            .onTapGesture { activate(row) }
                            .id(row.id)
                            .accessibilityAddTraits(index == current ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: rows.count < 9)
            .onChange(of: active) { if rows.indices.contains(current) { proxy.scrollTo(rows[current].id) } }
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .file(let path, let ranges):
            let from = Fuzzy.basenameStart(path)
            let units = Array(path.utf16)
            let name = String(decoding: units[from...], as: UTF16.self)
            let dir = String(decoding: units[..<from], as: UTF16.self)
            HStack(spacing: 8) {
                highlighted(name, Fuzzy.clamp(ranges, from: from, to: units.count))
                if !dir.isEmpty {
                    highlighted(dir, Fuzzy.clamp(ranges, from: 0, to: from))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(path)
                }
                Spacer(minLength: 0)
            }
        case .command(let command, let ranges):
            HStack(spacing: 8) {
                if let group = command.group, !group.isEmpty {
                    Text(group).font(.caption).foregroundStyle(.secondary)
                }
                highlighted(command.title, ranges)
                Spacer(minLength: 0)
                if let shortcut = command.shortcut, !shortcut.isEmpty { KeyCap(shortcut) }
            }
        case .session(let hit, _):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scope == "all" && hit.projectName != nil ? hit.projectName! : (hit.tool ?? Palette.roleLabel(hit.role)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                (Text(hit.snippet.truncatedStart ? "…" : "")
                    + highlightedText(hit.snippet.text, Palette.snippetRanges(hit.snippet))
                    + Text(hit.snippet.truncatedEnd ? "…" : ""))
                    .lineLimit(2)
                if hit.isSidechain { Text("sub-agent").font(.caption2).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
                Text(Palette.relativeTime(hit.at, now: Date().timeIntervalSince1970 * 1000))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func highlighted(_ text: String, _ ranges: [MatchRange]) -> Text { highlightedText(text, ranges) }

    private func highlightedText(_ text: String, _ ranges: [MatchRange]) -> Text {
        guard !ranges.isEmpty else { return Text(text) }
        return Fuzzy.segments(text, ranges).reduce(Text("")) { result, segment in
            result + (segment.matched ? Text(segment.text).bold().foregroundColor(.accentColor) : Text(segment.text))
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 3) { KeyCap("↑"); KeyCap("↓"); Text("navigate") }
            HStack(spacing: 3) { KeyCap("↩"); Text(mode == .sessions ? "copy" : mode == .commands ? "run" : "open") }
            HStack(spacing: 3) { KeyCap("esc"); Text("close") }
            if mode != .commands { HStack(spacing: 3) { KeyCap(">"); Text("for commands") } }
            if mode != .sessions && root != nil { HStack(spacing: 3) { KeyCap("?"); Text("for past sessions") } }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyMessage: String {
        Palette.emptyMessage(mode: mode, term: term.text, scope: scope, sessionsUnavailable: sessionsUnavailable,
                             sessionsError: sessionsError, searching: searching,
                             filesLoading: filesLoading, filesUnavailable: filesUnavailable)
    }

    // MARK: Behaviour

    private func start() {
        query = Palette.seed(mode: request.mode, projectRoot: root)
        active = 0
        copied = false
        fieldFocused = true
        loadFiles()
    }

    private func close() {
        model.answerDialog(NativeDialogName.palette, "close")
    }

    private func move(_ delta: Int, wrap: Bool, count: Int) {
        active = Palette.nextIndex(active, count: count, delta: delta, wrap: wrap)
    }

    private func handle(_ press: KeyPress, rows: [Row], current: Int) -> KeyPress.Result {
        switch press.key {
        case .downArrow: move(1, wrap: true, count: rows.count)
        case .upArrow: move(-1, wrap: true, count: rows.count)
        case .pageDown: move(Palette.pageJump, wrap: false, count: rows.count)
        case .pageUp: move(-Palette.pageJump, wrap: false, count: rows.count)
        case .home: active = Palette.nextIndex(0, count: rows.count, delta: 0, wrap: false)
        case .end: active = Palette.nextIndex(rows.count - 1, count: rows.count, delta: 0, wrap: false)
        case .tab: move(press.modifiers.contains(.shift) ? -1 : 1, wrap: true, count: rows.count)
        case .return: if rows.indices.contains(current) { activate(rows[current]) }
        case .escape: close()
        default: return .ignored
        }
        return .handled
    }

    private func activate(_ row: Row) {
        switch row {
        case .session(let hit, _):
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(hit.snippet.text, forType: .string)
        case .command(let command, _):
            model.answerDialog(NativeDialogName.palette, "run", argument: ["id": command.id])
        case .file(let path, _):
            guard let root else { return }
            Self.recents[root] = Array(([path] + (Self.recents[root] ?? []).filter { $0 != path }).prefix(Palette.maxRecents))
            var arg: [String: Any] = ["root": root, "path": path]
            if let line = term.line { arg["line"] = line }
            model.answerDialog(NativeDialogName.palette, "open-file", argument: arg)
        }
    }

    private func loadFiles() {
        guard let root else { return }
        if let cached = Self.fileCache[root] { files = cached; filesUnavailable = false; filesLoading = false; return }
        filesLoading = true
        filesUnavailable = false
        Task {
            defer { filesLoading = false }
            guard let answer = try? await EngineBridge.shared.invoke("search:files", [["root": root]]) as? [String: Any],
                  answer["ok"] as? Bool == true, let list = answer["files"] as? [String] else {
                files = []
                filesUnavailable = true
                return
            }
            Self.fileCache[root] = list
            files = list
        }
    }

    private func searchSessions() {
        guard mode == .sessions, let root else { return }
        let trimmed = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchRun += 1
        let run = searchRun
        if trimmed.count < 2 {
            hits = []; searching = false; sessionsError = nil; sessionsUnavailable = false
            Task { _ = try? await EngineBridge.shared.invoke("session-search:cancel") }
            return
        }
        searching = true
        sessionsError = nil
        let scope = self.scope
        Task {
            try? await Task.sleep(for: Palette.sessionDebounce)
            guard run == searchRun else { return }
            do {
                let request: [String: Any] = ["cwd": root, "query": trimmed, "scope": scope,
                                              "roles": Palette.searchRoles, "maxHits": Palette.maxSessionHits]
                let answer = try await EngineBridge.shared.invoke("session-search:run", [request]) as? [String: Any] ?? [:]
                guard run == searchRun else { return }
                if answer["ok"] as? Bool == true,
                   let raw = answer["hits"], JSONSerialization.isValidJSONObject(raw),
                   let data = try? JSONSerialization.data(withJSONObject: raw),
                   let decoded = try? JSONDecoder().decode([SessionHit].self, from: data) {
                    hits = decoded; searching = false; sessionsUnavailable = false
                } else if (answer["error"] as? String) != "cancelled" {
                    hits = []; searching = false; sessionsError = answer["message"] as? String
                }
            } catch {
                guard run == searchRun else { return }
                hits = []; searching = false; sessionsUnavailable = true
            }
        }
    }
}
