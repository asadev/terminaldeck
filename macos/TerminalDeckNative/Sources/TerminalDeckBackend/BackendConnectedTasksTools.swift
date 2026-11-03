import Foundation
import TerminalDeckNativeCore

/// Connected task systems' MCP tools and the app's own channels. Reads are free (the
/// caller's task access applies); every change goes through the existing approval path
/// (`authorize` at the alter tier) and the connection's "Changes made here" setting.
public enum BackendConnectedTasksTools {
    public static let owner = "connected-tasks"
    public static let readIDs = ["connected_tasks.systems", "connected_tasks.list", "connected_tasks.get"]
    public static let changeIDs = ["connected_tasks.update", "connected_tasks.comment", "connected_tasks.hand_to_agent", "connected_tasks.connect"]
    public static var ids: [String] { readIDs + changeIDs }
    public static let changedEvent = "connected-tasks:changed"
    public static let channels = ["state", "test", "connect", "update", "remove", "list", "refresh", "get", "change", "comment", "hand", "detail"]
        .map { "connected-tasks:" + $0 }

    public static func specs() throws -> [BackendMCPTool] {
        let s = NativeRPCValue.object([.init("type", .string("string"))])
        let b = NativeRPCValue.object([.init("type", .string("boolean"))])
        let n = NativeRPCValue.object([.init("type", .string("number"))])
        func described(_ base: NativeRPCValue, _ text: String) -> NativeRPCValue { base.setting("description", .string(text)) }
        func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let system = described(s, "The connected system's id or name, from connected_tasks_systems. May be left out when only one is connected.")
        let task = described(s, "The task's id in that system, from connected_tasks_list.")
        let pile = described(s.setting("enum", .array(ConnectedTasksPile.allCases.map { .string($0.rawValue) })),
                             "all, assigned_to_me, raised_by_me, or with_others (raised by you, with someone else).")
        return [
            try BackendMCPTool(id: "connected_tasks.systems", wireName: "connected_tasks_systems",
                description: "The task systems connected to Terminal Deck (Settings → Tasks → Connect a task system): name, address host, who it is connected as, what it can do, its status words, and whether changes ask first, go straight, or are off. Read-only; never shows a token.",
                inputSchema: schema([("projectId", described(s, "Filter by project id from project_registry.list."))], required: []), tier: .read),
            try BackendMCPTool(id: "connected_tasks.list", wireName: "connected_tasks_list",
                description: "Tasks from a connected task system, as the connected person sees them: id, title, status, priority, dates, board, labels, assignee, and whether each is assigned to you or raised by you. Filter by pile, status, text; finished ones are left out unless include_done. refresh: true reads the system again first (otherwise the last read is used, with its time). Read-only.",
                inputSchema: schema([("system", system), ("pile", pile), ("status", described(s, "Only tasks in this status (the system's own word).")),
                                     ("search", described(s, "Text to find in the title, board, labels or assignee.")),
                                     ("include_done", b), ("refresh", b), ("limit", described(n, "At most this many (default 50, up to 200)."))], required: []), tier: .read),
            try BackendMCPTool(id: "connected_tasks.get", wireName: "connected_tasks_get",
                description: "One task from a connected system, read now: description, people, subtasks, checklists, comments, activity, and whether it is with a Terminal Deck agent. Read-only.",
                inputSchema: schema([("system", system), ("task", task)], required: ["task"]), tier: .read),
            try BackendMCPTool(id: "connected_tasks.update", wireName: "connected_tasks_update",
                description: "Change a connected task's status (the system's own word), due date (YYYY-MM-DD, or empty to clear) and/or assignee (a person id or name from the task's people). Sent as the connected person; the system applies its own rules. Runs at once when the calling AI's permission mode allows it; the action is logged. If the system asks to confirm replacing someone, call again with confirm: true only after the owner agreed.",
                inputSchema: schema([("system", system), ("task", task), ("status", s), ("due_date", s), ("assignee", s), ("confirm", b)], required: ["task"]), tier: .alter),
            try BackendMCPTool(id: "connected_tasks.comment", wireName: "connected_tasks_comment",
                description: "Add a comment to a connected task, written as the connected person (up to 2000 characters). Runs at once when the calling AI's permission mode allows it; the action is logged.",
                inputSchema: schema([("system", system), ("task", task), ("body", s)], required: ["task", "body"]), tier: .alter),
            try BackendMCPTool(id: "connected_tasks.connect", wireName: "connected_tasks_connect",
                description: "Connect a task system (a CRM or tracker with an MCP server) for the owner: tests the address and token, then saves it (the token goes to the Keychain, never into any answer). Give the token in token_file — a file in the owner's home folder readable only by them (mode 600) — so it never appears in a conversation; token is accepted too. changes: ask (default), allow or off. Runs at once when the calling AI's permission mode allows it; the action is logged.",
                inputSchema: schema([("projectId", described(s, "The project id; known system names are inferred, otherwise Independent.")), ("name", described(s, "How the system is named on its tasks.")), ("url", described(s, "The system's MCP address (https).")),
                                     ("token_file", described(s, "Absolute path of a file holding only the access token (mode 600, in the home folder).")),
                                     ("token", s), ("changes", s.setting("enum", .array([.string("ask"), .string("allow"), .string("off")])))],
                                    required: ["name", "url"]), tier: .alter),
            try BackendMCPTool(id: "connected_tasks.hand_to_agent", wireName: "connected_tasks_hand_to_agent",
                description: "Hand a connected task to one of Terminal Deck's task agents: it becomes a local task the agent works on (in its default project unless project is given). When the agent finishes, its answer is posted back to the system as a comment, and the status is set to done if mark_done. Runs at once when the calling AI's permission mode allows it; the action is logged.",
                inputSchema: schema([("system", system), ("task", task), ("agent", described(s, "The task agent's id or name.")),
                                     ("project", described(s, "The project folder it works in; default: the agent's own.")), ("mark_done", b)],
                                    required: ["task", "agent"]), tier: .alter),
        ]
    }

