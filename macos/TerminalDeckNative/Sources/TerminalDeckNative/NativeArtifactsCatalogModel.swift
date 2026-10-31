import AppKit
import Observation
import TerminalDeckNativeCore

/// Catalog-specific presentation. Scans remain on the existing granted artifact channels.
@MainActor
@Observable
final class NativeArtifactsCatalogModel {
    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", documents = "Documents", pictures = "Pictures", videos = "Videos"
        var id: String { rawValue }
        static func of(_ path: String) -> Kind? {
            switch ArtifactRules.kindOf(path) {
            case "Document", "Web page": .documents
            case "Image": .pictures
            case "Video", "Sound": .videos
            default: nil
            }
        }
    }
    struct Row: Identifiable, Equatable {
        let root: String
        let artifact: Artifact
        let source: [String: String]
        /// Made by a session that was working in this project's folder (the scan's `own`).
        var own = false
        var id: String { root + "\u{0}" + artifact.relPath }
        var projectID: String { artifact.projectID }
        var request: [String: Any] { ["cwd": root, "relPath": artifact.relPath, "projectId": projectID] }
        /// Inside the project folder, or exactly the recorded path of a file a session made outside it.
        var url: URL? { ArtifactRules.locatedURL(root: root, relPath: artifact.relPath) }
        /// A short honest word for where an outside file is ("session scratch folder"); nil inside the folder.
        var location: String? { artifact.isOutside ? ArtifactRules.outsideLocation(artifact.relPath) : nil }
    }
    enum Presentation: Identifiable {
        case file(Row), source(Row)
        var id: String { switch self { case .file(let row): "file:" + row.id; case .source(let row): "source:" + row.id } }
    }
    /// One folder whose history could not be read. `id` is the folder; `trying` while its own Try Again runs.
    struct Failure: Identifiable { let id: String; let projectID: String; let message: String; var trying = false }
    struct Day: Identifiable { let id: Date; let title: String; let rows: [Row] }
    var projectID: String? {
        didSet { if persistSelection { UserDefaults.standard.set(projectID, forKey: "catalog.artifacts.project") } }
    }
    var kind: Kind = .all
    var search = ""
    var selected: Row?
    var presented: Presentation?
    var pendingDelete: Row?
    private(set) var isFixture = false
    private(set) var fixtureThumbnails: [String: NSImage] = [:]
    private(set) var pendingAction: String?
    private(set) var actionNotice: String?
    private(set) var rows: [Row] = []
    private(set) var failures: [Failure] = []
    private(set) var loading = false
    private(set) var actionError: String?
    private(set) var texts: [String: String] = [:]
    /// A page's own `<title>`, shown on its card while its picture is made or when it cannot be.
    private(set) var titles: [String: String] = [:]
        private(set) var sessionNames: [String: String] = [:]
    private(set) var sessions: [(id: String, title: String)] = []
    /// How many session histories the engine could not read and left out (each counted once, however
    /// many folders it was skipped for). Their paths are in the log, not on the page.
    private(set) var skippedHistories = 0
    @ObservationIgnored private var skippedByRoot: [String: Set<String>] = [:]
    @ObservationIgnored private var run = 0
    /// One reading at a time: the scanner keeps one list per caller, and a reading takes seconds.
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var scanAgain = false
    @ObservationIgnored private var roots: [String] = []
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var costTask: Task<Void, Never>?
    @ObservationIgnored private let persistSelection: Bool
    @ObservationIgnored private var previewRuns = Set<String>()
    @ObservationIgnored private let invoke: @MainActor (String, [Any]) async throws -> Any

    init(persistSelection: Bool = true, invoke: @escaping @MainActor (String, [Any]) async throws -> Any = { channel, arguments in
        try await EngineBridge.shared.invoke(channel, arguments)
    }) {
        self.invoke = invoke
        self.persistSelection = persistSelection
        projectID = persistSelection ? UserDefaults.standard.string(forKey: "catalog.artifacts.project") : nil
    }
    var visible: [Row] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter {
            (projectID == nil || $0.projectID == projectID) &&
            (kind == .all || Kind.of($0.artifact.relPath) == kind) &&
            (needle.isEmpty || ($0.artifact.name + " " + $0.artifact.relPath + " " + sourceName($0) + " " + NativePROJLabels.shared.name(for: $0.projectID) + " " + ($0.location ?? "")).localizedCaseInsensitiveContains(needle))
        }.sorted { $0.artifact.lastAt == $1.artifact.lastAt ? $0.id < $1.id : $0.artifact.lastAt > $1.artifact.lastAt }
    }
    var days: [Day] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: visible) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.artifact.lastAt / 1000)) }
        return groups.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today" : calendar.isDateInYesterday(day) ? "Yesterday" : day.formatted(.dateTime.month(.wide).day().year())
            return Day(id: day, title: title, rows: groups[day] ?? [])
        }
    }
    var visibleFailures: [Failure] { failures.filter { projectID == nil || $0.projectID == projectID } }
    func sourceName(_ row: Row) -> String {
        if let title = row.source["title"], !title.isEmpty { return title }
        if row.source["kind"] == "hoot" { return "Hoot" }
        if let id = row.artifact.sessionIds.first { return sessionNames[id] ?? "Session" }
        return "Saved file"
    }
    /// The card's second line. A file made outside the project folder says where it is in a few words
    /// (never the long scratch path); a file inside it says who made it.
    func subtitle(_ row: Row) -> String {
        let project = NativePROJLabels.shared.name(for: row.projectID)
        if let location = row.location { return "\(project) · \(location)" }
        return "\(sourceName(row)) · \(project)"
    }
    /// The preview's heading line: who, which project and, for an outside file, where.
    func detailLine(_ row: Row) -> String {
        ([sourceName(row), NativePROJLabels.shared.name(for: row.projectID)] + (row.location.map { [$0] } ?? [])).joined(separator: " · ")
    }
    /// The whole path on hover; the row itself stays short.
    func pathHelp(_ row: Row) -> String {
        guard let location = row.location else { return row.artifact.relPath }
        return "In the \(location): \(row.artifact.relPath)"
    }
    /// One row per file. A project folder inside another registered folder (a project inside the home
    /// folder) is read twice, and a file one project's session made in another's folder is found by both.
    /// The session's own project keeps the row; then the deeper folder; then the row inside its folder.
    static func oneRowPerFile(_ rows: [Row]) -> [Row] {
        var best: [String: Row] = [:], order: [String] = []
        for row in rows {
            let key = row.url?.path ?? row.id
            guard let held = best[key] else { best[key] = row; order.append(key); continue }
            let wins: Bool
            if row.own != held.own { wins = row.own }
            else if row.root.count != held.root.count { wins = row.root.count > held.root.count }
            else { wins = !row.artifact.isOutside && held.artifact.isOutside }
            if wins { best[key] = row }
        }
        return order.compactMap { best[$0] }
    }
    func show(roots: [String]) {
        let next = Array(Set(roots)).sorted()
        guard self.roots != next || subscriptions.isEmpty else { return }
        for root in self.roots where !next.contains(root) { NativeCostWatch.release(root) }
        for root in next where !self.roots.contains(root) { NativeCostWatch.retain(root) }
        self.roots = next
        failures.removeAll { !next.contains($0.id) }
        skippedByRoot = skippedByRoot.filter { next.contains($0.key) }
        skippedHistories = skippedByRoot.values.reduce(into: Set<String>()) { $0.formUnion($1) }.count
        if subscriptions.isEmpty {
            subscriptions.append(EngineBridge.shared.on("artifacts:changed") { [weak self] _ in self?.queueRefresh() })
            subscriptions.append(EngineBridge.shared.on("cost:update") { [weak self] value in
                guard let self, let cwd = (value.first as? [String: Any])?["cwd"] as? String,
                      self.roots.contains(cwd), self.costTask == nil else { return }
                // Cost events are the transcript watcher signal too. Coalesce a busy session's
                // pulses without postponing the refresh forever, and ignore other folders.
                self.costTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self else { return }
                    self.costTask = nil
                    self.refresh()
                }
            })
        }
        refresh()
    }
    private func queueRefresh(after delay: Duration = .milliseconds(250)) {
        eventTask?.cancel()
        eventTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            refresh()
        }
    }
    func stop() {
        subscriptions.forEach { $0.cancel() }; subscriptions = []
        eventTask?.cancel(); eventTask = nil
        costTask?.cancel(); costTask = nil
        roots.forEach { NativeCostWatch.release($0) }; roots = []
        run += 1; loading = false; scanAgain = false
    }
    /// One quiet line for what was left out, or nil when everything was read.
    var skippedNote: String? {
        guard skippedHistories > 0 else { return nil }
        return skippedHistories == 1 ? "1 session history couldn't be read" : "\(skippedHistories) session histories couldn't be read"
    }
    /// One folder's artifacts, as the engine lists them now.
    private func scan(_ root: String) async throws -> [Row] {
        // Artifacts alone, the project's own sessions first, and enough of them to reach older work.
        let answer = try await call("artifacts:list", [["cwd": root, "scope": "all", "only": "artifacts", "maxSessions": 200, "maxArtifacts": 600]])
        // A folder that belongs to no project (its sessions are "Independent") is not one the engine lists by
        // folder. It adds nothing, and it is never an error card.
        if let reply = answer as? [String: Any], reply["ok"] as? Bool != true,
           ArtifactRules.isQuietRefusal(error: reply["error"] as? String,
                                        projectID: PROJProjects.resolve(projectID: nil, folder: root, projects: NativePROJLabels.shared.projects)) {
            return []
        }
        switch ArtifactsWire.list(answer) {
        case .done(let list):
            // A history that could not be read was skipped, not a failure: everything else is listed.
            skippedByRoot[root] = Set((answer as? [String: Any])?["skippedKeys"] as? [String] ?? [])
            skippedHistories = skippedByRoot.values.reduce(into: Set<String>()) { $0.formUnion($1) }.count
            let wireRows = (answer as? [String: Any])?["artifacts"] as? [[String: Any]] ?? []
            let wire = Dictionary(wireRows.compactMap { value -> (String, [String: String])? in
                guard let path = value["relPath"] as? String else { return nil }
                let source = value["source"] as? [String: Any] ?? [:]
                return (path, source.reduce(into: [:]) { result, element in
                    if let text = element.value as? String { result[element.key] = text }
                    else if let number = element.value as? NSNumber { result[element.key] = number.stringValue }
                })
            }, uniquingKeysWith: { _, newer in newer })
            let own = Set(wireRows.compactMap { $0["own"] as? Bool == true ? $0["relPath"] as? String : nil })
            return list.artifacts.filter { ArtifactRules.isArtifact($0.relPath) && Kind.of($0.relPath) != nil }
                .map { Row(root: root, artifact: $0, source: wire[$0.relPath] ?? [:], own: own.contains($0.relPath)) }
        case .cancelled: throw CatalogError("History reading was interrupted. Try Again.")
        case .failed(let message): throw CatalogError(message)
        }
    }
    private func failure(_ root: String, _ error: any Error) -> Failure {
        Failure(id: root, projectID: PROJProjects.resolve(projectID: nil, folder: root, projects: NativePROJLabels.shared.projects), message: error.localizedDescription)
    }
    /// Reads every folder again. A reading already running is left to finish (restarting it on every
    /// change in a busy project meant it never did) and one more follows it. The cards already on
    /// screen, error cards included, stay where they are until their own folder has answered.
    func refresh() {
        guard !scanning else { scanAgain = true; return }
        scanning = true; scanAgain = false
        run += 1
        let ticket = run, roots = roots
        let first = rows.isEmpty
        loading = first && failures.isEmpty
        Task {
            defer {
                scanning = false
                // A change that arrived meanwhile is read a little later, not back to back.
                if scanAgain, run == ticket { scanAgain = false; queueRefresh(after: .seconds(4)) }
            }
            var collected: [Row] = [], errors: [Failure] = []
            // The existing scanner has one list cancellation slot per caller. Read folders in order.
            for root in roots {
                guard run == ticket else { return }
                do {
                    collected += try await scan(root)
                    guard run == ticket else { return }
                    // That folder answered: its error card, if it had one, goes; nobody else's card moves.
                    failures.removeAll { $0.id == root }
                    // The first time, each project's artifacts appear as soon as its history is read.
                    if first { rows = Self.oneRowPerFile(collected); loading = rows.isEmpty && failures.isEmpty }
                } catch {
                    guard run == ticket else { return }
                    let failed = failure(root, error)
                    errors.append(failed)
                    if let index = failures.firstIndex(where: { $0.id == root }) { failures[index] = failed } else { failures.append(failed) }
                }
            }
            guard run == ticket else { return }
            rows = Self.oneRowPerFile(collected); failures = errors; loading = false
            if let value = try? await call("session:list", []), let list = value as? [[String: Any]] {
                sessionNames = ArtifactsWire.sessionNames(value)
                sessions = list.compactMap { row in
                    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                    return (id, row["title"] as? String ?? "Session")
                }
            }
        }
    }
    /// Try Again on one card: that folder alone is read again. Its card says "Trying…" where it is,
    /// and no other card, row or error moves while it does.
    func retry(_ failure: Failure) {
        guard !isFixture, let index = failures.firstIndex(where: { $0.id == failure.id }), !failures[index].trying else { return }
        failures[index].trying = true
        // A whole reading is under way: it reaches this folder too, and replaces the card with what it finds.
        guard !scanning else { scanAgain = true; return }
        scanning = true
        let root = failure.id, ticket = run
        Task {
            defer {
                scanning = false
                if scanAgain, run == ticket { scanAgain = false; queueRefresh(after: .seconds(1)) }
            }
            do {
                let found = try await scan(root)
                guard run == ticket else { return }
                rows = Self.oneRowPerFile(rows.filter { $0.root != root } + found)
                failures.removeAll { $0.id == root }
            } catch {
                guard run == ticket, let index = failures.firstIndex(where: { $0.id == root }) else { return }
                failures[index] = self.failure(root, error)
            }
        }
    }
    /// A page's card shows its picture, and until that is made, its own title. Never its markup.
    /// The one file the row names is opened, and only it: inside the project folder or outside it.
    func preview(_ row: Row) {
        guard !isFixture, row.artifact.onDisk != nil, !previewRuns.contains(row.id), titles[row.id] == nil else { return }
        guard ArtifactRules.kindOf(row.artifact.relPath) == "Web page", let url = row.url else { return }
        previewRuns.insert(row.id)
        Task {
            defer { previewRuns.remove(row.id) }
            let text = await Task.detached(priority: .utility, operation: { NativeArtifactsCatalogModel.readExact(url) }).value
            titles[row.id] = text.flatMap(ArtifactRules.pageTitle) ?? ""
        }
    }
    /// The start of one recorded file as text, to find a page's title: a regular file at exactly that
    /// path (never a link, a folder or a pipe), at most 64 KB read, nil for anything else.
    nonisolated static func readExact(_ url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count), as: UTF8.self)
    }
    func reveal(_ row: Row) { guard !isFixture else { return }; if let url = row.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    func copy(_ row: Row) {
        guard !isFixture else { return }
        guard let url = row.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
    func showPreview(_ row: Row) { selected = row; presented = .file(row) }
    func openSource(_ row: Row) { selected = row; presented = .source(row) }
    func send(_ row: Row, to target: String) { action("artifacts:send", row: row, extra: ["target": target]) }
    func requestDelete(_ row: Row) { pendingDelete = row }
    func deleteFromList(_ row: Row) { action("artifacts:hide", row: row) }
    func clearError() { actionError = nil }
    private func action(_ channel: String, row: Row, extra: [String: Any] = [:]) {
        actionError = nil; actionNotice = nil
        guard !isFixture else { actionError = "Actions don't run in render fixtures."; return }
        guard pendingAction == nil else { return }
        pendingAction = channel == "artifacts:send" ? "Sending \(row.artifact.name)…" : "Removing \(row.artifact.name)…"
        Task {
            defer { pendingAction = nil }
            do {
                let value = try await call(channel, [row.request.merging(extra, uniquingKeysWith: { _, new in new })])
                guard let answer = value as? [String: Any], answer["ok"] as? Bool == true else {
                    throw CatalogError((value as? [String: Any])?["message"] as? String ?? "That action is unavailable. Try Again.")
                }
                actionNotice = channel == "artifacts:send" ? "Sent \(row.artifact.name)." : "Removed \(row.artifact.name) from the list."
                if channel == "artifacts:hide" { rows.removeAll { $0.id == row.id }; if selected?.id == row.id { selected = nil; presented = nil } }
            } catch { actionError = error.localizedDescription }
        }
    }
    private struct CatalogError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
    private func call(_ channel: String, _ args: [Any]) async throws -> Any {
        try await invoke(channel, args)
    }
}
