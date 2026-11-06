import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeHootChatModel {
    func messageAction(_ action: String, row: HootChatRow) -> Bool {
        guard !readOnly else { return false }
        if source.isHoot { return action == "rewind" ? canRewind : action == "fork" && HootChatActions.fork != nil }
        guard !providerConversationMissing else { return false }
        return messageActions.contains { ($0["rowId"].string == row.id || $0["sequence"].number == Double(row.sequence)) && $0[action].bool == true }
    }
    func fork(from row: HootChatRow) {
        guard messageAction("fork", row: row), !busy, !changingMessageHistory else { return }
        changingMessageHistory = true; messageActionProblem = nil
        Task {
            defer { changingMessageHistory = false }
            do {
                let boundary = messageActions.first { $0["rowId"].string == row.id || $0["sequence"].number == Double(row.sequence) }
                let options = NativeRPCValue.object([.init("throughSequence", boundary?["sequence"] ?? .number(Double(row.sequence)))])
                let result: NativeRPCValue
                if source.isHoot {
                    guard let fork = HootChatActions.fork else { throw NativeRPCError(code: "unavailable", message: "Hoot's conversation owner is unavailable.") }
                    result = try await fork(row.sequence)
                } else { result = try NativeRPCValue.fromFoundation(await invokeChat("fork", ["fork", options.foundation])) }
                guard result["confirmed"].bool == true || result["pending"].bool == true, result["session"]["id"].string != nil else {
                    throw NativeRPCError(code: "fork-unconfirmed", message: result["warning"].string ?? "The AI did not confirm the fork. The original chat was kept.")
                }
            } catch { messageActionProblem = error.localizedDescription }
        }
    }
}

extension NativeCompositionProduction {
    func chatRewindToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        guard let chats = sessionChats else { return [] }
        let spec = try BackendMCPTool(id: "sessions.chat_rewind", wireName: "sessions_chat_rewind",
            description: "Rewind a project Chat to a user message using the AI's own history control. Choose a sequence with rewind=true in session chat read messageActions. Later messages leave the conversation; files stay unchanged. Returns the chosen text for editing. Uses the same action approvals as other session tools; the calling AI's permission mode decides its prompts. The message button confirms before discarding turns. Claude resumes at the preceding recorded checkpoint; Codex reverts before the completed turn. Gemini has no supported rewind here.",
            inputSchema: try .parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"sequence":{"type":"integer","minimum":1}},"required":["sessionId","sequence"],"additionalProperties":false}"#.utf8)), tier: .act)
        return [.init(spec: spec, title: "Rewind this Chat") { caller, args in
            await BackendDeckToolsSupport.reply {
                let id = try args["sessionId"].requireString("session", nonempty: true)
                let resolved = try await gate.authority.resolve(caller)
                let meta = try await gate.authority.requireSession(id, native: caller)
                guard resolved.caller.kind == .local, meta.chat == true else { throw NativeRPCError(code: "not-granted", message: "Ask the Mac owner to rewind this Chat.") }
                guard let number = args["sequence"].number, number.isFinite, number.rounded() == number, number > 0, number < Double(Int.max / 2) else { throw NativeRPCError.invalidArguments("Choose a recorded message sequence.") }
                try await gate.authorize(caller, .act, "Rewind to here? Later messages in this chat are removed from the conversation.", true)
                let result = try await chats.rewind(id, sequence: Int(number))
                let model = await NativeHootChatModel.featureModel(id, name: meta.provider)
                try await model.finishRewind(result["text"].string ?? "")
                return .value(result)
            }
        }]
    }
}
