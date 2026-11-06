import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Nested app calls keep the parent's authority but need a distinct in-flight request identity.
enum NativeChatForkRequest {
    static func child(_ context: NativeRPCContext) -> NativeRPCContext {
        .init(caller: context.caller, ownerID: context.ownerID, origin: context.origin, capabilities: context.capabilities)
    }
    static func child(_ context: NativeRPCContext, authority: BackendCompositionAuthority) throws -> NativeRPCContext {
        try authority.childContext(context)
    }
}

/// Which app-made worktrees belong to which Chat, so cleanup only ever touches what a Chat here created.
/// The workspace service keeps the real record; this only remembers the key for each Chat.
enum NativeChatWorktreeLedger {
    struct Entry: Codable, Equatable { var key: String; var sessionID: String; var parentSessionID: String?; var folder: String; var createdAt: Double }
    private static let storeKey = "native.chat.worktrees"
    static var all: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    static func entry(session id: String) -> Entry? { all.first { $0.sessionID == id } }
    static func entry(key: String) -> Entry? { all.first { $0.key == key } }
    /// U11 (#539): a Chat reaches only its own worktree or one made from it, never another Chat's folder.
    static func reachable(_ entry: Entry, from chatID: String) -> Bool { entry.sessionID == chatID || entry.parentSessionID == chatID }
    static func record(_ entry: Entry) {
        var next = all.filter { $0.key != entry.key }
        next.append(entry)
        if next.count > 200 { next.removeFirst(next.count - 200) }
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: storeKey) }
    }
    static func forget(key: String) {
        if let data = try? JSONEncoder().encode(all.filter { $0.key != key }) { UserDefaults.standard.set(data, forKey: storeKey) }
    }
}

/// Stop the owned child before removing its workspace. A refused cleanup stays visible and retryable.
@MainActor enum NativeChatForkCleanup {
    struct Result { var sessionRemoved: Bool; var worktreeRemoved: Bool; var errors: [String] }
    static func run(sessionID: String?, worktreeKey: String?, close: (String) async throws -> Void,
                    remove: (String) async throws -> NativeRPCValue) async -> Result {
        var result = Result(sessionRemoved: sessionID == nil, worktreeRemoved: worktreeKey == nil, errors: [])
        if let sessionID {
            do { try await close(sessionID); result.sessionRemoved = true }
            catch { result.errors.append("The new Chat was kept: " + error.localizedDescription) }
        }
        if let worktreeKey, result.sessionRemoved {
            do {
                let removed = try await remove(worktreeKey)
                result.worktreeRemoved = removed["ok"].bool == true
                if !result.worktreeRemoved { result.errors.append(removed["message"].string ?? "The new worktree was kept; inspect its status before cleanup.") }
            } catch { result.errors.append("The new worktree was kept: " + error.localizedDescription) }
        }
        return result
    }
}

