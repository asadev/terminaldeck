import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Hand-offs between the native pages

/// What one native page hands the next when it sends the reader there — the
/// page's `onOpenFile(path)` (Source control → "Open in Files") and the `focus`
/// a view is opened onto (Source control's group). Taken once by the page it is
/// for, so a later visit opens plainly.
@MainActor
enum PanelHandoff {
    /// A file (relative to the project) the Files page should open and select.
    private(set) static var pendingFile: String?
    /// The Source control group to bring into view, when the page was opened onto one.
    private(set) static var gitFocus: GitFileGroup?

    /// "Open in Files": the page's own `showFile` (it keeps the open file and shows
    /// Files), with the file also handed over directly for a native Files page that
    /// cannot read the page's `openFile` yet.
    static func openFile(_ path: String) {
        pendingFile = path
        AppModel.shared.web.run(.openFile(path))
    }

    /// Open Source control onto one group — the page's `showPanel('git', focus)`.
    static func showGit(focus: GitFileGroup?) {
        gitFocus = focus
        AppModel.shared.web.run(.showPanel("git", focus: focus?.rawValue))
    }

    /// The page's open file and the focus a view was opened onto, from its `sidebar`
    /// state — set by the page's own doors (a file link, the palette, the Overview
    /// tiles) and by `open-file` / `show-panel`.
    static var pageOpenFile: String? { AppModel.shared.sidebar?.openFile }
    static var pageFocus: String? { AppModel.shared.sidebar?.focus }

    static func takeFile() -> String? {
        defer { pendingFile = nil }
        return pendingFile
    }

    static func takeGitFocus() -> GitFileGroup? {
        defer { gitFocus = nil }
        return gitFocus
    }
}

// MARK: - The screen

