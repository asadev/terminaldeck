import AppKit
import Observation
import TerminalDeckNativeCore

/// Everything the native Artifacts screen knows, and every call it makes.
///
/// The same engine channels the web page uses — `artifacts:list`,
/// `artifacts:changes`, `fs:read`, `session:list` — through `EngineBridge`, and
/// the same rules (`ArtifactRules`), so the two pages show the same rows, counts
/// and empty states. Opening, revealing and copying are done here, on this Mac.
@MainActor
@Observable
final class ArtifactsScreenModel {
    enum ListState: Equatable {
        case loading
        case ready(ArtifactList)
        case error(String)
    }

    enum HistoryState: Equatable {
        case loading
        case ready(ArtifactHistory)
        case error(String)
    }

    enum SourceState: Equatable {
        case loading
        case read(ArtifactRules.ReadState)
    }

    /// What the page found last time, kept across visits (two minutes fresh), as on the web.
    private static var cache = ArtifactsCache<ArtifactList>()

    private(set) var projectPath: String?
    /// Every session that wrote into this folder by default, as on the web.
    private(set) var scope: ArtifactScope = .all
    private(set) var kind: ArtifactScopeKind = .made
    private(set) var filter = ""
    private(set) var session: String?
    private(set) var selected: String?
    private(set) var showHistory = false
    private(set) var list: ListState = .loading
    /// A re-read under a list that is already drawn.
    private(set) var refreshing = false
    private(set) var history: [String: HistoryState] = [:]
    /// A page's markup, read through the engine when its Source view is shown.
    private(set) var source: [String: SourceState] = [:]
    private(set) var sessionNames: [String: String] = [:]
    /// Said when this Mac would not open the file; it belongs to one press.
    private(set) var openFailed: String?
    /// The clock relative times are read against (ms), moved on by `tick()`.
    private(set) var now = ArtifactsScreenModel.clock()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var listRun = 0
    @ObservationIgnored private var loadedKey: String?
    @ObservationIgnored private var historyCounter = 0
    @ObservationIgnored private var historyRuns: [String: Int] = [:]
    @ObservationIgnored private var namesAsked = false

    static let scanSeconds = 20.0
    static let readSeconds = 10.0
    /// The engine cancels the older scan on the same channel, and every native
    /// call shares one sender with the page. Once the page stops mounting its own
    /// Artifacts view under this one (`native-screens`) this should rarely fire;
    /// a cancelled answer is still asked again before it is shown.
    static let retryDelays: [Duration] = [.milliseconds(300), .milliseconds(900), .milliseconds(1800)]

    static func clock() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: Derived — read off the narrowed list, never the raw answer

    var raw: ArtifactList? {
        if case .ready(let list) = list { return list }
        return nil
    }

    var narrowed: (list: ArtifactList, hidden: Int)? { raw.map(ArtifactRules.onlyArtifacts) }
    var found: ArtifactList? { narrowed?.list }
    var hidden: Int { narrowed?.hidden ?? 0 }
    var sessions: [ArtifactSession] { found?.sessions ?? [] }

    var visible: [Artifact] {
        ArtifactRules.visible(found?.artifacts ?? [], kind: kind, session: session, filter: filter)
    }

    var counts: (made: Int, changed: Int) { ArtifactRules.counts(found?.artifacts ?? []) }

    var current: Artifact? {
        guard let selected else { return nil }
        return visible.first(where: { $0.relPath == selected })
    }

    var statusLine: String {
        switch list {
        case .loading: return "Reading this project’s history…"
        case .error: return ""
        case .ready:
            guard let found else { return "" }
            return ArtifactRules.summarize(found, shown: visible.count, kind: kind, hidden: hidden)
        }
    }

    func url(for artifact: Artifact) -> URL? {
        guard let projectPath else { return nil }
        return ArtifactRules.fileURL(root: projectPath, relPath: artifact.relPath)
    }

    // MARK: Controls

    /// The screen appeared, or the page's project changed: read it, from what is held first.
    func show(project: String?) {
        guard !started || project != projectPath else { return }
        started = true
        projectPath = project
        guard project != nil else { return }
        loadNames()
        startLoad(attempted: false)
    }

