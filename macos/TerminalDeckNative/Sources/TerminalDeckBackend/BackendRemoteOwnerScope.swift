import Foundation
import TerminalDeckNativeCore

/**
 * What only Full control may ask of this Mac from a phone, run the way this Mac's own screens run it (27 Oct, Decker
 * D3). A phone's packet context is neither the Mac's own context nor a credential-resolved core call, and it carries no
 * profile scope, so Switch account and usage readings from the phone were refused ("a current credential-resolved core
 * call", "The native session launcher is unavailable") before anything was read. At Full control (the person's own
 * device) the request runs under the owner's local context, as a chat started on the Mac does; below Full it is refused
 * in plain words and no owner authority is handed to it.
 */
public enum BackendRemoteOwnerScope {
    public typealias Owner = @Sendable () throws -> NativeRPCContext
    public static let switchNeedsFull = "Switching a session’s login needs Full control. Change this phone’s access on the Mac."
    public static let usageNeedsFull = "Reading a session’s usage needs Full control. Change this phone’s access on the Mac."

    /// The owner-only browser checks a phone at Full control passes, as this Mac's own window does (27 Oct walk, h):
    /// opening a window (and reading the worker profiles that choose its profile). Navigating and closing already run
    /// on the device's own window grant. Never a file, a scraping run or a worker change.
    public static let browserWindowChecks: Set<String> = ["browser:create", "browser.workers"]
    public static func opensBrowserWindows(level: BackendINT2PhoneAccessLevel?, kind: BackendRemoteDeviceKind, drivesWindows: Bool,
                                           operation: String, file: URL?) -> Bool {
        level == .full && kind == .mine && drivesWindows && file == nil && browserWindowChecks.contains(operation)
    }

    /// Full control: the level the host issued, or (a Mac without levels) the person's own device.
    public static func permits(_ context: BackendRemoteHostContext) -> Bool { BackendPhoneChats.fullControl(context) }

    /// The operation under the owner's context (and its profile scope), or under `fallback` when no owner is supplied.
    public static func run<T: Sendable>(_ owner: Owner?, fallback: NativeRPCContext,
                                        _ operation: @Sendable (NativeRPCContext) async throws -> T) async throws -> T {
        guard let owner else { return try await operation(fallback) }
        let local = try owner()
        #if TD_HOST_ACCOUNT_BRIDGE
        return try await BackendHOSTProfileScope.withContext(local) { try await operation(local) }
        #else
        return try await operation(local)
        #endif
    }
}
