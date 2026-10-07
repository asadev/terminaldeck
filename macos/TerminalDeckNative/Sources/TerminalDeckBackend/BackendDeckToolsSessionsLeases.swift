import Foundation
import Security
import TerminalDeckNativeCore

/// session-tools.ts's far-machine narrowing, applied to the existing positive
/// grant. Chrome extensions are retired by Asad's Safari/WebKit decision.
public enum BackendDeckToolsSessionsGrants {
    public static let ordinary = BackendOrdinarySessionToolGrant.names
    public static let elsewhere: Set<String> = ordinary.filter { name in
        !name.hasPrefix("assets.") && !name.hasPrefix("assets_") && !name.hasPrefix("devices.") && !name.hasPrefix("devices_") &&
        !["browser.network", "browser_network", "memory.search", "memory_search", "memory.read", "memory_read", "knowledge.note", "knowledge_note"].contains(name)
    }
    public static let tiers: Set<BackendMCPTier> = [.read, .act, .alter]
    public static let claimMilliseconds = 60_000
    public static let tokenFile = "deck-control.token"
}

public struct BackendDeckToolsSessionsPreparedElsewhere: Sendable {
    /// Secret remains inside this closure, and is written 0600 by SSH owner.
    public let configFor: @Sendable (String) throws -> String
    public let started: @Sendable (String, String) async throws -> Void
    public let drop: @Sendable () async -> Void
}

/// The existing local lease actor remains the single owner of local configs.
/// This companion only holds the source prepareElsewhere registrations: no
/// second config writer, PTY owner, caller table, endpoint or live-data root.
public actor BackendDeckToolsSessionsElsewhereLeases {
    private struct Lease: Sendable {
        let registration: BackendMCPRegistration
        let expiry: UUID
        var sessionID: String?
    }
    private let endpoint: any BackendMCPToolEndpoint
    private let clock: any BackendDeckCoreEventsClock
    private var leases: [UUID: Lease] = [:]
    private var stopped = false
    public init(endpoint: any BackendMCPToolEndpoint, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) { self.endpoint = endpoint; self.clock = clock }
    public func prepare(allowed: @escaping @Sendable () async -> Bool) async throws -> BackendDeckToolsSessionsPreparedElsewhere? {
        guard !stopped else { throw BackendSessionFailure.closed }
        guard try await endpoint.description() != nil else { return nil }
        let catalogue = try await endpoint.catalogue()
        var grant = Set<String>()
        for spec in catalogue where BackendDeckToolsSessionsGrants.elsewhere.contains(spec.id) || BackendDeckToolsSessionsGrants.elsewhere.contains(spec.wireName) {
            grant.insert(spec.id); grant.insert(spec.wireName)
        }
        guard !grant.isEmpty else { throw BackendDeckToolsSupport.unavailable("The registered elsewhere-session tool grant") }
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw BackendSessionFailure.invalidInput("macOS could not generate a private session MCP token.") }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let registration = try await endpoint.register(token: token, grant: BackendMCPCallerGrant(attended: true, allowedTools: grant, allowedTiers: BackendDeckToolsSessionsGrants.tiers, permitted: allowed))
        guard !stopped else { await endpoint.revoke(registration); throw BackendSessionFailure.closed }
        let id = UUID()
        let expiry = clock.schedule(after: Double(BackendDeckToolsSessionsGrants.claimMilliseconds)) { [weak self] in Task { await self?.expire(id) } }
        leases[id] = Lease(registration: registration, expiry: expiry)
        return BackendDeckToolsSessionsPreparedElsewhere(configFor: { url in
            let server = NativeRPCValue.object([.init("type", .string("http")), .init("url", .string(url)), .init("headers", .object([.init("Authorization", .string("Bearer " + token))]))])
            let bytes = try NativeRPCValue.object([.init("mcpServers", .object([.init("deck-control", server)]))]).encodedJSON(pretty: true)
            guard let text = String(data: bytes, encoding: .utf8) else { throw BackendDeckToolsSupport.unavailable("The session MCP config encoding") }
            return text + "\n"
        }, started: { [weak self] sessionID, machineID in
            guard let self else { throw BackendSessionFailure.closed }
            try await self.bind(id, sessionID: sessionID, machineID: machineID)
        }, drop: { [weak self] in await self?.forget(id) })
    }
    private func bind(_ id: UUID, sessionID: String, machineID: String) async throws {
        guard !stopped, var lease = leases[id], lease.sessionID == nil else { throw BackendSessionFailure.invalidInput("The session MCP caller expired or was already claimed.") }
        try await endpoint.bind(lease.registration, sessionID: sessionID, machineID: machineID)
        guard !stopped, leases[id] != nil else { await endpoint.revoke(lease.registration); throw BackendSessionFailure.closed }
        clock.cancel(lease.expiry); lease.sessionID = sessionID; leases[id] = lease
    }
    public var count: Int { leases.count }
    public func release(sessionID: String) async { for id in leases.compactMap({ $0.value.sessionID == sessionID ? $0.key : nil }) { await forget(id) } }
    public func stop() async { stopped = true; for id in Array(leases.keys) { await forget(id) } }
    private func expire(_ id: UUID) async { if leases[id]?.sessionID == nil { await forget(id) } }
    private func forget(_ id: UUID) async { guard let lease = leases.removeValue(forKey: id) else { return }; clock.cancel(lease.expiry); await endpoint.revoke(lease.registration) }
}

public struct BackendDeckToolsSessionsLeaseFacade: Sendable {
    public let local: BackendSessionToolLeases
    public let elsewhere: BackendDeckToolsSessionsElsewhereLeases
    private let endpoint: any BackendMCPToolEndpoint
    public init(local: BackendSessionToolLeases, endpoint: any BackendMCPToolEndpoint, clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) { self.local = local; self.endpoint = endpoint; elsewhere = BackendDeckToolsSessionsElsewhereLeases(endpoint: endpoint, clock: clock) }
    public func prepare() async throws -> BackendPreparedToolLease? {
        guard try await endpoint.description() != nil else { return nil }
        return try await local.prepareOrdinary()
    }
    public func prepareElsewhere(allowed: @escaping @Sendable () async -> Bool) async throws -> BackendDeckToolsSessionsPreparedElsewhere? { try await elsewhere.prepare(allowed: allowed) }
    public func release(sessionID: String) async { await local.release(sessionID: sessionID); await elsewhere.release(sessionID: sessionID) }
    public func stop() async { await local.stop(); await elsewhere.stop() }
    public func size() async -> Int { let here = await local.count; let there = await elsewhere.count; return here + there }
}