extension NativeCompositionProduction {
    /// F38 fork, F56 worktree launch/cleanup and F57 execution location for one project Chat. Every launch goes
    /// through the ordinary launcher, so the new Chat has its own account lease, tools and permission owner.
    func chatForkFeature(_ parentID: String, action: String, arguments: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        let historyParent = await sessionChats?.conversation(parentID)?.session
        guard ["fork", "worktree-chat", "worktree-status", "worktree-remove", "location"].contains(action), let chats = sessionChats,
              let parent = sessions?.manager.list().first(where: { $0.id == parentID }) ?? historyParent, parent.chat == true else {
            throw NativeRPCError.invalidArguments("Choose a project Chat and a supported fork, worktree or location action.")
        }
        guard let authority else { throw BackendSessionFailure.missingCapability("the current Chat request owner") }
        let table: [String: Set<String>] = ["fork": ["throughTurn", "throughSequence", "worktree", "title"], "worktree-chat": ["title"],
                                            "worktree-status": ["session"], "worktree-remove": ["session"], "location": []]
        guard Set(arguments.fields?.map(\.key) ?? []).isSubset(of: table[action] ?? []) else {
            throw NativeRPCError.invalidArguments("Use only the documented options. Folders, accounts and provider settings come from the source Chat.")
        }
        if action == "location" {
            return try await chats.providerFeature(parentID, operation: "location/read", arguments: .object([]))
        }
        if action == "worktree-status" || action == "worktree-remove" {
            let target = arguments["session"].string ?? parentID
            guard let entry = NativeChatWorktreeLedger.entry(session: target), let workspaces = files?.workspaces else {
                throw NativeRPCError(code: "no-worktree", message: "That Chat was not launched in an app-made worktree.")
            }
            guard NativeChatWorktreeLedger.reachable(entry, from: parentID) else {
                throw NativeRPCError(code: "not-granted", message: "That worktree belongs to a different Chat. Use that Chat, or the Chat it was made from.")
            }
            if action == "worktree-status" { return try await workspaces.view(taskID: entry.key, context: context) }
            let live = (sessions?.manager.list() ?? []).filter { $0.exitCode == nil }.map(\.cwd)
            let outcome = try await workspaces.remove(taskID: entry.key, liveFolders: live, context: context)
            if outcome["ok"].bool == true { NativeChatWorktreeLedger.forget(key: entry.key) }
            return outcome
        }
        if action == "fork", arguments["worktree"].bool != true, arguments["throughTurn"].isNullish, let number = arguments["throughSequence"].number,
           number.isFinite, number.rounded() == number, number > 0, number < Double(Int.max / 2),
           let result = try await chats.forkHootConversation(parentID, through: Int(number)) { return result }
        guard let profile = parent.profileId, !profile.isEmpty else {
            throw NativeRPCError(code: "account-scope-unavailable", message: "This Chat's exact account identity was not recorded. Choose the account explicitly in New Session; no default account was substituted.")
        }
        let wantsWorktree = action == "worktree-chat" || arguments["worktree"].bool == true
        if action == "fork", wantsWorktree, parent.provider != "codex" {
            throw NativeRPCError(code: "unavailable", message: "Only Codex can fork a conversation into a different folder. Claude resumes a conversation only from the folder it started in; fork there, or start a new Chat in a worktree without the old conversation.")
        }
        let saved = try await root.state.ledgerGet(parentID)
        var input = try BackendSessionSaved(saved).input(resume: false)
        input.tabKey = nil; input.replaces = nil
        input.resumeConversationId = nil; input.forkSession = nil; input.resumeSessionAt = nil
        input.taskID = nil; input.taskProject = nil
        let sourceState = try await chats.read(parentID, cursor: 0, limit: 1)
        let choices = sourceState["readOnly"].bool == true ? NativeRPCValue.object([]) : try await chats.options(parentID)
        if let model = choices["model"].string {
            let prefix = parent.provider + ":"
            input.model = model.hasPrefix(prefix) ? String(model.dropFirst(prefix.count)) : model
        }
        if let mode = choices["permissionMode"].string.flatMap(BackendHOOTSIMPermissionMode.init(rawValue:)), let provider = HootChatProvider(rawValue: parent.provider) {
            input.permissionMode = mode.cliMode(provider: provider)
        }
        input.effort = choices["effort"].string ?? input.effort
        input.chat = true
        var plan = NativeRPCValue.null
        if action == "fork" {
            let through = arguments["throughTurn"].string
            var args = through.map { NativeRPCValue.object([.init("throughTurn", .string($0))]) } ?? .object([])
            if !arguments["throughSequence"].isNullish { args = args.setting("throughSequence", arguments["throughSequence"]) }
            plan = try await chats.providerFeature(parentID, operation: "fork/create", arguments: args)
        }
        if action == "fork", plan["historySeed"].bool != true {
            input.resume = true
            input.resumeConversationId = try plan["conversationId"].requireString("forked conversation", nonempty: true)
            if plan["requiresForkLaunch"].bool == true { input.forkSession = true; input.resumeSessionAt = plan["resumeSessionAt"].string }
        }
        input.profileId = profile; input.homeProfileId = parent.homeProfileId; input.projectId = parent.projectId
        var folder = parent.cwd, worktreeEntry: NativeChatWorktreeLedger.Entry?
        var created = NativeRPCValue.null, createdID: String?
        do {
            if wantsWorktree {
                guard let workspaces = files?.workspaces else { throw BackendSessionFailure.missingCapability("the app's workspace owner") }
                let key = "chat-" + UUID().uuidString.lowercased()
                let title = arguments["title"].string.map { String($0.prefix(60)) } ?? (action == "fork" ? "fork" : "chat")
                guard let made = try await workspaces.folderFor(taskID: key, project: parent.cwd, useWorkspace: true, title: title, context: context) else {
                    let reason = try await workspaces.view(taskID: key, context: context)["refusal"].string
                    throw NativeRPCError(code: "worktree-unavailable", message: reason ?? "A worktree could not be made, so no Chat was started in a separate folder.")
                }
                folder = made
                worktreeEntry = .init(key: key, sessionID: "", parentSessionID: parentID, folder: made, createdAt: Date().timeIntervalSince1970 * 1000)
            }
            input.cwd = folder
            // A moved source belongs to this app; its child must share that owner before guarded seeding.
            created = try await BackendChatForkLaunchScope.$sourceID.withValue(action == "fork" ? parentID : nil) {
                try await root.registry.invoke("session:create", context: NativeChatForkRequest.child(context, authority: authority), arguments: [NativeRPCValue.parseJSON(JSONEncoder().encode(input))])
            }
            let id = try created["id"].requireString("new Chat session", nonempty: true)
            createdID = id
            if var entry = worktreeEntry { entry.sessionID = id; NativeChatWorktreeLedger.record(entry) }
            try await chats.ensure(id)
            if let sequence = arguments["throughSequence"].number {
                // This record comes from the app's ledger, never the caller's options. The keeper
                // still checks both live sessions' AI, login and the exact destination identity/folder.
                let recorded = NativeChatWorktreeLedger.entry(session: id)
                let worktree = recorded.flatMap { entry -> BackendChatForkWorktree? in
                    guard entry.parentSessionID == parentID, entry.folder == folder else { return nil }
                    return .init(key: entry.key, sessionID: id, parentSessionID: parentID, folder: entry.folder)
                }
                try await chats.seedFork(id, from: parentID, through: Int(sequence), worktree: worktree)
            }
            let forkTitle = parent.title + " · fork"
            if action == "fork" { _ = try await root.registry.invoke("session:rename", context: NativeChatForkRequest.child(context, authority: authority), arguments: [.string(id), .string(forkTitle)]) }
            let named = action == "fork" ? created.setting("title", .string(forkTitle)) : created
            let state = try await chats.read(id, cursor: nil, limit: 1)
            let actual = state["providerConversationId"].string ?? ""
            let pendingFork = action == "fork" && (plan["requiresForkLaunch"].bool == true || plan["historySeed"].bool == true) && actual.isEmpty
            let confirmed: Bool
            if action != "fork" { confirmed = true }
            else if plan["historySeed"].bool == true { confirmed = !actual.isEmpty && actual != plan["parentConversationId"].string }
            else if plan["requiresForkLaunch"].bool == true { confirmed = !actual.isEmpty && actual != plan["parentConversationId"].string }
            else { confirmed = actual == plan["conversationId"].string }
            if action == "fork", !confirmed, !pendingFork {
                throw NativeRPCError(code: "fork-unconfirmed", message: "The provider did not confirm the new conversation. The new Chat and clean worktree were rolled back where possible.")
            }
            if action == "fork", (confirmed || pendingFork), let metadata = named.foundation as? [String: Any] {
                AppModel.shared.buttonActions.created(metadata); AppModel.shared.select(id)
            }
            return .object([.init("session", named), .init("action", .string(action)), .init("parentSessionId", .string(parentID)),
                .init("conversationId", actual.isEmpty ? .null : .string(actual)), .init("parentConversationId", plan["parentConversationId"]),
                .init("forked", .bool(action == "fork" && confirmed)), .init("confirmed", .bool(confirmed)), .init("pending", .bool(pendingFork)),
                .init("folder", .string(folder)), .init("worktree", .bool(worktreeEntry != nil)), .init("branchSafe", .bool(worktreeEntry != nil)),
                .init("executionLocation", .string("this-mac")),
                .init("warning", confirmed ? .null : .string(pendingFork ? "The copied history is ready. The AI saves its new conversation when you send the first message." : "The provider did not confirm the new conversation. Inspect the new Chat before sending."))])
        } catch {
            let cleanup = await NativeChatForkCleanup.run(sessionID: createdID, worktreeKey: worktreeEntry?.key, close: { id in
                let cleanupContext = try authority.childContext(context)
                _ = try await root.registry.invoke("session:kill", context: cleanupContext, arguments: [.string(id)])
            }, remove: { key in
                guard let workspaces = files?.workspaces else { throw BackendSessionFailure.missingCapability("the app's workspace owner") }
                let live = (sessions?.manager.list() ?? []).filter { $0.exitCode == nil }.map(\.cwd)
                let result = try await workspaces.remove(taskID: key, liveFolders: live, context: context)
                if result["ok"].bool == true { NativeChatWorktreeLedger.forget(key: key) }
                return result
            })
            return .object([.init("session", cleanup.sessionRemoved ? .null : created), .init("action", .string(action)), .init("confirmed", .bool(false)),
                .init("worktree", .bool(!cleanup.worktreeRemoved)), .init("rolledBack", .bool(cleanup.sessionRemoved && cleanup.worktreeRemoved)),
                .init("warning", .string(([error.localizedDescription] + cleanup.errors).joined(separator: " ")))])
        }
    }

