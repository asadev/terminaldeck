import Foundation

/// What is known now, rather than a guess based on a disconnected relay.
public enum MacReach {
    public enum State: String, Sendable, CaseIterable {
        case desktop, locked, signingIn = "signing-in", diskUnlock = "disk-unlock", asleep, unreachable, setup
        public var words: String {
            switch self {
            case .desktop: "Your Mac is ready."
            case .locked: "Your Mac is locked. Type your Mac password to unlock it."
            case .signingIn: "Sign in to your Mac. Choose your account, then type its password."
            case .diskUnlock: "Your Mac restarted and is waiting for its disk password at the Mac."
            case .asleep: "Your Mac's screen is asleep — waking it…"
            case .unreachable: "Mac is asleep or unreachable. Check its power and internet connection."
            case .setup: "Set up access after a restart on your Mac: Devices → Device access → General."
            }
        }
    }
    public enum Registration: String, Sendable { case notRegistered, needsApproval, enabled, notBundled, unknown }
    /// Saved only by the signed app in the approved helper's private configuration, after reading General's setting.
    public static func bootKeepsAwake(_ configuration: NativeRPCValue) -> Bool {
        configuration["systemKeepAwake"].bool == true
    }
    public static let diskDetail = "Apple silicon with macOS 26 or later can unlock FileVault over SSH after a restart if Remote Login was already on and the Mac has a network connection. This needs a direct address reachable from your phone, usually on the same Wi-Fi. Our relay cannot run before the disk is unlocked."
    public static let daemonLabel = "dev.terminaldeck.app.mac-reach"
    public static let agentLabel = "dev.terminaldeck.app.mac-reach-screen"
    public static let daemonPlist = daemonLabel + ".plist"
    public static let agentPlist = agentLabel + ".plist"
    public static let daemonArgument = "--mac-reach-daemon"
    public static let agentArgument = "--mac-reach-agent"

    public static func state(reachable: Bool, diskUnlockConfirmed: Bool = false, loginDone: Bool = true,
                             locked: Bool = false, displayAsleep: Bool = false) -> State {
        if diskUnlockConfirmed { return .diskUnlock }
        guard reachable else { return .unreachable }
        if !loginDone { return .signingIn }
        if locked { return .locked }
        return displayAsleep ? .asleep : .desktop
    }
    public static func mayControl(kind: String, access: String?, approved: Bool) -> Bool {
        approved && kind == "mine" && (access == nil || access == "full")
    }
    /// The boot helper has no sessions, files, pairing, shell, account or general MCP door.
    public static let bootMessages: Set<String> = ["hello", "ping", "list", "link.peer", "link.moved", "sims.list", "sims.watch",
        "sims.unwatch", "sims.ack", "sims.key", "sims.input", "sims.unlock"]
}

extension MacReach {
    public static let agentSessionTypes = ["Aqua", "LoginWindow"]
    public enum SetupFailure: Error, Equatable { case releaseRequired, helperMissing }
    /// Kept separate from ServiceManagement so tests can exercise every registration state without registering a job.
    @MainActor public static func enableHelper(isRelease: Bool, status: () -> Registration, register: () throws -> Void) throws -> Registration {
        guard isRelease else { throw SetupFailure.releaseRequired }
        let before = status()
        if before == .enabled || before == .needsApproval { return before }
        guard before != .notBundled else { throw SetupFailure.helperMissing }
        try register()
        return status()
    }
}