    func setScope(_ scope: ArtifactScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        startLoad(attempted: false)
    }

    func setKind(_ kind: ArtifactScopeKind) {
        self.kind = kind
        reconcile()
    }

    func setFilter(_ text: String) {
        filter = text
        reconcile()
    }

    /// A chip toggles: pressing the lit one (or All sessions) clears it.
    func toggleSession(_ id: String?) {
        session = (id == nil || session == id) ? nil : id
        reconcile()
    }

    func select(_ relPath: String?) {
        guard let relPath, relPath != selected else { return }
        selected = relPath
        openFailed = nil
        loadHistoryIfShown()
    }

    func toggleHistory() {
        showHistory.toggle()
        loadHistoryIfShown()
    }

    /// Try again after a failed scan: a fresh read, not the held one.
    func retry() { startLoad(attempted: true) }

    /// Read again now, under the list that is drawn.
    func refresh() {
        guard projectPath != nil else { return }
        startLoad(attempted: false, force: true)
    }

    func retryHistory() {
        guard let selected else { return }
        history[selected] = nil
        loadHistoryIfShown()
    }

    func tick() { now = Self.clock() }

    // MARK: Acting on the file — on this Mac

    func open(_ artifact: Artifact) {
        openFailed = nil
        guard let url = url(for: artifact), NSWorkspace.shared.open(url) else {
            openFailed = "This machine would not open that file."
            return
        }
    }

