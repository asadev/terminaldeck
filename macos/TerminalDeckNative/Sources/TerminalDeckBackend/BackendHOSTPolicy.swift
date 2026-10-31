import Foundation

/// This is intentionally not an enable flag. The integration must establish
/// every resource lifetime before keeping a live AI process across app exit.
public struct BackendHOSTReadiness: Equatable, Sendable {
    public var accountLeases = false
    public var hookEndpoint = false
    public var mcpGrantsAndFiles = false
    public var pendingSwitches = false
    public var taskAndReceiverClaims = false
    public init() {}
    public var safeToDetach: Bool { accountLeases && hookEndpoint && mcpGrantsAndFiles && pendingSwitches && taskAndReceiverClaims }
}

public enum BackendHOSTPolicy {
    public enum Exit: Equatable, Sendable { case detach, stop, stayResident }
    public static func exit(keep: Bool, installingUpdate: Bool, hostConnected: Bool, resources: BackendHOSTReadiness) -> Exit {
        if !keep && !installingUpdate { return .stop }
        return hostConnected && resources.safeToDetach ? .detach : .stayResident
    }
    public static let fallbackMessage = "Sessions won't survive updates right now."
    public static let retryTitle = "Try Again"
    public static func deferredUpdateMessage(version: String) -> String {
        "Sessions are still running with host \(version). The session host will update after they finish."
    }
    /// Reattach first, then restore only unclaimed saved tabs. A folder alone
    /// is never proof: multiple legitimate tabs may share it.
    public static func claimed(savedID: String?, tabKey: String?, provider: String, conversation: String?,
                               attached: [BackendSessionMeta]) -> Bool {
        attached.contains { session in
            if let savedID, savedID == session.id { return true }
            if let tabKey, !tabKey.isEmpty, tabKey == session.tabKey { return true }
            return session.exitCode == nil && session.provider == provider && conversation != nil && conversation == session.agentSessionId
        }
    }
}
