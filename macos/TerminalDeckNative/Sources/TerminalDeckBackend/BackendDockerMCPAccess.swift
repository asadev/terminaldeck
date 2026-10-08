import Foundation
import TerminalDeckNativeCore

/// Shared by Docker and Apps MCP. Composition supplies the existing caller
/// ticket and consent/action-log gate; this adapter never invents an identity.
public struct BackendDockerMCPAccess: Sendable {
    public typealias RPCContext = @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext
    public typealias Authorize = @Sendable (BackendMCPCallContext, String, NativeRPCValue, BackendMCPTier, String, Bool) async throws -> Void
    public typealias NoteResult = @Sendable (BackendMCPCallContext, NativeRPCValue) async -> Void
    public let rpcContext: RPCContext
    public let authorize: Authorize
    public let noteResult: NoteResult

    /// authorize must ask the person for EVERY write, even when the caller has
    /// standing permission. A destructive request must name the current target.
    public init(rpcContext: @escaping RPCContext, authorize: @escaping Authorize,
                noteResult: @escaping NoteResult = { _, _ in }) {
        self.rpcContext = rpcContext; self.authorize = authorize; self.noteResult = noteResult
    }

    /// The running deck-control policy remains the only consent/budget/log row.
    /// ownerMustAnswer forbids standing key permission from covering a write.
    /// Call authorize before rpcContext so the ticket carries its real receipt.
    public init(gate: BackendCompositionDeckToolsGate) {
        self.init(rpcContext: { native in try await gate.authority.rpc(native) },
                  authorize: { native, _, _, tier, sentence, destructive in
                      try await gate.authorize(native, tier, sentence, destructive || tier != .read)
                  }, noteResult: { native, value in await gate.noteResult(native, value) })
    }

    public static func cancellable<T: Sendable>(_ cancellation: BackendMCPCancellation,
                                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !cancellation.isCancelled else { throw CancellationError() }
        let work = Task { try await operation() }
        let observer = cancellation.observe { work.cancel() }
        defer { cancellation.removeObserver(observer) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
