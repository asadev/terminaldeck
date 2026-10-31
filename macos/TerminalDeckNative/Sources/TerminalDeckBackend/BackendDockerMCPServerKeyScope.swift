import Foundation
import TerminalDeckNativeCore

/// The caller is credential-resolved by the shared authority. Full tool tier
/// never substitutes for the owner's grant on this particular saved server.
public enum BackendDockerMCPServerKeyScope {
    /// On since DKA2 (2026-10-09): per-server AI app access, SSH settings
    /// servers and Look only are wired and tested.
    public static let enabled = true
    public static let refusal = "Not allowed on this server. Ask the owner for access using access_request_scope."
    public static func allows(_ caller: BackendDeckCoreSecurityCaller, server: BackendServersStoredServer?) -> Bool {
        guard caller.kind != .remote, caller.machineID?.isEmpty != false else { return false }
        if caller.kind != .key { return true }
        guard caller.folders == nil, let id = caller.keyID, !id.isEmpty else { return false }
        return server?.aiKeyIDs?.contains(id) == true
    }
    /// docker.targets for one caller: the window (nil) and this Mac's own
    /// sessions see every saved server; a key sees only servers it was given;
    /// a remote caller sees none. Never an error for the servers left out.
    public static func visible(_ rows: [BackendServersStoredServer], caller: BackendDeckCoreSecurityCaller?) -> [BackendServersStoredServer] {
        guard let caller else { return rows }
        return rows.filter { allows(caller, server: $0) }
    }
    public static func check(_ caller: BackendDeckCoreSecurityCaller, server: BackendServersStoredServer?) throws {
        guard allows(caller, server: server) else { throw NativeRPCError(code: "access-denied", message: refusal) }
    }
}

/// Retains the existing store when composition becomes ready; no second cache,
/// file or credential owner. A pending consent cannot switch to another store.
public final class BackendDockerMCPServerStoreReference: @unchecked Sendable {
    private let lock = NSLock()
    private var store: BackendServersStore?
    public init() {}
    public func get() -> BackendServersStore? { lock.withLock { store } }
    public func install(_ value: BackendServersStore) throws {
        try lock.withLock {
            guard store == nil || store === value else { throw NativeRPCError(code: "composition-root-conflict", message: "Server access must use the existing server store.") }
            store = value
        }
    }
}
