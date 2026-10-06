import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Source control, drawn in Swift — the web page (`components/GitPanel.tsx`)
/// one-to-one: the branch line (detached, ahead/behind, the change count,
/// Refresh), the four groups (Conflicts, Staged, Changes, Untracked) with each
/// file's kind, name, folder and line counts, and beside them the chosen file's
/// change, with "Open in Files". The same empty, loading and error states:
/// reading, could not read (Try again), nothing to track (Create a repository),
/// working tree clean.
///
/// `git:watch` reads and keeps the status coming on `git:status-changed`;
/// `git:unwatch` when the page goes; `git:status` refreshes; `git:diff` reads a
/// change; `git:init` creates a repository — the page's channels.
struct NativeGitScreen: View {
    @State private var model = GitScreenModel()

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                VStack(alignment: .leading, spacing: 0) {
                    DeckScopeLine(path: project)
                        .padding(.bottom, 16)
                    GitPage(model: model)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                DeckNeedsProject(label: "Source control", symbol: "arrow.triangle.branch")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: project, initial: true) { _, path in model.show(path) }
        // The page opened Source control onto a group while it is already showing.
        .onChange(of: PanelHandoff.pageFocus) { _, focus in model.focus(focus) }
        .onDisappear { model.leave() }
    }
}

// MARK: - Model

@MainActor
@Observable
final class GitScreenModel {
    enum DiffState: Equatable {
        case idle
        case loading(path: String)
        case ready(path: String, text: String)
        case failed(path: String, message: String)
    }

    private(set) var cwd: String?
    private(set) var status: GitStatusResult?
    private(set) var loading = true
    private(set) var failure: String?
    private(set) var initialising = false
    private(set) var chosen: String?
    private(set) var diff = DiffState.idle
    /// The group asked for when the page was opened onto one (the Overview tile, a command).
    private(set) var focusGroup: GitFileGroup?

    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var diffRun = 0
    /// The file and group the diff on screen was read for; a status push for the same one does not read it again.
    @ObservationIgnored private var diffKey: String?
    /// What each folder last read, so coming back shows it at once (the page's `panel-cache`).
    @ObservationIgnored private static var held: [String: GitStatusResult] = [:]

    func show(_ path: String?) {
        guard path != cwd else { return }
        leave()
        cwd = path
        focusGroup = PanelHandoff.takeGitFocus() ?? PanelHandoff.pageFocus.flatMap(GitFileGroup.init(rawValue:))
        guard let path else { return }
        failure = nil
        let cached = Self.held[path]
        status = cached
        loading = cached == nil
        chosen = nil
        diff = .idle
        subscription = EngineBridge.shared.on("git:status-changed") { [weak self] args in
            guard let self, args.count >= 2, args[0] as? String == self.cwd, let next = GitStatusResult(json: args[1]) else { return }
            Self.held[path] = next
            self.apply(next)
        }
        Task {
            do {
                let first = try await EngineDeadline.invoke("git:watch", [path], what: "Reading this repository",
                                                            seconds: GitRules.watchDeadlineSeconds)
                guard let next = GitStatusResult(json: first) else { throw EngineDeadline.Overdue(message: "git could not read this folder") }
                Self.held[path] = next
                guard cwd == path else { return }
                apply(next)
                loading = false
            } catch {
                guard cwd == path else { return }
                loading = false
                // Something already on screen stays; a failure is only shown in its place.
                if cached == nil { failure = EngineDeadline.describe(error) }
            }
        }
    }

    func focus(_ value: String?) {
        guard let group = value.flatMap(GitFileGroup.init(rawValue:)) else { return }
        focusGroup = group
    }

    func leave() {
        subscription?.cancel()
        subscription = nil
        if let cwd { EngineBridge.shared.send("git:unwatch", [cwd]) }
        cwd = nil
    }

    func refresh() {
        guard let asked = cwd else { return }
        failure = nil
        Task {
            do {
                let answer = try await EngineDeadline.invoke("git:status", [asked], what: "Reading this repository",
                                                             seconds: GitRules.watchDeadlineSeconds)
                guard let next = GitStatusResult(json: answer) else { return }
                Self.held[asked] = next
                if cwd == asked { apply(next) }
            } catch {
                if cwd == asked { failure = EngineDeadline.describe(error) }
            }
        }
    }

    func startRepo() {
        guard let asked = cwd, !initialising else { return }
        initialising = true
        failure = nil
        Task {
            do {
                let answer = try await EngineDeadline.invoke("git:init", [asked], what: "Creating this repository",
                                                             seconds: GitRules.watchDeadlineSeconds)
                if let next = GitStatusResult(json: answer) {
                    Self.held[asked] = next
                    if cwd == asked { apply(next) }
                }
            } catch {
                if cwd == asked { failure = EngineDeadline.describe(error) }
            }
            if cwd == asked { initialising = false }
        }
    }

    var groups: [GitGroup] { status?.repo.map(GitRules.groups) ?? [] }

