import Foundation
import WidgetKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// What the widget snapshots of one refresh share (post-24, phone-terminal item 1: each phone's snapshot used to read
/// usage, tasks and the CPU sampler again, about twice a second per phone while agents worked).
struct NativeWidgetInputs {
    static let maxAge: TimeInterval = 1
    let at: Date
    let hostID: String?
    let sessions: [BackendSessionMeta]
    let statuses: [String: BackendSessionStatus]
    let tasks: [BackendTaskRecord]?
    let activity: NativeRPCValue
    var usage: [String: BackendUsageReport?] = [:]
}

extension NativeCompositionProduction {
    /// CPU and memory: the shared sampler, read at most every 15 s for widgets. Calling it on every status event
    /// also shortened the window the phones' Activity page and rings measure over.
    func widgetActivitySample(now: Date = Date()) async -> NativeRPCValue {
        if let cached = widgetActivity, now.timeIntervalSince(cached.at) < BackendWidgets.metricsInterval { return cached.value }
        let value = await systemActivityReader().sample(top: false)
        widgetActivity = (now, value)
        return value
    }

    /// One read of the shared inputs per refresh: every phone's snapshot (and the Mac's own widget) within a second reuses it.
    func sharedWidgetInputs(now: Date) async -> NativeWidgetInputs? {
        if let cached = widgetInputs, now.timeIntervalSince(cached.at) < NativeWidgetInputs.maxAge { return cached }
        guard let sessions else { return nil }
        let identity = try? await remoteTrust?.hostIdentity()
        let all = sessions.manager.list().filter { $0.exitCode == nil }
        var statuses: [String: BackendSessionStatus] = [:]
        for session in all { statuses[session.id] = await sessions.lifecycle.status(sessionID: session.id) }
        let tasks: [BackendTaskRecord]? = if let store = taskView?.store { try? await store.all() } else { nil }
        let inputs = NativeWidgetInputs(at: now, hostID: identity?.hostID, sessions: all, statuses: statuses, tasks: tasks,
                                        activity: await widgetActivitySample(now: now))
        widgetInputs = inputs
        return inputs
    }

    private func widgetUsage(_ sessionID: String?) async -> BackendUsageReport? {
        let key = sessionID ?? ""
        if let known = widgetInputs?.usage[key] { return known }
        let report = try? await usage?.usage.read(sessionID: sessionID)
        widgetInputs?.usage[key] = report
        return report
    }

    /// No probes, credentials or invented percentages: the same load and usage readers the app already uses.
    func widgetSnapshot(deviceID: String? = nil, project: String? = nil) async -> DeckWidgetSnapshot {
        let now = Date()
        let inputs = await sharedWidgetInputs(now: now)
        var hostID = inputs?.hostID
        if inputs == nil { hostID = (try? await remoteTrust?.hostIdentity())?.hostID }
        let unavailable = DeckWidgetSnapshot(updatedAt: (now.timeIntervalSince1970 * 1000).rounded(), connected: false, machineId: hostID, machineName: Host.current().localizedName ?? "Mac")
        guard let inputs else { return unavailable }
        if let deviceID {
            guard let trust = remoteTrust, await trust.isApproved(deviceID), let level = await trust.phoneAccess(deviceID), level != .hoot else { return unavailable }
        }
        let all = inputs.sessions
        var visible: [BackendSessionMeta] = []
        for session in all {
            if let project, session.cwd != project { continue }
            if let deviceID, let trust = remoteTrust {
                guard await trust.canReachFolder(deviceID, folder: session.cwd), await trust.sessionShared(deviceID, session: session.id) else { continue }
            }
            visible.append(session)
        }
        var waiting: [DeckWidgetSnapshot.Session] = []
        for session in visible {
            guard inputs.statuses[session.id] == .input else { continue }
            waiting.append(.init(id: session.id, name: String(session.title.prefix(80)), agent: session.provider,
                                 seat: NativePhonePictureFaces.sessions([session.id])[session.id]?.name))
        }
        let selected = AppModel.shared.sidebarSelection
        let usageSession = visible.first(where: { $0.id == selected })?.id ?? visible.first?.id
        let report: BackendUsageReport?
        if usageSession == nil && (deviceID != nil || project != nil) { report = nil }
        else { report = await widgetUsage(usageSession) }
        let activity = inputs.activity
        var tasks: [NativeRPCValue]?
        if let rows = inputs.tasks {
            var allowed: [NativeRPCValue] = []
            for row in rows where row.isLocal {
                if let project, row.project != project { continue }
                if let deviceID, let trust = remoteTrust {
                    guard await trust.canReachFolder(deviceID, folder: row.project) else { continue }
                }
                allowed.append(row.value)
            }
            tasks = BackendWidgets.dueTasks(allowed, at: now)
        }
        let firstTask = tasks?.first
        let totalMemory = activity["memory"]["total"].number ?? 0
        return DeckWidgetSnapshot(updatedAt: (now.timeIntervalSince1970 * 1000).rounded(), connected: true, machineId: inputs.hostID,
            machineName: Host.current().localizedName ?? "Mac", needsYouCount: waiting.count, needsYou: waiting,
            cpuPercent: activity["cpu"]["total"].number,
            memoryPercent: totalMemory > 0 ? activity["memory"]["used"].number.map { $0 / totalMemory * 100 } : nil,
            weeklyLimitRemainingPercent: BackendWidgets.weeklyRemaining(report, at: now), tasksDueCount: tasks?.count,
            nextTask: firstTask.flatMap { row in guard let id = row["id"].string, let title = row["title"].string else { return nil }; return .init(id: id, title: String(title.prefix(100)), projectPath: row["project"].string) }, usageSessionId: usageSession)
    }