    func reveal(_ artifact: Artifact) {
        guard let url = url(for: artifact) else { NSSound.beep(); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ artifact: Artifact) {
        guard let url = url(for: artifact) else { NSSound.beep(); return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url.path, forType: .string)
    }

    // MARK: Reading

    private func startLoad(attempted: Bool, force: Bool = false) {
        guard let projectPath else { return }
        listRun += 1
        let run = listRun
        let scope = self.scope
        let key = ArtifactsCache<ArtifactList>.key(root: projectPath, scope: scope)
        if key != loadedKey {
            loadedKey = key
            history = [:]
            historyRuns = [:]
            source = [:]
        }
        let held = attempted ? nil : Self.cache.recall(key, now: Date().timeIntervalSince1970)

        if let held {
            list = .ready(held.value)
            reconcile()
            loadHistoryIfShown()
            if held.fresh && !force {
                refreshing = false
                return
            }
            refreshing = true
        } else {
            list = .loading
            refreshing = false
            selected = nil
            session = nil
            history = [:]
            historyRuns = [:]
        }
        tick()

        Task {
            let request = ArtifactsWire.listRequest(cwd: projectPath, scope: scope)
            var attempt = 0
            while true {
                let answer: ArtifactsAnswer<ArtifactList>
                do {
                    let value = try await Self.invoke(ArtifactsWire.listChannel, args: [request],
                                                      what: "Reading this project’s history", seconds: Self.scanSeconds)
                    answer = ArtifactsWire.list(value)
                } catch {
                    answer = .failed(Self.describe(error))
                }
                guard listRun == run else { return }
                if answer == .cancelled, attempt < Self.retryDelays.count {
                    try? await Task.sleep(for: Self.retryDelays[attempt])
                    attempt += 1
                    guard listRun == run else { return }
                    continue
                }
                refreshing = false
                switch answer {
                case .done(let found):
                    Self.cache.remember(key, found, at: Date().timeIntervalSince1970)
                    if raw != found {
                        history = [:]
                        historyRuns = [:]
                        source = [:]
                    }
                    list = .ready(found)
                    tick()
                    reconcile()
                    loadHistoryIfShown()
                case .cancelled, .failed:
                    // A silent re-read behind a list that is already drawn leaves it alone.
                    if held == nil { list = .error(answer.failureMessage ?? ArtifactRules.cancelledMessage) }
                }
                return
            }
        }
    }

    /// The History pane is on screen with nothing for its file: ask for it.
    func ensureHistory() { loadHistoryIfShown() }

    private func loadHistoryIfShown() {
        guard showHistory, let projectPath, let relPath = selected, history[relPath] == nil else { return }
        historyCounter += 1
        let run = historyCounter
        historyRuns[relPath] = run
        history[relPath] = .loading
        let scope = self.scope
        Task {
            let request = ArtifactsWire.changesRequest(cwd: projectPath, relPath: relPath, scope: scope)
            var attempt = 0
            while true {
                let answer: ArtifactsAnswer<ArtifactHistory>
                do {
                    let value = try await Self.invoke(ArtifactsWire.changesChannel, args: [request],
                                                      what: "Reading the changes", seconds: Self.scanSeconds)
                    answer = ArtifactsWire.history(value)
                } catch {
                    answer = .failed(Self.describe(error))
                }
                guard historyRuns[relPath] == run else { return }
                if answer == .cancelled, attempt < Self.retryDelays.count {
                    try? await Task.sleep(for: Self.retryDelays[attempt])
                    attempt += 1
                    guard historyRuns[relPath] == run else { return }
                    continue
                }
                historyRuns[relPath] = nil
                switch answer {
                case .done(let found): history[relPath] = .ready(found)
                case .cancelled, .failed: history[relPath] = .error(answer.failureMessage ?? ArtifactRules.cancelledMessage)
                }
                return
            }
        }
    }

    /// A page's markup, through the engine's own file read — the same size limit
    /// and folder check the Files page has.
    func loadSource(_ artifact: Artifact) {
        guard let projectPath, source[artifact.relPath] == nil else { return }
        let relPath = artifact.relPath
        let bytes = artifact.onDisk?.bytes
        source[relPath] = .loading
        Task {
            let state: ArtifactRules.ReadState
            do {
                let value = try await Self.invoke(ArtifactsWire.readChannel, args: [projectPath, relPath],
                                                  what: "Reading this file", seconds: Self.readSeconds)
                state = ArtifactRules.describeRead(value, bytes: bytes)
            } catch {
                state = .error(Self.describe(error))
            }
            guard self.projectPath == projectPath, source[relPath] == .loading else { return }
            source[relPath] = .read(state)
        }
    }

    /// Conversation id → the name this window shows that session by. Read once;
    /// a failure is silent (chips keep their time).
    private func loadNames() {
        guard !namesAsked else { return }
        namesAsked = true
        Task {
            guard let value = try? await Self.invoke(ArtifactsWire.sessionsChannel, args: [],
                                                     what: "The sessions", seconds: Self.readSeconds) else { return }
            sessionNames = ArtifactsWire.sessionNames(value)
        }
    }

    /// What the web does in its effects after any change: drop a session filter
    /// whose chip is gone, and keep the page on content.
    private func reconcile() {
        let kept = ArtifactRules.keptSession(session, sessions: sessions)
        if kept != session { session = kept }
        let next = ArtifactRules.selection(current: selected, visible: visible)
        if next != selected {
            selected = next
            loadHistoryIfShown()
        }
    }

    // MARK: Engine

    /// Engine values are plain JSON-shaped Foundation objects, handed between tasks on the main actor.
    private struct Box: @unchecked Sendable { let value: Any }
    private struct Overdue: Error { let message: String }
    private final class Fired: @unchecked Sendable { var value = false }

    /// One engine call with a deadline: the answer, or a sentence saying it did not come.
    private static func invoke(_ channel: String, args: [Any], what: String, seconds: Double) async throws -> Any {
        let payload = Box(value: args)
        let work = Task { @MainActor () throws -> Box in
            let args = (payload.value as? [Any]) ?? []
            return Box(value: try await EngineBridge.shared.invoke(channel, args))
        }
        let fired = Fired()
        let deadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(seconds))
            fired.value = true
            work.cancel()
        }
        defer { deadline.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await work.value.value
            } onCancel: {
                work.cancel()
            }
        } catch {
            if fired.value { throw Overdue(message: ArtifactRules.overdue(what, seconds: seconds)) }
            throw error
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let overdue = error as? Overdue { return overdue.message }
        if let wire = error as? EngineWireError { return ArtifactRules.readFailure(wire.description) }
        return ArtifactRules.readFailure(error.localizedDescription)
    }
}
