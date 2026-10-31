import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func teamConversationToolDefinitions(gate: BackendCompositionDeckToolsGate,
                                         runtime: any BackendDeckToolsSessionsRuntime) throws -> [BackendDeckToolsDefinition] {
        guard let chats = sessionChats, let sessions else { return [] }
        let registry = root.registry, lifecycle = sessions.lifecycle, state = root.state
        let specs = try BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership)
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("do", string.setting("enum", .array(["list", "read", "start", "say", "stop", "turn", "answer", "open", "delete", "finish", "keep"].map(NativeRPCValue.string)))),
            .init("projectId", string), .init("agent", string), .init("state", string.setting("enum", .array([.string("open"), .string("finished")]))),
            .init("sessionId", string), .init("cwd", string), .init("title", string), .init("text", string), .init("request", string),
            .init("allowed", .object([.init("type", .string("boolean"))])), .init("answers", .object([.init("type", .string("object"))])),
            .init("seenSequence", .object([.init("type", .string("integer")), .init("minimum", .number(0))])),
            .init("conversationId", string),
            .init("cursor", .object([.init("type", .string("integer")), .init("minimum", .number(0))])),
            // 30 Oct (Decker): choose the account, model and effort up front; keep the job open past a turn's end.
            .init("account", string.setting("description", .string("start: the account (id or name) this job runs on. Left out: the seat's account, or the first signed-in one in your account order."))),
            .init("model", string.setting("description", .string("start: the model for this job instead of the agent's own."))),
            .init("effort", string.setting("description", .string("start: the effort for this job instead of the agent's own."))),
            .init("keepOpen", .object([.init("type", .string("boolean")), .init("description", .string("start or keep: the job stays open when a turn ends (for a seat that still has background work running); end it with finish or stop."))])),
            .init("result", string.setting("description", .string("finish: the job's result in one or two sentences."))),
            .init("limit", .object([.init("type", .string("integer")), .init("minimum", .number(1)), .init("maximum", .number(200)), .init("description", .string("list: most rows, default 50."))])),
            .init("offset", .object([.init("type", .string("integer")), .init("minimum", .number(0)), .init("description", .string("list: rows to skip, for the next page."))])),
            .init("full", .object([.init("type", .string("boolean")), .init("description", .string("list: the whole record of each row instead of the short one."))]))
        ])), .init("required", .array([.string("do")])), .init("additionalProperties", .bool(false))])
        let spec = try BackendMCPTool(id: "sessions.conversations", wireName: "sessions_conversations",
            description: "Team chats: list by project, agent (either side), open/finished (short rows, newest first, 50 a page: limit/offset; full for whole records); read any job's separate history (cursor 0 reads from the start); start a fresh job with a saved agent (id or name), title and text brief, optionally its account, model and effort, and keepOpen; say a follow-up while open; answer permission requests; read its turn; stop and keep history; finish with a result; keep (keepOpen) an open job; open history in the app; explicitly delete a finished history entry. A delivered answer closes the job and its process unless the job is kept open. The start answer says which account the job runs on and why. New work always starts a new job from its brief and Deck Memory.",
            inputSchema: schema, tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Team conversations") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                let action = try args["do"].requireString("action")
                if action == "list" {
                    try await gate.authorize(caller, .read, "List team conversations", false)
                    // 30 Oct (Decker): the whole records of every finished job came to 200K+ characters. Short rows, a page at a time.
                    let page = try NativeTeamChatListPage(args)
                    var visible: [BackendTeamChatRecord] = []
                    for row in await chats.conversations(project: args["projectId"].string, agent: args["agent"].string, state: args["state"].string) {
                        if (try? await gate.authority.requireHistorySession(row.session, native: caller)) != nil { visible.append(row) }
                    }
                    var rows: [NativeRPCValue] = []
                    for row in page.slice(visible) {
                        // 28 Oct (CPU): the unread the chat last reported, not a fresh read of every chat (`BackendChatUnreadCache`).
                        let entry = try await chats.unreadEntry(row.session.id)
                        rows.append((page.full ? row.wire : NativeTeamChatListPage.compact(row)).setting("unread", entry.unread))
                    }
                    return .value(page.wire(rows, total: visible.count))
                }
                if action == "start" {
                    try NativeTeamChatStartPolicy.requireDesktop(resolved.caller.kind)
                    let cwd = try args["cwd"].requireString("cwd", nonempty: true)
                    guard try await runtime.knownFolders(caller).contains(cwd) else { throw NativeRPCError.invalidArguments("Choose a project folder you can access.") }
                    let wanted = try args["agent"].requireString("agent", nonempty: true)
                    let title = try args["title"].requireString("title", nonempty: true)
                    let text = try args["text"].requireString("brief", nonempty: true)
                    try await gate.authorize(caller, .act, "Start this agent's job", true)
                    let saved = try await registry.invoke("tasks:state", context: gate.authority.localContext(), arguments: [])
                    // 30 Oct (Decker wrote "Shell & Design"): a saved agent by its id or its name.
                    guard let agent = NativeSavedAgentLookup.find(wanted, in: saved["agents"].elements ?? []), let id = agent["id"].string else {
                        let names = (saved["agents"].elements ?? []).filter { $0["status"].string != "archived" }.compactMap { $0["name"].string }.sorted()
                        throw NativeRPCError.invalidArguments("Choose a saved agent (by id or name): " + names.joined(separator: ", ") + ".")
                    }
                    let sender = await lifecycle.conversationSender(resolved.caller)
                    // #160: filed under the project of the folder it works in, not the agent's home project.
                    var input = try BackendAgentSessionInput.make(agent: agent, folder: cwd,
                        projectID: args["projectId"].string ?? PROJProjects.resolve(projectID: nil, folder: cwd), chat: true, specs: specs)
                    input.origin = .copilot
                    input.teamJob = .init(fromID: sender.id, fromName: sender.name,
                        agentID: id, agentName: agent["name"].string ?? id, title: title)
                    input.teamJob?.keepOpen = args["keepOpen"].bool == true ? true : nil
                    if let model = args["model"].string?.trimmingCharacters(in: .whitespaces), !model.isEmpty { input.model = model }
                    if let effort = args["effort"].string?.trimmingCharacters(in: .whitespaces), !effort.isEmpty { input.effort = effort }
                    // 30 Oct: the seat's assigned account (or the one named here); never a signed-out login.
                    let preferred = await state.getPreferences()["defaultProvider"].string ?? "claude"
                    let provider = input.provider ?? preferred
                    let account = try await NativeTeamJobAccounts(sessions: sessions, context: { try gate.authority.localContext() })
                        .pick(agent: agent, provider: provider, folder: cwd, requested: args["account"].string)
                    if let account { input.profileId = account.id }
                    let plan = await BackendAGTJobStart.shared?.plan(agent: agent, title: title, details: text)
                    let authorized = try NativeTeamChatStartPolicy.authorized(input, callID: resolved.callID)
                    // 30 Oct: finished jobs whose earlier close failed (helper busy) leave the session list before a new one starts.
                    await chats.retireFinishedJobs()
                    let meta = try await lifecycle.create(authorized, context: .init(rememberTab: false, fromAI: true), holdOnFailure: false)
                    resolved.noteStarted(meta.id)
                    do { _ = try await chats.say(meta.id, text: text + (plan?.brief ?? "")) }
                    catch { try? await chats.finishJob(meta.id, result: error.localizedDescription, failed: true); throw error }
                    await gate.noteResult(caller, .object([.init("sessionId", .string(meta.id))]))
                    let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
                    await NativeButtonActions.openQuietly(value)
                    return .value(value.setting("account", account?.wire ?? .null).setting("keepOpen", .bool(input.teamJob?.keepOpen == true)))
                }
                // 30 Oct (Decker passed the job's id as conversationId, or the AI's own conversation id): any of them finds the job.
                guard let record = await NativeTeamChatJobLookup.find(args, chats: chats) else {
                    if args["sessionId"].isNullish, args["conversationId"].isNullish { throw NativeRPCError.invalidArguments("Pass the job's sessionId (sessions_conversations list gives it).") }
                    throw BackendSessionFailure.missingSession
                }
                let id = record.session.id
                try await gate.authority.requireHistorySession(record.session, native: caller)
                let change = ["say", "stop", "answer", "open", "delete", "finish", "keep"].contains(action)
                if action != "answer" {
                    try await gate.authorize(caller, change ? .act : .read, "Use this team conversation", action == "delete" || (change && !resolved.startedByCopilot(id)))
                }
                switch action {
                case "read":
                    let cursor = try BackendHootChatChannels.integer(args["cursor"], maximum: Int.max - 1)
                    let seen = try BackendHootChatChannels.integer(args["seenSequence"], maximum: Int.max - 1)
                    let conversation = args["conversationId"].string.flatMap { $0 == id || args["sessionId"].isNullish ? nil : $0 }
                    return .value(try await chats.read(id, cursor: cursor, limit: 500, seen: seen, conversation: conversation))
                case "say": return .value(try await chats.say(id, text: args["text"].requireString("text", nonempty: true)))
                case "stop": return .value(try await chats.stop(id))
                case "turn": return .value(BackendSessionChats.wire(try await chats.turn(id)))
                case "answer":
                    guard let allowed = args["allowed"].bool else { throw NativeRPCError.invalidArguments("Say whether to allow the request.") }
                    let requestID = try args["request"].requireString("request", nonempty: true)
                    let answers = try args["answers"].isNullish ? NativeRPCValue.object([]) : args["answers"].requireObject("answers")
                    let authorizedAnswers = try await NativeChatApprovalAuthority.authorize(requestID: requestID, allowed: allowed, answers: answers,
                        ownerMustAnswer: !resolved.startedByCopilot(id), caller: caller,
                        read: { try await chats.read(id, cursor: nil, limit: 1) }, authorize: gate.authorize)
                    return .value(try await chats.answer(id, request: requestID, allowed: allowed, answers: authorizedAnswers))
                case "delete":
                    try await chats.deleteJobHistory(id)
                    return .value(.bool(true))
                case "finish":
                    let result = try args["result"].requireString("result", nonempty: true)
                    try await chats.finishJob(id, result: result, failed: false)
                    return .value(await chats.conversation(id).map(NativeTeamChatListPage.compact) ?? .bool(true))
                case "keep":
                    try await chats.keepJobOpen(id, args["keepOpen"].bool ?? true)
                    return .value(await chats.conversation(id).map(NativeTeamChatListPage.compact) ?? .bool(true))
                case "open":
                    let meta = try await chats.openJobHistory(id)
                    let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
                    await MainActor.run {
                        if let row = value.foundation as? [String: Any] { AppModel.shared.buttonActions.openedHistory(row) }
                    }
                    try await registry.publish("session:created", arguments: [value], ownerID: BackendCompositionRoot.appOwnerID)
                    return .value(value)
                default: throw NativeRPCError.invalidArguments("Unknown conversation action.")
                }
            }
        }]
    }
}

