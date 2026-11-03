#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Only the app-composed routine launch/follow-up account lookup uses this
/// scope. Its already accepted job outlives the request that scheduled it.
/// Never borrow that request's TaskLocal profile ticket: it expires on return.
/// The current app owner is validated again; public callers keep their tickets.
public enum BackendRoutinesAppProfileScope {
    public static func withOwner<T: Sendable>(authority: BackendCompositionAuthority?,
        operation: @Sendable () async throws -> T) async throws -> T {
        guard let authority else {
            throw NativeRPCError(code: "unavailable", message: "The routine's current app account owner is unavailable.")
        }
        let owner = try authority.localContext()
        return try await BackendHOSTProfileScope.withContext(owner, operation: operation)
    }
}
#endif
