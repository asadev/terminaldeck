import Foundation
import TerminalDeckNativeCore

/// Caller provenance is supplied by the authenticated app/tool dispatcher. It
/// is not reconstructed from a requested server, shell ID or machine ID.
public struct BackendServersCaller: Sendable {
    public enum Kind: String, Sendable { case nativeUI, local, key, remote, session }
    public let kind: Kind
    public let attended: Bool
    public let context: NativeRPCContext
    public init(kind: Kind, attended: Bool, context: NativeRPCContext) { self.kind = kind; self.attended = attended; self.context = context }
    public var actsAsOwner: Bool { kind == .nativeUI || kind == .local || kind == .key }
    public var grantAsker: String { kind == .nativeUI || kind == .local ? "local" : kind.rawValue }
    /// Only the native form or the trusted, already-authorized server-manage
    /// adapter may consume credential input. This never comes from tool JSON.
    public var canConsumeCredentialInput: Bool {
        kind == .nativeUI || (actsAsOwner && context.caller == .internalEngine && context.capabilities.contains("servers:credential-input"))
    }
}
public struct BackendServersAuthorization: Sendable {
    public let operation: String
    public let serverId: String?
    public let shellId: String?
    public let tier: BackendMCPTier
    public let arguments: NativeRPCValue
    public init(operation: String, serverId: String? = nil, shellId: String? = nil, tier: BackendMCPTier, arguments: NativeRPCValue = .missing) {
        self.operation = operation; self.serverId = serverId; self.shellId = shellId; self.tier = tier; self.arguments = arguments
    }
}
public enum BackendServersWire {
    public static func value<T: Encodable>(_ value: T) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(value)) }
    public static func ok(_ fields: [NativeRPCValue.Field] = []) -> NativeRPCValue { .object([.init("ok", .bool(true))] + fields) }
    public static func failed(_ error: Error) -> NativeRPCValue {
        if let error = error as? BackendServersActionFailed { return failure(error.sentence, detail: error.detail) }
        if let error = error as? BackendServersActionRefused { return failure(error.sentence) }
        if let error = error as? BackendServersProblem { return error.wireValue.setting("ok", .bool(false)).setting("detail", .string("")) }
        return failure(error.localizedDescription.isEmpty ? "Something went wrong reaching that server." : error.localizedDescription)
    }
    public static func failure(_ sentence: String, detail: String = "") -> NativeRPCValue {
        .object([.init("ok", .bool(false)), .init("sentence", .string(sentence)), .init("detail", .string(detail))])
    }
    public static func integer(_ raw: NativeRPCValue, fallback: Int, minimum: Int, maximum: Int) -> Int {
        guard let number = raw.number else { return fallback }; return Int(min(Double(maximum), max(Double(minimum), number.rounded(.towardZero))))
    }
}

