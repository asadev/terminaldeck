import Foundation
import TerminalDeckNativeCore

public enum BackendPCDecisionsMCP {
    public static let channel = "decisions:perform"
    public static func definitions(service: BackendPCDecisions, changed: @escaping @Sendable () async throws -> Void = {}) throws -> [BackendDeckToolsDefinition] {
        let fields = #""project":{"type":"string"},"task":{"type":"string"},"action":{"type":"string"},"request":{"type":"string"},"expected":{"type":"integer","minimum":0},"policy":{"type":["string","null"]},"policyExpected":{"type":"integer","minimum":0},"mode":{"type":"string","enum":["off","owner-before-start"]},"name":{"type":"string"},"title":{"type":"string"},"body":{"type":"string"},"rationale":{"type":"string"},"text":{"type":"string"},"review":{"type":"object"}"#
        let rows: [(String, BackendMCPTier, String)] = [("get", .read, "Read a local task's optional business decision and project workflows."), ("proposal", .act, "Draft, comment or submit an opted-in local proposal; never approves or starts it."), ("owner", .alter, "Request the person's explicit workflow/decision choice. Read get first; include its ownerReview as review. Production starts remain held until final validation hooks exist.")]
        return try rows.map { suffix, tier, description in
            let id = "decisions." + suffix
            let schema = try NativeRPCValue.parseJSON(Data(("{\"type\":\"object\",\"properties\":{" + fields + "},\"anyOf\":[{\"required\":[\"task\"]},{\"required\":[\"project\"]}],\"additionalProperties\":false}").utf8))
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: schema, tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description) { context, args in
                try await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(tier), BackendMCPToolNames.permits(id, granted: context.allowedTools) || BackendMCPToolNames.permits(spec.wireName, granted: context.allowedTools) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot use that decision control.") }
                    let action = suffix == "get" ? "get" : try args["action"].requireString("action")
                    guard suffix == "get" || (suffix == "owner" ? PCDecisions.ownerActions.contains(action) : ["draft", "comment", "submit"].contains(action)) else { throw NativeRPCError(code: "not-granted", message: "Owner decisions require the explicit owner tool and confirmation.") }
                    let value = try await service.perform(action, args: args, call: .tool(context))
                    if action != "get" { try await changed() }
                    return .value(value)
                }
            }
        }
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendPCDecisions,
                                requireOwnerUI: @escaping NativeChannelRegistry.Policy) async throws {
        try await registry.register(channel, ownerID: ownerID, policy: requireOwnerUI) { context, args in
            let input = context.argument(0, in: args)
            let action = try input["action"].requireString("action")
            let value = try await service.perform(action, args: input, call: .app(context))
            if action != "get" { try await registry.publish("tasks:changed", arguments: []) }
            return value
        }
    }
}
