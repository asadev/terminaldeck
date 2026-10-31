import Foundation
import TerminalDeckNativeCore

/// Snake-case UI/MCP fields adapt to the original TAG/AGS values. This helper
/// validates a proposal; the canonical writer owns consent and publication.
public enum BackendAGOPTProfileFieldAdapter {
    public struct Proposal: Sendable {
        public let profile: NativeRPCValue
        public let settings: AGSAgentSettings
        public let field: String
        public let privateField: Bool
    }
    public static func proposal(profile: NativeRPCValue, settings: AGSAgentSettings, field: String, value: NativeRPCValue) throws -> Proposal {
        guard BackendAGOPTProfileFields.names.contains(field) else { throw NativeRPCError.invalidArguments("Choose an existing settings field.") }
        if field == "tool_use_restrictions", !value.isNullish { _ = try ToolUseRestrictions(value) }
        var tag = profile, raw = try BackendAGSCodec.value(settings)
        let privateField = ["hooks", "environment_variables"].contains(field)
        if let declared = BackendAGOPTProfileFields.profile[field] {
            let property = field == "extra_task_instructions" && profile["sourceFile"].string != nil ? "instructions" : declared
            let next: NativeRPCValue
            if field == "project", value.isNullish { next = .string(PROJProjects.independentID) } else { next = value }
            tag = tag.setting(property, next)
            if field == "project" { tag = tag.setting("projectIdInferred", .bool(false)) }
            let mirrors = ["coding_ai": "provider", "model": "model", "effort": "effort", "before_it_changes_files": "permissionMode", "tools_it_must_not_use": "deniedTools", "working_folder": "workingFolder", "keep_open_until_close": "keepOpen"]
            if let property = mirrors[field] { raw = raw.setting(property, value) }
        } else if let property = BackendAGOPTProfileFields.privateSettings[field] { raw = raw.setting(property, value) }
        else if let property = BackendAGOPTProfileFields.efficiency[field] {
            if field == "stop_when_done" {
                guard let stop = value.bool else { throw NativeRPCError.invalidArguments("Stop when done is on or off.") }
                // The agent window's switch writes exactly the same (AGSStopWhenDone).
                var stopping = settings
                AGSStopWhenDone.apply(stop, to: &stopping)
                raw = try BackendAGSCodec.value(stopping)
                let keep = AGSStopWhenDone.keepAlive(stop)
                tag = tag.setting("keepAliveUntilClose", .bool(keep.untilClose)).setting("keepAliveMinutes", .number(Double(keep.minutes)))
            } else {
                let controls = raw["efficiency"].isNullish ? NativeRPCValue.object([]) : raw["efficiency"]
                raw = raw.setting("efficiency", controls.setting(property, value))
            }
        }
        let proposed = try BackendAGSCodec.decode(AGSAgentSettings.self, raw)
        try BackendAGSValidation.check(proposed)
        // Unknown fields are not silently discarded by an older Core model.
        if let property = BackendAGOPTProfileFields.efficiency[field], field != "stop_when_done" {
            let encoded = try BackendAGSCodec.value(proposed)
            guard encoded["efficiency"][property] == value || encoded["efficiency"][property].isNullish && value.isNullish else {
                throw NativeRPCError(code: "unavailable", message: "This settings field has not joined the canonical agent model yet.")
            }
        }
        let merged = tag.setting("provider", .string(proposed.provider))
            .setting("model", proposed.model.map(NativeRPCValue.string) ?? .null)
            .setting("effort", proposed.effort.map(NativeRPCValue.string) ?? .null)
            .setting("permissionMode", proposed.permissionMode.map(NativeRPCValue.string) ?? .null)
            .setting("blockedTools", .array(proposed.deniedTools.map(NativeRPCValue.string)))
            .setting("defaultProject", proposed.workingFolder.map(NativeRPCValue.string) ?? .null)
            .setting("keepAliveUntilClose", .bool(proposed.keepOpen))
        var clean = try BackendTaskConfiguration.cleanAgent(merged, others: [])
        clean = clean.setting("status", profile["status"]).setting("statusAt", profile["statusAt"])
        let checkedProperty = field == "extra_task_instructions" && profile["sourceFile"].string != nil ? "instructions" : BackendAGOPTProfileFields.profile[field]
        if let property = checkedProperty, clean[property] != tag[property] {
            throw NativeRPCError(code: "unavailable", message: "This settings field has not joined the canonical profile model yet.")
        }
        try BackendTaskConfiguration.checkSupported(clean)
        return Proposal(profile: clean, settings: proposed, field: field, privateField: privateField)
    }
    public static func values(profile: NativeRPCValue, settings: AGSAgentSettings) throws -> NativeRPCValue {
        let raw = try BackendAGSCodec.value(settings)
        var fields: [NativeRPCValue.Field] = []
        for (name, property) in BackendAGOPTProfileFields.profile {
            fields.append(.init(name, name == "extra_task_instructions" && profile["sourceFile"].string != nil && profile[property].isNullish ? profile["instructions"] : profile[property]))
        }
        for (name, property) in BackendAGOPTProfileFields.privateSettings { fields.append(.init(name, raw[property])) }
        for (name, property) in BackendAGOPTProfileFields.efficiency {
            if name == "stop_when_done" { fields.append(.init(name, .bool(AGSStopWhenDone.isOn(keepAliveUntilClose: profile["keepAliveUntilClose"].bool == true, keepAliveMinutes: profile["keepAliveMinutes"].number ?? Double(TasksLimits.defaultKeepAliveMinutes))))) }
            else { fields.append(.init(name, raw["efficiency"][property])) }
        }
        return .object(fields.sorted { $0.key < $1.key })
    }
}
