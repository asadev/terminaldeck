import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

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

extension NativeCompositionProduction {
    /// F38 fork, F56 worktree launch/cleanup and F57 execution location for one project Chat. Every launch goes
    /// through the ordinary launcher, so the new Chat has its own account lease, tools and permission owner.
    func chatForkFeature(_ parentID: String, action: String, arguments: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard ["fork", "worktree-chat", "worktree-status", "worktree-remove", "location"].contains(action), let chats = sessionChats,
              let parent = sessions?.manager.list().first(where: { $0.id == parentID }), parent.chat == true else {
            throw NativeRPCError.invalidArguments("Choose a project Chat and a supported fork, worktree or location action.")
        }
        let table: [String: Set<String>] = ["fork": ["throughTurn", "worktree", "title"], "worktree-chat": ["title"],
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
        guard let profile = parent.profileId, !profile.isEmpty else {
            throw NativeRPCError(code: "account-scope-unavailable", message: "This Chat's exact account identity was not recorded. Choose the account explicitly in New Session; no default account was substituted.")
        }
        let wantsWorktree = action == "worktree-chat" || arguments["worktree"].bool == true
        if action == "fork", wantsWorktree, parent.provider != "codex" {
            throw NativeRPCError(code: "unavailable", message: "Only Codex can fork a conversation into a different folder. Claude resumes a conversation only from the folder it started in; fork there, or start a new Chat in a worktree without the old conversation.")
        }
        var plan = NativeRPCValue.null
        if action == "fork" {
            let through = arguments["throughTurn"].string
            let args = through.map { NativeRPCValue.object([.init("throughTurn", .string($0))]) } ?? .object([])
            plan = try await chats.providerFeature(parentID, operation: "fork/create", arguments: args)
        }
        var folder = parent.cwd, worktreeEntry: NativeChatWorktreeLedger.Entry?
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
        var input = BackendCreateSessionInput(cwd: folder, provider: parent.provider)
        input.chat = true
        if action == "fork" {
            input.resume = true
            input.resumeConversationId = try plan["conversationId"].requireString("forked conversation", nonempty: true)
            if plan["requiresForkLaunch"].bool == true { input.forkSession = true }
        }
        input.profileId = profile; input.homeProfileId = parent.homeProfileId; input.projectId = parent.projectId
        let created: NativeRPCValue
        do {
            created = try await root.registry.invoke("session:create", context: context, arguments: [NativeRPCValue.parseJSON(JSONEncoder().encode(input))])
        } catch {
            // Nothing launched: give the just-made, untouched worktree back so it is not orphaned.
            if let worktreeEntry, let workspaces = files?.workspaces { _ = try? await workspaces.remove(taskID: worktreeEntry.key, liveFolders: [], context: context) }
            throw error
        }
        let id = try created["id"].requireString("new Chat session", nonempty: true)
        if var entry = worktreeEntry { entry.sessionID = id; NativeChatWorktreeLedger.record(entry) }
        do {
            try await chats.ensure(id)
            let state = try await chats.read(id, cursor: nil, limit: 1)
            let actual = state["providerConversationId"].string ?? ""
            let confirmed: Bool
            if action != "fork" { confirmed = true }
            else if plan["requiresForkLaunch"].bool == true { confirmed = !actual.isEmpty && actual != plan["parentConversationId"].string }
            else { confirmed = actual == plan["conversationId"].string }
            return .object([.init("session", created), .init("action", .string(action)), .init("parentSessionId", .string(parentID)),
                .init("conversationId", actual.isEmpty ? .null : .string(actual)), .init("parentConversationId", plan["parentConversationId"]),
                .init("forked", .bool(action == "fork" && confirmed)), .init("confirmed", .bool(confirmed)),
                .init("folder", .string(folder)), .init("worktree", .bool(worktreeEntry != nil)), .init("branchSafe", .bool(worktreeEntry != nil)),
                .init("executionLocation", .string("this-mac")),
                .init("warning", confirmed ? .null : .string("The provider did not confirm the new conversation. Inspect the new Chat before sending."))])
        } catch {
            return .object([.init("session", created), .init("action", .string(action)), .init("confirmed", .bool(false)),
                .init("worktree", .bool(worktreeEntry != nil)), .init("warning", .string(error.localizedDescription))])
        }
    }

    func chatForkToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.chat_fork", wireName: "sessions_chat_fork",
            description: "Fork a project Chat's provider conversation into a new Chat, start a new Chat in its own git worktree, check or clean up that worktree, or read where a Chat really runs. fork asks the provider for a real copy with its own conversation ID (Codex can fork from an earlier turn or into a worktree; Claude forks whole and in the same folder). worktree-chat starts a fresh Chat in a new worktree of the project. worktree-remove keeps a worktree that has uncommitted changes or a running session, and never deletes its branch. location reports the machine, folder and continuation limits; every Chat runs on this Mac. Fork and worktree actions belong to the Mac owner.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["fork","worktree-chat","worktree-status","worktree-remove","location"]},"throughTurn":{"type":"string"},"worktree":{"type":"boolean"},"title":{"type":"string"},"session":{"type":"string"}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
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
                for key in ["throughTurn", "worktree", "title", "session"] where !args[key].isNullish { options = options.setting(key, args[key]) }
                let result = try await self.chatForkFeature(id, action: action, arguments: options, context: gate.authority.rpc(caller))
                if let started = result["session"]["id"].string { resolved.noteStarted(started); await gate.noteResult(caller, result) }
                return .value(result)
            }
        }]
    }
}
