#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Original app provider discovery, kept separate from helper account storage.
/// Concrete NativeProviders and the authenticated scoped helper adapter both
/// implement these actual operations; no aux-state provider is substituted.
public protocol BackendHOSTUsageProvider: Sendable {
    func loginPath() async throws -> String
    func resolveBinary(_ id: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary
}
extension BackendNativeProviders: BackendHOSTUsageProvider {}
#endif