/// Files, drawn in Swift — the web page (the Files page in `shell/PanelView.tsx`,
/// `components/FileTree.tsx`, `components/FileViewer.tsx`) one-to-one: the
/// "Ignored" switch over the project's tree, the tree (folders open in place,
/// links marked, a blocked link shown and never followed, per-folder errors and
/// "list shortened"), the keyboard (arrows, Home, End, Return, Space), and beside
/// it the open file — name, its extension, "N lines · size", the numbered lines
/// coloured by language, and the binary, too-large, failed and "Nothing to open"
/// states. An empty project gets the page's blank state with "Show ignored files".
///
/// `fs:list` lists a folder and `fs:read` reads a file, as the page called them.
struct NativeFilesScreen: View {
    @State private var model = FilesScreenModel()

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                VStack(alignment: .leading, spacing: 0) {
                    DeckScopeLine(path: project)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                    FilesPage(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DeckNeedsProject(label: "Files", symbol: "doc")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: project, initial: true) { _, path in
            model.show(path)
            if let file = PanelHandoff.takeFile() ?? PanelHandoff.pageOpenFile { model.select(file) }
        }
        // The page's own door (a file link, a palette row, another page) sets its `openFile`.
        .onChange(of: PanelHandoff.pageOpenFile) { _, file in
            if let file, file != model.selected { model.select(file) }
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class FilesScreenModel {
    enum ViewState: Equatable {
        case empty
        case loading(path: String)
        case failed(path: String, message: String)
        case ready(path: String, read: FileRead)
    }

    private(set) var root: String?
    private(set) var showIgnored = false
    private(set) var tree = FileTreeState()
    /// The open file, relative to the project.
    private(set) var selected: String?
    private(set) var view = ViewState.empty
    /// "Nothing to open" waits a moment, so it never flashes before the tree opens a file.
    private(set) var showEmpty = false

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openedFor: String?
    @ObservationIgnored private var defaultFile: String?
    @ObservationIgnored private var readRun = 0
    @ObservationIgnored private var emptyTimer: Task<Void, Never>?

    /// The page's `panel-cache`: a tree read lately, and the open file, per project.
    private struct HeldTree { let tree: FileTreeState; let defaultFile: String?; let at: Date }
    @ObservationIgnored private static var heldTrees: [String: HeldTree] = [:]
    @ObservationIgnored private static var heldReads: [String: (read: FileRead, at: Date)] = [:]
    @ObservationIgnored private static var openFiles: [String: String] = [:]

    var layout: FilesPageLayout { FilesRules.layout(tree.rootState) }

    func show(_ path: String?) {
        guard path != root else { return }
        save()
        root = path
        showIgnored = false
        openedFor = nil
        selected = path.flatMap { Self.openFiles[$0] }
        restart()
        loadFile()
    }

    func setIgnored(_ on: Bool) {
        save()
        showIgnored = on
        restart()
    }

    func select(_ relPath: String) {
        guard let root else { return }
        selected = relPath
        Self.openFiles[root] = relPath
        tree.focus(relPath)
        loadFile()
    }

    // MARK: The tree

    private func key(_ root: String) -> String { "\(root)|\(showIgnored ? "all" : "visible")" }

    private func save() {
        guard let root, tree.children[FileTreeState.root] != nil else { return }
        Self.heldTrees[key(root)] = HeldTree(tree: tree, defaultFile: defaultFile, at: Date())
    }

    private func restart() {
        generation += 1
        guard let root else {
            tree = FileTreeState()
            return
        }
        if let held = Self.heldTrees[key(root)] {
            var hydrated = held.tree
            hydrated.loading = []
            hydrated.errors = [:]
            tree = hydrated
            defaultFile = held.defaultFile
            autoOpen(FileTreeState.root, entries: tree.children[FileTreeState.root] ?? [])
            if Date().timeIntervalSince(held.at) >= FilesRules.treeFreshSeconds { load(FileTreeState.root, silent: true) }
        } else {
            tree = FileTreeState()
            defaultFile = nil
            load(FileTreeState.root)
        }
    }

    private func load(_ dir: String, silent: Bool = false) {
        guard let root else { return }
        let gen = generation
        if !silent { tree.loadStarted(dir) }
        let options: [String: Any] = ["showIgnored": showIgnored, "withStats": dir == FileTreeState.root]
        Task {
            do {
                let answer = try await EngineDeadline.invoke("fs:list", [root, dir, options], what: FilesRules.listWhat(dir),
                                                             seconds: FilesRules.listDeadlineSeconds)
                guard gen == generation else { return }
                guard let listing = DirListing(json: answer) else { throw EngineDeadline.Overdue(message: "That folder could not be read.") }
                tree.loaded(dir, listing)
                if dir == FileTreeState.root { defaultFile = listing.defaultFile }
                autoOpen(dir, entries: listing.entries)
            } catch {
                guard gen == generation, !silent else { return }
                tree.failed(dir, EngineDeadline.describe(error))
            }
        }
    }

    /// The root's suggested file opens once per project, when nothing is open yet.
    private func autoOpen(_ dir: String, entries: [FsEntry]) {
        guard let root, FilesRules.shouldAutoOpen(autoSelect: true, dir: dir, root: root, openedFor: openedFor, selected: selected) else { return }
        openedFor = root
        guard let defaultFile, let first = entries.first(where: { $0.relPath == defaultFile }) else { return }
        tree.focus(first.relPath)
        if !first.isDir { select(first.relPath) }
    }

    func toggle(_ entry: FsEntry) {
        switch tree.toggle(entry) {
        case .none: break
        case .collapse: tree.collapse(entry.relPath)
        case .expand: tree.expand(entry.relPath)
        case .load: load(entry.relPath)
        }
    }

    /// A press on a row: choose it; a folder opens or closes; a file opens.
    func activate(_ entry: FsEntry) {
        tree.focus(entry.relPath)
        if entry.blocked { return }
        toggle(entry)
        if !entry.isDir { select(entry.relPath) }
    }

    func key(_ key: FileTreeState.Key) -> Bool {
        switch tree.effect(of: key) {
        case .none: return false
        case .focus(let path): tree.focus(path)
        case .toggle(let entry): toggle(entry)
        case .collapse(let dir): tree.collapse(dir)
        case .activate(let entry): activate(entry)
        }
        return true
    }

    // MARK: The open file

    private func loadFile() {
        emptyTimer?.cancel()
        readRun += 1
        let run = readRun
        guard let root, let path = selected else {
            view = .empty
            showEmpty = false
            emptyTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(FilesRules.emptyGraceSeconds))
                guard !Task.isCancelled, let self, run == self.readRun else { return }
                self.showEmpty = true
            }
            return
        }
        showEmpty = false
        let cacheKey = "\(root)|\(path)"
        let held = Self.heldReads[cacheKey]
        if let held { view = .ready(path: path, read: held.read) } else { view = .loading(path: path) }
        if let held, Date().timeIntervalSince(held.at) < FilesRules.readFreshSeconds { return }
        Task {
            do {
                let answer = try await EngineDeadline.invoke("fs:read", [root, path], what: FilesRules.readWhat(path),
                                                             seconds: FilesRules.readDeadlineSeconds)
                guard let read = FileRead(json: answer) else { throw EngineDeadline.Overdue(message: "That file could not be read.") }
                if read.bytes <= FilesRules.maxCachedBytes { Self.heldReads[cacheKey] = (read, Date()) }
                guard run == readRun else { return }
                view = .ready(path: path, read: read)
            } catch {
                guard run == readRun, held == nil else { return }
                view = .failed(path: path, message: EngineDeadline.describe(error))
            }
        }
    }
}

// MARK: - The page

private struct FilesPage: View {
    let model: FilesScreenModel

