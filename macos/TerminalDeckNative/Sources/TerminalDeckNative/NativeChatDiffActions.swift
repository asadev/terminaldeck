import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// File mutations stay with the app's filesystem authority. Helper events supply the
    /// change, while the original caller's current file grants authorize every operation.
    func chatDiffFeature(_ id: String, action: String, arguments: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard let files, let chats = sessionChats,
              let meta = sessions?.manager.list().first(where: { $0.id == id }), meta.chat == true else { throw BackendSessionFailure.missingSession }
        guard ["list", "preview", "apply", "reject"].contains(action) else { throw NativeRPCError.invalidArguments("Choose list, preview, apply or reject.") }
        if chatDiffActions == nil { chatDiffActions = BackendChatDiffActions(authority: files.authority) }
        guard let service = chatDiffActions else { throw BackendSessionFailure.missingSession }
        let snapshot = try await chats.read(id, cursor: nil, limit: 500)
        if action == "apply" || action == "reject" {
            guard snapshot["busy"].bool != true, (snapshot["pending"].elements ?? []).isEmpty, (snapshot["ownedTerminalWriters"].number ?? 0) == 0,
                  !(snapshot["children"].elements ?? []).contains(where: ChatChildTasks.running) else {
                throw NativeRPCError(code: "busy", message: "Finish or stop this chat and its background writers before changing a recorded file version.")
            }
        }
        if action != "list" {
            let proposal = try arguments["id"].requireString("proposal ID", nonempty: true)
            guard chatDiffOwners[proposal]?.contains(id) == true else { throw NativeRPCError.invalidArguments("Choose a proposal from this chat's file-change list.") }
            switch action {
            case "preview": return try await service.preview(id: proposal, context: context)
            case "apply": return try await service.apply(id: proposal, context: context)
            default: return try await service.reject(id: proposal, context: context)
            }
        }
        var items: [NativeRPCValue] = [], unavailable: [NativeRPCValue] = []
        let events = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
        let edits = HootChatProjection.rows(events).filter(BackendChatDiffs.isEdit).suffix(64)
        for row in edits {
            let input = row.value["input"]
            let changes = Array((input["changes"].elements ?? [input]).prefix(64 - items.count))
            for change in changes {
                do {
                    let receipt = try await service.register(change: change, projectRoot: meta.cwd, context: context)
                    if receipt["available"].bool == false { unavailable.append(receipt.setting("sourceEventId", .string(row.id))); continue }
                    guard let proposal = receipt["id"].string else { throw NativeRPCError.malformed("The file change has no proposal identity.") }
                    chatDiffOwners[proposal, default: []].insert(id)
                    if !chatDiffOwnerOrder.contains(proposal) { chatDiffOwnerOrder.append(proposal) }
                    if chatDiffOwnerOrder.count > 256 { chatDiffOwners[chatDiffOwnerOrder.removeFirst()] = nil }
                    if !items.contains(where: { $0["id"].string == proposal }) { items.append(receipt.setting("sourceEventId", .string(row.id))) }
                } catch {
                    unavailable.append(.object([.init("sourceEventId", .string(row.id)), .init("reason", .string(error.localizedDescription))]))
                }
            }
            if items.count == 64 { break }
        }
        return .object([.init("items", .array(items)), .init("unavailable", .array(unavailable)),
            .init("scope", .string("Exact recorded text changes only. Diverged, ambiguous, binary, renamed or unversioned changes cannot be applied or rejected here."))])
    }

    func chatDiffToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.chat_diffs", wireName: "sessions_chat_diffs",
            description: "List exact provider-recorded text changes in a Chat, preview their immutable before/after versions, conditionally apply a pending change, or reject a pending/already-applied change. Uses current caller file grants, version and identity checks; refuses diverged files and active writers. Select a proposal ID from list. Never discards unrelated edits or rewinds the conversation.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["list","preview","apply","reject"]},"id":{"type":"string"}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Conditional Chat file changes") { caller, args in
            await BackendDeckToolsSupport.reply {
                let id = try args["sessionId"].requireString("session", nonempty: true)
                let action = try args["do"].requireString("action", nonempty: true)
                let meta = try await gate.authority.requireSession(id, native: caller)
                guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }
                let change = action == "apply" || action == "reject"
                try await gate.authorize(caller, change ? .act : .read, change ? "Conditionally change this recorded file version" : "Read recorded file versions", change)
                let context = try await gate.authority.rpc(caller)
                let result = try await self.chatDiffFeature(id, action: action, arguments: args, context: context)
                if change { await gate.noteResult(caller, .object([.init("sessionId", .string(id)), .init("action", .string(action)), .init("id", args["id"])])) }
                return .value(result)
            }
        }]
    }
}
