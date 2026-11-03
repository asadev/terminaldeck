import Foundation
import TerminalDeckNativeCore

/// Optional TAG settings. Missing fields retain the pre-TAG behavior.
public enum BackendTAGAgentProfile {
    /// Asad, 11 Oct: "there should not be any limit in the app". There is no cap on how many agents a person has;
    /// this is only how many agents ONE save-many request may name (a request size, like a page of results).
    public static let maximumPerCall = 50
    /// Task launches are Claude Code's; its modes come from the one list (AGSCapabilities).
    public static var permissionModes: [String] { AGSCapabilities.permissionModes(provider: "claude") }

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
        let projectID = try text("projectId", label: "The project", maximum: 128)
        if let id = projectID.string, !PROJProjects.isValidID(id) { throw NativeRPCError.invalidArguments("Choose a valid project id, or Independent.") }
        if !input["projectIdInferred"].isNullish, input["projectIdInferred"].bool == nil { throw NativeRPCError.invalidArguments("The inferred project marker has to be on or off.") }
        if !input["keepAliveUntilClose"].isNullish && input["keepAliveUntilClose"].bool == nil { throw NativeRPCError.invalidArguments("Keep open until closed has to be on or off.") }
        let reviewer = try text("reviewerAgent", label: "The reviewer agent", maximum: 40)
        if let id = reviewer.string, id.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) == nil { throw NativeRPCError.invalidArguments("The reviewer has to be a task agent id.") }
        let source = try text("sourceFile", label: "The source file", maximum: 4_000)
        let directory = try text("sourceDirectory", label: "The source folder", maximum: 4_000)
        for path in [source.string, directory.string].compactMap({ $0 }) where !path.hasPrefix("/") { throw NativeRPCError.invalidArguments("The imported source has to be a full path.") }
        let inferredProject = projectID.isNullish || input["projectIdInferred"].bool == true
        let resolvedProject = PROJProjects.resolve(projectID: inferredProject ? nil : projectID.string,
            folder: directory.string ?? source.string ?? project.string)
        // AGT: the agent's picture and who it reports to. Optional; old profiles load unchanged.
        let icon = try text("icon", label: "The icon", maximum: 80)
        if let problem = AGTIcon.problem(icon.string) { throw NativeRPCError.invalidArguments(problem) }
        let reportsTo = try text("reportsTo", label: "Reports to", maximum: 40)
        if let boss = reportsTo.string, boss != AGTDirectory.hootID, boss.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) == nil {
            throw NativeRPCError.invalidArguments("Reports to has to be a task agent id, @hoot, or empty for independent.")
        }
        // Deck Memory: the role (seat) the agent was hired into. Memory belongs to the seat.
        let seat = try text("seat", label: "The role", maximum: 64)
        if let problem = AGTSeats.roleProblem(seat.string) { throw NativeRPCError.invalidArguments(problem) }
        let status = try text("syncStatus", label: "The sync status", maximum: 20)
        if let status = status.string, !["synced", "error", "missing"].contains(status) { throw NativeRPCError.invalidArguments("The sync status has to be synced, error or missing.") }
        if !input["syncedAt"].isNullish && (input["syncedAt"].number.map { !$0.isFinite || $0 < 0 } ?? true) { throw NativeRPCError.invalidArguments("The sync time has to be a time.") }
        var result: [(String, NativeRPCValue)] = [("claudeAgent", claude), ("allowedTools", allowed), ("permissionMode", permission),
                ("projectId", .string(resolvedProject)),
                ("projectIdInferred", .bool(inferredProject && resolvedProject == PROJProjects.independentID)),
                ("keepAliveUntilClose", .bool(input["keepAliveUntilClose"].bool == true)),
                ("defaultProject", project.string.map { .string(URL(fileURLWithPath: $0).standardizedFileURL.path) } ?? .null),
                ("reviewerAgent", reviewer), ("sourceFile", source), ("sourceDirectory", directory),
                ("syncStatus", status), ("syncedAt", input["syncedAt"].number.map(NativeRPCValue.number) ?? .null),
                ("syncError", try text("syncError", label: "The sync error", maximum: 2_000)),
                ("creatorKeyId", try text("creatorKeyId", label: "The profile creator", maximum: 128)),
                ("keyInitializedFields", input["keyInitializedFields"].elements.map(NativeRPCValue.array) ?? .array([]))]
        // Stored only when set, so rows written before AGT keep their exact shape.
        if !icon.isNullish { result.append(("icon", icon)) }
        if !reportsTo.isNullish { result.append(("reportsTo", reportsTo)) }
        if !seat.isNullish { result.append(("seat", seat)) }
        if input.has("toolUseRestrictions") { result.append(("toolUseRestrictions", input["toolUseRestrictions"])) }
        return result
    }
}
