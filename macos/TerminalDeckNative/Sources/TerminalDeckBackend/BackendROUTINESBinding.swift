import Foundation
import TerminalDeckNativeCore

public extension BackendRoutinesRoutine {
    /// One canonical header store; these are read aliases, not another agent store.
    var agentID: String? { BackendROUTINESBinding.agentID(unknown: unknown) }
    var routinesAgentID: String { agentID ?? "" }
}

/// Matches BackendTaskConfiguration.clean's canonical profile-ID grammar and
/// 40-character ceiling. The Claude subagent name is a different field/type.
public enum BackendROUTINESBinding {
    public static func isValidAgentID(_ id: String) -> Bool {
        id == "@hoot" || id.utf16.count <= 40 && id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
    }
    /// Missing is legacy Hoot. Explicit malformed/repeated headers are unknown,
    /// never authority to guess from a folder or a profile's display name.
    public static func agentID(unknown: [String: [String]]) -> String? {
        guard let values = unknown["agent-id"] else { return "@hoot" }
        guard values.count == 1, let id = values.first, isValidAgentID(id) else { return nil }
        return id
    }
    public static func unknownWire(_ routine: BackendRoutinesRoutine) -> NativeRPCValue {
        .object(routine.orderedUnknownKeys.map { key in .init(key, .array((routine.unknown[key] ?? []).map(NativeRPCValue.string))) })
    }
    /// IPC update's minimal carry seam. Omitted unknown metadata and project
    /// provenance remain byte-semantically unchanged before parser validation.
    /// An explicit agentId replaces only the agent-id header.
    public static func carrying(existing: BackendRoutinesRoutine, draft: NativeRPCValue) -> NativeRPCValue {
        var result = draft
        if draft["unknown"] == .missing { result = result.setting("unknown", unknownWire(existing)) }
        if draft["agentId"] == .missing, draft["unknown"] != .missing, existing.unknown["agent-id"] != nil {
            result = result.setting("agentId", existing.agentID.map(NativeRPCValue.string) ?? .null)
        }
        if draft["projectId"] == .missing {
            result = result.setting("projectId", .string(existing.projectID))
            if draft["projectIdInferred"] == .missing { result = result.setting("projectIdInferred", .bool(existing.projectIdInferred)) }
        }
        return result
    }
}