/// Native ipc.ts room: measured facts and available actions share one cache.
/// No timer, local copy of the server summary, or unbounded command tool.
public actor BackendServersCoordinator {
    public typealias Authorize = @Sendable (BackendServersCaller, BackendServersAuthorization) async throws -> Void
    public let store: BackendServersStore
    public let connections: BackendServersConnections
    public let grants: BackendServersGrants
    public let journal: any BackendServersWayBackJournal
    public let backupDirectory: URL
    private let authorize: Authorize
    private let now: @Sendable () -> Double
    private let download: (@Sendable (String, String, String) async throws -> Int)?
    private var views: [String: BackendServersView] = [:]
    private var measurements: [String: BackendServersFacts] = [:]
    private let revisions = BackendServersMeasurementRevisions()
    private let lifetimes = BackendServersMeasurementRevisions()
    private var measuredRevision: [String: UInt64] = [:], viewRevision: [String: UInt64] = [:]
    private struct PageHold { let ticket: UUID; var lease: BackendServersConnectionLease? }
    private var holds: [String: [String: PageHold]] = [:]
    private struct Opening { let id: UUID, revision: UInt64, task: Task<BackendServersFacts, Error> }
    private var opening: [String: Opening] = [:]
    private var closed = false
    private var retiring: Set<String> = []
    public init(store: BackendServersStore, connections: BackendServersConnections, grants: BackendServersGrants,
                journal: any BackendServersWayBackJournal, storageDirectory: URL,
                authorize: @escaping Authorize, download: (@Sendable (String, String, String) async throws -> Int)?,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.store = store; self.connections = connections; self.grants = grants; self.journal = journal
        backupDirectory = storageDirectory.appendingPathComponent("backups", isDirectory: true)
        self.authorize = authorize; self.download = download; self.now = now
    }
    public func check(_ caller: BackendServersCaller, _ request: BackendServersAuthorization) async throws {
        guard !closed else { throw NativeRPCError(code: "closed", message: "The native server room is stopped.") }
        if let id = request.serverId, retiring.contains(id), request.operation != "servers:forget" { throw CancellationError() }
        try await authorize(caller, request); try Task.checkCancellation()
        guard !closed else { throw NativeRPCError(code: "closed", message: "The native server room stopped while permission was being checked.") }
        if let id = request.serverId, retiring.contains(id), request.operation != "servers:forget" { throw CancellationError() }
    }
    public func knows(_ id: String) throws -> Bool { try store.get(id) != nil }
    public nonisolated func serverLifetime(_ id: String) -> UInt64 { lifetimes.read(id) }
    public func requireLiveServer(_ id: String, lifetime: UInt64) throws {
        guard !closed, !retiring.contains(id), serverLifetime(id) == lifetime, try knows(id) else { throw CancellationError() }
    }
    public func list(_ caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await check(caller, .init(operation: "servers:list", tier: .read))
        return .array(try store.list().map { BackendServersSummary($0).wireValue })
    }
    public func cached(_ id: String) -> BackendServersView? { viewRevision[id] == revisions.read(id) ? views[id] : nil }
    /// A setup broadcast is synchronous in the source. Mark its measurement
    /// stale before queuing a UI event; a following account ask cannot race it.
    public nonisolated func invalidateFromEvent(_ id: String) { revisions.invalidate(id) }
    public func invalidate(_ id: String) { invalidateFromEvent(id); views[id] = nil; measurements[id] = nil; measuredRevision[id] = nil; viewRevision[id] = nil }
    public func measured(_ id: String, refresh: Bool = false) async throws -> BackendServersFacts {
        guard !closed, !retiring.contains(id) else { throw CancellationError() }
        let revision = revisions.read(id)
        if !refresh, measuredRevision[id] == revision, let cached = measurements[id] { return cached }
        if let existing = opening[id], existing.revision == revision { return try await existing.task.value }
        let connections = self.connections, measuredAt = now, ticket = UUID()
        let task = Task { try await BackendServersProbe.gather(id, connections: connections, measuredAt: measuredAt) }
        opening[id] = Opening(id: ticket, revision: revision, task: task)
        defer { if opening[id]?.id == ticket { opening[id] = nil } }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard !closed, !retiring.contains(id) else { throw CancellationError() }
        if revisions.read(id) == revision { measurements[id] = value; measuredRevision[id] = revision }
        return value
    }
    public func look(_ id: String, caller: BackendServersCaller, holdSurface: Bool = true) async throws -> BackendServersView {
        let lifetime = serverLifetime(id)
        try await check(caller, .init(operation: "servers:look", serverId: id, tier: .read))
        guard try knows(id) else { throw BackendServersActionRefused("There is no server with the id \(id) in this app.") }
        try requireLiveServer(id, lifetime: lifetime)
        if holdSurface, holds[id]?[caller.context.ownerID] == nil {
            // Reserve before suspension. Simultaneous reads on one surface
            // own one page hold, not two acquisitions and one release.
            let ticket = UUID()
            holds[id, default: [:]][caller.context.ownerID] = PageHold(ticket: ticket, lease: nil)
            do {
                let lease = try await connections.acquireLease(id)
                guard holds[id]?[caller.context.ownerID]?.ticket == ticket else { await connections.release(lease); throw CancellationError() }
                holds[id]?[caller.context.ownerID]?.lease = lease
                try requireLiveServer(id, lifetime: lifetime)
            }
            catch {
                if holds[id]?[caller.context.ownerID]?.ticket == ticket, let hold = holds[id]?.removeValue(forKey: caller.context.ownerID), let lease = hold.lease { await connections.release(lease) }
                if holds[id]?.isEmpty == true { holds[id] = nil }
                throw error
            }
        }
        let revision = revisions.read(id), facts = try await measured(id, refresh: true)
        var survey = BackendServersWayBackSurvey()
        do {
            let result = try await connections.runScript(id, script: BackendServersClassify.waybackScript(facts))
            if result.code == 0 { survey = BackendServersClassify.parseSurvey(result.stdout) }
        } catch { /* Unknown way back removes Update, not the observed cards. */ }
        try requireLiveServer(id, lifetime: lifetime)
        if holdSurface, holds[id]?[caller.context.ownerID] == nil { throw CancellationError() }
        let view = BackendServersView(facts: facts, survey: survey, canDownload: download != nil)
        if revisions.read(id) == revision { views[id] = view; viewRevision[id] = revision }; return view
    }
    public func closePage(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await check(caller, .init(operation: "servers:close", serverId: id, tier: .act))
        if let hold = holds[id]?.removeValue(forKey: caller.context.ownerID), let lease = hold.lease { await connections.release(lease) }
        if holds[id]?.isEmpty == true { holds[id] = nil }
        invalidate(id)
        // A page owns no terminal. Only terminal close/EOF/forget/app stop does.
        return .object([.init("closed", .bool(true))])
    }
    public func disconnectOwner(_ owner: String) async {
        for id in Array(holds.keys) {
            guard let hold = holds[id]?.removeValue(forKey: owner) else { continue }
            if holds[id]?.isEmpty == true { holds[id] = nil }
            if let lease = hold.lease { await connections.release(lease) }
        }
    }
    public func beginForgetting(_ id: String) {
        if retiring.insert(id).inserted { lifetimes.invalidate(id) }
        grants.revoke(id)
    }
    public func forgetServer(_ id: String) async {
        beginForgetting(id)
        opening.removeValue(forKey: id)?.task.cancel()
        let old = holds.removeValue(forKey: id)?.values.compactMap(\.lease) ?? []
        invalidate(id); grants.revoke(id)
        for lease in old { await connections.release(lease) }
        await connections.closeServer(id)
    }
    private func card(_ view: BackendServersView, id: String) throws -> BackendServersCard {
        guard let card = view.cards.first(where: { $0.id == id }) else { throw BackendServersActionRefused("That isn’t on this server any more. Refresh the page.") }; return card
    }
    public func preview(_ id: String, cardId: String, action: BackendServersActionID, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await check(caller, .init(operation: "servers:preview", serverId: id, tier: .read))
        let view: BackendServersView
        if let value = cached(id) { view = value } else { view = try await look(id, caller: caller, holdSurface: false) }
        return try BackendServersActions.previewOf(action, target: .init(serverId: id, card: card(view, id: cardId), facts: view.facts.actionFacts), composeAvailable: view.composeAvailable).wireValue()
    }
    public func act(_ id: String, cardId: String, action: BackendServersActionID, caller: BackendServersCaller, requireCached: Bool = false) async throws -> BackendServersActionOutcome {
        guard caller.actsAsOwner else { throw BackendServersActionRefused("Changing anything on a server only works for the person at this machine, or an AI app they gave an access key to. A paired device cannot do it and cannot be given permission to. Say what you would have done and let them do it.") }
        if requireCached, cached(id) == nil { throw BackendServersActionRefused("Call servers.look on \(id) first. Nothing on this server can be changed before this app has seen what is on it.") }
        let view: BackendServersView
        if let value = cached(id) { view = value } else { view = try await look(id, caller: caller, holdSurface: false) }
        let target = try card(view, id: cardId)
        let available = BackendServersActions.availableActions(target, facts: view.facts.actionFacts, canDownload: download != nil, composeAvailable: view.composeAvailable)
        if action != .goBack, !available.offered.contains(action) { throw BackendServersActionRefused(available.absent.first { $0.actionId == action }?.because ?? "That isn’t something this app can do to \(target.name).") }
        let tier: BackendMCPTier = grants.granted(id, asker: caller.grantAsker) && caller.kind == .local ? .act : .alter
        let args = NativeRPCValue.object([.init("serverId", .string(id)), .init("cardId", .string(cardId)), .init("action", .string(action.rawValue)),
            .init("preview", try BackendServersActions.previewOf(action, target: .init(serverId: id, card: target, facts: view.facts.actionFacts), composeAvailable: view.composeAvailable).wireValue())])
        try await check(caller, .init(operation: "servers.control", serverId: id, tier: tier, arguments: args))
        let deps = BackendServersActionDeps(connections: connections, journal: journal, download: download, backupDir: backupDirectory.path, now: now)
        let result = try await BackendServersActions.perform(deps, actionId: action, target: .init(serverId: id, card: target, facts: view.facts.actionFacts))
        if ![.open, .copyAddress, .logs].contains(action) { invalidate(id) }
        return result
    }
    public func logs(_ id: String, cardId: String, lines: Double, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await check(caller, .init(operation: "servers.logs", serverId: id, tier: .read))
        let view: BackendServersView
        if let value = cached(id) { view = value } else { view = try await look(id, caller: caller, holdSurface: false) }
        let count = min(2_000, max(1, lines.isFinite ? lines.rounded(.towardZero) : 200))
        let deps = BackendServersActionDeps(connections: connections, journal: journal, download: download, backupDir: backupDirectory.path, now: now, logLines: count)
        let result = try await BackendServersActions.perform(deps, actionId: .logs, target: .init(serverId: id, card: card(view, id: cardId), facts: view.facts.actionFacts))
        return result.value ?? .object([.init("lines", .array([]))])
    }
    public func beginStopping() {
        closed = true; for entry in opening.values { entry.task.cancel() }; opening = [:]
    }
    public func stop() async {
        beginStopping()
        grants.revokeAll(); views = [:]; measurements = [:]; holds = [:]
        await connections.closeAll()
    }
}

final class BackendServersMeasurementRevisions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: UInt64] = [:]
    func read(_ id: String) -> UInt64 { lock.withLock { values[id] ?? 0 } }
    func invalidate(_ id: String) { lock.withLock { values[id, default: 0] &+= 1 } }
}
