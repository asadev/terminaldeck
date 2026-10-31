import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// Resume through the ordinary launcher so the child has its own account lease,
    /// tools and permission owner. The parent's pipe never receives a synthetic turn.
    func chatChildFeature(_ parentID: String, action: String, arguments: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard ["list", "read", "resume"].contains(action), let chats = sessionChats,
              let parent = sessions?.manager.list().first(where: { $0.id == parentID }), parent.chat == true else {
            throw NativeRPCError.invalidArguments("Choose a project Chat and a supported child action.")
        }
        let query = NativeRPCValue.object((arguments.fields ?? []).filter { ["taskId", "cursor", "limit"].contains($0.key) })
        let receipt = try await chats.providerFeature(parentID, operation: "children/" + action, arguments: query)
        guard action == "resume" else { return receipt }
        let conversation = try receipt["conversationId"].requireString("verified child conversation", nonempty: true)
        guard receipt["resume"]["requiresOwnedLaunch"].bool == true, receipt["cwd"].string == parent.cwd else {
            throw NativeRPCError(code: "child-scope", message: "The provider did not confirm a child conversation in this project's launch scope.")
        }
        guard let profile = parent.profileId, !profile.isEmpty else {
            throw NativeRPCError(code: "account-scope-unavailable", message: "This parent's exact account identity was not recorded. Choose the account explicitly in New Session; no default account was substituted.")
        }
        let key = [parent.provider, parent.profileId ?? "system", parent.homeProfileId ?? "", parent.projectId ?? "", parent.cwd, conversation].joined(separator: "\u{1f}")
        if let opening = chatChildOpenings[key] { return try await opening.value }
        let opening = Task<NativeRPCValue, Error> { @MainActor in
            let candidates: [BackendSessionMeta] = self.sessions?.manager.list() ?? []
            let foreignOwner = candidates.contains { candidate in
                candidate.agentSessionId == conversation && candidate.provider == parent.provider && candidate.cwd == parent.cwd && candidate.profileId == parent.profileId && candidate.homeProfileId == parent.homeProfileId && candidate.projectId != parent.projectId && candidate.chat == true && candidate.exitCode == nil
            }
            guard !foreignOwner else { throw NativeRPCError(code: "child-owned-elsewhere", message: "This child conversation is already open under another app project. Use its existing Chat instead of creating a second owner.") }
            let existing: BackendSessionMeta? = candidates.first { candidate in
                guard candidate.agentSessionId == conversation, candidate.provider == parent.provider, candidate.cwd == parent.cwd else { return false }
                guard candidate.profileId == parent.profileId, candidate.homeProfileId == parent.homeProfileId, candidate.projectId == parent.projectId else { return false }
                return candidate.chat == true && candidate.exitCode == nil
            }
            let created: NativeRPCValue
            if let existing { created = try NativeRPCValue.parseJSON(JSONEncoder().encode(existing)) }
            else {
                var input = BackendCreateSessionInput(cwd: parent.cwd, provider: parent.provider)
                input.chat = true; input.resume = true; input.resumeConversationId = conversation
                input.profileId = profile; input.homeProfileId = parent.homeProfileId; input.projectId = parent.projectId
                created = try await self.root.registry.invoke("session:create", context: context,
                    arguments: [NativeRPCValue.parseJSON(JSONEncoder().encode(input))])
            }
            let id = try created["id"].requireString("child Chat session", nonempty: true)
            do {
                try await chats.ensure(id)
                let state = try await chats.read(id, cursor: nil, limit: 1)
                let confirmed = state["providerConversationId"].string == conversation
                return .object([.init("session", created), .init("conversationId", .string(conversation)),
                    .init("parentSessionId", .string(parentID)), .init("resumed", .bool(confirmed)),
                    .init("existing", .bool(existing != nil)), .init("executionLocation", .string("local")),
                    .init("warning", confirmed ? .null : .string("The exact provider conversation was not confirmed. Inspect the new child Chat before sending."))])
            } catch {
                // A launch already exists. Return its identity instead of inviting a duplicate retry.
                return .object([.init("session", created), .init("conversationId", .string(conversation)),
                    .init("resumed", .bool(false)), .init("warning", .string(error.localizedDescription))])
            }
        }
        chatChildOpenings[key] = opening
        defer { chatChildOpenings[key] = nil }
        return try await opening.value
    }

    func chatChildToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.chat_children", wireName: "sessions_chat_children",
            description: "List provider-owned child tasks, read an exact child's bounded conversation, or resume an eligible durable child in a separate Chat using its parent's account and project. Resume runs the real provider resume through its own permission owner; it never sends a synthetic turn to the parent. Choose taskId from list. Unknown, running, ephemeral, foreign-folder and foreign-parent children refuse resume. Existing launched child Chats are reused.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["list","read","resume"]},"taskId":{"type":"string"},"cursor":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Child Chat conversations") { caller, args in
            await BackendDeckToolsSupport.reply {
                let id = try args["sessionId"].requireString("parent session", nonempty: true)
                let action = try args["do"].requireString("action", nonempty: true)
                let resolved = try await gate.authority.resolve(caller)
                _ = try await gate.authority.requireSession(id, native: caller)
                if action == "resume", resolved.caller.kind != .local { throw NativeRPCError(code: "not-granted", message: "Ask the Mac owner to open this child's saved Chat.") }
                try await gate.authorize(caller, action == "resume" ? .act : .read, "Read or resume this provider child", action == "resume")
                let result = try await self.chatChildFeature(id, action: action, arguments: args, context: gate.authority.rpc(caller))
                if let started = result["session"]["id"].string { resolved.noteStarted(started); await gate.noteResult(caller, result) }
                return .value(result)
            }
        }]
    }
}
