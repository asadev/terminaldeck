import Foundation
import TerminalDeckNativeCore

/// Sequence is assigned by the single PTY owner, on the same queue that appends
/// bytes to its existing replay buffer. This creates no second replay owner.
public struct BackendRemoteServePTYEvent: Sendable {
    public let sequence: UInt64
    public let event: BackendSessionEvent
    public init(sequence: UInt64, event: BackendSessionEvent) { self.sequence = sequence; self.event = event }
}
public struct BackendRemoteServePTYSnapshot: Sendable {
    public let sequence: UInt64
    public let session: BackendSessionMeta
    public let replay: String
    public let status: BackendSessionStatus
    public init(sequence: UInt64, session: BackendSessionMeta, replay: String, status: BackendSessionStatus) {
        self.sequence = sequence; self.session = session; self.replay = replay; self.status = status
    }
}
/// Real manager and deterministic fake expose the same serialized boundary.
/// observe is installed before any attach; snapshot and sequence are atomic.
public protocol BackendRemoteServePTYSource: Sendable {
    func list() -> [BackendSessionMeta]
    func write(_ id: String, data: String) throws
    func resize(_ id: String, cols: Int, rows: Int) throws
    func kill(_ id: String)
    func snapshot(_ id: String) -> BackendRemoteServePTYSnapshot?
    func currentSequence() -> UInt64
    func observe(_ callback: @escaping @Sendable (BackendRemoteServePTYEvent) -> Void) -> NativeRPCSubscription
}

/// Uses the existing manager's queue/replay; no second PTY or scrollback store.
/// BackendPTYManager's three queue-owned SPI methods are the exact night
/// request in handoffs/BackendRemoteServePTYJoin.patch (O2 owns that file).
extension BackendPTYManager: BackendRemoteServePTYSource {
    public func kill(_ id: String) { kill(id, reason: .stopped) }
    public func snapshot(_ id: String) -> BackendRemoteServePTYSnapshot? { remoteServeSnapshot(id) }
    public func currentSequence() -> UInt64 { remoteServeCurrentSequence() }
    public func observe(_ callback: @escaping @Sendable (BackendRemoteServePTYEvent) -> Void) -> NativeRPCSubscription {
        remoteServeObserve(callback)
    }
}
