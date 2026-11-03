#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Deferred sessions retain their original app process owner. Only their
/// established account reservation is bound to that owner's actual child.
public protocol BackendHOSTExternalAccountBinding: BackendAccountLaunchResolver {
    func bindExternal(_ account: BackendAccountLaunch, session: BackendSessionMeta, pid: Int32) async throws
}
#endif
