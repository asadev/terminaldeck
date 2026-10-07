import Foundation

/// Reuses deck-core's actual/fake clock rather than a second timer owner. A
/// bound clock follows the whole async task call and its child operations.
public enum BackendTaskClockContext {
    @TaskLocal public static var clock: any BackendDeckCoreEventsClock = BackendTaskTimers.realClock
    public static func withClock<T: Sendable>(_ clock: any BackendDeckCoreEventsClock, operation: @Sendable () async throws -> T) async rethrows -> T {
        try await $clock.withValue(clock, operation: operation)
    }
    public static func sleep(milliseconds: Double) async throws {
        let clock = self.clock, latch = SleepLatch()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                latch.install(continuation)
                let token = clock.schedule(after: max(0, milliseconds)) { latch.finish(nil) }
                latch.bind(clock: clock, token: token)
            }
        } onCancel: { latch.finish(CancellationError()) }
    }
    private final class SleepLatch: @unchecked Sendable {
        let lock = NSLock(); var continuation: CheckedContinuation<Void, any Error>?, finished = false
        var error: (any Error)?, clock: (any BackendDeckCoreEventsClock)?, token: UUID?
        func install(_ c: CheckedContinuation<Void, any Error>) { let outcome = lock.withLock { if finished { return true }; continuation = c; return false }; if outcome { if let error { c.resume(throwing: error) } else { c.resume() } } }
        func bind(clock: any BackendDeckCoreEventsClock, token: UUID) { let cancel = lock.withLock { self.clock = clock; self.token = token; return finished }; if cancel { clock.cancel(token) } }
        func finish(_ error: (any Error)?) {
            let result = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any BackendDeckCoreEventsClock)?, UUID?) in
                guard !finished else { return (nil, nil, nil) }; finished = true; self.error = error; let c = continuation; continuation = nil; return (c, clock, token)
            }
            if let token = result.2 { result.1?.cancel(token) }
            if let c = result.0 { if let error { c.resume(throwing: error) } else { c.resume() } }
        }
    }
}

public final class BackendTaskTimer: @unchecked Sendable {
    private let clock: any BackendDeckCoreEventsClock, id: UUID
    public init(clock: any BackendDeckCoreEventsClock, id: UUID) { self.clock = clock; self.id = id }
    public func cancel() { clock.cancel(id) }
    deinit { cancel() }
}
public enum BackendTaskTimers {
    public static let realClock = BackendDeckCoreEventsRealClock()
    public static func schedule(milliseconds: Double, operation: @escaping @Sendable () async -> Void) -> BackendTaskTimer {
        let clock = BackendTaskClockContext.clock, actor = BackendTaskActor.current
        let id = clock.schedule(after: max(0, milliseconds)) {
            Task { await BackendTaskClockContext.withClock(clock) { await BackendTaskActor.withActor(actor, operation: operation) } }
        }; return BackendTaskTimer(clock: clock, id: id)
    }
}