    var current: (file: GitFile, group: GitGroup)? {
        for group in groups {
            if let file = group.files.first(where: { $0.path == chosen }) { return (file, group) }
        }
        return nil
    }

    func choose(_ path: String) {
        guard path != chosen else { return }
        chosen = path
        loadDiff()
    }

    func retryDiff() { loadDiff(force: true) }

    private func apply(_ next: GitStatusResult) {
        status = next
        // Keep the choice while its file is still listed; otherwise the first with a diff.
        let rows = groups.flatMap(\.files)
        if rows.isEmpty {
            chosen = nil
            diff = .idle
        } else if let chosen, rows.contains(where: { $0.path == chosen }) {
            loadDiff()
        } else {
            chosen = GitRules.firstChoice(groups)
            loadDiff(force: true)
        }
    }

    private func loadDiff(force: Bool = false) {
        guard let cwd, let current else {
            diff = .idle
            diffKey = nil
            return
        }
        let path = current.file.path
        let key = "\(current.group.key.rawValue):\(path):\(current.file.binary)"
        guard force || key != diffKey else { return }
        diffKey = key
        if current.file.path.hasSuffix("/") || current.file.binary {
            diff = .ready(path: path, text: "")
            return
        }
        diffRun += 1
        let run = diffRun
        diff = .loading(path: path)
        let mode = GitRules.diffMode(current.group.key)
        Task {
            do {
                let answer = try await EngineDeadline.invoke("git:diff", [cwd, path, mode], what: "Reading this change",
                                                             seconds: GitRules.diffDeadlineSeconds)
                guard run == diffRun else { return }
                diff = .ready(path: path, text: answer as? String ?? "")
            } catch {
                guard run == diffRun else { return }
                diff = .failed(path: path, message: EngineDeadline.describe(error))
            }
        }
    }
}

/// One engine call with a deadline: the answer, or the page's sentence saying it
/// did not come ("Reading this repository did not answer within 15 seconds.").
@MainActor
enum EngineDeadline {
    struct Overdue: Error { let message: String }

    private final class Box: @unchecked Sendable {
        let value: Any
        init(_ value: Any) { self.value = value }
    }

    private final class Fired: @unchecked Sendable { var value = false }

    static func invoke(_ channel: String, _ args: [Any?] = [], what: String, seconds: Double) async throws -> Any {
        let payload = Box(args)
        let work = Task { @MainActor () throws -> Box in
            Box(try await EngineBridge.shared.invoke(channel, payload.value as? [Any?] ?? []))
        }
        let fired = Fired()
        let timer = Task { @MainActor in
            try await Task.sleep(for: .seconds(seconds))
            fired.value = true
            work.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await work.value.value
        } catch {
            if fired.value { throw Overdue(message: ArtifactRules.overdue(what, seconds: seconds)) }
            throw error
        }
    }

    /// The sentence for a failure: the deadline's own, or the engine's without Electron's wrapper.
    static func describe(_ error: Error) -> String {
        if let overdue = error as? Overdue { return overdue.message }
        if let wire = error as? EngineWireError { return ArtifactRules.readFailure(wire.description) }
        return ArtifactRules.readFailure(error.localizedDescription)
    }
}

// MARK: - The page

private struct GitPage: View {
    let model: GitScreenModel

    var body: some View {
        if model.loading && model.status == nil {
            NativePageNote("Reading repository…", busy: true)
        } else if model.status == nil, let failure = model.failure {
            NativePageEmpty(symbol: "arrow.triangle.branch", title: "Could not read this repository",
                            action: PageEmptyAction(label: "Try again", primary: true, perform: model.refresh)) {
                Text(failure)
            }
        } else if let repo = model.status?.repo {
            VStack(alignment: .leading, spacing: 16) {
                GitHeader(repo: repo, refresh: model.refresh)
                if repo.clean {
                    NativePageEmpty(symbol: "arrow.triangle.branch", title: "Working tree clean")
                } else {
                    GitBody(model: model)
                }
            }
        } else {
            let view = GitRules.unavailable(model.status)
            NativePageEmpty(symbol: "arrow.triangle.branch", title: view.title,
                            action: view.canInit ? PageEmptyAction(label: model.initialising ? "Creating…" : "Create a repository",
                                                                   primary: true, busy: model.initialising, perform: model.startRepo) : nil) {
                Text(view.message)
            }
        }
    }
}