    var body: some View {
        let layout = model.layout
        if layout == .blank, let root = model.root {
            NativePageEmpty(symbol: "doc", title: model.showIgnored ? "Empty folder" : "Nothing to show",
                            action: model.showIgnored ? nil : PageEmptyAction(label: "Show ignored files", primary: true) { model.setIgnored(true) }) {
                Text(FilesRules.blankReason(root: root, showIgnored: model.showIgnored))
            }
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    IgnoredToggle(on: model.showIgnored) { model.setIgnored(!model.showIgnored) }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    FileTreeView(model: model)
                        .padding(.top, layout == .treeOnly ? 24 : 0)
                }
                .frame(width: layout == .treeOnly ? nil : 280)
                .frame(maxWidth: layout == .treeOnly ? .infinity : 280, maxHeight: .infinity, alignment: .topLeading)
                if layout == .treeAndViewer {
                    FileViewerView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.025))
                }
            }
        }
    }
}

/// "Ignored": show or hide what the project's .gitignore excludes.
private struct IgnoredToggle: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Ignored")
                .font(.caption)
                .foregroundStyle(on ? Color.primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(on ? Color.primary.opacity(0.12) : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(on ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help(on ? "Hide files your .gitignore excludes" : "Show files your .gitignore excludes")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - The tree

private struct FileTreeView: View {
    let model: FilesScreenModel
    @FocusState private var focused: Bool

    var body: some View {
        let tree = model.tree
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch tree.rootState {
                    case .error(let message): TreeMessage(text: message, depth: 0, error: true)
                    case .loading: TreeMessage(text: "Loading…", depth: 0)
                    case .empty: TreeMessage(text: "Nothing to show.", depth: 0)
                    case .ready: EmptyView()
                    }
                    ForEach(tree.rows) { row in
                        let entry = row.entry
                        let open = entry.isDir && tree.expanded.contains(entry.relPath)
                        FileTreeRow(entry: entry, depth: row.depth, open: open,
                                    selected: entry.relPath == model.selected,
                                    focused: focused && entry.relPath == tree.focused,
                                    loading: tree.loading.contains(entry.relPath)) {
                            model.activate(entry)
                            focused = true
                        }
                        .id(entry.relPath)
                        if let error = tree.errors[entry.relPath] {
                            TreeMessage(text: error, depth: row.depth + 1, error: true)
                        }
                        if open && tree.truncated.contains(entry.relPath) {
                            TreeMessage(text: FilesRules.truncatedLine, depth: row.depth + 1)
                        }
                    }
                    if tree.truncated.contains(FileTreeState.root) {
                        TreeMessage(text: FilesRules.truncatedLine, depth: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .onChange(of: tree.focused) { _, path in
                if let path { proxy.scrollTo(path) }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { model.key(.down) ? .handled : .ignored }
        .onKeyPress(.upArrow) { model.key(.up) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { model.key(.right) ? .handled : .ignored }
        .onKeyPress(.leftArrow) { model.key(.left) ? .handled : .ignored }
        .onKeyPress(.home) { model.key(.home) ? .handled : .ignored }
        .onKeyPress(.end) { model.key(.end) ? .handled : .ignored }
        .onKeyPress(.return) { model.key(.activate) ? .handled : .ignored }
        .onKeyPress(.space) { model.key(.activate) ? .handled : .ignored }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project files")
    }
}

private struct TreeMessage: View {
    let text: String
    let depth: Int
    var error = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(error ? Color.red : .secondary)
            .padding(.leading, 8 + CGFloat(depth) * 16)
            .padding(.vertical, 4)
            .textSelection(.enabled)
    }
}

private struct FileTreeRow: View {
    let entry: FsEntry
    let depth: Int
    let open: Bool
    let selected: Bool
    let focused: Bool
    let loading: Bool
    let press: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 10)
                .opacity(entry.isDir && !entry.blocked ? 1 : 0)
            Image(systemName: entry.isDir ? "folder" : "doc")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            if entry.symlink {
                Text("link").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
            }
            if loading { Text("…").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(entry.blocked ? .secondary : .primary)
        .padding(.leading, 6 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 26)
        .background(selected ? Color.primary.opacity(0.12) : (hovering ? Color.primary.opacity(0.05) : .clear), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(focused ? 0.7 : 0), lineWidth: 1.5))
        .contentShape(.rect)
        .onTapGesture(perform: press)
        .onHover { hovering = $0 }
        .help(FilesRules.rowTitle(entry))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(entry.isDir && !entry.blocked ? (open ? "expanded" : "collapsed") : "")
    }
}

// MARK: - The viewer

private struct FileViewerView: View {
    let model: FilesScreenModel

    var body: some View {
        let path = model.selected
        let read = Self.read(model.view, path: path)
        let document = Self.document(read)
        VStack(alignment: .leading, spacing: 0) {
            if let path {
                HStack(spacing: 8) {
                    Text(FilesRules.name(of: path)).font(.body.weight(.semibold)).lineLimit(1).help(path)
                    let ext = FilesRules.extensionOf(path).uppercased()
                    if !ext.isEmpty {
                        Text(ext)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .background(Color.secondary.opacity(0.15), in: .capsule)
                    }
                    Spacer()
                    Text(FilesRules.viewerMeta(lines: document?.count, read: read))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
            Group {
                switch model.view {
                case .empty:
                    if model.showEmpty { NativePageEmpty(symbol: "doc", title: "Nothing to open") }
                case .loading:
                    ViewerNotice(text: "Loading…")
                case .failed(_, let message):
                    ViewerNotice(text: FilesRules.errorLine(message), error: true)
                case .ready(_, .tooLarge(_, let bytes, let limit)):
                    ViewerNotice(text: FilesRules.tooLargeLine(bytes: bytes, limit: limit))
                case .ready(_, .binary(_, let bytes)):
                    ViewerNotice(text: FilesRules.binaryLine(bytes: bytes))
                case .ready(_, .text):
                    if let document, let path {
                        VStack(alignment: .leading, spacing: 0) {
                            if document.shown < document.count {
                                ViewerNotice(text: FilesRules.shownLine(shown: document.shown, count: document.count))
                            }
                            CodeTextView(source: document.source, language: Highlighter.language(of: path), path: path)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(path.map { "Contents of \(FilesRules.name(of: $0))" } ?? "No file open")
    }
}

extension FileViewerView {
    static func read(_ view: FilesScreenModel.ViewState, path: String?) -> FileRead? {
        if case let .ready(shown, read) = view, shown == path { return read }
        return nil
    }

    static func document(_ read: FileRead?) -> (source: String, count: Int, shown: Int)? {
        if case let .text(_, text, _)? = read { return FilesRules.document(text) }
        return nil
    }
}

private struct ViewerNotice: View {
    let text: String
    var error = false

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(error ? Color.red : .secondary)
            .textSelection(.enabled)
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
    }
}

/// The numbered, coloured lines: one selectable text view with a line-number gutter,
/// so a long file scrolls as one document and copies as text.
private struct CodeTextView: NSViewRepresentable {
    let source: String
    let language: Language?
    let path: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 4)
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let gutter = LineNumberRuler(textView: text)
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, context.coordinator.shown != "\(path)\u{0}\(source.count)\u{0}\(source.hashValue)" else { return }
        context.coordinator.shown = "\(path)\u{0}\(source.count)\u{0}\(source.hashValue)"
        text.textStorage?.setAttributedString(Self.coloured(source, language))
        text.scroll(.zero)
        scroll.verticalRulerView?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shown = "" }

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// The tokens as colours — plain text past the highlighting budget, as the page does.
    static func coloured(_ source: String, _ language: Language?) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        guard let language, source.count <= FilesRules.highlightMaxChars else {
            return NSAttributedString(string: source, attributes: base)
        }
        let out = NSMutableAttributedString()
        for token in Highlighter.tokenize(source, language) {
            var attributes = base
            switch token.kind {
            case .plain: break
            case .comment: attributes[.foregroundColor] = NSColor.secondaryLabelColor
            case .string: attributes[.foregroundColor] = NSColor.systemGreen
            case .number: attributes[.foregroundColor] = NSColor.systemOrange
            case .keyword: attributes[.foregroundColor] = NSColor.systemBlue
            case .meta: attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            }
            out.append(NSAttributedString(string: token.text, attributes: attributes))
        }
        return out
    }
}

/// The gutter: each line's number beside its first line fragment.
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var line = 1
        // Count the lines above what is on screen.
        text.enumerateSubstrings(in: NSRange(location: 0, length: characters.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let inset = textView.textContainerInset.height
        let offset = convert(NSPoint.zero, from: textView).y
        var index = characters.location
        while index < NSMaxRange(characters) || (index == 0 && text.length == 0) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
            var fragment = layout.lineFragmentRect(forGlyphAt: min(glyph, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
            if text.length == 0 { fragment = NSRect(x: 0, y: 0, width: 0, height: 15) }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: fragment.minY + inset + offset + (fragment.height - size.height) / 2),
                       withAttributes: attributes)
            line += 1
            if text.length == 0 { break }
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}
