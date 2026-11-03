import Foundation

/// Serializes an owner's operations across awaits. Different keys (session switches) stay independent.
final class BackendSessionAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    var isBusy: Bool { lock.withLock { !waiting.isEmpty } }
    func enter(_ key: String = "") async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock { () -> Bool in
                if waiting[key] != nil { waiting[key]!.append(continuation); return false }
                waiting[key] = []; return true
            }
            if acquired { continuation.resume() }
        }
    }
    func leave(_ key: String = "") {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard var entrants = waiting[key] else { preconditionFailure("The session gate has no owner.") }
            guard !entrants.isEmpty else { waiting[key] = nil; return nil }
            let next = entrants.removeFirst(); waiting[key] = entrants; return next
        }
        next?.resume()
    }
}
