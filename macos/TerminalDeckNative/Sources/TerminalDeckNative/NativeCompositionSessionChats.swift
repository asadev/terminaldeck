import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The session a `session:chat:*` call is about (its first argument).
private enum SessionChatArguments {
    static func id(_ args: [NativeRPCValue]) throws -> String { try (args.first ?? .missing).requireString("session id", nonempty: true) }
}

/// Chat sessions (Asad, 13 Oct): the owner of their AIs, the launcher's chat dispatch, and the window's
/// `session:chat:*` calls. Installed with the sessions, before anything is restored, so a restored chat comes
/// back as a chat.
extension NativeCompositionProduction {
    static let sessionChatsOwner = "native-composition:session-chats"

    /// Tools use the same owners as the window, through the current caller's session and consent checks.
    func sessionChatToolDefinitions(gate: BackendCompositionDeckToolsGate,
                                    runtime: any BackendDeckToolsSessionsRuntime) throws -> [BackendDeckToolsDefinition] {
        guard let chats = sessionChats, let sessions else { return [] }
        let lifecycle = sessions.lifecycle, registry = root.registry
        let storageRoot = root.dataRoot.path
        let workspaces = files?.workspaces
        let referenceFiles = files?.files
        let fileAuthority = files?.authority
        let hootRuntime = hoot?.runtime
        let specs = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        func schema(_ fields: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(fields.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let verbs = string.setting("enum", .array(SessionChatToolPolicy.operations.map { .string($0.name) }))
        let referenceSchema = schema([("path", string), ("kind", string.setting("enum", .array([.string("file"), .string("folder")])) )], required: ["path"])
        let chat = try BackendMCPTool(id: "sessions.chat", wireName: "sessions_chat",
            description: "Read or control a chat using do and direction (default read). Non-read directions, drafts with text, find/detail with query and options updates are actions. say sends; stop interrupts the answer; stop-job ends its team job. answer uses the pending request’s structured answers, approvalNonce and scope. Mac panels and clipboard actions keep owner checks; provider features use sessions_chat_provider.",
            inputSchema: schema([("sessionId", string), ("do", verbs), ("text", string), ("request", string), ("clientMessageId", string), ("sentAt", string), ("clientSequence", string),
                ("allowed", .object([.init("type", .string("boolean"))])), ("answers", .object([.init("type", .string("object"))])),
                ("seenSequence", .object([.init("type", .string("integer")), .init("minimum", .number(0))])),
                ("conversationId", string),
                ("query", string.setting("maxLength", .number(1024))),
                ("attachmentAction", string.setting("enum", .array(["read", "add", "remove", "validate", "send"].map(NativeRPCValue.string)))),
                ("paths", .object([.init("type", .string("array")), .init("items", string), .init("maxItems", .number(32))])),
                ("direction", string.setting("enum", .array(["read", "previous", "next", "open", "close", "retry", "refresh", "compact", "stop", "insert", "copy", "reveal", "prepare", "speak", "listen"].map(NativeRPCValue.string)))),
                ("path", string), ("kind", string.setting("enum", .array([.string("file"), .string("folder")]))),
                ("references", .object([.init("type", .string("array")), .init("items", referenceSchema), .init("maxItems", .number(8))])),
                ("options", BackendSessionChatOptionsTool.schema)], required: ["sessionId", "do"]), tier: .read)
        let start = try BackendMCPTool(id: "sessions.start_agent", wireName: "sessions_start_agent",
            description: "Start a session with provider (claude, codex, gemini) or a saved agent (id or name), with its own AI, account, settings and seat. Each AI job is a fresh chat; use sessions_conversations for a named brief. The caller's project access applies. Read permission requests and restart handles with sessions_conversations events; answer requests there.",
            inputSchema: schema([("agent", string), ("provider", string.setting("enum", .array(["claude", "codex", "gemini"].map(NativeRPCValue.string)))),
                ("permissionMode", string), ("cwd", string), ("projectId", string),
                ("mode", string.setting("enum", .array([.string("chat"), .string("terminal")])))], required: ["cwd"]), tier: .act)
        var definitions = [chat, start].map { spec in
            BackendDeckToolsDefinition(spec: spec, title: spec.description) { caller, args in
                await BackendDeckToolsSupport.reply {
                    let resolved = try await gate.authority.resolve(caller)
                    let verb = args["do"].string ?? "", requestedID = args["sessionId"].string ?? ""
                    // 30 Oct: a team job may be named by its AI's own conversation id; the job's session id is used.
                    let id = spec.id == start.id || requestedID == "hoot" ? requestedID : (try await NativeChatSessionLookup.jobID(requestedID, chats: chats, authority: gate.authority))
                    if spec.id == start.id {
                        guard resolved.caller.kind != .remote else {
                            throw NativeRPCError(code: "not-granted", message: "Ask Hoot to start a saved agent's session.")
                        }
                        guard args["mode"].string != "terminal" else { throw NativeRPCError.invalidArguments("AI-to-AI jobs run in chat. A person can choose Terminal in New session.") }
                        let cwd = try args["cwd"].requireString("cwd", nonempty: true)
                        _ = try await gate.authority.knownFolder(cwd, native: caller)
                        try BackendDeckCoreCatalogueBuiltins.requireExistingFolder(cwd)
                        try BackendAgentStartSelection.requireSafeFolder(cwd, storageRoot: storageRoot, workspaceFolders: await workspaces?.liveFolders() ?? [])
                        try BackendDeckCoreCatalogueBuiltins.requireStartRoom(cwd: cwd, sessions: await runtime.sessions(caller), startedByCaller: resolved.startedByCopilot)
                        try await gate.authorize(caller, .act, "Start a session as the saved agent", true)
                        // The saved record is read by the same app-only channel used by New session; caller identity
                        // and the folder were checked above before entering that local channel.
                        let saved = try await registry.invoke("tasks:state", context: gate.authority.localContext(), arguments: [])
                        let choice = try BackendAgentStartSelection(arguments: args, agents: saved["agents"].elements ?? [])
                        let agent = choice.agent ?? .object([])
                        let sender = await lifecycle.conversationSender(resolved.caller)
                        // #160: filed under the project of the folder it works in, not the agent's home project.
                        var input = try choice.input(folder: cwd,
                            projectID: args["projectId"].string ?? PROJProjects.resolve(projectID: nil, folder: cwd), specs: specs)
                        input.origin = .copilot
                        input.teamJob = .init(fromID: sender.id, fromName: sender.name,
                            agentID: choice.id, agentName: choice.name, title: "Conversation")
                        input.teamJob?.starterSessionID = resolved.caller.sessionID
                        // 30 Oct: the seat's account (or the first signed-in one in the person's order), never a signed-out login.
                        let provider = choice.provider
                        let account = try await NativeTeamJobAccounts(sessions: sessions, context: { try gate.authority.localContext() })
                            .pick(agent: agent, provider: provider, folder: cwd, requested: nil)
                        if let account { input.profileId = account.id }
                        let authorized = try NativeTeamChatStartPolicy.authorized(input, callID: resolved.callID)
                        let meta = try await lifecycle.create(authorized, context: .init(rememberTab: false, fromAI: true), holdOnFailure: false)
                        let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
                        if let id = value["id"].string { resolved.noteStarted(id) }
                        await NativeButtonActions.openQuietly(value)
                        await gate.noteResult(caller, .object([.init("sessionId", value["id"])]))
                        return .value(value.setting("account", account?.wire ?? .null)
                            .setting("events", .object([.init("tool", .string("sessions_conversations")), .init("do", .string("events"))])))
                    }
                    let operation = try SessionChatToolPolicy.operation(verb)
                    if operation.isPanel {
                        let direction = try operation.direction(args)
                        let name: String
                        if id == "hoot" {
                            guard resolved.caller.kind == .local, caller.sessionID.isEmpty || caller.sessionID != hootRuntime?.structuredChat?.conversationID else {
                                throw NativeRPCError(code: "access-denied", message: "This draft belongs to the Mac's owner.")
                            }
                            name = "Hoot"
                        } else {
                            let meta = try await NativeChatSessionLookup.require(id, caller: caller, gate: gate, chats: chats)
                            guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }
                            name = TerminalAgent.name(meta.provider)
                        }
                        let change = try operation.changes(args)
                        if let refusal = try operation.refusal(args, local: resolved.caller.kind == .local) {
                            throw NativeRPCError(code: "not-granted", message: refusal)
                        }
                        // U11 (#22): a file an AI attaches must sit inside that caller's own file grants (the same
                        // filesystem authority sessions_chat_diffs uses), and the owner is asked about the real action.
                        var requestedPaths = args["paths"].elements?.compactMap(\.string) ?? []
                        if verb == "attachments", ["add", "send"].contains(direction), !requestedPaths.isEmpty {
                            requestedPaths = try await NativeGrantedFiles.paths(requestedPaths, authority: fileAuthority, context: gate.authority.rpc(caller))
                        }
                        let attachPaths = requestedPaths
                        let sentence: String
                        if verb == "attachments", ["add", "send"].contains(direction) {
                            let names = attachPaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
                            sentence = direction == "add" ? "Attach \(names) to this chat"
                                : names.isEmpty ? "Send this chat's message and its attached files to \(name)" : "Send \(names) to \(name) in this chat"
                        } else { sentence = "Read or navigate this chat" }
                        try await gate.authorize(caller, change ? .act : .read, sentence, change)
                        if verb == "attachments", direction == "send", let text = args["text"].string, !attachPaths.isEmpty {
                            let sender = await lifecycle.conversationSender(resolved.caller)
                            let receipt = try await Task { @MainActor in
                                let model = NativeHootChatModel.queueOwner(id) ?? NativeHootChatModel.forSession(id, name: name)
                                await model.start()
                                let queued = try await model.queueCapture(text: text, paths: attachPaths,
                                    source: .object([.init("kind", .string("capture")), .init("senderName", .string(sender.name))]))
                                return model.attachmentLimits.wire.setting("queuedId", .string(queued)).setting("accepted", .bool(true))
                            }.value
                            return .value(receipt)
                        }
                        let result = try await Task { @MainActor in
                            let model = NativeHootChatModel.queueOwner(id) ?? NativeHootChatModel.forSession(id, name: name)
                            await model.start()
                            if verb == "voice" { return try await model.voiceTool(direction, request: args["request"].string) }
                            if verb == "routines" { return try await model.routineTool(direction, request: args["request"].string, text: args["text"].string) }
                            if verb == "goals" { return try model.goalTool(direction, request: args["request"].string) }
                            if verb == "editor-context" {
                                let revision = try BackendHootChatChannels.integer(args["seenSequence"], maximum: Int.max - 1)
                                return try model.editorContextTool(direction, request: args["request"].string, mode: args["text"].string, revision: revision)
                            }
                            if verb == "side" { return try model.sideTool(direction, request: args["request"].string, text: args["text"].string) }
                            if verb == "review" { return try model.reviewTool(direction, request: args["request"].string, text: args["text"].string) }
                            if verb == "limits" { return try await model.limitsTool(direction) }
                            if verb == "context" {
                                if direction != "read", !model.source.isHoot { throw NativeRPCError.invalidArguments("This context popover belongs to Hoot. Ordinary Chat exposes the same reading in its existing session header.") }
                                if direction != "read" { model.chatContextVisible = direction == "open" }
                                return model.chatContextState
                            }
                            if verb == "diagnostics" { return try model.diagnosticTool(direction, request: args["request"].string, query: args["query"].string) }
                            if verb == "account" { return try await model.accountTool(direction, request: args["request"].string) }
                            if verb == "artifacts" { return try model.artifactTool(direction, request: args["request"].string, query: args["query"].string) }
                            if verb == "connections" { return try await model.connectionTool(direction, request: args["request"].string) }
                            if verb == "skills" { return try await model.skillTool(direction, request: args["request"].string) }
                            if verb == "sources" { return try await model.sourceTool(direction, request: args["request"].string) }
                            if verb == "detail" { return try model.detailTool(direction, query: args["query"].string, recordID: args["request"].string) }
                            if verb == "shortcuts" {
                                if direction != "read" { model.chatShortcutsVisible = direction == "open" }
                                return NativeChatShortcuts.wire
                            }
                            if verb == "export" { return try model.transcriptExport(copy: direction == "copy") }
                            if verb == "draft" {
                                if let text = args["text"].string { try model.setDraftText(text) }
                                return model.composerDraft.wire
                            }
                            if verb == "attachments" { return try model.attachmentTool(direction, paths: attachPaths) }
                            if verb == "recovery" { return try model.recover(direction) }
                            if verb == "children" {
                                return direction == "read" ? .array(model.childTasks) : try await model.stopChild(args["request"].requireString("task ID", nonempty: true))
                            }
                            if verb == "find" {
                                if change { model.findChat(direction, query: args["query"].string) }
                                return model.findState
                            }
                            if direction == "insert" { try model.insertPrompt(args["request"].requireString("prompt id", nonempty: true)) }
                            let handled = direction == "read" || direction == "insert" || model.recallPrompt(previous: direction == "previous")
                            return model.promptSearchState(args["query"].string ?? "").setting("handled", .bool(handled))
                        }.value
                        await gate.noteResult(caller, .object([.init("sessionId", .string(id)), .init("action", .string("history"))]))
                        return .value(result)
                    }
                    let meta = try await NativeChatSessionLookup.require(id, caller: caller, gate: gate, chats: chats, message: verb == "say")
                    let change = try operation.changes(args)
                    if verb != "answer" {
                        try await gate.authorize(caller, change ? .act : .read, change ? "Change this chat session" : "Read this chat session",
                            change && (!resolved.startedByCopilot(id) || !args["options"].isNullish))
                    }
                    let value: NativeRPCValue
                    switch verb {
                    case "read":
                        let seen = try BackendHootChatChannels.integer(args["seenSequence"], maximum: Int.max - 1)
                        let snapshot = try await chats.read(id, cursor: nil, limit: 500, seen: seen, conversation: args["conversationId"].string)
                        let events = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
                        let references = await MainActor.run { NativeHootChatModel.queueOwner(id)?.composerDraft.activeMentions.filter(\.isReference).map(\.wire) ?? [] }
                        var details = snapshot.setting("activity", ChatWorkingState.read(snapshot, events: events).wire())
                        let progress = BackendChatTodos.progress(events, children: details["children"].elements)
                        let complete = snapshot["hasMore"].bool != true && (events.first?.sequence ?? 1) <= 1
                        let steps = complete ? progress.rows : details["todos"].elements ?? progress.rows
                        details = details.setting("todos", .array(steps)).setting("taskProgress", progress.wire.setting("steps", .array(steps)))
                        if (details["thoughts"].elements ?? []).isEmpty { details = details.setting("thoughts", .array(BackendChatThoughts.summaries(events))) }
                        let diffs = BackendChatDiffs.cards(HootChatProjection.rows(events)).map(\.wire)
                        value = details.setting("sessionId", .string(id)).setting("draftReferences", .array(references)).setting("diffs", .array(diffs))
                    case "say":
                        let text = try args["text"].requireString("text", nonempty: true)
                        let source = resolved.caller
                        let callerID = [source.kind.rawValue, source.deviceID ?? "", source.keyID ?? "", source.sessionID ?? "", source.machineID ?? ""]
                            .map { "\($0.utf8.count):" + $0 }.joined()
                        let messageID = BackendChatRetryIdentity.messageID(args["clientMessageId"].string,
                            caller: callerID, conversation: id, text: text, frame: args)
                        let wanted = args["references"].elements ?? []
                        if wanted.isEmpty { value = try await BackendSessionDirectory.say(id, text: text, chats: chats, rows: gate.authority.sessionViews(), clientMessageID: messageID,
                            readTarget: { _ = try await gate.authority.requireSession(id, native: caller) }) }
                        else {
                            guard let referenceFiles else { throw NativeRPCError(code: "unavailable", message: "Project file context is not ready.") }
                            let rpc = try await gate.authority.rpc(caller)
                            let references = try await BackendChatReferences.read(wanted, root: meta.cwd, service: referenceFiles, context: rpc)
                            let sender = await lifecycle.conversationSender(resolved.caller)
                            let context = NativeRPCValue.object([.init("files", .array(references)), .init("source", .object([.init("kind", .string("agent")), .init("title", .string("Message from " + sender.name)), .init("sessionId", .string(caller.sessionID))]))])
                            value = try await BackendSessionDirectory.say(id, text: text, chats: chats, rows: gate.authority.sessionViews(), context: context, clientMessageID: messageID,
                            readTarget: { _ = try await gate.authority.requireSession(id, native: caller) })
                        }
                    case "files":
                        guard let referenceFiles else { throw NativeRPCError(code: "unavailable", message: "Project file search is not ready.") }
                        let rpc = try await gate.authority.rpc(caller)
                        let result = try await referenceFiles.projectFiles(root: meta.cwd, context: rpc, home: NSHomeDirectory())
                        value = .array(BackendChatReferences.candidates(result["files"].elements?.compactMap(\.string) ?? [], query: args["text"].string ?? ""))
                    case "mention":
                        guard meta.chat == true, let referenceFiles else { throw NativeRPCError.invalidArguments("Choose a Chat session with a project.") }
                        let path = try BackendChatReferences.relative(args["path"].requireString("path", nonempty: true))
                        let kind = args["kind"].string ?? "file"
                        let rpc = try await gate.authority.rpc(caller)
                        _ = try await BackendChatReferences.read([.object([.init("path", .string(path)), .init("kind", .string(kind))])], root: meta.cwd, service: referenceFiles, context: rpc)
                        value = try await Task { @MainActor in
                            let model = NativeHootChatModel.forSession(id, name: TerminalAgent.name(meta.provider))
                            await model.start()
                            return try model.addReference(path: path, kind: kind, root: meta.cwd)
                        }.value
                    case "stop":
                        await MainActor.run { NativeHootChatModel.queueOwner(id)?.holdQueuedMessages("Stopped. Review before sending this queued message.") }
                        value = try await chats.stopAnswer(id)
                    case "stop-job":
                        try await chats.finishJob(id, result: "Stopped", failed: true)
                        value = try await chats.read(id, cursor: nil, limit: 500)
                    case "answer":
                        guard let allowed = args["allowed"].bool else { throw NativeRPCError.invalidArguments("Say whether the request is allowed.") }
                        let requestID = try args["request"].requireString("request", nonempty: true)
                        let answers = try args["answers"].isNullish ? NativeRPCValue.object([]) : args["answers"].requireObject("answers")
                        let authorizedAnswers = try await NativeChatApprovalAuthority.authorize(requestID: requestID, allowed: allowed, answers: answers,
                            ownerMustAnswer: !resolved.startedByCopilot(id) || !args["options"].isNullish, caller: caller,
                            read: { try await chats.read(id, cursor: nil, limit: 1) }, authorize: gate.authorize)
                        value = try await chats.answer(id, request: requestID, allowed: allowed, answers: authorizedAnswers)
                    case "options": value = try await BackendSessionChatOptionsTool.invoke(chats, id: id, patch: args["options"])
                    case "turn": value = BackendSessionChats.wire(try await chats.turn(id))
                    default: throw NativeRPCError.invalidArguments("Unknown chat action.")
                    }
                    await gate.noteResult(caller, .object([.init("sessionId", .string(id)), .init("action", .string(verb))]))
                    return .value(value)
                }
            }
        }
        definitions.append(try browserCaptureFeedbackTool(gate: gate))
        definitions.append(try passiveChatWindowTool(gate: gate))
        let queue = try BackendMCPTool(id: "chats.queue", wireName: "chats_queue",
            description: "List, queue, edit, remove, reorder or Send now a pending message in a chat session or Hoot (sessionId hoot). The pinned outbox survives app restart. Reorder moves id before beforeId, or to the end when omitted. Send now uses native Codex steering where supported, or interrupt-and-send for Claude/Gemini. A missing helper capability keeps the message queued. Changes use the caller's existing approval and session access rules.",
            inputSchema: schema([("sessionId", string), ("do", string.setting("enum", .array(["list", "queue", "edit", "remove", "reorder", "send-now"].map(NativeRPCValue.string)))),
                ("id", string), ("beforeId", string), ("text", string.setting("maxLength", .number(262_144)))], required: ["sessionId", "do"]), tier: .read)
        definitions.append(BackendDeckToolsDefinition(spec: queue, title: "Queued chat messages") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                let target = try args["sessionId"].requireString("sessionId", nonempty: true)
                let action = try args["do"].requireString("do", nonempty: true)
                let name: String
                if target == "hoot" {
                    guard resolved.caller.kind == .local, caller.sessionID.isEmpty || caller.sessionID != hootRuntime?.structuredChat?.conversationID else {
                        throw NativeRPCError(code: "access-denied", message: "This Hoot conversation belongs to the Mac's owner; Hoot cannot queue messages to itself.")
                    }
                    name = "Hoot"
                } else {
                    let meta = try await gate.authority.requireSession(target, native: caller)
                    guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }
                    name = ["claude": "Claude Code", "codex": "Codex", "gemini": "Gemini"][meta.provider] ?? meta.provider
                }
                let change = action != "list"
                try await gate.authorize(caller, change ? .act : .read, change ? "Change a queued chat message" : "Read queued chat messages", change)
                let sender = await lifecycle.conversationSender(resolved.caller)
                let context = NativeRPCValue.object([.init("source", .object([
                    .init("kind", .string("agent")), .init("title", .string("Message from " + sender.name)),
                    .init("sessionId", .string(caller.sessionID))]))])
                let value: NativeRPCValue = try await Task { @MainActor in
                    let found = NativeHootChatModel.queueOwner(target)
                    let model = found ?? NativeHootChatModel.forSession(target, name: name)
                    if action == "queue" { await model.start() }
                    return try await model.queueTool(action, id: args["id"].string, text: args["text"].string, before: args["beforeId"].string, context: context)
                }.value
                await gate.noteResult(caller, .object([.init("sessionId", .string(target)), .init("action", .string(action))]))
                return .value(value)
            }
        })
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        let restart = try BackendMCPTool(id: "developer.session_host_restart", wireName: "developer_session_host_restart",
            description: "The explicitly agreed one-time local session-helper upgrade. Requires every session idle; uses saved-conversation recovery; refuses a second request in this app instance.",
            inputSchema: schema([("inspect", .object([.init("type", .string("boolean"))]))], required: []), tier: .act, advertised: false)
        definitions.append(BackendDeckToolsDefinition(spec: restart, title: "Apply agreed session-helper upgrade") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                guard resolved.caller.kind != .remote else { throw BackendHOSTFailure.authentication }
                try await gate.authorize(caller, .act, "Apply the agreed one-time session-helper upgrade", false)
                guard let managed = await MainActor.run(body: { self.hostManaged }) else { throw BackendHOSTFailure.unavailable }
                if args["inspect"].bool == true { return .value(try await managed.restartState()) }
                return .value(try await managed.restartOnce())
            }
        })
        #endif
        return definitions + (try chatProviderToolDefinitions(gate: gate))
    }

    func installSessionChats() async throws {
        guard let sessions, let authority else { throw NativeRPCError(code: "composition-incomplete", message: "Chat sessions need the sessions first.") }
        let registry = root.registry
        let chats = BackendSessionChats(manager: sessions.manager,
            directory: root.dataRoot.appendingPathComponent("session-chats", isDirectory: true),
            publish: { [weak self] id, snapshot in
                authority.note(.status(sessionID: id, status: BackendSessionDirectory.status(snapshot), source: "chat"))
                // What is said in a session belongs to the person's own window, like its terminal output.
                try? await registry.publish(BackendSessionChats.event, arguments: [.string(id), snapshot], ownerID: BackendCompositionRoot.appOwnerID)
                // And to a paired phone watching this chat (it reads the conversation again through its own gates).
                if let phone = await MainActor.run(body: { self?.phoneChats }) { await phone.published(id) }
            }, noteConversation: { [ledger = sessions.ledger] id, conversation in
                // The saved launch resumes the CLI's own conversation after a restart.
                try? await ledger.updateConversation(id, conversationID: conversation)
            }, diary: { job, snapshot in
                guard DeckMemory.isReady else { return }
                let owner = DeckMemorySessionCenter.shared?.owner(sessionID: job.session.id)
                let seat = owner.flatMap { BackendAGTMemoryOwners.memoryOwner($0) } ?? .project(job.session.resolvedProjectID)
                _ = try await DeckMemory.store.appendDiary(BackendTeamChatDiary.drafts(job, snapshot: snapshot, owner: seat))
            }, usageReport: { id in
                // The existing header usage owner; read its account report, never start a second poller.
                try await registry.invoke("usage:read", context: authority.localContext(), arguments: [.string(id)])
            })
        sessionChats = chats
        await chats.setEarlierEngineMove { [state = root.state, launcher = sessions.launcher, joins] id in
            let saved = try BackendSessionSaved(await state.ledgerGet(id))
            let boundary: BackendDeviceBoundary?
            if let device = saved.deviceID { boundary = try await joins.phoneStartBoundary(deviceID: device, folder: saved.cwd) }
            else { boundary = nil }
            let snapshot = try await chats.read(id, cursor: nil, limit: 1)
            let conversation = try snapshot["providerConversationId"].requireString("saved AI conversation", nonempty: true)
            var input = saved.input(resume: true, conversationID: conversation, replaces: id)
            input.chat = true
            _ = try await launcher.create(input, context: .init(deviceBoundary: boundary, rememberTab: false), chatMigration: { input, spawn in
                try await chats.moveEarlierChat(id, input: input, spawn: spawn)
            })
        }

        await sessions.lifecycle.setChatOwners(typing: { id, data in try await chats.type(id, data: data) },
                                               removal: { meta in try await chats.removeSession(meta) })
        // 22 Oct (Asad, "remove this 128 limit"): a finished team job leaves the session list, the same close as
        // "Close" (its record and history stay; Open brings it back). One the person is looking at stays until they close it.
        // One close at a time (Reviewer, finding 5); a refused close is tried again at the next sweep.
        await chats.setFinishedJobRetirement { [lifecycle = sessions.lifecycle] id in
            guard await MainActor.run(body: { !AppModel.shared.isTerminating && !NativeSessionsOnScreen.ids().contains(id) }) else { return }
            try await lifecycle.close(sessionID: id)
        }
        await NativeSessionRunaway.watch(sessions.lifecycle)
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        if let client = hostManaged?.managedClient {
            if client.hello.chatService == 1 {
                try await chats.useHost(client)
                await sessions.setChatHost(client)
                await sessions.launch.setChatSurvival(true)
                await sessions.launcher.setHostedChatAttachment { meta in try await chats.adoptHostedSession(meta) }
                NativeCompositionRoot.note("Chat sessions are kept by the session helper and reconnect after app restarts.")
            } else {
                NativeCompositionRoot.note("The running session helper is older: chats run in the app until a later install. The helper was left running.")
            }
        }
        #endif
        try await chats.restoreJobHistory()
        // The ones a running helper still lists from before this start leave after the page shows its tabs (pageReady).
        await sessions.launcher.setLocalChatPreference { key in await chats.prefersLocalEngine(tabKey: key) }
        await sessions.launcher.setChatDispatch { input, spawn in try await chats.launch(input, spawn: spawn) }
        // Like Hoot's CLI: an app-owned AI holding an account ends before the sessions are handed to the helper.
        BackendHOSTKeepDetachPreparation.register("session-chats") { await chats.endAllForQuit() }
        let owner = Self.sessionChatsOwner
        let local: NativeChannelRegistry.Policy = { try authority.requireLocalUI($0) }
        try await registry.register("session:chat:provider", ownerID: owner, policy: local) { _, args in
            guard args.count == 3 else { throw NativeRPCError.invalidArguments("Expected session, feature and arguments.") }
            let id = try await self.providerSessionID(SessionChatArguments.id(args)), operation = try args[1].requireString("feature", nonempty: true)
            let result = try await chats.providerFeature(id, operation: operation, arguments: args[2])
            return operation == "capabilities" ? result.setting("serviceSessionId", .string(id)) : result
        }
        try await registry.register("hoot:chat:provider", ownerID: owner, policy: local) { _, args in
            guard args.count == 2 else { throw NativeRPCError.invalidArguments("Expected feature and arguments.") }
            let id = try await self.providerSessionID("hoot"), operation = try args[0].requireString("feature", nonempty: true)
            let result = try await chats.providerFeature(id, operation: operation, arguments: args[1])
            return operation == "capabilities" ? result.setting("serviceSessionId", .string(id)) : result
        }
        try await registry.register("session:chat:diffs", ownerID: owner, policy: local) { context, args in
            guard args.count == 3 else { throw NativeRPCError.invalidArguments("Expected session, diff action and arguments.") }
            return try await self.chatDiffFeature(SessionChatArguments.id(args), action: args[1].requireString("action", nonempty: true), arguments: args[2], context: context)
        }
        try await registry.register("session:chat:terminal", ownerID: owner, policy: local) { _, args in
            guard args.count == 3 else { throw NativeRPCError.invalidArguments("Expected session, terminal action and arguments.") }
            return try await self.chatOwnedTerminalFeature(SessionChatArguments.id(args), operation: args[1].requireString("terminal action", nonempty: true), arguments: args[2], origin: .nativeUser)
        }
        try await registry.register("session:chat:children", ownerID: owner, policy: local) { context, args in
            guard args.count == 3 else { throw NativeRPCError.invalidArguments("Expected parent session, child action and arguments.") }
            return try await self.chatChildFeature(SessionChatArguments.id(args), action: args[1].requireString("action", nonempty: true), arguments: args[2], context: context)
        }
        try await registry.register("session:chat:fork", ownerID: owner, policy: local) { context, args in
            guard args.count == 3 else { throw NativeRPCError.invalidArguments("Expected source session, fork action and arguments.") }
            return try await self.chatForkFeature(SessionChatArguments.id(args), action: args[1].requireString("action", nonempty: true), arguments: args[2], context: context)
        }
        try await registry.register("session:chat:read", ownerID: owner, policy: local) { _, args in
            let cursor = try BackendHootChatChannels.integer(args.count > 1 ? args[1] : .null, maximum: Int.max - 1)
            let limit = try BackendHootChatChannels.integer(args.count > 2 ? args[2] : .null, maximum: 500) ?? 200
            let seen = try BackendHootChatChannels.integer(args.count > 3 ? args[3] : .null, maximum: Int.max - 1)
            return try await chats.read(try SessionChatArguments.id(args), cursor: cursor, limit: limit, seen: seen,
                conversation: args.count > 4 ? args[4].string : nil)
        }
        try await registry.register("session:chat:draft", ownerID: owner, policy: local) { _, args in
            guard args.count == 2 else { throw NativeRPCError.invalidArguments("Expected the session and its draft.") }
            try await chats.setDraft(try SessionChatArguments.id(args), text: args[1].requireString("draft"))
            return .bool(true)
        }
        for channel in ["session:chat:rewind", "session:chat:undo-rewind", "session:chat:handoff"] {
            try await registry.register(channel, ownerID: owner, policy: local) { _, args in
                let id = try SessionChatArguments.id(args)
                if channel == "session:chat:undo-rewind" { return try await chats.rewind(id, sequence: nil) }
                guard args.count == 2, let sequence = try BackendHootChatChannels.integer(args[1], maximum: Int.max - 1), sequence > 0 else { throw NativeRPCError.invalidArguments("Choose a message in this chat.") }
                return channel == "session:chat:handoff" ? try await chats.handoffPrompt(id, sequence: sequence) : try await chats.rewind(id, sequence: sequence)
            }
        }
        try await registry.register("session:chat:say", ownerID: owner, policy: local) { _, args in
            guard (2...5).contains(args.count) else { throw NativeRPCError.invalidArguments("Expected the session, the message, optional attachments and optional context.") }
            return try await chats.say(try SessionChatArguments.id(args), text: try args[1].requireString("message"),
                attachments: args.count > 2 ? try args[2].requireArray("attachments") : [],
                context: args.count > 3 ? args[3] : .object([]), clientMessageID: args.count > 4 ? args[4].string : nil)
        }
        try await registry.register("session:chat:queued", ownerID: owner, policy: local) { _, args in
            guard args.count == 2, let count = try BackendHootChatChannels.integer(args[1], maximum: 1_000_000) else { throw NativeRPCError.invalidArguments("Expected session and queued message count.") }
            try await chats.setQueuedCount(try SessionChatArguments.id(args), count: count)
            return .bool(true)
        }
        try await registry.register("session:chat:steer", ownerID: owner, policy: local) { _, args in
            guard (2...5).contains(args.count) else { throw NativeRPCError.invalidArguments("Expected the session, message, optional attachments and optional context.") }
            return try await chats.steer(try SessionChatArguments.id(args), text: args[1].requireString("message"),
                attachments: args.count > 2 ? args[2].requireArray("attachments") : [], context: args.count > 3 ? args[3] : .object([]), clientMessageID: args.count > 4 ? args[4].string : nil)
        }
        try await registry.register("session:chat:stop", ownerID: owner, policy: local) { _, args in try await chats.stopAnswer(try SessionChatArguments.id(args)) }
        try await registry.register("session:chat:child-stop", ownerID: owner, policy: local) { _, args in
            guard args.count == 2 else { throw NativeRPCError.invalidArguments("Choose a session and one task.") }
            return try await chats.stopChild(SessionChatArguments.id(args), task: args[1].requireString("taskId", nonempty: true))
        }
        try await registry.register("session:chat:answer", ownerID: owner, policy: local) { _, args in
            guard (3...4).contains(args.count), let allowed = args[2].bool else { throw NativeRPCError.invalidArguments("Expected the session, the request, allow or deny and optional answers.") }
            return try await chats.answer(try SessionChatArguments.id(args), request: try args[1].requireString("requestId", nonempty: true), allowed: allowed,
                answers: args.count > 3 ? try args[3].requireObject("answers") : .object([]))
        }
        try await registry.register("session:chat:ensure", ownerID: owner, policy: local) { _, args in
            let session = try SessionChatArguments.id(args)
            try await chats.ensure(session)
            return try await chats.read(session, cursor: nil, limit: 500)
        }
        try await registry.register("session:chat:options", ownerID: owner, policy: local) { _, args in
            let session = try SessionChatArguments.id(args)
            guard args.count <= 2 else { throw NativeRPCError.invalidArguments("Expected the session and an optional change.") }
            if args.count == 2, !args[1].isNullish { return try await chats.setOptions(session, try args[1].requireObject("options")) }
            return try await chats.options(session)
        }
        try await registry.register("session:chat:turn", ownerID: owner, policy: local) { _, args in
            BackendSessionChats.wire(try await chats.turn(try SessionChatArguments.id(args)))
        }
        let state = root.state
        try await registry.register("session:agent-owners", ownerID: owner, policy: local) { _, _ in
            var fields: [NativeRPCValue.Field] = []
            let entries = (try? await state.ledgerEntries()) ?? []
            for entry in entries {
                if let profile = entry.saved["agentProfileID"].string,
                   profile.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil {
                    fields.append(.init(entry.id, .string(profile)))
                }
            }
            return .object(fields)
        }
        try await registry.register("session:team:list", ownerID: owner, policy: local) { _, args in
            .array(await chats.conversationCatalogue(project: args.first?.string, agent: args.count > 1 ? args[1].string : nil,
                state: args.count > 2 ? args[2].string : nil))
        }
        try await registry.register("session:team:open", ownerID: owner, policy: local) { _, args in
            let meta = try await chats.openJobHistory(try SessionChatArguments.id(args))
            let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
            await MainActor.run {
                if let row = value.foundation as? [String: Any] { AppModel.shared.buttonActions.openedHistory(row) }
            }
            try await registry.publish("session:created", arguments: [value], ownerID: BackendCompositionRoot.appOwnerID)
            return value
        }
        try await registry.register("session:team:resume", ownerID: owner, policy: local) { _, args in
            let id = try SessionChatArguments.id(args)
            let input = try await chats.jobResumeInput(id)
            let meta = try await sessions.lifecycle.create(input, context: .init(rememberTab: false, fromWindow: true), holdOnFailure: false)
            _ = try await chats.continueResumedJob(meta.id)
            let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
            await NativeButtonActions.openQuietly(value)
            return value
        }
        try await registry.register("session:team:delete", ownerID: owner, policy: local) { _, args in
            try await chats.deleteJobHistory(try SessionChatArguments.id(args))
            return .bool(true)
        }
        try await registry.register("session:team:stop", ownerID: owner, policy: local) { _, args in
            try await chats.finishJob(SessionChatArguments.id(args), result: "Stopped", failed: true)
            return .bool(true)
        }
        // The New session dialog's Agent: a session that runs AS a saved agent (its seat, memory, AI and account).
        let lifecycle = sessions.lifecycle
        let agentSpecs = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        try await registry.register("session:start-agent", ownerID: owner, policy: local) { _, args in
            guard (1...6).contains(args.count) else { throw NativeRPCError.invalidArguments("Expected the agent, its project, the folder, chat or not, the session permission choice and the account picked for this session.") }
            let agentID = try args[0].requireString("agent", nonempty: true)
            let projectID = args.count > 1 ? args[1].string.flatMap { $0.isEmpty ? nil : $0 } : nil
            let saved = try await registry.invoke("tasks:state", context: try authority.localContext(), arguments: [])
            guard let agent = saved["agents"].elements?.first(where: { $0["id"].string == agentID }) else {
                throw NativeRPCError(code: "not-found", message: "That agent is no longer saved. Pick it again.")
            }
            var folder = args.count > 2 ? args[2].string : nil
            if folder?.isEmpty != false, let projectID {
                let projects = try await registry.invoke("project-registry:list", context: try authority.localContext(), arguments: [])
                folder = projects["projects"].elements?.first { $0["id"].string == projectID }?["folders"].elements?.first?.string
            }
            guard let folder, !folder.isEmpty else { throw NativeRPCError.invalidArguments("Choose the agent's project (or a folder) first.") }
            var input = try BackendAgentSessionInput.make(agent: agent, folder: folder, projectID: projectID,
                                                          chat: args.count > 3 ? args[3].bool : nil, specs: agentSpecs)
            if args.count > 4, let permission = args[4].string {
                guard AGSCapabilities.permissionModes(provider: input.provider ?? "claude").contains(permission) else {
                    throw NativeRPCError.invalidArguments("That permission mode does not belong to the selected AI.")
                }
                input.permissionMode = permission
            }
            // 10 Nov (Asad: the account picked in New session is the account the session starts on): an explicit pick
            // wins over the agent's own saved account; no pick keeps the agent's.
            if args.count > 5, let picked = args[5].string, !picked.isEmpty { input.profileId = picked }
            let meta = try await lifecycle.create(input, context: BackendLaunchContext(rememberTab: true, fromWindow: true))
            return try NativeRPCValue.parseJSON(JSONEncoder().encode(meta)).setting("agentProfileID", .string(agentID))
        }
        try await root.retain(.init(name: "session-chats", domains: ["session-chats"], ownerID: owner,
            invokes: Set(BackendSessionChats.channels + ["session:start-agent", "session:agent-owners", "session:team:list", "session:team:open", "session:team:delete", "session:team:stop", "session:team:resume"]), events: [BackendSessionChats.event],
            stop: { await registry.removeOwner(owner) }))
    }
}

