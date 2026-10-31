import Foundation

/// Keeps expensive real credential verification independent of machine load.
/// Only the host's injected timer changes; production auth and deadlines remain real.
final class INT2PhoneHostClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var instant = 0
    private var sleepers: [UUID: Sleeper] = [:]
    let scheduled = BackendDeckCoreTestPortSecuritySignal()
    let cancelled = BackendDeckCoreTestPortSecuritySignal()

    func now() -> Double { lock.withLock { Double(instant) } }
    func deadlines() -> [Int] { lock.withLock { sleepers.values.map(\.deadline).sorted() } }
    func sleep(_ milliseconds: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registered = lock.withLock {
                    guard !Task.isCancelled else { return false }
                    sleepers[id] = Sleeper(deadline: instant + milliseconds, continuation: continuation)
                    return true
                }
                if registered { scheduled.signal() }
                else { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
            if sleeper != nil { self.cancelled.signal() }
        }
    }
    func advance(_ milliseconds: Int) {
        let ready = lock.withLock {
            instant += milliseconds
            return sleepers.filter { $0.value.deadline <= instant }.keys.compactMap {
                sleepers.removeValue(forKey: $0)?.continuation
            }
        }
        for continuation in ready { continuation.resume() }
    }
}
