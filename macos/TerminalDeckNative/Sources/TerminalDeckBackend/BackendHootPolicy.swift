import Foundation
import TerminalDeckNativeCore

/// What Hoot itself may do through this app's tools. Asad, 12 Oct: "What Hoot can do things should not be here
/// completely". Hoot can always run sessions, hand problems to the right agent, use simulators and phones, and open
/// any folder; the four switches of Settings → Hoot ("What Hoot may do") are gone. What stays is the designed
/// refusal: Hoot never changes its own settings (only the person does). Rate guards and the while-driving refusals
/// live with their own tools and are not decided here.
public struct HootPolicySnapshot: Sendable, Equatable {
    /// How a problem handed to Hoot (from the browser, a simulator, a note) is routed: "ask" puts a routing card in the
    /// chat for the person to send or retarget (the behaviour every install had by default); "notify" sends after the
    /// Undo window. Fixed by the app: no setting chooses it any more, and "never" no longer exists.
    public var routingMode = "ask"
    public init(routingMode: String = "ask") { self.routingMode = routingMode == "notify" ? "notify" : "ask" }

    /// Hoot may read its own settings, never change them: only the person widens a switch.
    public static let ownSettingsReads: Set<String> = ["hoot.routines.settings_get", "hoot.routines.memory_list", "hoot.routines.actions_list"]

    /// The one decision for a tool Hoot is about to call. Throws the plain reason only for Hoot's own settings.
    public func check(tool: String, arguments: NativeRPCValue) throws {
        if tool.hasPrefix("hoot.routines."), !Self.ownSettingsReads.contains(tool) {
            throw NativeRPCError(code: "hoot-policy", message: "Hoot cannot change its own settings. Only you can, in Settings → Hoot.")
        }
    }
}

/// The one owner of Hoot's tool-call fence (its MCP grant calls `check`), and the clean-up of the retired switches.
public actor BackendHootPolicy {
    /// The settings the four retired switches were saved under. Removed once from the settings file at start.
    public static let retiredKeys = ["hoot.policy.runSessions", "hoot.policy.routingMode", "hoot.policy.useDevices", "hoot.policy.folders"]
    private let settings: BackendAppSettingsStore
    private var cleaned = false
    public init(settings: BackendAppSettingsStore) { self.settings = settings }

    /// Fixed: nothing the person saved earlier narrows Hoot any more.
    public func snapshot() async -> HootPolicySnapshot {
        await removeRetiredSettings()
        return HootPolicySnapshot()
    }
    /// Takes the four retired switches out of the settings file (an older install may hold them). Safe to call any
    /// number of times; a file without them is left exactly as it is.
    public func removeRetiredSettings() async {
        guard !cleaned else { return }
        cleaned = true
        var present: [NativeRPCValue.Field] = []
        for key in Self.retiredKeys {
            if !(await settings.value(key)).isNullish { present.append(.init(key, .null)) }
        }
        guard !present.isEmpty else { return }
        _ = try? await settings.patch(.object(present))
    }
    /// Enforcement for Hoot's own tool calls: only its own settings are refused.
    public func check(tool: String, arguments: NativeRPCValue) async throws {
        try await snapshot().check(tool: tool, arguments: arguments)
    }
}
