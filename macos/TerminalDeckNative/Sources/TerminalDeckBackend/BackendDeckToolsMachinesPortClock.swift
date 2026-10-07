import Foundation

/// Cancellation-aware wait over the existing shared scheduler. Production uses
/// its real clock; case ports advance an injected clock without sleeping.
public enum BackendDeckToolsMachinesPortClock {
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private var continuation: CheckedContinuation<Void, any Error>?
        private var timer: UUID?
        private var clock: (any BackendDeckCoreEventsClock)?
        func begin(_ continuation: CheckedContinuation<Void, any Error>, clock: any BackendDeckCoreEventsClock, milliseconds: Double) {
            let already = lock.withLock { () -> Bool in
                if finished { return true }; self.continuation = continuation; self.clock = clock; return false
            }
            if already { continuation.resume(throwing: CancellationError()); return }
            let handle = clock.schedule(after: milliseconds) { [weak self] in self?.complete(nil) }
            let cancel = lock.withLock { () -> Bool in if finished { return true }; timer = handle; return false }
            if cancel { clock.cancel(handle) }
        }
        func complete(_ error: (any Error)?) {
            let captured = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, (any BackendDeckCoreEventsClock)?, UUID?) in
                guard !finished else { return (nil, nil, nil) }; finished = true
                let captured = (continuation, clock, timer); continuation = nil; timer = nil; clock = nil; return captured
            }
            if let clock = captured.1, let timer = captured.2 { clock.cancel(timer) }
            if let continuation = captured.0 { if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
    }
    public static func wait(clock: any BackendDeckCoreEventsClock, milliseconds: Double) async throws {
        let pending = Pending()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in pending.begin(continuation, clock: clock, milliseconds: milliseconds) }
        } onCancel: { pending.complete(CancellationError()) }
    }
}
