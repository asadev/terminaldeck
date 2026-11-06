import Foundation
import TerminalDeckNativeCore

/// A password may run only during this short, monotonic window, shared across the local processes.
/// It carries no password. Cancellation and expiry are checked again at each secure-field keystroke.
public final class BackendMacSignInAttempt: @unchecked Sendable {
    @TaskLocal public static var current: BackendMacSignInAttempt?
    public static let failureWords = "Couldn't sign in right now — try again"
    public static var failure: NativeRPCError { .init(code: "unavailable", message: failureWords) }
    public let expiresAt: Double
    private let lock = NSLock()
    private var cancelled = false
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    public init(expiresAt: Double = ProcessInfo.processInfo.systemUptime + 2) { self.expiresAt = expiresAt }
    public func cancel() {
        let actions = lock.withLock {
            cancelled = true
            let actions = Array(cancellations.values); cancellations = [:]
            return actions
        }
        for action in actions { action() }
    }
    public func whenCancelled(_ action: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let run = lock.withLock { if cancelled { return true }; cancellations[id] = action; return false }
        if run { action() }
        return id
    }
    public func removeCancellation(_ id: UUID) { _ = lock.withLock { cancellations.removeValue(forKey: id) } }
    public func check(now: Double = ProcessInfo.processInfo.systemUptime) throws {
        guard !Task.isCancelled, !lock.withLock({ cancelled }), expiresAt.isFinite,
              now < expiresAt, expiresAt - now <= 2 else { throw Self.failure }
    }
}
