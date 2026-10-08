import Foundation
import Observation
import TerminalDeckNativeCore

@MainActor @Observable
final class AWAgentsWatchModel {
    typealias Read = @MainActor (String, [Any?]) async throws -> Any
    var agents: [AWWatchAgent] = []
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
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var watch: UUID?
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private let read: Read
    /// DKA adds HOOT's published channel once the shared stream is registered.
    let sourceEvents: [String]
    init(sourceEvents: [String] = ["session:created", "session:status", "session:exit", "session:removed", "session:renamed", "tasks:changed", "machines:state", "hoot:chat:changed", "agents-watch:changed"],
         read: @escaping Read = { channel, args in try await EngineBridge.shared.invoke(channel, args) }) {
        self.sourceEvents = sourceEvents
        self.read = read
    }
    var selected: AWWatchAgent? { agents.first { $0.id == selectedID } }
    var visible: [AWWatchAgent] { AWWatchProjection.filtered(agents, state: stateFilter, query: search) }
    func start() {
        guard subscriptions.isEmpty else { return }
        for event in sourceEvents {
            subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }
    func stop() {
        generation += 1; readGeneration += 1
        loadTask?.cancel(); readTask?.cancel(); loadTask = nil; readTask = nil
        subscriptions.forEach { $0.cancel() }; subscriptions.removeAll()
        closeWatch()
    }
    func refresh() {
        generation += 1
        let mine = generation
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let request: [String: Any] = ["limit": 200, "query": self?.search ?? "", "state": self?.stateFilter as Any? ?? NSNull()]
                guard let self else { return }
                let raw = try await self.read("agents-watch:list", [request])
                try Task.checkCancellation()
                guard self.generation == mine else { return }
                let value = try NativeRPCValue.fromFoundation(raw)
                agents = (value["agents"].elements ?? []).compactMap(AWWatchAgent.decode)
                counts = Dictionary((value["counts"].fields ?? []).compactMap { field in field.value.number.map { (field.key, Int($0)) } }, uniquingKeysWith: { first, _ in first })
                counts["all"] = Int(value["allTotal"].number ?? Double(agents.count))
                notices = (value["notices"].elements ?? []).compactMap(\.string)
                if value["hasMore"].bool == true { notices.append("Showing the first 200 agents. Narrow the search to find others.") }
                loading = false; error = nil
                if let selectedID, !agents.contains(where: { $0.id == selectedID }) { select(nil) }
                if self.selectedID == nil { select(visible.first?.id) } else { readSelected() }
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == mine else { return }
                loading = false; self.error = error.localizedDescription
            }
        }
    }
    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id; entries = []; expandedEntries.removeAll(); conversationError = nil; conversationNotice = nil; updatedAt = nil
        readGeneration += 1; readTask?.cancel(); closeWatch()
        readSelected()
    }
    func readSelected() {
        guard let selectedID else { reading = false; return }
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
    private func closeWatch() {
        if let watch { NativeTranscriptBackend.shared.unwatch(watch) }
        watch = nil; watchedPath = nil
    }
    func openSession() {
        guard let agent = selected else { return }
        if agent.kind == "hoot" { AppModel.shared.select("hoot"); return }
        guard let id = agent.sessionID, agent.state != .offline else { return }
        let target = agent.machineID.isEmpty ? SessionTarget.local(id) : .machine(machineId: agent.machineID, sessionId: id)
        AppModel.shared.selectTab(target.tabId)
    }
}
