import AppKit
import Foundation
import Observation
import TerminalDeckNativeCore

@MainActor @Observable
final class AWAgentsWatchModel {
    typealias Read = @MainActor (String, [Any?]) async throws -> Any
    var agents: [AWWatchAgent] = [] { didSet { remerge() } }
    var notices: [String] = []
    var selectedID: String?
    var entries: [AWWatchEntry] = []
    var loading = true
    var counts: [String: Int] = [:]
    var reading = false
    var error: String?
    var conversationError: String?
    var conversationNotice: String?
    var updatedAt: Double?
    var stateFilter: String?
    var search = ""
    var follow = true
    var expandedEntries: Set<String> = []
    /// AGT: every agent on this Mac in other apps (read-only), and which ones to show.
    var device: [AGTDeviceAgent] = [] { didSet { remerge() } }
    var deviceLoaded = false
    var deviceCost: (wallMS: Double, cpuMS: Double)?
    var source: AGTWatchSource = .all
    var selectedProjectID: String?
    var inspectorPresented = false
    var stopRequested = false
    var resumeRequested = false
    var changing = false
    var metric: AWLoadMetric = .cpu
    var history: [AWLoadPoint] = []
    var sampledAt = Date().timeIntervalSince1970 * 1000
    var heavyJob = "—"
    var heavyJobBusy = false
    var usageError: String?
    private var metrics: [String: NativeRPCValue] = [:] { didSet { remerge() } }
    /// The rows with each one's latest metrics merged in: made once when the rows or a metrics
    /// packet change, not on every read (a render reads them about fifteen times).
    private var merged: [AWWatchAgent] = []
    @ObservationIgnored private var holdingMerge = false
    @ObservationIgnored private var viewerID = UUID().uuidString
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var lastSequence: Double?
    @ObservationIgnored private var listDeadline: Task<Void, Never>?
    @ObservationIgnored private var metricsTask: Task<Void, Never>?
    @ObservationIgnored private var active = false
    /// Change events re-read the list at most once per 1.5 s, one read at a time (see `AGTRefreshPacer`).
    @ObservationIgnored private lazy var eventPacer = AGTRefreshPacer { [weak self] in
        guard let self, self.active else { return }
        self.refresh()
        await self.loadTask?.value
    }
    var subtitle: String {
        "\(unfiltered.filter { $0.state != .finished }.count) running on this Mac · \(unfiltered.filter { $0.state == .working }.count) working · \(unfiltered.filter { $0.state == .waiting }.count) waiting"
    }
    var totalTokens: Double? {
        let values = visible.compactMap(\.tokensToday)
        return visible.isEmpty ? 0 : values.count != visible.count ? nil : values.reduce(0, +)
    }
    var totalMemory: Double? {
        if selectedProjectID == nil, source == .all, search.isEmpty, let value = lastLoad["agentMemoryBytes"].number { return value }
        let activeRows = visible.filter { $0.state != .finished && $0.state != .offline }
        let values = activeRows.compactMap(\.memoryBytes)
        return activeRows.isEmpty ? 0 : values.count != activeRows.count ? nil : values.reduce(0, +)
    }
    @ObservationIgnored private var lastLoad = NativeRPCValue.object([])
    func projectName(_ row: AWWatchAgent) -> String {
        row.kind == "hoot" ? "Every project" : NativePROJLabels.shared.name(for: PROJProjects.resolve(projectID: row.projectID, folder: row.project, projects: NativePROJLabels.shared.projects))
    }
    func sourceCount(_ source: AGTWatchSource) -> Int {
        unfiltered.filter { source == .all || ($0.isOtherApp ? source == .other : source == .terminalDeck) }.count
    }
    private func remerge() {
        guard !holdingMerge else { return }
        let other = device.filter { !$0.app.isTerminalDeck }.compactMap(AGTWatchSource.row)
        let all = Dictionary((other + agents.filter { $0.machineID.isEmpty }).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        merged = AWWatchProjection.sorted(Array(all.values)).map { row in
            guard let sample = metrics[row.id] else { return row }
            var wire = row.wireValue
            for field in sample.fields ?? [] where field.key != "id" {
                if field.key == "since", field.value.number == nil { continue }
                wire = wire.setting(field.key, field.value)
            }
            return AWWatchAgent.decode(wire) ?? row
        }
    }
    private var unfiltered: [AWWatchAgent] {
        merged.filter { row in
            let knownInactive = metrics[row.id]?["isRunning"].bool == false
            let stoppedOther = row.isOtherApp && row.state == .finished
            return (!knownInactive || stoppedOther) &&
                (row.kind == "hoot" || selectedProjectID == nil ||
                 PROJProjects.resolve(projectID: row.projectID, folder: row.project,
                     projects: NativePROJLabels.shared.projects) == selectedProjectID)
        }
    }
    /// Metrics events update cells and history only; never reread a transcript.
    func acceptMetrics(_ value: NativeRPCValue) {
        // One merge for the packet, however many of its parts change the rows.
        holdingMerge = true
        var rowsChanged = false
        defer {
            holdingMerge = false
            if rowsChanged { remerge() }
        }
        if let sequence = value["sequence"].number {
            if let previous = lastSequence, sequence < previous { return }
            if sequence > (lastSequence ?? -1), let at = value["load"]["at"].number,
               let previous = history.last?.at, at < previous { history.removeAll() }
            lastSequence = sequence
        }
        if let rows = value["agents"].elements {
            let currentOther = Set(agents.filter(\.isOtherApp).map { $0.id + ":" + $0.state.rawValue })
            let inventory = rows.compactMap(AWWatchAgent.decode)
            let newOther = Set(inventory.filter(\.isOtherApp).map { $0.id + ":" + $0.state.rawValue })
            agents = inventory
            rowsChanged = true
            if active && newOther != currentOther { refreshDevice(invalidate: false) }
            if let selectedID, !inventory.contains(where: { $0.id == selectedID }) { select(nil) }
        }
        if let rows = value["metrics"].elements {
            metrics = Dictionary(rows.compactMap { row in row["id"].string.map { ($0, row) } }, uniquingKeysWith: { _, last in last })
            rowsChanged = true
        }
        if let load = value["load"].fields, !load.isEmpty, let at = value["load"]["at"].number, at >= (history.last?.at ?? 0) {
            sampledAt = at; lastLoad = value["load"]
            let point = AWLoadPoint(at: at, agentCPU: value["load"]["agentCPU"].number,
                otherCPU: value["load"]["otherCPU"].number, memoryPressure: value["load"]["memoryPressure"].number,
                tokensPerMinute: value["load"]["tokensPerMinute"].number, freeMemoryBytes: value["load"]["freeMemoryBytes"].number,
                processes: value["load"]["processes"].number.flatMap { Int(exactly: $0) })
            if history.last?.at == at { history[history.count - 1] = point }
            else { history.append(point) }
            history = Array(history.filter { $0.at >= at - 300_000 }.suffix(150))
        }
        if let busy = value["heavyJob"]["busy"].bool { heavyJob = busy ? "1 of 1" : "0 of 1"; heavyJobBusy = busy }
        if value["error"] != .missing { self.usageError = value["error"].string }
    }
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var deviceGeneration = 0
    @ObservationIgnored private var deviceWatch = AGTDeviceWatch()
    @ObservationIgnored private var transcriptWatch: AGTFileWatch?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var watch: UUID?
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private let read: Read
    @ObservationIgnored private let iconProvider: @MainActor (AWWatchAgent) -> AGTIcon?
    /// DKA adds HOOT's published channel once the shared stream is registered.
    let sourceEvents: [String]
    init(sourceEvents: [String] = ["session:created", "session:status", "session:exit", "session:removed", "session:renamed", "tasks:changed", "hoot:chat:changed", "agents-watch:changed"],
         iconProvider: @escaping @MainActor (AWWatchAgent) -> AGTIcon? = { _ in nil },
         read: @escaping Read = { channel, args in try await EngineBridge.shared.invoke(channel, args, timeout: 10) }) {
        self.sourceEvents = sourceEvents
        self.read = read
        self.iconProvider = iconProvider
    }
    private func profile(for row: AWWatchAgent) -> AgentProfile? {
        let state = TasksStore.shared.state
        let assignee = state?.tasks.first { $0.id == row.taskID }?.assignee
        return state?.agents.first { profile in
            profile.id == assignee || (profile.name == row.name &&
                PROJProjects.resolve(projectID: nil, folder: profile.defaultProject,
                    projects: NativePROJLabels.shared.projects) == row.resolvedProjectID)
        }
    }
    /// The agent id and chosen colour behind a row, so its glyph matches every other screen.
    func colourIdentity(for row: AWWatchAgent) -> (id: String, colour: String?) {
        let profile = profile(for: row)
        return (profile?.id ?? row.sourceID, AGTIcon.colour(profile?.icon))
    }
    func icon(for row: AWWatchAgent) -> AGTIcon {
        if let icon = iconProvider(row) { return icon }
        let profile = profile(for: row)
        if let icon = AGTIcon.parse(profile?.icon) { return icon }
        return .symbol(row.kind == "hoot" ? "bird" : row.provider == "codex" ? "cpu" : row.provider == "gemini" ? "sparkles" : "terminal")
    }
    var selected: AWWatchAgent? { combined.first { $0.id == selectedID } }
    /// Terminal Deck's own agents (from Agents at work) and, without duplicates, the ones in other apps.
    var combined: [AWWatchAgent] {
        unfiltered.filter { source == .all || ($0.isOtherApp ? source == .other : source == .terminalDeck) }
    }
    var visible: [AWWatchAgent] { AWWatchProjection.filtered(combined, state: stateFilter, query: search) }
    func deviceAgent(_ rowID: String?) -> AGTDeviceAgent? {
        guard let rowID, rowID.hasPrefix(AGTWatchSource.prefix) else { return nil }
        return device.first { $0.id == String(rowID.dropFirst(AGTWatchSource.prefix.count)) }
    }
    /// Counts over what the source filter shows (before the state filter).
    var shownCounts: [String: Int] {
        var counts = ["all": visible.count]
        for state in AWWatchState.allCases { counts[state.rawValue] = visible.filter { $0.state == state }.count }
        return counts
    }
    func start() {
        guard !active else { return }
        active = true
        watchGeneration += 1
        viewerID = UUID().uuidString
        let watcher = viewerID, watchVersion = watchGeneration
        NativePROJLabels.shared.start()
        for event in sourceEvents {
            subscriptions.append(EngineBridge.shared.on(event) { [weak self] args in
                guard let self, self.active else { return }
                if event == "agents-watch:changed", let raw = args.first,
                   let value = try? NativeRPCValue.fromFoundation(raw), value["metrics"].elements != nil {
                    self.acceptMetrics(value)
                } else { self.eventPacer.request() }
            })
        }
        refresh()
        // Other apps' agents: read when shown, on app launch/quit and Claude/Codex file events,
        // with resource updates pushed by the engine only while this page is visible.
        deviceWatch.start { [weak self] in self?.refreshDevice() }
        refreshDevice()
        metricsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await self.read("agents-watch:watch", [["viewerID": watcher, "visible": true]])
                if !self.active || self.watchGeneration != watchVersion {
                    _ = try? await self.read("agents-watch:watch", [["viewerID": watcher, "visible": false]])
                    return
                }
                if let wire = try? NativeRPCValue.fromFoundation(value) { self.acceptMetrics(wire) }
            } catch { if self.active { self.usageError = "Couldn't read process usage. " + error.localizedDescription } }
        }
    }
    func refreshDevice(invalidate: Bool = true) {
        deviceGeneration += 1
        let mine = deviceGeneration
        deviceTask?.cancel()
        deviceTask = Task { [weak self] in
            do {
                guard let self else { return }
                if invalidate { _ = try await self.read("agents-watch:invalidate", []) }
                let raw = try await self.read("agents-watch:devices", [])
                try Task.checkCancellation()
                guard self.deviceGeneration == mine else { return }
                let value = try NativeRPCValue.fromFoundation(raw)
                self.device = (value["agents"].elements ?? []).compactMap(AGTDeviceAgent.decode)
                if let wall = value["cost"]["wallMS"].number, let cpu = value["cost"]["cpuMS"].number { self.deviceCost = (wall, cpu) }
                self.deviceLoaded = true
                if let selectedID = self.selectedID, selectedID.hasPrefix(AGTWatchSource.prefix), self.deviceAgent(selectedID) == nil { self.select(nil) }
            } catch is CancellationError {
            } catch { self?.deviceLoaded = true }
        }
    }
    func stop() {
        active = false
        reading = false
        listDeadline?.cancel(); listDeadline = nil
        eventPacer.cancel()
        watchGeneration += 1
        metricsTask?.cancel(); metricsTask = nil
        let read = self.read, viewer = viewerID
        Task { _ = try? await read("agents-watch:watch", [["viewerID": viewer, "visible": false]]) }
        deviceWatch.stop(); deviceTask?.cancel(); deviceTask = nil
        transcriptWatch?.stop(); transcriptWatch = nil
        generation += 1; readGeneration += 1
        loadTask?.cancel(); readTask?.cancel(); loadTask = nil; readTask = nil
        subscriptions.forEach { $0.cancel() }; subscriptions.removeAll()
        closeWatch()
    }
    func retry() {
        guard active else { return }
        stop()
        error = nil; usageError = nil
        start()
        if inspectorPresented { readSelected() }
    }
    func refresh() {
        if agents.isEmpty { loading = true }
        if loading, listDeadline == nil {
            listDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.active, self.loading else { return }
                self.generation += 1; self.loadTask?.cancel()
                self.loading = false; self.error = "Couldn't read the agents. Try Again."
                self.listDeadline = nil
            }
        }
        generation += 1
        let mine = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let request: [String: Any] = ["limit": 200]
                guard let self else { return }
                if self.active { _ = try? await self.read("agents-watch:invalidate", []) }
                let raw = try await self.read("agents-watch:list", [request])
                try Task.checkCancellation()
                guard self.generation == mine else { return }
                let value = try NativeRPCValue.fromFoundation(raw)
                let rows = (value["agents"].elements ?? []).compactMap(AWWatchAgent.decode)
                if rows != agents { agents = rows }
                counts = Dictionary((value["counts"].fields ?? []).compactMap { field in field.value.number.map { (field.key, Int($0)) } }, uniquingKeysWith: { first, _ in first })
                counts["all"] = Int(value["allTotal"].number ?? Double(agents.count))
                notices = (value["notices"].elements ?? []).compactMap(\.string)
                if value["hasMore"].bool == true { notices.append("Showing the first 200 agents. Narrow the search to find others.") }
                listDeadline?.cancel(); listDeadline = nil
                loading = false; error = nil
                if let selectedID, !selectedID.hasPrefix(AGTWatchSource.prefix), !agents.contains(where: { $0.id == selectedID }) { select(nil) }
                if self.selectedID == nil { select(visible.first?.id) }
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == mine else { return }
                listDeadline?.cancel(); listDeadline = nil
                loading = false; self.error = error.localizedDescription
            }
        }
    }
    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id; entries = []; expandedEntries.removeAll(); conversationError = nil; conversationNotice = nil; updatedAt = nil
        readGeneration += 1; readTask?.cancel(); closeWatch()
        if inspectorPresented { readSelected() }
    }
    func inspectorChanged(_ shown: Bool) {
        if shown { readSelected() }
        else { readGeneration += 1; readTask?.cancel(); readTask = nil; reading = false; closeWatch() }
    }
    func readSelected() {
        guard let selectedID else { reading = false; return }
        if selectedID.hasPrefix(AGTWatchSource.prefix) { readDevice(selectedID); return }
        readGeneration += 1
        let mine = readGeneration
        readTask?.cancel(); reading = true
        readTask = Task { [weak self] in
            do {
                guard let self else { return }
                let raw = try await self.read("agents-watch:read", [["agentID": selectedID, "limit": 200]])
                try Task.checkCancellation()
                guard self.readGeneration == mine, self.selectedID == selectedID else { return }
                let value = try NativeRPCValue.fromFoundation(raw)
                entries = (value["entries"].elements ?? []).compactMap(AWWatchEntry.decode)
                conversationNotice = value["notice"].string
                updatedAt = value["updatedAt"].number
                reading = false; conversationError = nil
                if let path = value["watchPath"].string, path != watchedPath {
                    closeWatch(); watchedPath = path
                    let token = try await NativeTranscriptBackend.shared.watch(["transcriptPath": path], onUpdate: { [weak self] _ in
                        // The existing watcher emits even when only tools changed.
                        self?.readSelected()
                    }, onFailure: { [weak self] text in self?.conversationError = text })
                    guard self.readGeneration == mine, self.selectedID == selectedID else {
                        NativeTranscriptBackend.shared.unwatch(token); return
                    }
                    watch = token
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.readGeneration == mine else { return }
                reading = false; conversationError = error.localizedDescription
                // Retry can reinstall a failed watcher instead of holding its path.
                if watch == nil { watchedPath = nil }
            }
        }
    }
    /// Another app's conversation, read-only, followed through its own file's change events.
    private func readDevice(_ rowID: String) {
        guard deviceAgent(rowID) != nil else { reading = false; return }
        readGeneration += 1
        let mine = readGeneration
        readTask?.cancel(); reading = true
        readTask = Task { [weak self] in
            do {
                guard let self else { return }
                let raw = try await self.read("agents-watch:read", [["agentID": rowID, "limit": 200]])
                try Task.checkCancellation()
                guard self.readGeneration == mine, self.selectedID == rowID else { return }
                let value = try NativeRPCValue.fromFoundation(raw)
                entries = (value["entries"].elements ?? []).compactMap(AWWatchEntry.decode)
                conversationNotice = value["notice"].string
                updatedAt = value["updatedAt"].number
                reading = false; conversationError = nil
                if let path = value["watchPath"].string, transcriptWatch?.path != path {
                    transcriptWatch?.stop()
                    transcriptWatch = AGTFileWatch(path: path) { [weak self] in
                        guard let self, self.selectedID == rowID, self.follow else { return }
                        self.readDevice(rowID)
                    }
                }
            } catch is CancellationError {
            } catch {
                guard let self, self.readGeneration == mine else { return }
                reading = false; entries = []; conversationError = error.localizedDescription
            }
        }
    }
    private func closeWatch() {
        transcriptWatch?.stop(); transcriptWatch = nil
        if let watch { NativeTranscriptBackend.shared.unwatch(watch) }
        watch = nil; watchedPath = nil
    }
    func stopSelected() {
        guard let agent = selected, !agent.isOtherApp, !changing else { return }
        changing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.changing = false }
            do { _ = try await self.read("agents-watch:stop", [["id": agent.id, "confirmed": true]]); self.refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    /// The person frees a heavy job lock whose holder stopped; the next waiting agent starts.
    func freeHeavyJob() {
        guard heavyJobBusy, !changing else { return }
        changing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.changing = false }
            do { _ = try await self.read("agents-watch:free-heavy-job", []); self.refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func resumeSelected() {
        guard let other = deviceAgent(selectedID), other.state == .finished, !changing else { return }
        changing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.changing = false }
            do { _ = try await self.read("agents-watch:resume", [["id": AGTWatchSource.prefix + other.id, "confirmed": true]]); self.refresh() }
            catch { self.error = error.localizedDescription }
        }
    }
    func openSession() {
        if let other = deviceAgent(selectedID) { AGTWatchSource.bringForward(other); return }
        guard let agent = selected else { return }
        if agent.kind == "hoot" { AppModel.shared.select("hoot"); return }
        guard let id = agent.sessionID, agent.state != .offline else { return }
        let target = SessionTarget.local(id)
        AppModel.shared.selectTab(target.tabId)
    }
}
