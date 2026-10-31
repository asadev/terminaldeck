import Foundation

/// Shared wall-clock race seam. Production uses DispatchQueue; parity tests
/// advance a manual scheduler through this same decision, never real sleeps.
public protocol BackendMcpClientDeadlineScheduling: Sendable {
    func schedule(milliseconds: Int, fire: @escaping @Sendable () -> Void) -> BackendMcpClientDeadlineTicket
}

public final class BackendMcpClientDeadlineTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (@Sendable () -> Void)?
    public init(cancel: @escaping @Sendable () -> Void) { cancelAction = cancel }
    public func cancel() {
        let action = lock.withLock { let action = cancelAction; cancelAction = nil; return action }; action?()
    }
    deinit { cancel() }
}

public struct BackendMcpClientDispatchScheduler: BackendMcpClientDeadlineScheduling, Sendable {
    private final class Work: @unchecked Sendable { let item: DispatchWorkItem; init(_ item: DispatchWorkItem) { self.item = item } }
    public init() {}
    public func schedule(milliseconds: Int, fire: @escaping @Sendable () -> Void) -> BackendMcpClientDeadlineTicket {
        let work = Work(DispatchWorkItem(block: fire))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(milliseconds), execute: work.item)
        return .init { work.item.cancel() }
    }
}
