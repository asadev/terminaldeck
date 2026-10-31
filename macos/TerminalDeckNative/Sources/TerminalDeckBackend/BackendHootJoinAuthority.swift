import Foundation
import TerminalDeckNativeCore

/// Request 8: the concrete Hoot sender authority. Only the in-process native
/// app constructs `.nativeApp` contexts (the HTTP bridge gives pages `.page`
/// and paired devices `.pairedDevice`). The main window is the composition
/// root's app owner; the island and the pointer catcher each get a random
/// per-launch owner ID that only their own panel bindings hold. Any other
/// caller, any other owner ID and any caller-supplied argument is unrelated.
public final class BackendHootJoinSourceAuthority: BackendHootRegistrationAuthority, @unchecked Sendable {
    public let islandOwnerID: String
    public let catcherOwnerID: String
    private let window: @Sendable (NativeRPCContext) throws -> Void
    private let lock = NSLock()
    private var revoked = false

    /// `window` is the app's actual live-window check, normally
    /// `BackendCompositionAuthority.requireLocalUI` (or the root's static
    /// `BackendCompositionRoot.requireLocalUI` before that authority exists).
    public init(window: @escaping @Sendable (NativeRPCContext) throws -> Void = BackendCompositionRoot.requireLocalUI) {
        let launch = UUID().uuidString.lowercased()
        islandOwnerID = "native-app:hoot-island:" + launch
        catcherOwnerID = "native-app:hoot-catcher:" + launch
        self.window = window
    }

    public func source(_ context: NativeRPCContext) throws -> BackendHootRegistrationSource {
        guard context.caller == .nativeApp, !lock.withLock({ revoked }) else { return .unrelated }
        switch context.ownerID {
        case islandOwnerID: return .island
        case catcherOwnerID: return .catcher
        case BackendCompositionRoot.appOwnerID:
            // A closed or revoked window is not a window sender.
            do { try window(context); return .window } catch { return .unrelated }
        default: return .unrelated
        }
    }

    /// The contexts the island's SwiftUI shape and the catcher panel pass to
    /// `NativeChannelRegistry.invoke/send`. Hand each only to its own binding.
    public func islandContext() -> NativeRPCContext { .init(caller: .nativeApp, ownerID: islandOwnerID) }
    public func catcherContext() -> NativeRPCContext { .init(caller: .nativeApp, ownerID: catcherOwnerID) }

    /// Graph shutdown: after this no island/catcher/window message is Hoot's.
    public func revoke() { lock.withLock { revoked = true } }
}