/// 30 Oct (Decker: "There is no session with that id" for a team job): a finished team job has left the live list
/// (it reopens on demand), and a lead often has the AI's own conversation id. The live session comes first; then the
/// team job by its id or its AI's conversation id, under the same project boundary as its history.
enum NativeChatSessionLookup {
    static func require(_ id: String, caller: BackendMCPCallContext, gate: BackendCompositionDeckToolsGate,
                        chats: BackendSessionChats, message: Bool = false) async throws -> BackendSessionMeta {
        do { return try await gate.authority.requireSession(id, native: caller, message: message) }
        catch BackendSessionFailure.missingSession {
            guard let record = await chats.conversation(id) else { throw BackendSessionFailure.missingSession }
            try await gate.authority.requireHistorySession(record.session, native: caller)
            return record.session
        }
    }
    /// The team job whose AI conversation this is, else the id as given.
    static func jobID(_ id: String, chats: BackendSessionChats, authority: BackendCompositionAuthority) async throws -> String {
        if let row = try BackendSessionDirectory.resolve(id, rows: authority.sessionViews()), let canonical = row["id"].string { return canonical }
        guard !id.isEmpty, await chats.conversation(id) == nil,
              let record = await chats.conversations().first(where: { $0.session.agentSessionId == id }) else { return id }
        return record.session.id
    }
}
