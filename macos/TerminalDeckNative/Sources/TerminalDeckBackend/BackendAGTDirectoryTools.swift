import Foundation
import TerminalDeckNativeCore

/// AGT: the Agents page's MCP tools. Reads are free (your current access applies);
/// changes go through the existing approval path (`authority.authorize` at the
/// alter tier, grouped like task-agent profile saves) and through TAG's
/// narrow-only save, so a key may restrict an agent but never widen it.
public struct BackendAGTDirectoryService: Sendable {
    public typealias LiveRead = @Sendable (BackendMCPCallContext) async throws -> (agents: [AWWatchAgent], tasks: [NativeRPCValue], notices: [String])
    public let config: BackendTaskConfiguration
    public let authority: BackendTaskToolAuthority
    public let live: LiveRead?
    public let profileRead: (@Sendable (BackendMCPCallContext, String) async throws -> NativeRPCValue)?

    public init(config: BackendTaskConfiguration, authority: BackendTaskToolAuthority, live: LiveRead? = nil,
                profileRead: (@Sendable (BackendMCPCallContext, String) async throws -> NativeRPCValue)? = nil) {
        self.config = config; self.authority = authority; self.live = live; self.profileRead = profileRead
    }

    /// Reads the live picture through the existing Agents-at-work source, which applies its own access rules.
    public static func liveRead(_ source: any AWAgentsWatchSource) -> LiveRead {
        { context in
            let snapshot = try await source.snapshot(.mcp(context))
            return (snapshot.agents, snapshot.tasks, snapshot.notices)
        }
    }

    func directory(_ caller: BackendMCPCallContext) async throws -> (agents: [AGTAgent], profiles: [NativeRPCValue], tasks: [AGTTaskInput], notices: [String]) {
        var notices: [String] = [], profiles: [NativeRPCValue] = []
        do { try await authority.requireTasks(caller); profiles = try await config.allAgents() }
        catch let error as NativeRPCError where ["access-denied", "not-permitted", "not-granted"].contains(error.code) {
            notices.append("Task-agent profiles are outside this caller's task access.")
        }
        var rows: [AWWatchAgent] = [], tasks: [AGTTaskInput] = []
        if let live {
            do {
                let read = try await live(caller)
                rows = read.agents; tasks = read.tasks.compactMap(AGTTaskInput.init); notices += read.notices
            } catch let error as NativeRPCError where ["access-denied", "not-permitted", "not-granted"].contains(error.code) {
                notices.append("Live activity is outside this caller's access.")
            }
        } else { notices.append("Live activity is not connected.") }
        // Which seat the app put each session in (a session working as its project's lead shows under the lead's name).
        let seats = Dictionary(await BackendAGTHands.shared.all().compactMap { hand in AGTSeat(owner: hand.seat).map { (hand.sessionID, $0.key) } },
                               uniquingKeysWith: { first, _ in first })
        let agents = AGTDirectory.build(profiles: profiles.compactMap(AGTProfileInput.init), live: rows, tasks: tasks,
                                        sessionSeats: seats, projects: (try? await BackendPROJRegistry.installed?.projects()) ?? PROJProjects.defaults)
        return (agents, profiles, tasks, notices)
    }

