import Foundation
import Darwin

/// No command, environment, account value or secret is stored here.
public struct BackendHOSTOrphanIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var groupID: Int32
    public var uid: UInt32
    public var startedSeconds: UInt64
    public var startedMicroseconds: UInt64
    public var auditWords: [UInt32]
    public var zombie: Bool
    public var stopped: Bool

    public init(pid: Int32, parentPID: Int32, groupID: Int32, uid: UInt32,
                startedSeconds: UInt64, startedMicroseconds: UInt64,
                auditWords: [UInt32], zombie: Bool = false, stopped: Bool = false) {
        self.pid = pid; self.parentPID = parentPID; self.groupID = groupID; self.uid = uid
        self.startedSeconds = startedSeconds; self.startedMicroseconds = startedMicroseconds
        self.auditWords = auditWords; self.zombie = zombie; self.stopped = stopped
    }
    /// exec may change the audit PID version; birth identity remains stable.
    public func sameProcess(as other: Self) -> Bool {
        pid == other.pid && uid == other.uid && startedSeconds == other.startedSeconds
            && startedMicroseconds == other.startedMicroseconds
    }
    var valid: Bool {
        pid > 1 && parentPID >= 0 && groupID > 0 && uid == geteuid()
            && startedSeconds > 0 && startedMicroseconds < 1_000_000
            && (zombie || (auditWords.count == 8 && auditWords[5] == UInt32(pid) && auditWords[1] == uid))
    }
}

public struct BackendHOSTOrphanRecord: Codable, Equatable, Sendable {
    public var sessionID: String
    public var owner: BackendHOSTOrphanIdentity
    public var rootPID: Int32
    public var processes: [BackendHOSTOrphanIdentity]
    /// Claude Code's config folder when the session runs Claude Code (a path, never a value from it): a recovery stop
    /// waits for a sign-in renewal under way there before it freezes and kills (lane mac-signin-renewal "Left").
    public var renewalFolder: String? = nil
}

public struct BackendHOSTOrphanRecovery: Codable, Sendable {
    public enum State: String, Codable, Sendable { case liveOwner, recoverable, gone, identityChanged, unverified }
    public var record: BackendHOSTOrphanRecord
    public var state: State
    public var livePIDs: [Int32]
    public var replacedPIDs: [Int32]
    public var unverifiedPIDs: [Int32]
}

public struct BackendHOSTOrphanProof: Codable, Sendable {
    public var sessionID: String
    public var recordedPIDs: [Int32]
    public var signalledPIDs: [Int32]
    public var remainingPIDs: [Int32]
    public var replacedPIDs: [Int32]
    public var unverifiedPIDs: [Int32]
    public var inventoryRemoved: Bool
    public var clean: Bool { remainingPIDs.isEmpty && unverifiedPIDs.isEmpty && inventoryRemoved }
    /// Covers identities captured while ancestry was provable, not unseen daemons.
    public var coverage = "Recorded processes only; a descendant that daemonized before observation cannot be recovered by guessing ancestry."
}

public enum BackendHOSTOrphanFailure: Error, LocalizedError, Sendable {
    case invalid(String), kernel(String, Int32), liveOwner, missingSession, budget
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .kernel(let operation, let status): "Orphan recovery could not \(operation) (kernel status \(status))."
        case .liveOwner: "The original host is still running. Its sessions were left alone."
        case .missingSession: "No owned orphan record exists for this session."
        case .budget: "The owned process inventory reached its safety limit."
        }
    }
}

/// Injected operations must bind signalling to a kernel process identity,
/// never merely recheck a PID and then call kill(pid). Production uses audit tokens.
public struct BackendHOSTOrphanKernel: Sendable {
    public var ownPID: Int32
    public var inspect: @Sendable (Int32) throws -> BackendHOSTOrphanIdentity?
    public var children: @Sendable (Int32) throws -> [Int32]
    public var signal: @Sendable (BackendHOSTOrphanIdentity, Int32) throws -> Bool
    public var sleep: @Sendable () async throws -> Void
    public var watch: @Sendable (Int32, @escaping @Sendable () -> Void) -> BackendHOSTOrphanWatch?

    public init(inspect: @escaping @Sendable (Int32) throws -> BackendHOSTOrphanIdentity?,
                children: @escaping @Sendable (Int32) throws -> [Int32],
                signal: @escaping @Sendable (BackendHOSTOrphanIdentity, Int32) throws -> Bool,
                sleep: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(25)) },
                watch: @escaping @Sendable (Int32, @escaping @Sendable () -> Void) -> BackendHOSTOrphanWatch? = { _, _ in nil },
                ownPID: Int32 = getpid()) {
        self.ownPID = ownPID; self.inspect = inspect; self.children = children; self.signal = signal; self.sleep = sleep; self.watch = watch
    }
}

public final class BackendHOSTOrphanWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    public init(cancel: @escaping @Sendable () -> Void) { action = cancel }
    public func cancel() { let work = lock.withLock { let work = action; action = nil; return work }; work?() }
    deinit { cancel() }
}
