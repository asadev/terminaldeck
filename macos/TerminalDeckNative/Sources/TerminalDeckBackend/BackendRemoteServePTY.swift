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
    /// 28 Oct: the phones and other Macs attached to the session, at their sizes. `user`: the one that just chose the
    /// session owns its size from now on; `keep`: only if nobody chose it since (a phone coming back after its link
    /// dropped). True when the program was given a new size (`BackendTerminalViewers`).
    func setViewerSizes(_ id: String, _ claims: [BackendTerminalViewers.Claim], user: String?, keep: Bool) throws -> Bool
    /// Who owns the session's size and what it is, or nil when nothing is known yet.
    func viewerSizes(_ id: String) -> BackendTerminalViewers?
    /// Called after any change of a session's size or owner.
    func observeSizes(_ callback: @escaping @Sendable (String) -> Void) -> NativeRPCSubscription
}

extension BackendRemoteServePTYSource {
    /// A source with no Mac terminal of its own (test fakes): the one that chose it has the size.
    public func setViewerSizes(_ id: String, _ claims: [BackendTerminalViewers.Claim], user: String?, keep: Bool) throws -> Bool {
        guard let user, let claim = claims.last(where: { $0.viewer == user }) else { return false }
        try resize(id, cols: claim.size.cols, rows: claim.size.rows)
        return true
    }
    public func viewerSizes(_ id: String) -> BackendTerminalViewers? { nil }
    public func observeSizes(_ callback: @escaping @Sendable (String) -> Void) -> NativeRPCSubscription {
        NativeRPCSubscription(id: UUID()) {}
    }
}

extension BackendPTYManager: BackendRemoteServePTYSource {
    public func kill(_ id: String) { kill(id, reason: .stopped) }
    public func snapshot(_ id: String) -> BackendRemoteServePTYSnapshot? { remoteServeSnapshot(id) }
    public func currentSequence() -> UInt64 { remoteServeCurrentSequence() }
    public func observe(_ callback: @escaping @Sendable (BackendRemoteServePTYEvent) -> Void) -> NativeRPCSubscription {
        remoteServeObserve(callback)
    }
}
