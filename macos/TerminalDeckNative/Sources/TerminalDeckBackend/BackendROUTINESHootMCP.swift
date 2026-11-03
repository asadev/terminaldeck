import Foundation
import TerminalDeckNativeCore

/// Additive aliases over the SAME runtime, policy and memory owners.
public enum BackendROUTINESHootMCP {
    public static func definitions(service: BackendROUTINESHootSettings, access: BackendDeckToolsAppAccess,
        visible: @escaping @Sendable (BackendMCPCallContext) async throws -> Void,
        isHootSession: @escaping @Sendable (String) async -> Bool) throws -> [BackendDeckToolsDefinition] {
        let empty = #"{"type":"object","properties":{},"additionalProperties":false}"#
        let entries: [(String, String, BackendMCPTier, String)] = [
            ("settings_get", "read", .read, empty),
            ("settings_set", "set", .alter, #"{"type":"object","properties":{"field":{"type":"string","enum":["permissionMode","provider","profileId","model","effort","contextWindow"]},"value":{}},"required":["field","value"],"additionalProperties":false}"#),
            ("start", "start", .act, empty), ("stop", "stop", .alter, empty), ("restart", "restart", .alter, empty),
            ("memory_list", "memory-list", .read, empty),
            ("memory_delete", "memory-delete", .alter, #"{"type":"object","properties":{"name":{"type":"string","maxLength":255}},"required":["name"],"additionalProperties":false}"#),
            ("actions_list", "actions", .read, empty), ("folder_show", "reveal", .act, empty),
            ("reset", "reset", .alter, #"{"type":"object","properties":{"confirm":{"type":"string","enum":["Reset Hoot"]}},"required":["confirm"],"additionalProperties":false}"#)
        ]
        return try entries.map { name, operation, tier, schema in
            let id = "hoot.routines." + name
            let wire = "hoot_" + name
            let title: String
            switch operation {
            case "read": title = "Read Hoot settings and supported abilities"
            case "set": title = "Change Hoot settings"
            case "memory-list": title = "Read what Hoot remembers"
            case "memory-delete": title = "Delete a Hoot note"
            case "actions": title = "Read Hoot's action log"
            case "reveal": title = "Show Hoot's folder in Finder"
            case "reset": title = "Stop Hoot and clear its chat and notes; keep routines and settings"
            default: title = operation.capitalized + " Hoot"
            }
            let spec = try BackendMCPTool(id: id, wireName: wire, description: title,
                inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: title, index: title) { context, arguments in
                guard context.allowedTools.contains(id) || context.allowedTools.contains(wire), context.allowedTiers.contains(tier) else {
                    throw NativeRPCError(code: "access-denied", message: "This caller cannot use this Hoot tool.")
                }
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                try await visible(context)
                let caller = try await access.caller(context)
                let changes = tier != .read
                if changes, let session = caller.sessionID, await isHootSession(session) {
                    throw NativeRPCError(code: "access-denied", message: "Hoot cannot change its own settings or memory through its own tools.")
                }
                if operation == "set" {
                    let field = try arguments["field"].requireString("field")
                    // Bypass is the owner's own choice in Hoot's settings; no AI app or key may set or widen to it.
                    if field == "permissionMode", let mode = arguments["value"].string, BackendHootChatStore.bypassModes.contains(mode) || mode == "allow" {
                        throw NativeRPCError(code: "not-granted", message: "Only you can turn on Bypass, in Hoot's settings.")
                    }
                    if field != "permissionMode" { try BackendROUTINESHootSettings.validate(field: field, value: arguments["value"]) }
                }
                // Never log note contents, private folder names, model/account names.
                let safe = NativeRPCValue.object([.init("operation", .string(operation)), .init("field", arguments["field"])])
                let summary = operation == "set" ? "Change Hoot's \(arguments["field"].string ?? "setting")" : title
                try await access.authorize(context, id, safe, tier, summary, changes)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                try await visible(context)
                let value = try await service.perform(operation, arguments: arguments)
                if value["ok"].bool == false {
                    throw NativeRPCError(code: "operation-failed", message: value["error"].string ?? "Hoot could not complete that action.")
                }
                try await visible(context)
                try await access.record(context, id, safe, .object([.init("ok", .bool(true))]))
                return .value(value)
            }
        }
    }
}