    public func invoke(_ tool: String, arguments args: NativeRPCValue, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        try Task.checkCancellation()
        let change = BackendAGTDirectoryTools.changeIDs.contains(tool)
        let tier: BackendMCPTier = change ? .alter : .read
        guard caller.allowedTiers.contains(tier) else {
            throw NativeRPCError(code: caller.attended ? "not-granted" : "not-permitted-unattended", message: "The caller cannot change agents.")
        }
        if change { return try await self.change(tool, args, caller: caller) }
        try await authority.authorize(caller, tool, args, .read)
        let read = try await directory(caller)
        switch tool {
        case "agents.directory":
            var agents = AGTDirectory.filtered(read.agents, query: args["query"].string ?? "")
            if let project = args["project"].string, !project.isEmpty {
                agents = agents.filter { $0.project == project || $0.projectName.caseInsensitiveCompare(project) == .orderedSame }
            }
            let grouping = AGTDirectory.Grouping(rawValue: args["group"].string ?? "project") ?? .project
            let groups = AGTDirectory.groups(agents, by: grouping).map { group in
                NativeRPCValue.object([.init("title", .string(group.title)), .init("folder", group.subtitle.map(NativeRPCValue.string) ?? .null),
                                       .init("agents", .array(group.agents.map { .string($0.id) }))])
            }
            return .object([.init("agents", .array(agents.map(\.wireValue))), .init("groups", .array(groups)),
                            .init("total", .number(Double(agents.count))), .init("notices", .array(read.notices.map(NativeRPCValue.string)))])
        case "agents.profile":
            let id = try args["id"].requireString("id", nonempty: true)
            // The v2 facade checks the caller's CURRENT profile/folder scope
            // before reading any runtime/settings/source data. Live-only
            // session aliases retain the existing directory behavior below.
            if let profileRead {
                if id == AGTDirectory.hootID { return try await profileRead(caller, id) }
                if let profile = try await config.agent(id), let savedID = profile["id"].string {
                    let detail = try await profileRead(caller, savedID)
                    if detail["coverage"].string == "public-agent-identity" { return detail }
                    let sessions = read.agents.first { $0.profileID == savedID }?.sessionIDs ?? []
                    return detail.setting("sessions", .array(sessions.map(NativeRPCValue.string)))
                }
            }
            guard let agent = read.agents.first(where: { $0.id == id || $0.profileID == id.lowercased() || $0.name.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw NativeRPCError.invalidArguments("There is no agent \(id) in your current access; agents_directory lists them.")
            }
            let reports = read.agents.filter { $0.reportsTo == agent.id && $0.kind == .profile }
            let manager = agent.reportsTo.flatMap { boss in read.agents.first { $0.id == boss } }
            let recent = read.tasks.filter { $0.assignee == agent.profileID || (!agent.name.isEmpty && $0.agentName == agent.name) }
                .sorted { $0.updatedAt > $1.updatedAt }.prefix(10)
            var settings = NativeRPCValue.null
            if let profileID = agent.profileID, let row = read.profiles.first(where: { $0["id"].string == profileID }) {
                settings = row.removing("instructions").removing("creatorKeyId").removing("keyInitializedFields")
            }
            return agent.wireValue
                .setting("reportsToName", manager.map { .string($0.name) } ?? .null)
                .setting("reports", .array(reports.map { .object([.init("id", .string($0.id)), .init("name", .string($0.name))]) }))
                .setting("recentTasks", .array(recent.map { .object([.init("id", .string($0.id)), .init("title", .string($0.title)),
                                                                     .init("state", .string($0.state)), .init("updatedAt", .number($0.updatedAt))]) }))
                .setting("settings", settings)
                .setting("notices", .array(read.notices.map(NativeRPCValue.string)))
        default:
            return AGTOrgChart.wireValue(AGTOrgChart.chart(read.agents))
                .setting("notices", .array(read.notices.map(NativeRPCValue.string)))
        }
    }

    private func change(_ tool: String, _ args: NativeRPCValue, caller: BackendMCPCallContext) async throws -> NativeRPCValue {
        let raw = try args["id"].requireString("id", nonempty: true)
        let hootProfile = try await config.agent("hoot") != nil
        if raw == AGTDirectory.hootID || (raw.lowercased() == "hoot" && !hootProfile) {
            throw NativeRPCError.invalidArguments("Hoot is built in: its look and place are fixed. Agents can report to it with reportsTo \(AGTDirectory.hootID).")
        }
        if raw.hasPrefix(AGTDirectory.sessionPrefix) {
            throw NativeRPCError.invalidArguments("A live session has no profile to change. Save it as a task agent first (tasks_agents do=save), then change that.")
        }
        try await authority.requireTasks(caller)
        guard let existing = try await config.agent(raw), let id = existing["id"].string else {
            throw NativeRPCError.invalidArguments("There is no task agent called \(raw); agents_directory lists them.")
        }
        var patch = NativeRPCValue.object([.init("id", .string(id))])
        switch tool {
        case "agents.set_icon":
            let icon = args["icon"]
            if !icon.isNullish {
                guard let text = icon.string, AGTIcon.parse(text) != nil else { throw NativeRPCError.invalidArguments(AGTIcon.problem(icon.string ?? "?") ?? "The icon is not valid.") }
            }
            patch = patch.setting("icon", icon.isNullish ? .null : icon)
        case "agents.set_reports_to":
            let boss = args["reportsTo"]
            if let name = boss.string, !name.isEmpty {
                let target: String
                if name == AGTDirectory.hootID || (name.lowercased() == "hoot" && !hootProfile) { target = AGTDirectory.hootID }
                else {
                    guard let row = try await config.agent(name), let other = row["id"].string else { throw NativeRPCError.invalidArguments("There is no task agent called \(name) to report to.") }
                    target = other
                }
                patch = patch.setting("reportsTo", .string(target))
            } else { patch = patch.setting("reportsTo", .null) }
        default:
            let fields = try args["fields"].requireObject("fields")
            for field in fields.fields ?? [] {
                guard BackendAGTDirectoryTools.editableFields.contains(field.key) else {
                    throw NativeRPCError.invalidArguments("\(field.key) cannot be changed here. Editable: \(BackendAGTDirectoryTools.editableFields.joined(separator: ", ")).")
                }
                patch = patch.setting(field.key, field.value)
            }
        }
        if let project = patch["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) }
        // Hoot: every agent; a project's lead: its own project's agents; any other session: none.
        try await authority.checkAgentScope(caller, rows: [existing.merging(patch)], acting: "save", config: config)
        // The existing approval path: owner answers for the alter tier unless this key has standing approval for profiles.
        try await authority.authorize(caller, tool, args, .alter)
        let saved: NativeRPCValue
        if try await authority.widensAgents?(caller) ?? false {
            // Hoot, or a project's lead for its own project: may widen as the owner can (Asad, 12 Oct).
            saved = try await config.saveAgentsAsCaller(request: .object([.init("do", .string("save")), .init("agent", patch)]),
                inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", ownerMode: true).first ?? .null
        } else {
            saved = try await config.saveAgentNarrowed(patch, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default",
                                                       callerKeyID: try await authority.callerKeyID?(caller))
        }
        return .object([.init("saved", saved.removing("instructions").removing("creatorKeyId").removing("keyInitializedFields"))])
    }
}

public enum BackendAGTDirectoryTools {
    public static let owner = "agents-directory"
    public static let readIDs = ["agents.directory", "agents.profile", "agents.org_chart"]
    public static let changeIDs = ["agents.set_icon", "agents.set_reports_to", "agents.edit_profile"]
    /// Every AGT tool, for the catalogue (agents_on_this_mac is registered by BackendAGTDeviceTools).
    public static var ids: [String] { readIDs + changeIDs + [BackendAGTDeviceTools.toolID] }
    /// Both spellings, as the consent grouping sees them.
    public static let changeTools: Set<String> = Set(changeIDs + changeIDs.map { $0.replacingOccurrences(of: ".", with: "_") })
    public static let editableFields = ["name", "role", "icon", "reportsTo", "defaultProject", "model", "effort", "allowedTools", "blockedTools",
                                        "skillsOff", "permissionMode", "keepAliveMinutes", "keepAliveUntilClose", "reviewerAgent"]

    public static func specs() throws -> [BackendMCPTool] {
        let s = NativeRPCValue.object([.init("type", .string("string"))])
        let nullable = NativeRPCValue.object([.init("type", .array([.string("string"), .string("null")]))])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let group = s.setting("enum", .array([.string("project"), .string("reportsTo")]))
        return [
            try BackendMCPTool(id: "agents.directory", wireName: "agents_directory",
                description: "Every agent: task-agent profiles, imported Claude Code agents, Hoot and live sessions, with project, model, status, what each is doing now, who it reports to and last activity. Filter by query or project; group by project or reportsTo. Read-only; your current access applies.",
                inputSchema: schema([("query", s), ("project", s), ("group", group)], required: []), tier: .read),
            try BackendMCPTool(id: "agents.profile", wireName: "agents_profile",
                description: "One agent's profile: role, icon, project, model, settings, manager, direct reports, live activity and recent tasks. Read-only.",
                inputSchema: schema([("id", s)], required: ["id"]), tier: .read),
            try BackendMCPTool(id: "agents.org_chart", wireName: "agents_org_chart",
                description: "The organisation chart: who reports to whom, as trees, plus the independent agents. Read-only.",
                inputSchema: schema([], required: []), tier: .read),
            try BackendMCPTool(id: "agents.set_icon", wireName: "agents_set_icon",
                description: "Set a task agent's icon: sf:<SF Symbol name> or emoji:<one emoji>, or null for the default.",
                inputSchema: schema([("id", s), ("icon", nullable)], required: ["id", "icon"]), tier: .alter),
            try BackendMCPTool(id: "agents.set_reports_to", wireName: "agents_set_reports_to",
                description: "Set who a task agent reports to: another agent's id, @hoot, or null for independent. Loops are refused.",
                inputSchema: schema([("id", s), ("reportsTo", nullable)], required: ["id", "reportsTo"]), tier: .alter),
            try BackendMCPTool(id: "agents.edit_profile", wireName: "agents_edit_profile",
                description: "Change a task agent's profile fields: \(editableFields.joined(separator: ", ")). A key may only restrict tools, permission mode and keep-open, never widen them; relaxing needs the owner in the app.",
                inputSchema: schema([("id", s), ("fields", .object([.init("type", .string("object"))]))], required: ["id", "fields"]), tier: .alter),
        ]
    }

    public static func install(server: BackendNativeMCPServer, service: BackendAGTDirectoryService, ownerID: String = owner) async throws {
        let existing = Set(await server.registrations().map { $0.0.id })
        let specs = try specs()
        guard specs.allSatisfy({ !existing.contains($0.id) }) else {
            throw NativeRPCError(code: "duplicate-handler", message: "The Agents tools are already registered.")
        }
        do {
            for spec in specs {
                let id = spec.id
                try await server.registerTool(spec, ownerID: ownerID) { context, args in
                    .value(try await service.invoke(id, arguments: args, caller: context))
                }
            }
        } catch { await server.removeTools(ownerID: ownerID); throw error }
    }
}

/// AGT: write an imported agent's own Claude Code file, only when the owner said
/// yes on the profile page. Changes description, model and tools in the
/// frontmatter; the body (the agent's identity) is never touched.
public enum BackendAGTSourceWriter {
    public static func update(file: URL, directory: URL, description: String?, model: String??, tools: [String]??) throws {
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.pathExtension.lowercased() == "md", resolved.deletingLastPathComponent().path == directory.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw NativeRPCError.invalidArguments("Only the agent's own file in its .claude/agents folder can be changed.")
        }
        guard let data = FileManager.default.contents(atPath: resolved.path), data.count <= 512_000, let text = String(data: data, encoding: .utf8) else {
            throw NativeRPCError.invalidArguments("The agent file could not be read.")
        }
        let updated = try rewrite(text, description: description, model: model, tools: tools)
        try Data(updated.utf8).write(to: resolved, options: .atomic)
    }

    /// The frontmatter with the given keys replaced (or added before the closing ---).
    public static func rewrite(_ source: String, description: String?, model: String??, tools: [String]??) throws -> String {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              var end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw NativeRPCError.invalidArguments("The agent file has no frontmatter to change.")
        }
        func set(_ key: String, _ value: String?) {
            var index = 1
            var found: Int?
            while index < end {
                let line = lines[index]
                if line.first?.isWhitespace != true, line.hasPrefix(key + ":") { found = index; break }
                index += 1
            }
            if let start = found {
                var stop = start + 1
                while stop < end, lines[stop].first?.isWhitespace == true || lines[stop].isEmpty && stop + 1 < end && lines[stop + 1].first?.isWhitespace == true { stop += 1 }
                lines.removeSubrange(start..<stop); end -= stop - start
                if let value { lines.insert("\(key): \(value)", at: start); end += 1 }
            } else if let value {
                lines.insert("\(key): \(value)", at: end); end += 1
            }
        }
        if let description { set("description", try scalar(description)) }
        if let model { set("model", try model.map(scalar)) }
        if let tools { set("tools", try tools.map { list in try list.map(scalar).joined(separator: ", ") }) }
        return lines.joined(separator: "\n")
    }

    static func scalar(_ raw: String) throws -> String {
        let text = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty, text.utf16.count <= 4_000 else { throw NativeRPCError.invalidArguments("The value for the agent file is empty or too long.") }
        let plain = text.range(of: #"^[A-Za-z0-9(][^:#"'\[\]{}]*$"#, options: .regularExpression) != nil && !text.hasSuffix(":")
        if plain { return text }
        // YAML reads \ inside double quotes as an escape ("C:\build" would break the file); single quotes keep it as typed.
        if !text.contains("\"") && !text.contains("\\") { return "\"" + text + "\"" }
        if !text.contains("'") { return "'" + text + "'" }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public extension BackendAGTDirectoryTools {
    static let writeSourceChannel = "agents-directory:write-source"

    /// The profile page's "also change the file" answer. App only: an MCP caller never writes agent files.
    static func installAppChannel(registry: NativeChannelRegistry, config: BackendTaskConfiguration, ownerID: String = owner,
                                  requireApp: @escaping @Sendable (NativeRPCContext) throws -> Void) async throws {
        guard await !registry.has(writeSourceChannel) else {
            throw NativeRPCError(code: "duplicate-handler", message: "The Agents file writer is already registered.")
        }
        try await registry.register(writeSourceChannel, ownerID: ownerID,
            policy: { context in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Only the app's profile page can change an agent file.") }
            }, handler: { context, args in
                try context.requireCount(args, 1...1)
                try requireApp(context)
                let input = try args[0].requireObject("change")
                let id = try input["id"].requireString("id", nonempty: true)
                guard let row = try await config.agent(id), let file = row["sourceFile"].string, let folder = row["sourceDirectory"].string else {
                    throw NativeRPCError.invalidArguments("That agent was not imported from a Claude Code agent file.")
                }
                let model: String?? = input.has("model") ? .some(input["model"].string) : .none
                let tools: [String]?? = input.has("tools") ? .some(input["tools"].elements?.compactMap(\.string)) : .none
                try BackendAGTSourceWriter.update(file: URL(fileURLWithPath: file), directory: URL(fileURLWithPath: folder),
                                                  description: input["description"].string, model: model, tools: tools)
                return .object([.init("written", .string(file))])
            })
    }
}
