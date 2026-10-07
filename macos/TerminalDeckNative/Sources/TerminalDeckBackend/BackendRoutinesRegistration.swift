import Foundation
import TerminalDeckNativeCore

/// Suppliers attach to the actual owners' existing push streams. Returning a
/// subscription means the observer is live; unsupported binding must throw.
/// No supplier here is a poll, a scanner, a process launcher or a raw hook.
public struct BackendRoutinesEventBindings: Sendable {
    public typealias Started = @Sendable (@escaping @Sendable (BackendSessionMeta) async -> Void) async throws -> NativeRPCSubscription
    public typealias Status = @Sendable (@escaping @Sendable (String, BackendSessionStatus) async -> Void) async throws -> NativeRPCSubscription
    public typealias Exit = @Sendable (@escaping @Sendable (String, Int) async -> Void) async throws -> NativeRPCSubscription
    public typealias Alerts = @Sendable (@escaping @Sendable (NativeRPCValue) async -> Void) async throws -> NativeRPCSubscription
    public typealias Wake = @Sendable (@escaping @Sendable () async -> Void) async throws -> NativeRPCSubscription

    /// Attach first and replay all current authoritative session metadata before
    /// returning this lease. Future start callbacks must complete before that
    /// session's first status, alert or exit is delivered. Origin routine/run
    /// fields and cwd come from the actual session owner, never event arguments.
    public let sessionStarted: Started?
    /// Include the activity owner's status changes and validated hook receipts.
    /// Raw session:data bytes and unvalidated hook payloads are not statuses.
    public let sessionStatus: Status?
    /// Supply the actual source exit code (zero finished; other codes failed).
    public let sessionExit: Exit?
    /// Observe exactly the report already produced by the alerts owner. Keep
    /// returning that same report to its caller; do not initiate another scan.
    public let alertReport: Alerts?
    /// Observe the Mac owner's existing resume event, not a new watchdog timer.
    public let wake: Wake?

    public init(sessionStarted: Started? = nil, sessionStatus: Status? = nil,
                sessionExit: Exit? = nil, alertReport: Alerts? = nil, wake: Wake? = nil) {
        self.sessionStarted = sessionStarted; self.sessionStatus = sessionStatus
        self.sessionExit = sessionExit; self.alertReport = alertReport; self.wake = wake
    }
}

/// Retain this for the area's lifetime. Await cleanup.cancelAndWait() before
/// releasing its dependencies. Dropping the handle also schedules cleanup.
public struct BackendRoutinesRegistrationHandle: Sendable {
    public let service: BackendRoutinesService
    public let ownerID: String
    /// A unique MCP contribution owner, even when the channel owner was named
    /// by the composition root. Cleanup cannot remove its other tool areas.
    public let mcpOwnerID: String?
    public let channels: Set<String>
    public let definitions: [BackendDeckToolsDefinition]
    public let boundSources: Set<String>
    public let sessionMetadataBound: Bool
    public let wakeBound: Bool
    public let startedEngine: Bool
    public let cleanup: NativeRPCSubscription
    public var toolIDs: Set<String> { Set(definitions.map { $0.spec.id }) }
    /// Feed these same definitions to the central describe/index supplier.
    public var catalogueMetadata: [BackendDeckCoreCatalogueMetadata] { definitions.map(\.catalogueMetadata) }

    fileprivate init(service: BackendRoutinesService, ownerID: String, mcpOwnerID: String?,
                     definitions: [BackendDeckToolsDefinition], boundSources: Set<String>,
                     sessionMetadataBound: Bool, wakeBound: Bool, startedEngine: Bool,
                     cleanup: NativeRPCSubscription) {
        self.service = service; self.ownerID = ownerID; self.mcpOwnerID = mcpOwnerID
        channels = BackendRoutinesAPI.channels; self.definitions = definitions
        self.boundSources = boundSources; self.sessionMetadataBound = sessionMetadataBound
        self.wakeBound = wakeBound; self.startedEngine = startedEngine; self.cleanup = cleanup
    }
}

