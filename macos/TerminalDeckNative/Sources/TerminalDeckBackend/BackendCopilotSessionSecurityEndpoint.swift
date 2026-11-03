import Foundation
import TerminalDeckNativeCore

/// Adapter to the one authoritative deck-core security server. Conformance is
/// only for reusing the existing private file leases; all token matching, tiers,
/// consent, budgets and action logging stay in BackendDeckCoreSecurityServer.
public actor BackendCopilotSessionSecurityEndpoint: BackendMCPToolEndpoint {
    public nonisolated let readiness: BackendLaunchReadiness = .ready
    private let server: BackendDeckCoreSecurityServer
    private let plansOnly: @Sendable () async -> Bool
    /// Hoot's permission switches, checked before each of Hoot's tool calls.
    private let beforeTool: (@Sendable (String, NativeRPCValue) async throws -> Void)?
    private struct Entry: Sendable {
        let table: BackendDeckCoreSecurityCallerTable
        let grant: BackendMCPCallerGrant
        let cancellation: BackendMCPCancellation
        var sessionID: String?
        var machineID: String?
    }
    // Handles for revoke/bind, never a second credential matching authority.
    private var entries: [UUID: Entry] = [:]
    /// Hoot's permission mode is Bypass: its app changes do not ask (askFirst false on its caller).
    private let bypass: @Sendable () async -> Bool
    public init(server: BackendDeckCoreSecurityServer, plansOnly: @escaping @Sendable () async -> Bool = { false },
                bypass: @escaping @Sendable () async -> Bool = { false },
                beforeTool: (@Sendable (String, NativeRPCValue) async throws -> Void)? = nil) {
        self.server = server; self.plansOnly = plansOnly; self.bypass = bypass; self.beforeTool = beforeTool
    }
    public func description() async throws -> BackendMCPEndpointDescription? {
        guard let endpoint = await server.currentEndpoint() else { return nil }
        return try .init(url: endpoint.url, implementation: .native)
    }
    public func catalogue() async throws -> [BackendMCPTool] {
        try await server.listedTools(caller: .local)
    }
    public func register(token: String, grant: BackendMCPCallerGrant) async throws -> BackendMCPRegistration {
        guard let endpoint = await server.currentEndpoint() else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's actual deck-control security server is unavailable.")
        }
        let pendingID = UUID(), cancellation = BackendMCPCancellation()
        let security = BackendDeckCoreSecurityGrant(identity: pendingID.uuidString.lowercased(), attended: grant.attended,
            // Source local Hoot is unrestricted within the actual catalogue.
            // A fixed wire-name grant would silently drop registered aliases.
            tools: nil, cancellation: cancellation, caller: { [weak self] in
                guard let self else { return .init(kind: .local, tiers: []) }
                return await self.caller(pendingID)
            }, beforeTool: beforeTool)
        entries[pendingID] = .init(table: endpoint.callers, grant: grant, cancellation: cancellation)
        let actual: UUID
        do { actual = try await endpoint.callers.set(token: token, grant: security) }
        catch { entries[pendingID] = nil; throw error }
        // Table IDs can differ from the closure ID; both are explicit handles.
        if actual != pendingID { registrations[actual] = pendingID }
        guard await server.currentEndpoint()?.callers === endpoint.callers else {
            _ = await endpoint.callers.revoke(actual); entries[pendingID] = nil; registrations[actual] = nil
            throw NativeRPCError(code: "unavailable", message: "Hoot's deck-control server changed while its caller was registered.")
        }
        return .init(id: actual)
    }
    private var registrations: [UUID: UUID] = [:]
    private func caller(_ id: UUID) async -> BackendDeckCoreSecurityCaller {
        guard let entry = entries[id], !entry.cancellation.isCancelled, await entry.grant.permitted() else {
            return .init(kind: .local, tiers: [])
        }
        guard !entry.cancellation.isCancelled, entries[id] != nil else { return .init(kind: .local, tiers: []) }
        let tiers = await plansOnly() ? entry.grant.allowedTiers.intersection([.read]) : entry.grant.allowedTiers
        guard !entry.cancellation.isCancelled, entries[id] != nil else { return .init(kind: .local, tiers: []) }
        return .init(kind: .local, tiers: tiers, askFirst: await bypass() ? false : nil, sessionID: entry.sessionID, machineID: entry.machineID)
    }
    public func bind(_ registration: BackendMCPRegistration, sessionID: String, machineID: String) async throws {
        let id = registrations[registration.id] ?? registration.id
        guard var entry = entries[id], !entry.cancellation.isCancelled, !sessionID.isEmpty,
              await server.currentEndpoint()?.callers === entry.table, entries[id] != nil, !entry.cancellation.isCancelled else {
            throw NativeRPCError(code: "unavailable", message: "Hoot's pending security caller expired before its session could bind.")
        }
        entry.sessionID = sessionID; entry.machineID = machineID; entries[id] = entry
    }
    public func revoke(_ registration: BackendMCPRegistration) async {
        let id = registrations.removeValue(forKey: registration.id) ?? registration.id
        guard let entry = entries.removeValue(forKey: id) else { return }
        _ = await entry.table.revoke(registration.id)
        entry.cancellation.cancel()
    }
}
