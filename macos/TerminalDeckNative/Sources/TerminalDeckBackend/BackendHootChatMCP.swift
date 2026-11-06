import Foundation
import TerminalDeckNativeCore

/// Central deck-tools supplies the CURRENT caller/key Hoot visibility check.
/// This area cannot manufacture that authority or expose an approval tool.
public enum BackendHootChatMCP {
    public static func definitions(runtime: BackendCopilotSessionRuntime, access: BackendDeckToolsAppAccess,
                                   visible: @escaping @Sendable (BackendMCPCallContext) async throws -> Void) throws -> [BackendDeckToolsDefinition] {
        let descriptions: [(String, String, String, BackendMCPTier, String)] = [
            ("hoot.chat.read", "hoot_chat_read", "Read Hoot's structured conversation with a bounded cursor. The newest content is followed automatically in open chat views; seenSequence remains an ignored compatibility field.", .read,
             #"{"type":"object","properties":{"cursor":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":500},"seenSequence":{"type":"integer","minimum":0},"conversationId":{"type":"string"}},"additionalProperties":false}"#),
            ("hoot.chat.ask", "hoot_chat_ask", "Send a message to Hoot through its assistant chat.", .alter,
             #"{"type":"object","properties":{"clientMessageId":{"type":"string","minLength":1},"sentAt":{"type":["string","number"]},"clientSequence":{"type":["string","number"]},"message":{"type":"string","maxLength":262144},"attachments":{"type":"array","maxItems":4,"items":{"type":"object"}}},"required":["message"],"additionalProperties":false}"#),
            ("hoot.chat.stop", "hoot_chat_stop", "Interrupt Hoot's current answer, keeping the conversation and separately controlled background tasks.", .alter,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("hoot.send", "hoot_send", "Send a note and pictures to the same Hoot conversation, with structured source context. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{"clientMessageId":{"type":"string","minLength":1},"sentAt":{"type":["string","number"]},"clientSequence":{"type":["string","number"]},"text":{"type":"string","maxLength":262144},"attachments":{"type":"array","maxItems":4,"items":{"type":"object"}},"context":{"type":"object"}},"required":["text"],"additionalProperties":false}"#),
            ("hoot.new_chat", "hoot_new_chat", "Start a fresh Hoot conversation, keeping the old history. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("hoot.set_permission_mode", "hoot_set_permission_mode", "Choose this Hoot chat's permission mode. Agent and session sends always require their own approval.", .alter,
             #"{"type":"object","properties":{"mode":{"type":"string","enum":["ask","plan","changes"]}},"required":["mode"],"additionalProperties":false}"#),
            ("hoot.set_model", "hoot_set_model", "Choose an offered installed Coding AI and model for this chat only. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{"model":{"type":"string"}},"required":["model"],"additionalProperties":false}"#),
            ("hoot.chat.rewind", "hoot_chat_rewind", "Take Hoot's chat back to one message, as the Rewind button does: what came after is set aside (kept, not deleted) and Hoot's desk is rebuilt up to there. `sequence` is that message's event number from hoot.chat.read. Can be undone with hoot.chat.rewind_undo until the next message. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{"sequence":{"type":"integer","minimum":1}},"required":["sequence"],"additionalProperties":false}"#),
            ("hoot.chat.fork", "hoot_chat_fork", "Start a separate Hoot conversation through the chosen message, keeping the original conversation unchanged. The new conversation appears in sessions_conversations and the chat list.", .alter,
             #"{"type":"object","properties":{"sequence":{"type":"integer","minimum":1}},"required":["sequence"],"additionalProperties":false}"#),
            ("hoot.chat.rewind_undo", "hoot_chat_rewind_undo", "Undo the last rewind of Hoot's chat: the messages and Hoot's desk go back as they were. Only until the next message is sent. Runs at once when the calling AI's permission mode allows it; the action is logged.", .alter,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
            ("hoot.chat.background", "hoot_chat_background", "What Hoot is working on in the background (a task, a handoff): the one running now, and how many are waiting their turn. Changes nothing.", .read,
             #"{"type":"object","properties":{},"additionalProperties":false}"#),
        ]
        return try descriptions.map { id, wire, description, tier, schema in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(schema.utf8)), tier: tier, advertised: false)
            let aliases = id == "hoot.send" ? ["hoot_say"] : []
            return BackendDeckToolsDefinition(spec: spec, title: description, index: description, aliases: aliases) { context, args in
                guard context.allowedTools.contains(id) || context.allowedTools.contains(wire) || aliases.contains(where: context.allowedTools.contains), context.allowedTiers.contains(tier) else {
                    throw NativeRPCError(code: "access-denied", message: "This caller cannot use this Hoot chat tool.")
                }
                try await visible(context)
                let caller = try await access.caller(context)
                if id != "hoot.chat.read", id != "hoot.chat.background", caller.sessionID == runtime.structuredChat?.conversationID {
                    throw NativeRPCError(code: "access-denied", message: "Hoot cannot ask or stop itself through its own tool door.")
                }
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                let message = args[id == "hoot.send" ? "text" : "message"].string ?? ""
                let safe = NativeRPCValue.object([.init("characters", .number(Double(message.count))),
                    .init("attachments", .number(Double(args["attachments"].elements?.count ?? 0))),
                    .init("mode", args["mode"]), .init("model", args["model"])])
                let summary: String
                switch id {
                case "hoot.chat.ask", "hoot.send":
                    summary = "Send this note to Hoot with \(args["attachments"].elements?.count ?? 0) attachments: “\(String(message.prefix(160)))\(message.count > 160 ? "…" : "")”"
                case "hoot.new_chat": summary = "Start a new Hoot chat and keep the current conversation in its history."
                case "hoot.set_permission_mode": summary = "Set this Hoot chat's permission mode to \(args["mode"].string ?? "?"). Session starts and messages still ask first."
                case "hoot.set_model": summary = "Use \(args["model"].string ?? "?") for this Hoot chat only."
                case "hoot.chat.rewind": summary = "Take Hoot's chat back to message \(args["sequence"].number.map { String(Int($0)) } ?? "?"). What came after is set aside and can be put back until the next message."
                case "hoot.chat.rewind_undo": summary = "Undo the last rewind of Hoot's chat."
                default: summary = description
                }
                try await access.authorize(context, id, safe, tier, summary, tier != .read)
                guard !context.cancellation.isCancelled else { throw CancellationError() }
                try await visible(context)
                let value: NativeRPCValue
                switch id {
                case "hoot.chat.read": value = try await runtime.invoke("hoot:chat:read", arguments: [args["cursor"], args["limit"], args["seenSequence"], args["conversationId"]])
                case "hoot.chat.ask", "hoot.send":
                    let message = try args[id == "hoot.send" ? "text" : "message"].requireString("message")
                    let attachments = args["attachments"].isNullish ? [] : try args["attachments"].requireArray("attachments")
                    try await visible(context)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    value = try await runtime.sayValidated(message, attachments: attachments,
                        context: args["context"].isNullish ? .object([]) : args["context"], clientMessageID: BackendChatRetryIdentity.messageID(args["clientMessageId"].string, caller: BackendChatRetryIdentity.caller(caller), conversation: runtime.structuredChat?.conversationID ?? "hoot", text: message, frame: args))
                case "hoot.new_chat": value = try await runtime.invoke("hoot:chat:new", arguments: [])
                case "hoot.set_permission_mode":
                    // Bypass is the owner's choice in Hoot's window only, never a tool's.
                    guard args["mode"].string != "bypass" else {
                        throw NativeRPCError(code: "access-denied", message: "Only you can choose Bypass, in Hoot's window.")
                    }
                    value = try await runtime.invoke("hoot:chat:options", arguments: [.object([.init("permissionMode", args["mode"])])])
                case "hoot.set_model":
                    value = try await runtime.invoke("hoot:chat:options", arguments: [.object([.init("model", args["model"])])])
                case "hoot.chat.rewind":
                    guard let sequence = args["sequence"].number, sequence >= 1, sequence.rounded() == sequence else { throw NativeRPCError.invalidArguments("sequence must be a message's event number.") }
                    let text = try await runtime.rewindChat(to: Int(sequence))
                    value = try await runtime.invoke("hoot:chat:read", arguments: []).setting("returnedText", .string(text))
                case "hoot.chat.fork":
                    guard let sequence = args["sequence"].number, sequence.isFinite, sequence >= 1, sequence.rounded() == sequence, sequence < Double(Int.max / 2) else { throw NativeRPCError.invalidArguments("Choose a message's event number.") }
                    value = try await runtime.forkChat(through: Int(sequence))
                case "hoot.chat.rewind_undo":
                    try await runtime.undoRewindChat()
                    value = try await runtime.invoke("hoot:chat:read", arguments: [])
                case "hoot.chat.background": value = await runtime.backgroundStatus()
                default: value = try await runtime.invoke("hoot:chat:stop", arguments: [])
                }
                try await visible(context)
                try await access.record(context, id, safe, .object([.init("conversationId", value["conversationId"]), .init("busy", value["busy"])]))
                return .value(value)
            }
        }
    }
}