private struct GitHeader: View {
    let repo: GitRepoStatus
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(repo.branch.label)
                .font(.body.weight(.semibold))
                .foregroundStyle(repo.branch.detached ? .secondary : .primary)
                .help(repo.branch.upstream ?? "")
            if repo.branch.ahead > 0 {
                Text("↑\(repo.branch.ahead)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help("\(repo.branch.ahead) commit(s) to push")
            }
            if repo.branch.behind > 0 {
                Text("↓\(repo.branch.behind)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .help("\(repo.branch.behind) commit(s) to pull")
            }
            Spacer()
            if repo.changeCount > 0 {
                Text("\(repo.changeCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: .capsule)
            }
            Button(action: refresh) {
                Label("Refresh git status", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
    }
}

private struct GitBody: View {
    let model: GitScreenModel

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 900
            let layout = narrow ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                GitGroups(model: model)
                    .frame(width: narrow ? nil : 420)
                    .frame(maxHeight: narrow ? geometry.size.height * 0.4 : .infinity)
                if let current = model.current {
                    GitDiffPane(model: model, file: current.file, group: current.group)
                }
            }
        }
    }
}

enum GitColors {
    static func kind(_ kind: GitChangeKind) -> Color {
        switch kind {
        case .added: .green
        case .modified: .primary
        case .deleted: .red
        case .renamed, .copied, .typechange: .blue
        case .untracked: .secondary
        case .conflicted: .orange
        case .unknown: .secondary
        }
    }
}

private struct GitGroups: View {
    let model: GitScreenModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(group.label).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                Text("\(group.files.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                            ForEach(group.files.prefix(GitRules.maxRowsPerGroup)) { file in
                                GitRow(file: file, selected: file.path == model.chosen) { model.choose(file.path) }
                                    // Where Hoot's tour points at a changed file (the page's `data-drive-anchor="git-file:<cwd>:<path>"`).
                                    .driveAnchor(DriveAnchor.gitFile(cwd: model.cwd ?? "", path: file.path).id)
                            }
                            if group.files.count > GitRules.maxRowsPerGroup {
                                Text("\(group.files.count - GitRules.maxRowsPerGroup) more not shown")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(group.key == model.focusGroup ? Color.accentColor.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
                        .id(group.key)
                    }
                }
            }
            .onAppear {
                if let focus = model.focusGroup { proxy.scrollTo(focus, anchor: .top) }
            }
            .onChange(of: model.focusGroup) { _, focus in
                if let focus { withAnimation { proxy.scrollTo(focus, anchor: .top) } }
            }
        }
    }
}

private struct GitRow: View {
    let file: GitFile
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Text(GitRules.changeLabel(file.kind, code: file.code))
                    .font(.callout)
                    .foregroundStyle(GitColors.kind(file.kind))
                    .frame(width: 66, alignment: .leading)
                Text(GitRules.baseName(file.path)).lineLimit(1)
                Text(GitRules.rowDetail(file))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                if file.binary {
                    Text("bin").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        if let added = file.insertions, added > 0 { Text("+\(added)").foregroundStyle(.green) }
                        if let removed = file.deletions, removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? Color.primary.opacity(0.12) : (hovering ? Color.primary.opacity(0.05) : .clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(GitRules.rowTitle(file))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct GitDiffPane: View {
    let model: GitScreenModel
    let file: GitFile
    let group: GitGroup

    var body: some View {
        let reason = GitRules.noDiffReason(file)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(file.path)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.path)
                Text(GitRules.diffMeta(file, group: group.key)).font(.callout).foregroundStyle(.secondary)
                if !file.path.hasSuffix("/") {
                    Button("Open in Files") { PanelHandoff.openFile(file.path) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .padding(.top, 4)
                }
            }
            .padding(16)

            Group {
                if let reason {
                    NativePageNote(reason).padding(16)
                } else {
                    switch model.diff {
                    case .idle:
                        NativePageNote("Reading this change…", busy: true)
                    case .loading(let path) where path == file.path:
                        NativePageNote("Reading this change…", busy: true)
                    case let .failed(path, message) where path == file.path:
                        VStack(spacing: 10) {
                            NativePageNote(message).fixedSize(horizontal: false, vertical: true)
                            Button("Try again", action: model.retryDiff)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case let .ready(path, text) where path == file.path:
                        GitDiffBody(lines: GitRules.parseUnifiedDiff(text).filter { $0.kind != .meta }, group: group.key)
                    default:
                        NativePageNote("Reading this change…", busy: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes in \(file.path)")
    }
}

private struct GitDiffBody: View {
    let lines: [GitDiffLine]
    let group: GitFileGroup

    var body: some View {
        if lines.isEmpty {
            NativePageNote(GitRules.noTextChange(group)).padding(16)
        } else {
            let shown = Array(lines.prefix(GitRules.maxDiffLines))
            GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.kind == .add ? "+" : line.kind == .del ? "−" : " ")
                                .frame(width: 18)
                                .foregroundStyle(tint(line.kind))
                                .accessibilityHidden(true)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .hunk ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(fill(line.kind))
                    }
                    if lines.count > shown.count {
                        Text(GitRules.moreLines(lines.count - shown.count))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .textSelection(.enabled)
                // Top-left, as the page lays it out: a short change does not float in the middle.
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
            }
            }
        }
    }

    private func tint(_ kind: GitDiffLineKind) -> Color {
        switch kind {
        case .add: .green
        case .del: .red
        default: .secondary
        }
    }

    private func fill(_ kind: GitDiffLineKind) -> Color {
        switch kind {
        case .add: Color.green.opacity(0.14)
        case .del: Color.red.opacity(0.14)
        default: .clear
        }
    }
}
