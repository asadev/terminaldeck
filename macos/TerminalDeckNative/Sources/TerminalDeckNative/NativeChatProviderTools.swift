import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    private var providerOwnerConversationID: String? { hoot?.runtime.structuredChat?.conversationID }
    func providerSessionID(_ id: String) async throws -> String {
        guard id == "hoot" else { return id }
        guard let store = hoot?.runtime.structuredChat, let hosted = await store.hostedSessionID else {
            throw NativeRPCError(code: "helper-upgrade-required", message: "Hoot needs a hosted Chat conversation for provider features. Its running conversation was left intact.")
        }
        return hosted
    }
    func chatProviderToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        guard let chats = sessionChats else { return [] }
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let spec = try BackendMCPTool(id: "sessions.chat_provider", wireName: "sessions_chat_provider",
            description: "Provider Chat features through the owning session helper. queue/list reads accepted messages; queue/resume releases a held message by arguments.id; queue/remove removes one saved message by arguments.id. capabilities reports protocol availability; catalogue/list and catalogue/read browse this account's saved conversations in this project; skills/list and instructions/read report source receipts; goals/read,set,edit,pause,resume,clear use actual provider goals; connections lists/reads provider plugins and apps, enables by inventory ID or starts explicit auth; review/start uses target uncommitted, baseBranch (branch), commit (sha) or custom (instructions). side/open,send,read,close owns an independent ephemeral read-only fork. voice/start,audio,text,events,stop use provider realtime transport. terminals/capabilities,list,read,stop,clean use verified thread-owned command identities; unsupported terminal creation/write/resize/foreground stay unavailable. Each action is provider gated. Unsupported capabilities return their actual limitation. No arbitrary provider RPC or configuration is accepted.",
            inputSchema: .object([.init("type", .string("object")), .init("properties", .object([
                .init("sessionId", string), .init("operation", string.setting("enum", .array(BackendChatProviderFeaturePolicy.operations.map(NativeRPCValue.string)))),
                .init("arguments", .object([.init("type", .string("object"))]))])),
                .init("required", .array([.string("sessionId"), .string("operation")])), .init("additionalProperties", .bool(false))]), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Provider Chat features") { caller, args in
            await BackendDeckToolsSupport.reply {
                let id = try args["sessionId"].requireString("session", nonempty: true)
                let operation = try args["operation"].requireString("operation", nonempty: true)
                let arguments = args["arguments"].isNullish ? NativeRPCValue.object([]) : args["arguments"]
                try BackendChatProviderFeaturePolicy.validate(operation, arguments: arguments)
                let resolved = try await gate.authority.resolve(caller)
                try BackendChatProviderFeaturePolicy.authorize(operation, caller: resolved.caller.kind)
                if id == "hoot" {
                    let ownConversation = await self.providerOwnerConversationID
                    guard resolved.caller.kind == .local, caller.sessionID.isEmpty || caller.sessionID != ownConversation else { throw NativeRPCError(code: "access-denied", message: "Hoot's provider controls belong to the Mac owner.") }
                } else {
                    let meta = try await gate.authority.requireSession(id, native: caller)
                    guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }
                }
                let change = BackendChatProviderFeaturePolicy.changes(operation)
                try await gate.authorize(caller, change ? .act : .read, change ? "Use provider Chat feature: " + operation : "Read this provider Chat feature", change)
                let result = try await chats.providerFeature(self.providerSessionID(id), operation: operation, arguments: arguments)
                if change { await gate.noteResult(caller, .object([.init("sessionId", .string(id)), .init("operation", .string(operation))])) }
                return .value(result)
            }
        }] + (try chatDiffToolDefinitions(gate: gate)) + (try chatChildToolDefinitions(gate: gate)) + (try chatOwnedTerminalToolDefinitions(gate: gate)) + (try chatForkToolDefinitions(gate: gate)) + (try chatRewindToolDefinitions(gate: gate))
    }
}