    func chatForkToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.chat_fork", wireName: "sessions_chat_fork",
            description: "Fork a project Chat at a recorded message into a separate Chat; start a fresh Chat in a git worktree; inspect or remove an owned worktree; or read where the Chat runs. Claude and Codex use provider-native copies where supported. Gemini and earlier team or read-only histories use a fresh conversation seeded with checked, bounded history. The source keeps its own owner and messages. A fork keeps the exact source AI, account, folder and approval settings; only Codex provider forks support a different worktree. Use throughSequence from the chat read's messageActions for an exact supported message. A fresh fork can be pending until its first input saves the new provider identity. worktree-remove preserves changed worktrees, live sessions and branches. These operations use the existing Mac owner and approval checks.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["fork","worktree-chat","worktree-status","worktree-remove","location"]},"throughTurn":{"type":"string"},"throughSequence":{"type":"integer","minimum":1},"worktree":{"type":"boolean"},"title":{"type":"string"},"session":{"type":"string"}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Chat fork, worktree and location") { caller, args in
            await BackendDeckToolsSupport.reply {
                let id = try args["sessionId"].requireString("source session", nonempty: true)
                let action = try args["do"].requireString("action", nonempty: true)
                let resolved = try await gate.authority.resolve(caller)
                _ = try await gate.authority.requireSession(id, native: caller)
                let changes = ["fork", "worktree-chat", "worktree-remove"].contains(action)
                if changes, resolved.caller.kind != .local { throw NativeRPCError(code: "not-granted", message: "Ask the Mac owner to fork this Chat or change its worktree.") }
                try await gate.authorize(caller, changes ? .act : .read, "Fork, worktree or location for this Chat", changes)
                var options = NativeRPCValue.object([])
                for key in ["throughTurn", "throughSequence", "worktree", "title", "session"] where !args[key].isNullish { options = options.setting(key, args[key]) }
                let result = try await self.chatForkFeature(id, action: action, arguments: options, context: gate.authority.rpc(caller))
                if let started = result["session"]["id"].string { resolved.noteStarted(started); await gate.noteResult(caller, result) }
                return .value(result)
            }
        }]
    }
}