/// One composition-root call. A preassembled service supplies the actual store,
/// runner, unattended tool/config/provider adapters, folder authority and shared
/// Git/file sources. This function neither creates/seeds a service nor starts
/// an MCP listener or CLI. The engine starts only when explicitly requested.
public enum BackendRoutinesRegistration {
    public static func register(registry: NativeChannelRegistry, service: BackendRoutinesService,
                                ownerID: String? = nil, events: BackendRoutinesEventBindings = .init(),
                                mcpServer: BackendNativeMCPServer? = nil,
                                mcpAccess: BackendDeckToolsAppAccess? = nil,
                                startEngine: Bool = false) async throws -> BackendRoutinesRegistrationHandle {
        guard (mcpServer == nil) == (mcpAccess == nil) else {
            throw NativeRPCError(code: "unavailable", message: "Routine MCP registration needs both the native MCP server and the shared consent/log access adapter.")
        }
        guard events.sessionStarted != nil || (events.sessionStatus == nil && events.sessionExit == nil) else {
            throw NativeRPCError(code: "unavailable", message: "Routine session status/exit subscriptions need the authoritative session-start metadata subscription first, so folder scope and routine provenance are preserved.")
        }
        let owner = ownerID ?? "native-routines-" + UUID().uuidString.lowercased()
        guard !owner.isEmpty, !owner.contains("\0") else { throw NativeRPCError.invalidArguments("Routine registration needs a nonempty owner id.") }
        let channels = BackendRoutinesAPI.channels
        let existingChannels = Set(await registry.channels())
        let channelConflicts = channels.intersection(existingChannels).sorted()
        guard channelConflicts.isEmpty else {
            throw NativeRPCError(code: "duplicate-handler", message: "Routine channels already have an owner: " + channelConflicts.joined(separator: ", "))
        }

        let definitions: [BackendDeckToolsDefinition]
        let toolOwner: String?
        if let server = mcpServer, let access = mcpAccess {
            definitions = try BackendDeckToolsAppRoutines.definitions(service: BackendRoutinesRegisteredAppAdapter(api: service.api), access: access)
            let expected: Set<String> = ["routines.list", "routines.get", "routines.save", "routines.delete", "routines.run", "routines.pause", "routines.resume"]
            guard definitions.count == expected.count, Set(definitions.map { $0.spec.id }) == expected else {
                throw NativeRPCError(code: "unavailable", message: "The native routine MCP definitions do not match the seven source tools.")
            }
            let offeredNames = Set(definitions.flatMap { [$0.spec.id, $0.spec.wireName] })
            let current = try await server.catalogue(), currentNames = Set(current.flatMap { [$0.id, $0.wireName] })
            let conflicts = offeredNames.intersection(currentNames).sorted()
            guard conflicts.isEmpty else {
                throw NativeRPCError(code: "duplicate-tool", message: "Routine MCP tools already have an owner: " + conflicts.joined(separator: ", "))
            }
            toolOwner = owner + ":routines-tools:" + UUID().uuidString.lowercased()
        } else { definitions = []; toolOwner = nil }

        // All duplicate/dependency checks finish before event suppliers attach
        // or source health is changed. Rollback removes only this contribution.
        let relay = BackendRoutinesRegisteredEventRelay(engine: service.engine)
        var subscriptions: [NativeRPCSubscription] = []
        var sources = Set<String>(), startedMetadata = false, wakeBound = false
        var toolsRegistered = false, channelsAttempted = false, eventsAttempted = false, engineStartAttempted = false
        do {
            try Task.checkCancellation()
            channelsAttempted = true
            try await service.api.register(on: registry, ownerID: owner)
            if let server = mcpServer, let toolOwner {
                // These handlers already enter the supplied AppAccess source
                // gate. A direct API handler here would bypass consent/logging.
                try await server.replaceTools(ownerID: toolOwner, tools: definitions.map { ($0.spec, $0.handler) })
                toolsRegistered = true
            }
            eventsAttempted = true
            if let subscribe = events.sessionStarted {
                subscriptions.append(try await subscribe { await relay.started($0) })
                startedMetadata = true
            }
            if let subscribe = events.sessionStatus {
                subscriptions.append(try await subscribe { await relay.status(id: $0, value: $1) })
                sources.insert("session-idle")
            }
            if let subscribe = events.sessionExit {
                subscriptions.append(try await subscribe { await relay.exit(id: $0, code: $1) })
                sources.formUnion(["session-finished", "session-failed"])
            }
            if let subscribe = events.alertReport {
                subscriptions.append(try await subscribe { await relay.alert($0) })
                sources.insert("alert")
            }
            if let subscribe = events.wake {
                subscriptions.append(try await subscribe { await relay.wake() })
                wakeBound = true
            }
            // ServiceOptions.wired is a declaration; only successfully returned
            // real leases above establish these event sources as subscribed.
            for kind in BackendRoutinesRegisteredEventRelay.eventKinds {
                await service.engine.markSource(kind, subscribed: sources.contains(kind),
                    note: sources.contains(kind) ? nil : "No native \(kind) event subscription was supplied to routine registration.")
            }
            if startEngine {
                try Task.checkCancellation()
                engineStartAttempted = true
                try await service.start()
            }
        } catch {
            await relay.close()
            for subscription in subscriptions.reversed() { await subscription.cancelAndWait() }
            if engineStartAttempted { await service.stop() }
            if eventsAttempted { for kind in BackendRoutinesRegisteredEventRelay.eventKinds { await service.engine.markSource(kind, subscribed: false, note: "The native routine event registration was rolled back.") } }
            if toolsRegistered, let server = mcpServer, let toolOwner { await server.removeTools(ownerID: toolOwner) }
            if channelsAttempted { for channel in channels { await registry.removeHandler(channel, ownerID: owner) } }
            throw error
        }

        let leases = subscriptions, boundSources = sources
        let cleanup = NativeRPCSubscription {
            await relay.close()
            for subscription in leases.reversed() { await subscription.cancelAndWait() }
            for kind in boundSources { await service.engine.markSource(kind, subscribed: false, note: "The native routine event registration was removed.") }
            if startEngine { await service.stop() }
            for channel in channels { await registry.removeHandler(channel, ownerID: owner) }
            if let server = mcpServer, let toolOwner { await server.removeTools(ownerID: toolOwner) }
        }
        return .init(service: service, ownerID: owner, mcpOwnerID: toolOwner,
                     definitions: definitions, boundSources: boundSources,
                     sessionMetadataBound: startedMetadata, wakeBound: wakeBound,
                     startedEngine: startEngine, cleanup: cleanup)
    }
}

