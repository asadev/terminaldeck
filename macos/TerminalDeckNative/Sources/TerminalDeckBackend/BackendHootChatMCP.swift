import Foundation
import TerminalDeckNativeCore

/// Central deck-tools supplies the CURRENT caller/key Hoot visibility check.
/// This area cannot manufacture that authority or expose an approval tool.
public enum BackendHootChatMCP {
    public static func definitions(runtime: BackendCopilotSessionRuntime, access: BackendDeckToolsAppAccess,
                                   visible: @escaping @Sendable (BackendMCPCallContext) async throws -> Void) throws -> [BackendDeckToolsDefinition] {
        let descriptions: [(String, String, String, BackendMCPTier, String)] = [
            ("hoot.chat.read", "hoot_chat_read", "Read Hoot's structured conversation with a bounded cursor.", .read,
             #"{"type":"object","properties":{"cursor":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":500}},"additionalProperties":false}"#),
            ("hoot.chat.ask", "hoot_chat_ask", "Send a message to Hoot through its assistant chat.", .act,
             #"{"type":"object","properties":{"message":{"type":"string","maxLength":262144},"attachments":{"type":"array","maxItems":4,"items":{"type":"object"}}},"required":["message"],"additionalProperties":false}"#),
            ("hoot.chat.stop", "hoot_chat_stop", "Stop Hoot's current CLI process. The conversation stays saved.", .alter,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
        ]
        return try descriptions.map { id, wire, description, tier, schema in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description) { context, args in
                guard context.allowedTools.contains(id) || context.allowedTools.contains(wire), context.allowedTiers.contains(tier) else {
                    throw NativeRPCError(code: "access-denied", message: "This caller cannot use this Hoot chat tool.")
                }
                try await visible(context)
                let caller = try await access.caller(context)
                if id != "hoot.chat.read", caller.sessionID == runtime.structuredChat?.conversationID {
                    throw NativeRPCError(code: "access-denied", message: "Hoot cannot ask or stop itself through its own tool door.")
                }
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                let safe = NativeRPCValue.object([.init("characters", .number(Double(args["message"].string?.count ?? 0))),
                    .init("attachments", .number(Double(args["attachments"].elements?.count ?? 0)))])
                try await access.authorize(context, id, safe, tier, description, id == "hoot.chat.stop")
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                try await visible(context)
                let value: NativeRPCValue
                switch id {
                case "hoot.chat.read": value = try await runtime.invoke("hoot:chat:read", arguments: [args["cursor"], args["limit"]])
                case "hoot.chat.ask":
                    let message = try args["message"].requireString("message")
                    let attachments = args["attachments"].isNullish ? [] : try args["attachments"].requireArray("attachments")
                    let state = try await runtime.ensure()
                    guard state.status == .running, let chat = runtime.structuredChat else {
                        throw NativeRPCError(code: "unavailable", message: state.problem ?? "Hoot could not start.")
                    }
                    try await visible(context)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    value = try await chat.say(message, attachments: attachments)
                default: value = try await runtime.invoke("hoot:chat:stop", arguments: [])
                }
                try await visible(context)
                try await access.record(context, id, safe, .object([.init("conversationId", value["conversationId"]), .init("busy", value["busy"])]))
                return .value(value)
            }
        }
    }
}
