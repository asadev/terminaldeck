import Foundation
import TerminalDeckNativeCore

/// Optional TAG settings. Missing fields retain the pre-TAG behavior.
public enum BackendTAGAgentProfile {
    public static let maximumAgents = 50
    public static let permissionModes = ["default", "acceptEdits", "plan", "bypassPermissions"]

    static func fields(_ input: NativeRPCValue, provider: String?) throws -> [(String, NativeRPCValue)] {
        func text(_ key: String, label: String, maximum: Int) throws -> NativeRPCValue {
            let value = input[key]
            if value.isNullish { return .null }
            guard let raw = value.string else { throw NativeRPCError.invalidArguments("\(label) has to be text.") }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .null }
            guard trimmed.utf16.count <= maximum, !trimmed.contains("\0") else { throw NativeRPCError.invalidArguments("\(label) is too long or contains an invalid character.") }
            return .string(trimmed)
        }
        let claude = try text("claudeAgent", label: "The Claude Code agent", maximum: 80)
        if let name = claude.string, name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("The Claude Code agent name can only use letters, digits, dashes and underscores.")
        }
        var allowed: NativeRPCValue = .null
        if !input["allowedTools"].isNullish {
            guard let list = input["allowedTools"].elements, list.count <= 200 else { throw NativeRPCError.invalidArguments("Allowed tools has to be a list of at most 200 tool names.") }
            var names: [String] = []
            for item in list {
                guard let raw = item.string else { throw NativeRPCError.invalidArguments("Each allowed tool has to be a tool name.") }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if SourceNamespace.agentSettingsEnabled {
                    try BackendAGSValidation.check(AGSAgentSettings(provider: provider ?? "claude", allowedTools: [name]))
                } else if !BackendSharedAgentTools.isToolName(name) {
                    throw NativeRPCError.invalidArguments("\(name) is not a tool name that can be allowed.")
                }
                if !names.contains(name) { names.append(name) }
            }
            allowed = .array(names.map(NativeRPCValue.string))
        }
        let permission = try text("permissionMode", label: "Permission mode", maximum: 40)
        if let mode = permission.string {
            if SourceNamespace.agentSettingsEnabled {
                if !AGSCapabilities.permissionModes(provider: provider ?? "claude").contains(mode) { throw NativeRPCError.invalidArguments("Choose a permission mode supported by the selected coding agent.") }
            } else if !permissionModes.contains(mode) {
                throw NativeRPCError.invalidArguments("Choose a permission mode from the list.")
            }
        }
        if !claude.isNullish {
            guard provider == "claude" else { throw NativeRPCError.invalidArguments("Choose Claude Code to set its named agent definition.") }
        }
        if !allowed.isNullish || !permission.isNullish {
            if SourceNamespace.agentSettingsEnabled {
                guard AGSCapabilities.providers.contains(provider ?? "claude") else { throw NativeRPCError.invalidArguments("Choose a supported coding agent for tool or permission settings.") }
            } else {
                guard provider == nil || provider == "claude" else {
                    throw NativeRPCError.invalidArguments("Claude Code agent, allowed tools and permission mode need Claude Code. Clear them, or choose Claude Code.")
                }
            }
        }
        let project = try text("defaultProject", label: "The default project folder", maximum: 4_000)
        if let path = project.string, !path.hasPrefix("/") { throw NativeRPCError.invalidArguments("The default project folder is not a full folder path.") }
        if !input["keepAliveUntilClose"].isNullish && input["keepAliveUntilClose"].bool == nil { throw NativeRPCError.invalidArguments("Keep open until closed has to be on or off.") }
        let reviewer = try text("reviewerAgent", label: "The reviewer agent", maximum: 40)
        if let id = reviewer.string, id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) == nil { throw NativeRPCError.invalidArguments("The reviewer has to be a task agent id.") }
        let source = try text("sourceFile", label: "The source file", maximum: 4_000)
        let directory = try text("sourceDirectory", label: "The source folder", maximum: 4_000)
        for path in [source.string, directory.string].compactMap({ $0 }) where !path.hasPrefix("/") { throw NativeRPCError.invalidArguments("The imported source has to be a full path.") }
        let status = try text("syncStatus", label: "The sync status", maximum: 20)
        if let status = status.string, !["synced", "error", "missing"].contains(status) { throw NativeRPCError.invalidArguments("The sync status has to be synced, error or missing.") }
        if !input["syncedAt"].isNullish && (input["syncedAt"].number.map { !$0.isFinite || $0 < 0 } ?? true) { throw NativeRPCError.invalidArguments("The sync time has to be a time.") }
        return [("claudeAgent", claude), ("allowedTools", allowed), ("permissionMode", permission),
                ("keepAliveUntilClose", .bool(input["keepAliveUntilClose"].bool == true)),
                ("defaultProject", project.string.map { .string(URL(fileURLWithPath: $0).standardizedFileURL.path) } ?? .null),
                ("reviewerAgent", reviewer), ("sourceFile", source), ("sourceDirectory", directory),
                ("syncStatus", status), ("syncedAt", input["syncedAt"].number.map(NativeRPCValue.number) ?? .null),
                ("syncError", try text("syncError", label: "The sync error", maximum: 2_000))]
    }
}
