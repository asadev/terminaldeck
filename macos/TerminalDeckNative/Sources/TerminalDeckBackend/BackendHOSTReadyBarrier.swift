import Foundation

/// A one-shot stream-ready signal. Each caller owns its deadline; finishing cancels every timer.
public final class BackendHOSTReadyBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: DispatchWorkItem
    }
    private var waiters: [UUID: Waiter] = [:]
    public init() {}
    public func finish(_ error: Error?) {
        let value: Result<Void, Error> = error.map(Result.failure) ?? .success(())
        let pending = lock.withLock { () -> [Waiter] in
            guard result == nil else { return [] }
            result = value
            let pending = Array(waiters.values); waiters.removeAll(); return pending
        }
        for waiter in pending { waiter.timeout.cancel(); waiter.continuation.resume(with: value) }
    }
    public func wait(timeout: TimeInterval) async throws {
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            let timer = DispatchWorkItem { [weak self] in
                let pending = self?.lock.withLock { self?.waiters.removeValue(forKey: id) }
                pending?.continuation.resume(throwing: BackendHOSTFailure.unavailable)
            }
            let finished = lock.withLock { () -> Result<Void, Error>? in
                if let result { return result }
                waiters[id] = Waiter(continuation: continuation, timeout: timer)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                return nil
            }
            if let finished { continuation.resume(with: finished) }
        }
    }
}
