import Foundation
import TerminalDeckNativeCore

/// The feature door cannot be used as an arbitrary app-server/config proxy.
public enum BackendChatProviderFeaturePolicy {
    public static let operations = BackendChatProviderControls.operations + BackendChatProviderTerminals.operations + ["capabilities", "mcp/status", "mcp/details", "mcp/auth", "mcp/reconnect", "policy/read", "policy/change", "children/list", "children/read", "children/resume",
        "catalogue/list", "catalogue/read", "skills/list", "instructions/read",
        "voice/events",
        "review/start", "side/open", "side/send", "side/read", "side/close"
    ] + sessionFeatureOperations
    /// F29, F35, F38, F57: file checkpoints, background tasks, fork and location. Older helpers lack them.
    public static let sessionFeatureOperations = BackendChatFileCheckpoints.operations + BackendChatBackground.operations + BackendChatFork.operations
    public static func changes(_ operation: String) -> Bool {
        !["terminals/capabilities", "terminals/list", "terminals/read", "capabilities", "mcp/status", "mcp/details", "policy/read", "children/list", "children/read", "catalogue/list", "catalogue/read", "skills/list", "instructions/read", "connections/plugins", "connections/installedPlugins", "connections/apps", "connections/installedApps", "connections/plugin", "connections/app",
          "goals/read", "voice/capabilities", "voice/voices", "voice/events", "side/read",
          "checkpoints/list", "checkpoints/preview", "background/list", "background/output", "location/read"].contains(operation)
    }
    public static func validate(_ operation: String, arguments: NativeRPCValue) throws {
        guard operations.contains(operation), arguments.fields != nil, try arguments.encodedJSON().count <= 1_048_576 else {
            throw NativeRPCError.invalidArguments("Choose a supported provider feature with bounded arguments.")
        }
        for key in ["cursor", "limit"] where arguments[key].number != nil {
            guard let number = arguments[key].number, number.isFinite, number.rounded() == number, number >= 0, number <= Double(Int.max / 2) else {
                throw NativeRPCError.invalidArguments("Invalid page boundary.")
            }
        }
    }
    public static func authorize(_ operation: String, caller: BackendDeckCoreSecurityCaller.Kind) throws {
        // A file restore rewrites the person's files and a fork creates provider state; both belong to the Mac owner.
        let accountChange = operation == "policy/change" || operation == "mcp/auth" || (operation.hasPrefix("connections/") && changes(operation))
            || operation == "checkpoints/restore" || operation == "fork/create"
        guard !accountChange || caller == .local else {
            throw NativeRPCError(code: "not-granted", message: "Provider account connections, installation and authentication belong to the Mac owner; this session's grant does not widen the whole account.")
        }
    }
}
