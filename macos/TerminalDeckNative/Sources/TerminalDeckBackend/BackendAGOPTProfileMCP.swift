import Foundation
import TerminalDeckNativeCore

/// The existing agents.profile identity delegates its v2 read to this service.
/// This area adds only field adapters and actions; it never owns another profile.
public enum BackendAGOPTProfileMCP {
    public static let toolIDs = ["agents.settings_get", "agents.settings_set", "agents.profile_action", "agents.instructions_get", "agents.instructions_set", "agents.budget_get", "agents.budget_set"]
    public static func definitions(service: BackendAGOPTProfileService) throws -> [BackendDeckToolsDefinition] {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let bool = NativeRPCValue.object([.init("type", .string("boolean"))])
        let fields = string.setting("enum", .array(BackendAGOPTProfileFields.names.sorted().map(NativeRPCValue.string)))
        let descriptions = [
            "Read this agent's existing profile settings and resolved controls. No private hooks or environment values are returned through MCP.",
            "Set one named agent setting. Uses the existing profile/AGS save and exact owner approval; key narrowing keeps its existing bounds. Changes apply at the next task start or reply.",
            "Wake, pause, resume, duplicate, forget reused sessions, stop all work or archive one agent. Changes run at once when the calling AI's permission mode allows them; each is logged. assign_task only opens the assignee's task sheet; it never creates or starts work.",
            "Read the agent's exact authorized Markdown file and its revision. Imported source and managed extra instructions stay distinct; missing files are explicit.",
            "Save the agent's Markdown file. Runs at once when the calling AI's permission mode allows it; the action is logged. Supply its hash from instructions_get; keep_mine reviews the current conflicting file before replacing it. No arbitrary path is accepted.",
            "Read this month's observed budget data. Dollars require confirmed API billing and attributed provider-reported cost; plan accounts use tokens and unknown figures remain missing.",
            "Change one existing monthly/per-task budget field. Runs at once when the calling AI's permission mode allows it; the action is logged. No account probing, billing activation or fabricated spend."
        ]
        return try toolIDs.enumerated().map { index, id in
            let read = [0, 3, 5].contains(index)
            var properties: [(String, NativeRPCValue)] = [("id", string)], required = ["id"]
            switch index {
            case 1, 6: properties += [("field", fields), ("value", .object([]))]; required += ["field", "value"]
            case 2: properties += [("action", string), ("target", string)]; required += ["action"]
            case 4: properties += [("text", string), ("hash", string), ("keep_mine", bool)]; required += ["text", "hash"]
            default: break
            }
            let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })), .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
            // Every tool that changes an agent is listed at its true tier (.alter): a read-tier listing
            // let Hoot in Ask first change settings, permission mode or budget without asking (#532).
            // The core door enters .alter once; the field domain's exact widening card still follows.
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: descriptions[index], inputSchema: schema, tier: read ? .read : .alter)
            return BackendDeckToolsDefinition(spec: spec, title: id.replacingOccurrences(of: ".", with: " "), index: descriptions[index]) { context, args in
                await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(spec.tier), !context.cancellation.isCancelled else { throw NativeRPCError(code: "not-granted", message: "This caller cannot use that agent operation.") }
                    let id = try args["id"].requireString("agent id", nonempty: true), call = BackendAGOPTProfileCall.tool(context)
                    let value: NativeRPCValue
                    switch index {
                    case 0: value = try await service.settings(id, call: call)
                    case 1: value = try await service.setSetting(id, field: args["field"].requireString("setting field", nonempty: true), value: args["value"], call: call)
                    case 2: value = try await service.action(id, action: args["action"].requireString("agent action", nonempty: true), target: args["target"].string, call: call)
                    case 3: value = try await service.instructions(id, call: call)
                    case 4: value = try await service.saveInstructions(id, text: args["text"].requireString("instructions"), hash: args["hash"].requireString("file revision", nonempty: true), keepMine: args["keep_mine"].bool == true, call: call)
                    case 5: value = try await service.budget(id, call: call)
                    default: value = try await service.setBudget(id, field: args["field"].requireString("budget field", nonempty: true), value: args["value"], call: call)
                    }
                    return .value(value)
                }
            }
        }
    }
    public static func safeArguments(_ args: NativeRPCValue) -> NativeRPCValue {
        if ["environment_variables", "hooks"].contains(args["field"].string ?? "") { return args.setting("value", .string("[private setting]")) }
        return args
    }
}