/// Adopts Hoot's task runtime, including its existing fence/account/tool owner. No second CLI is started.
actor NativeHootTaskChatJobs {
    let chats: BackendSessionChats
    let registry: NativeChannelRegistry
    var sessions: [String: String] = [:]
    let agents: @Sendable () async -> [NativeRPCValue]
    init(chats: BackendSessionChats, registry: NativeChannelRegistry, agents: @escaping @Sendable () async -> [NativeRPCValue]) {
        self.chats = chats; self.registry = registry; self.agents = agents
    }
    func start(taskID: String, title: String, runtime: BackendCopilotSessionRuntime, task: BackendTaskRecord?) async throws -> BackendSessionMeta {
        let state = try await runtime.ensure()
        let folder = task?.project.hasPrefix("/") == true ? task!.project : state.folder.runningIn ?? "/"
        let from = BackendTeamChatSender.request(task?.value["requestedBy"].string ?? "tasks", agents: await agents())
        let meta = try await chats.exposeTaskRuntime(runtime, folder: folder, projectID: task?.value["projectId"].string,
            job: .init(fromID: from.id, fromName: from.name,
                agentID: "hoot", agentName: "Hoot", title: title, taskID: taskID))
        sessions[taskID] = meta.id
        try await registry.publish("session:created", arguments: [try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))], ownerID: BackendCompositionRoot.appOwnerID)
        return meta
    }
    func finish(taskID: String, result: BackendHootTaskResult) async {
        guard let id = sessions.removeValue(forKey: taskID) else { return }
        try? await chats.finishJob(id, result: result.problem ?? result.answer, failed: !result.finished)
    }
}