    func installWidgets() async {
        guard let endpoint = remoteEndpoint else { return }
        let owner = "native.widgets"
        let reader: BackendWidgets.Reader = { [weak self] device, project in await self?.widgetSnapshot(deviceID: device, project: project) ?? .empty }
        let stream = BackendWidgets(read: reader, send: { connection, message in try await endpoint.sendToConnection(connection, message: message) })
        do {
            let lease = try await endpoint.installFeatures(ownerID: owner, features: [await stream.feature()], connectionClosed: { await stream.disconnected($0) })
            let watcher = NativeWidgetWatcher(read: { await reader(nil, nil) }, changed: { await stream.changed() }, report: report)
            watcher.start()
            do {
                try await root.retain(.init(name: "widgets", domains: ["widgets"], ownerID: owner, invokes: [], stop: {
                    await MainActor.run { watcher.stop() }; await stream.stop(); await lease.cancelAndWait()
                }))
                widgets = stream; widgetWatcher = watcher
            } catch { watcher.stop(); await stream.stop(); await lease.cancelAndWait(); throw error }
        } catch { report("Widgets are unavailable: " + error.localizedDescription) }
    }

    func installWidgetTools(access: BackendDeckToolsAppAccess) async throws {
        let owner = "native.widget-tools", root = root, joins = joins
        let definitions = try BackendWidgets.definitions(reader: { [weak self] device, project in await self?.widgetSnapshot(deviceID: device, project: project) ?? .empty }, access: access)
        let bundle = try BackendDeckCoreCatalogueBundle(metadata: definitions.map(\.catalogueMetadata), policies: definitions.map { joins.nativePolicy($0) })
        do {
            try joins.replaceContributions(owner: owner, [bundle], policiesWrapped: true)
            try await root.mcp.replaceTools(ownerID: owner, tools: definitions.map { ($0.spec, $0.handler) })
            try await root.retain(.init(name: "widget-tools", domains: ["widget-tools"], ownerID: owner, invokes: [], stop: {
                await root.mcp.removeTools(ownerID: owner); try joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            }))
        } catch {
            await root.mcp.removeTools(ownerID: owner); try? joins.replaceContributions(owner: owner, [], policiesWrapped: true)
            throw error
        }
    }
}

@MainActor
final class NativeWidgetWatcher {
    private let read: @Sendable () async -> DeckWidgetSnapshot
    private let changed: @Sendable () async -> Void
    private let report: @Sendable (String) -> Void
    private var subscriptions: [EngineSubscription] = []
    private var refresh: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var writeErrorReported = false
    private var dirty = false
    private var gate = DeckWidgetReloadGate()
    private var pendingReload: Task<Void, Never>?
    init(read: @escaping @Sendable () async -> DeckWidgetSnapshot, changed: @escaping @Sendable () async -> Void,
         report: @escaping @Sendable (String) -> Void) { self.read = read; self.changed = changed; self.report = report }
    func start() {
        guard subscriptions.isEmpty else { return }
        for event in ["session:status", "session:created", "session:removed", "session:renamed", "session:exit", "tasks:changed", "usage:update"] {
            subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in self?.schedule() })
        }
        schedule()
        // WidgetKit's background budget is 15 minutes. Event-driven changes write immediately; this refreshes idle load.
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { break }
                self?.schedule()
            }
        }
    }
    func schedule() {
        dirty = true
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            guard let self else { return }
            // Coalesce a burst of status events (about two a second while agents work) into one refresh.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            dirty = false
            let snapshot = await read()
            guard !Task.isCancelled else { refresh = nil; return }
            do {
                let scratch = Bundle.main.object(forInfoDictionaryKey: "TDAgentConfigReadOnly") as? Bool == true
                let customGroup = Bundle.main.object(forInfoDictionaryKey: "TDWidgetAppGroup") as? String
                // A scratch copy writes only into its own group, never the installed app's.
                if !scratch || (customGroup.map { ![DeckWidgetStore.macAppGroup, DeckWidgetStore.appGroup].contains($0) } ?? false) {
                    try DeckWidgetStore.write(snapshot)
                    reloadIfNeeded(snapshot)
                }
            } catch {
                if !writeErrorReported { report("Widgets cannot read the shared snapshot: " + error.localizedDescription); writeErrorReported = true }
            }
            await changed()
            refresh = nil
            if dirty { schedule() }
        }
    }
    private func reloadIfNeeded(_ snapshot: DeckWidgetSnapshot) {
        guard let delay = gate.decide(snapshot) else { return }
        if delay == 0 { pendingReload?.cancel(); pendingReload = nil; WidgetCenter.shared.reloadAllTimelines(); return }
        guard pendingReload == nil else { return }
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            pendingReload = nil
            gate.reloaded(DeckWidgetStore.read()); WidgetCenter.shared.reloadAllTimelines()
        }
    }
    func stop() {
        subscriptions.forEach { $0.cancel() }; subscriptions = []; clock?.cancel(); clock = nil; refresh?.cancel(); refresh = nil
        pendingReload?.cancel(); pendingReload = nil
    }
}