/// Uses the loader, not RoutineView: views omit quiet-for/expect-every and a
/// partial MCP edit would otherwise reset them when replacing the file.
public struct BackendRoutinesRegisteredAppAdapter: BackendDeckToolsAppRoutineService {
    let api: BackendRoutinesAPI
    /// INT: the composition builds the seven routine tools for the one core door over the same API.
    public init(api: BackendRoutinesAPI) { self.api = api }
    public func list() async throws -> [NativeRPCValue] { await api.list().map(\.wire) }
    public func get(_ id: String) async throws -> NativeRPCValue? { await api.get(.string(id))?.wire }
    public func text(_ id: String) async throws -> NativeRPCValue { await api.text(.string(id)) }
    public func draftFromFile(id: String, text: String) async throws -> NativeRPCValue? {
        guard let routine = BackendRoutinesFormat.parseRoutine(id, text: text).routine else { return nil }
        var fields: [NativeRPCValue.Field] = [
            .init("name", .string(routine.name)),
            .init("when", .array(routine.triggers.map { .string(BackendRoutinesFormat.serializeTrigger($0)) })),
            .init("in", .string(routine.folder)), .init("prompt", .string(routine.prompt)),
            .init("enabled", .bool(routine.enabled)), .init("overlap", .string(routine.overlap.rawValue)),
            .init("maxRunsPerHour", .number(Double(routine.maxRunsPerHour))),
            .init("maxRunsPerDay", .number(Double(routine.maxRunsPerDay))),
            .init("quietFor", .string(BackendRoutinesFormat.serializeDuration(routine.quietForMs)))
        ]
        if let expect = routine.expectEveryMs { fields.append(.init("expectEvery", .string(BackendRoutinesFormat.serializeDuration(expect)))) }
        return .object(fields)
    }
    public func create(_ draft: NativeRPCValue) async throws -> NativeRPCValue { try await api.create(draft).wire }
    public func update(_ id: String, draft: NativeRPCValue) async throws -> NativeRPCValue { try await api.update(.string(id), draft: draft).wire }
    public func remove(_ id: String) async throws -> NativeRPCValue { try await api.remove(.string(id)) }
    public func run(_ id: String, by: String) async throws -> NativeRPCValue { await api.run(.string(id), by: by).wire }
    public func pause(_ id: String, reason: String) async throws -> Bool { await api.pause(.string(id), reason: .string(reason)) }
    public func resume(_ id: String) async throws -> Bool { await api.resume(.string(id)) }
}

/// Event suppliers and retained cleanup share this actor so detached callbacks
/// cannot continue forwarding new events after the registration is closed.
private actor BackendRoutinesRegisteredEventRelay {
    static let eventKinds = ["session-finished", "session-failed", "session-idle", "alert"]
    private let engine: BackendRoutinesEngine
    private var active = true
    init(engine: BackendRoutinesEngine) { self.engine = engine }
    func close() { active = false }
    func started(_ metadata: BackendSessionMeta) async { guard active else { return }; await engine.noteSessionStarted(metadata) }
    func status(id: String, value: BackendSessionStatus) async { guard active else { return }; await engine.noteSessionStatus(sessionId: id, status: value) }
    func exit(id: String, code: Int) async { guard active else { return }; await engine.noteSessionExit(sessionId: id, exitCode: code) }
    func alert(_ report: NativeRPCValue) async { guard active else { return }; await engine.noteAlertReport(report) }
    func wake() async { guard active else { return }; await engine.wake() }
}