/// Phone starts keep their existing device boundary; this new agent start is desktop-only.
enum NativeTeamChatStartPolicy {
    /// Called only after this tool's caller, project and effect were checked. The saved-agent settings
    /// gate requires the same issued call identity as sessions.start, never one from tool arguments.
    static func authorized(_ input: BackendCreateSessionInput, callID: String) throws -> BackendCreateSessionInput {
        guard !callID.isEmpty else { throw NativeRPCError.invalidArguments("This agent launch needs its checked request.") }
        var input = input
        input.origin = .copilot
        input.originRunId = callID
        return input
    }
    static func requireDesktop(_ kind: BackendDeckCoreSecurityCaller.Kind) throws {
        guard kind != .remote else { throw NativeRPCError.invalidArguments("Start a saved agent's chat on the Mac. Phone support comes later.") }
    }
}

/// 30 Oct (Decker: a list of finished jobs came back at 200K+ characters): a page of short rows, newest first.
struct NativeTeamChatListPage {
    let limit: Int, offset: Int, full: Bool
    init(_ args: NativeRPCValue) throws {
        func integer(_ value: NativeRPCValue, _ fallback: Int, _ range: ClosedRange<Int>, _ name: String) throws -> Int {
            if value.isNullish { return fallback }
            guard let number = value.number, number.rounded(.towardZero) == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
                throw NativeRPCError.invalidArguments("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
            }
            return Int(number)
        }
        limit = try integer(args["limit"], 50, 1...200, "limit")
        offset = try integer(args["offset"], 0, 0...1_000_000, "offset")
        full = args["full"].bool == true
    }
    func slice<T>(_ rows: [T]) -> ArraySlice<T> { rows.dropFirst(offset).prefix(limit) }
    func wire(_ rows: [NativeRPCValue], total: Int) -> NativeRPCValue {
        let next = offset + rows.count
        return .object([.init("rows", .array(rows)), .init("total", .number(Double(total))),
                        .init("nextOffset", next < total ? .number(Double(next)) : .null)])
    }
    /// What a lead needs to pick a job: who, what, state and the start of the result. read gives the rest.
    static func compact(_ row: BackendTeamChatRecord) -> NativeRPCValue {
        let state = row.isFinished ? (row.failed ? "failed" : "finished") : "open"
        let result = row.result.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        var fields: [NativeRPCValue.Field] = []
        fields.append(.init("sessionId", .string(row.session.id)))
        fields.append(.init("title", .string(row.job.title)))
        fields.append(.init("agent", .string(row.job.agentName)))
        fields.append(.init("agentId", .string(row.job.agentID)))
        fields.append(.init("from", .string(row.job.fromName)))
        fields.append(.init("state", .string(state)))
        fields.append(.init("keepOpen", .bool(row.job.keepOpen == true)))
        let project = NativeRPCValue.string(row.session.resolvedProjectID)
        fields.append(.init("project", project))
        fields.append(.init("cwd", .string(row.session.cwd)))
        let account: NativeRPCValue = row.session.profileId.map { .string($0) } ?? .null
        fields.append(.init("account", account))
        fields.append(.init("startedAt", .number(row.session.createdAt)))
        let finished: NativeRPCValue = row.finishedAt.map { .number($0.timeIntervalSince1970 * 1000) } ?? .null
        fields.append(.init("finishedAt", finished))
        let shown: NativeRPCValue = result.map { .string($0) } ?? .null
        fields.append(.init("result", shown))
        return .object(fields)
    }
}

/// A job named by its session id, by the id passed as conversationId, or by the AI's own conversation id.
enum NativeTeamChatJobLookup {
    static func find(_ args: NativeRPCValue, chats: BackendSessionChats) async -> BackendTeamChatRecord? {
        for key in ["sessionId", "conversationId"] {
            guard let wanted = args[key].string, !wanted.isEmpty else { continue }
            if let record = await chats.conversation(wanted) { return record }
            if let record = await chats.conversations().first(where: { $0.session.agentSessionId == wanted }) { return record }
        }
        return nil
    }
}
