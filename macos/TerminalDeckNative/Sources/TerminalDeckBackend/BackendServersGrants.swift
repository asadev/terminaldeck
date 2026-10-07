import Foundation

public struct BackendServersGrantState: Codable, Equatable, Sendable {
    public let serverId: String, expiresAt: Double, grantedAt: Double
}
public struct BackendServersGrantRefused: Error, LocalizedError, Sendable {
    public let reason: String, message: String
    public var errorDescription: String? { message }
}
/// Source grants.ts. These grants never reach disk, cross server IDs, or apply
/// to a remote/session/access-key caller. Read-time expiry uses no timer.
public final class BackendServersGrants: @unchecked Sendable {
    public static let defaultGrantMilliseconds: Double = 3_600_000, maximumGrantMilliseconds: Double = 14_400_000, maximumLiveGrants = 64
    private let now: @Sendable () -> Double, knows: (@Sendable (String) -> Bool)?, assistantName: String
    private let lock = NSLock(); private var live: [String: BackendServersGrantState] = [:]
    public init(assistantName: String, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, knows: (@Sendable (String) -> Bool)? = nil) {
        self.assistantName = assistantName; self.now = now; self.knows = knows
    }
    public func grant(_ serverId: String, asker: String, forMilliseconds: Double = defaultGrantMilliseconds) throws -> BackendServersGrantState {
        try lock.withLock {
            guard asker == "local" else { throw BackendServersGrantRefused(reason: "not-local", message: "Control of a server can only be granted by the person at this machine. A paired device cannot give it, and cannot receive it.") }
            if let knows, !knows(serverId) { throw BackendServersGrantRefused(reason: "unknown-server", message: "That server is not one this app knows about.") }
            sweep()
            guard live[serverId] != nil || live.count < Self.maximumLiveGrants else { throw BackendServersGrantRefused(reason: "too-many", message: "Too many servers are already under \(assistantName)’s control. Take control back from one first.") }
            let at = now(), duration = forMilliseconds.isNaN ? 0 : min(max(forMilliseconds.rounded(.towardZero), 0), Self.maximumGrantMilliseconds)
            let state = BackendServersGrantState(serverId: serverId, expiresAt: at + duration, grantedAt: at); live[serverId] = state; return state
        }
    }
    public func revoke(_ serverId: String) { lock.withLock { live[serverId] = nil } }
    public func revokeAll() { lock.withLock { live = [:] } }
    public func granted(_ serverId: String, asker: String) -> Bool { guard asker == "local" else { return false }; return state(serverId) != nil }
    public func state(_ serverId: String) -> BackendServersGrantState? { lock.withLock { sweep(); return live[serverId] } }
    public func list() -> [BackendServersGrantState] { lock.withLock { sweep(); return live.values.sorted { $0.grantedAt > $1.grantedAt } } }
    private func sweep() { let at = now(); live = live.filter { $0.value.expiresAt > at } }
}