    /// Which system a call means: by id, by name, or the only one.
    static func system(_ value: NativeRPCValue, in state: NativeRPCValue) throws -> String {
        let systems = state["connections"].elements ?? []
        guard !systems.isEmpty else {
            throw NativeRPCError.invalidArguments("No task system is connected. The owner connects one in Settings → Tasks → Connect a task system.")
        }
        guard let wanted = value.string, !wanted.isEmpty else {
            guard systems.count == 1, let id = systems[0]["id"].string else {
                throw NativeRPCError.invalidArguments("Several task systems are connected; name one: " + systems.compactMap { $0["name"].string }.joined(separator: ", ") + ".")
            }
            return id
        }
        if let match = systems.first(where: { $0["id"].string == wanted || $0["name"].string?.caseInsensitiveCompare(wanted) == .orderedSame }),
           let id = match["id"].string { return id }
        throw NativeRPCError.invalidArguments("There is no connected task system called \(wanted).")
    }

    public static func invoke(_ tool: String, arguments args: NativeRPCValue, caller: BackendMCPCallContext,
                              service: BackendConnectedTasksService, authority: BackendTaskToolAuthority,
                              agentID: @escaping @Sendable (String) async throws -> String? = { $0 }) async throws -> NativeRPCValue {
        try Task.checkCancellation()
        let change = changeIDs.contains(tool)
        let tier: BackendMCPTier = change ? .alter : .read
        guard caller.allowedTiers.contains(tier) else {
            throw NativeRPCError(code: caller.attended ? "not-granted" : "not-permitted-unattended", message: "The caller cannot change connected tasks.")
        }
        try await authority.requireTasks(caller)
        let state = try await service.state(projectId: args["projectId"].string)
        if tool == "connected_tasks.connect" {
            // The approval path first: nothing is read or sent before the owner says yes.
            try await authority.authorize(caller, tool, args.removing("token"), .alter)
            let token = try args["token_file"].string.map(readTokenFile) ?? args["token"].string ?? ""
            return try await service.connect(.object([.init("projectId", args["projectId"]), .init("name", args["name"]), .init("url", args["url"]), .init("token", .string(token)),
                                                      .init("changes", args["changes"].isNullish ? .string("ask") : args["changes"])]))
        }
        if tool == "connected_tasks.systems" {
            try await authority.authorize(caller, tool, args, .read)
            return .object([.init("systems", state["connections"])])
        }
        let id = try system(args["system"], in: state)
        if !change {
            try await authority.authorize(caller, tool, args, .read)
            if tool == "connected_tasks.get" {
                return try await service.detail(id, remoteID: try args["task"].requireString("task", nonempty: true))
            }
            let read = args["refresh"].bool == true ? try await service.refresh(id) : try await service.tasks(id)
            guard let list = ConnectedTaskList(read) else { throw NativeRPCError(code: "malformed", message: "The task list could not be read.") }
            let pile = ConnectedTasksPile(rawValue: args["pile"].string ?? "all") ?? .all
            let statuses: Set<String> = args["status"].string.map { [$0] } ?? []
            let rows = ConnectedTasksFilter.apply(list.tasks, pile: pile, statuses: statuses, search: args["search"].string ?? "",
                                                  showDone: args["include_done"].bool == true, doneStatus: list.system.doneStatus,
                                                  today: ConnectedTasksFilter.today())
            let limit = min(200, max(1, Int(args["limit"].number ?? 50)))
            let byID = Dictionary((read["tasks"].elements ?? []).compactMap { row in row["id"].string.map { ($0, row) } }, uniquingKeysWith: { a, _ in a })
            return .object([
                .init("system", .object([.init("id", .string(id)), .init("name", .string(list.system.name))])),
                .init("readAt", list.refreshedAt.map { .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0 / 1000))) } ?? .null),
                .init("total", .number(Double(rows.count))),
                .init("tasks", .array(rows.prefix(limit).compactMap { byID[$0.id] })),
                .init("note", .string(list.refreshedAt == nil ? "Not read yet — pass refresh: true." : "From the last read; pass refresh: true to read again.")),
            ])
        }
        let remote = try args["task"].requireString("task", nonempty: true)
        // The existing approval path: the owner answers for the alter tier.
        try await authority.authorize(caller, tool, args, .alter)
        switch tool {
        case "connected_tasks.comment":
            return try await service.comment(id, remoteID: remote, body: try args["body"].requireString("body", nonempty: true), via: .tool)
        case "connected_tasks.hand_to_agent":
            let named = try args["agent"].requireString("agent", nonempty: true)
            guard let agent = try await agentID(named) else { throw NativeRPCError.invalidArguments("There is no task agent called \(named).") }
            if let project = args["project"].string, !project.isEmpty { try await authority.project(caller, project) }
            return try await service.handToAgent(id, remoteID: remote, agent: agent, project: args["project"].string,
                                                 markDone: args["mark_done"].bool, via: .tool)
        default:
            var patch: [NativeRPCValue.Field] = []
            if args.has("status") { patch.append(.init("status", args["status"])) }
            if args.has("due_date") { patch.append(.init("dueDate", args["due_date"])) }
            if args.has("assignee") { patch.append(.init("assignee", args["assignee"])) }
            if args["confirm"].bool == true { patch.append(.init("confirm", .bool(true))) }
            return try await service.change(id, remoteID: remote, change: .object(patch), via: .tool)
        }
    }

    /// A token file: an absolute path inside the owner's home, a regular file they own, readable only by them, small.
    static func readTokenFile(_ path: String) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard path.hasPrefix("/"), url.path.hasPrefix(home + "/") else {
            throw NativeRPCError.invalidArguments("token_file has to be an absolute path inside your home folder.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              mode & 0o077 == 0, ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 8_192 else {
            throw NativeRPCError.invalidArguments("token_file has to be your own small file readable only by you (chmod 600).")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        // A bare token, or KEY=token lines (the first *TOKEN= line wins).
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if let line = lines.first(where: { $0.range(of: #"^[A-Z0-9_]*TOKEN="#, options: .regularExpression) != nil }) {
            return String(line[line.index(after: line.firstIndex(of: "=")!)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        guard lines.count == 1 else { throw NativeRPCError.invalidArguments("token_file has to hold just the token (or one NAME_TOKEN=… line).") }
        return lines[0]
    }

    public static func install(server: BackendNativeMCPServer, service: BackendConnectedTasksService, authority: BackendTaskToolAuthority,
                               agentID: @escaping @Sendable (String) async throws -> String?, ownerID: String = owner) async throws {
        let existing = Set(await server.registrations().map { $0.0.id })
        let specs = try specs()
        guard specs.allSatisfy({ !existing.contains($0.id) }) else {
            throw NativeRPCError(code: "duplicate-handler", message: "The connected task tools are already registered.")
        }
        do {
            for spec in specs {
                let id = spec.id
                try await server.registerTool(spec, ownerID: ownerID) { context, args in
                    .value(try await invoke(id, arguments: args, caller: context, service: service, authority: authority, agentID: agentID))
                }
            }
        } catch { await server.removeTools(ownerID: ownerID); throw error }
    }

    /// The app's own channels (the owner's screens). Ask mode is enforced by the service:
    /// a change arrives with `confirmed` only after the owner said yes on screen.
    public static func installAppChannels(registry: NativeChannelRegistry, service: BackendConnectedTasksService, ownerID: String = owner,
                                          requireApp: @escaping @Sendable (NativeRPCContext) throws -> Void) async throws {
        for channel in channels where await registry.has(channel) {
            throw NativeRPCError(code: "duplicate-handler", message: "\(channel) is already registered.")
        }
        func register(_ name: String, _ count: ClosedRange<Int>,
                      _ body: @escaping @Sendable ([NativeRPCValue]) async throws -> NativeRPCValue) async throws {
            try await registry.register("connected-tasks:" + name, ownerID: ownerID,
                policy: { context in
                    guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's own screens use this.") }
                }, handler: { context, args in
                    try context.requireCount(args, count)
                    try requireApp(context)
                    return try await body(args)
                })
        }
        @Sendable func text(_ value: NativeRPCValue, _ label: String) throws -> String { try value.requireString(label, nonempty: true) }
        do {
            try await register("state", 0...0) { _ in try await service.state() }
            try await register("test", 1...1) { args in try await service.test(args[0]) }
            try await register("connect", 1...1) { args in try await service.connect(args[0]) }
            try await register("update", 2...2) { args in try await service.update(try text(args[0], "id"), try args[1].requireObject("change")) }
            try await register("remove", 1...1) { args in try await service.remove(try text(args[0], "id")); return .object([.init("removed", .bool(true))]) }
            try await register("list", 1...1) { args in try await service.tasks(try text(args[0], "id")) }
            try await register("refresh", 1...1) { args in try await service.refresh(try text(args[0], "id")) }
            try await register("get", 2...2) { args in try await service.detail(try text(args[0], "id"), remoteID: try text(args[1], "task")) }
            try await register("change", 3...4) { args in
                try await service.change(try text(args[0], "id"), remoteID: try text(args[1], "task"), change: try args[2].requireObject("change"),
                                         via: .app, confirmed: args.count > 3 && args[3].bool == true)
            }
            try await register("comment", 3...4) { args in
                try await service.comment(try text(args[0], "id"), remoteID: try text(args[1], "task"), body: try text(args[2], "comment"),
                                          via: .app, confirmed: args.count > 3 && args[3].bool == true)
            }
            // The task popup on a connected task: its own function names, answered by the system.
            try await register("detail", 3...4) { args in
                try await service.popup(try text(args[0], "id"), function: try text(args[1], "function"), arguments: try args[2].requireArray("arguments"),
                                        confirmed: args.count > 3 && args[3].bool == true)
            }
            try await register("hand", 3...4) { args in
                let input = try args[2].requireObject("hand-over")
                return try await service.handToAgent(try text(args[0], "id"), remoteID: try text(args[1], "task"),
                    agent: try input["agent"].requireString("agent", nonempty: true), project: input["project"].string,
                    markDone: input["markDone"].bool, via: .app, confirmed: args.count > 3 && args[3].bool == true)
            }
        } catch {
            await registry.removeOwner(ownerID); throw error
        }
    }
}
