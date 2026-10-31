import Foundation
import TerminalDeckNativeCore

/// Connected task systems: tasks that live in another system (a CRM, a tracker),
/// seen and worked on from Terminal Deck through that system's MCP server.
///
/// - The system is the source of truth. A bounded copy of its last answer is kept so
///   the page shows something at once; it is always labelled with when it was read.
/// - It is read on demand only (the page opens, the app comes forward, Refresh, and
///   after each change sent from here). There is no timer and no poll.
/// - Changes (status, comment, due date, assignee) are one call each, as the connected
///   person, then the task is read again. Never queued, never retried on their own.
/// - "Changes made here" per connection: ask (default), allow, or off (read only).
///   Ask is enforced here: an unconfirmed change from the app is refused.
/// - A task handed to a Terminal Deck agent becomes a local task; when the agent
///   finishes, its answer is posted back as a comment, once (and the status set to
///   the system's done word if that was chosen at hand-over).
public actor BackendConnectedTasksService {
    public enum Via: Sendable, Equatable {
        /// The app's own screens (the owner); Ask mode needs `confirmed`.
        case app
        /// An MCP caller that already passed the approval path.
        case tool
    }

    public enum Changes: String, Sendable, CaseIterable {
        case ask, allow, off
    }

    /// What a handed-over local task has come to. Nil from `agentOutcome` while it runs.
    public struct AgentOutcome: Sendable, Equatable {
        public var answer: String?
        public var stopped: Bool
        public init(answer: String?, stopped: Bool = false) { self.answer = answer; self.stopped = stopped }
    }

    /// The local task engine, as this service needs it (wired by the composition, faked in tests).
    public struct Agents: Sendable {
        /// Makes a local task (title, instructions, assignee, project, board) and answers its id.
        public var create: @Sendable (NativeRPCValue) async throws -> String
        /// The local task's outcome, nil while it is still working.
        public var outcome: @Sendable (String) async throws -> AgentOutcome?
        /// An agent's name and default project, nil when there is no such agent.
        public var agent: @Sendable (String) async throws -> (name: String, project: String?)?
        public init(create: @escaping @Sendable (NativeRPCValue) async throws -> String,
                    outcome: @escaping @Sendable (String) async throws -> AgentOutcome?,
                    agent: @escaping @Sendable (String) async throws -> (name: String, project: String?)?) {
            self.create = create; self.outcome = outcome; self.agent = agent
        }
    }

    public static let fileName = "connected-tasks.json"
    public static let maximumConnections = 10
    /// Comments posted from here stay within what common systems accept.
    public static let commentLimit = 2_000
    public static let listLimit = 200

    private let persistence: BackendTaskPersistence
    private let secrets: any BackendConnectedTasksSecrets
    private let transport: any BackendConnectedTasksTransport
    private let agents: Agents
    let now: @Sendable () -> Double
    let changed: @Sendable () async -> Void
    private let problem: @Sendable (String) -> Void

    private var started = false
    private var connections: [NativeRPCValue] = []
    private var cache: [String: NativeRPCValue] = [:]
    var people: [String: NativeRPCValue] = [:]
    private var handoffs: [NativeRPCValue] = []
    private var clients: [String: (key: String, client: BackendConnectedTasksClient)] = [:]
    private var checking = false, checkAgain = false
    /// The task popup's reads of one task, kept a few seconds so its parallel loads cost one call each.
    var reads: [String: (at: Double, value: NativeRPCValue)] = [:]
    /// Which task a subtask, checklist, item, field or attachment id belongs to (learned from reads), per
    /// connection and only for the `ownersTasks` tasks opened most recently, so it never grows without end.
    var owners: [String: [(task: String, ids: Set<String>)]] = [:]
    static let ownersTasks = 50
    /// A task read updates the list's copy; the settings file is written once a moment later, not per read.
    private var cacheSave: Task<Void, Never>?
    static let cacheSaveDelay: Duration = .seconds(2)
    /// Checklists made in the popup but not sent yet (the system makes a list with its first item).
    var draftLists: [String: (task: String, title: String)] = [:]
    let chooseFiles: (@Sendable () async throws -> [URL])?
    let openURL: (@Sendable (URL) async -> Void)?

    public init(persistence: BackendTaskPersistence, secrets: any BackendConnectedTasksSecrets,
                transport: any BackendConnectedTasksTransport = BackendConnectedTasksURLSessionTransport(),
                agents: Agents, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                changed: @escaping @Sendable () async -> Void = {}, problem: @escaping @Sendable (String) -> Void = { _ in },
                chooseFiles: (@Sendable () async throws -> [URL])? = nil, openURL: (@Sendable (URL) async -> Void)? = nil) {
        self.persistence = persistence; self.secrets = secrets; self.transport = transport; self.agents = agents
        self.now = now; self.changed = changed; self.problem = problem; self.chooseFiles = chooseFiles; self.openURL = openURL
    }

    // MARK: Saved state

    public func start() throws {
        guard !started else { return }
        let saved = try persistence.read(Self.fileName, maximumBytes: 16 * 1024 * 1024) ?? .object([])
        let moved = Self.migrateLegacyProjects(saved["connections"].elements ?? [], registered: PROJProjects.defaults)
        connections = moved.rows.filter { $0["id"].string != nil && $0["url"].string != nil }.map { row in
            if let explicit = Self.explicitProjectId(row) { return row.setting("projectId", .string(explicit)).removing("projectIdInferred") }
            return row.removing("projectId").setting("projectIdInferred", .bool(true))
        }
        for field in saved["cache"].fields ?? [] where connections.contains(where: { $0["id"].string == field.key }) { cache[field.key] = field.value }
        for field in saved["people"].fields ?? [] where connections.contains(where: { $0["id"].string == field.key }) { people[field.key] = field.value }
        handoffs = (saved["handoffs"].elements ?? []).filter { $0["localTaskId"].string != nil && $0["connection"].string != nil }
        started = true
        // The project is written into the connection's own saved settings once; a read-only copy keeps it in memory.
        if moved.changed { try? save() }
    }

    /// One-time migration (11 Oct). Before projects had ids, a connection's project came from its NAME
    /// ("iLoop" or "CRM" → the project "crm", "iMatch" → "imatch"): a rule built for one person's setup.
    /// Now a connection with no project saved whose name that rule matched gets that project written into
    /// its own settings, but only when the person has a registered project with that id. A project already
    /// saved is never changed, and after this nothing is decided by a name any more.
    static func migrateLegacyProjects(_ rows: [NativeRPCValue], registered: [PROJProject]) -> (rows: [NativeRPCValue], changed: Bool) {
        var changed = false
        let migrated = rows.map { row -> NativeRPCValue in
            guard explicitProjectId(row) == nil else { return row }
            let name = row["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let id = name == "iloop" || name == "crm" ? "crm" : name == "imatch" ? "imatch" : nil
            guard let id, registered.contains(where: { $0.id == id }) else { return row }
            changed = true
            return row.setting("projectId", .string(id)).removing("projectIdInferred")
        }
        return (migrated, changed)
    }

    private func save() throws {
        cacheSave?.cancel(); cacheSave = nil
        try persistence.write(Self.fileName, value: .object([
            .init("version", .number(1)),
            .init("connections", .array(connections)),
            .init("cache", .object(cache.sorted { $0.key < $1.key }.map { .init($0.key, $0.value) })),
            .init("people", .object(people.sorted { $0.key < $1.key }.map { .init($0.key, $0.value) })),
            .init("handoffs", .array(handoffs.suffix(500))),
        ]))
    }

    private func saveCacheSoon() {
        guard cacheSave == nil else { return }
        cacheSave = Task { [weak self] in
            try? await Task.sleep(for: Self.cacheSaveDelay)
            guard !Task.isCancelled else { return }
            await self?.flushCache()
        }
    }

    func flushCache() {
        cacheSave = nil
        try? save()
    }

    func requireStarted() throws {
        guard started else { throw NativeRPCError(code: "unavailable", message: "Connected task systems are still starting.") }
    }

    func connection(_ id: String) throws -> NativeRPCValue {
        try requireStarted()
        guard let row = connections.first(where: { $0["id"].string == id }) else {
            throw NativeRPCError.invalidArguments("There is no connected task system with that id. connected_tasks_systems lists them.")
        }
        return row
    }

    private func replace(_ row: NativeRPCValue) {
        guard let id = row["id"].string, let index = connections.firstIndex(where: { $0["id"].string == id }) else { return }
        connections[index] = row
    }

    func profile(_ row: NativeRPCValue) -> BackendConnectedTasksProfile { .init(wire: row["profile"]) }

    func replaceProfile(_ id: String, _ profile: BackendConnectedTasksProfile) {
        guard let row = try? connection(id) else { return }
        replace(row.setting("profile", profile.wire)); try? save()
    }

    // MARK: Views (never a token)

    static func explicitProjectId(_ row: NativeRPCValue) -> String? {
        if row["projectIdInferred"].bool != true, let explicit = row["projectId"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty { return explicit }
        return nil
    }
    static func projectId(_ row: NativeRPCValue) -> String {
        PROJProjects.resolve(projectID: explicitProjectId(row), folder: row["folder"].string ?? row["startIn"].string)
    }

    public func view(_ row: NativeRPCValue) -> NativeRPCValue {
        let id = row["id"].string ?? "", profile = profile(row), cached = cache[id] ?? .object([])
        let host = row["url"].string.flatMap { URL(string: $0)?.host } ?? ""
        var value = NativeRPCValue.object([
            .init("projectId", .string(Self.projectId(row))), .init("projectName", .string(PROJProjects.name(for: Self.projectId(row)))), .init("id", .string(id)), .init("name", row["name"]), .init("url", row["url"]), .init("host", .string(host)),
            .init("enabled", .bool(row["enabled"].bool != false)), .init("changes", .string(row["changes"].string ?? Changes.ask.rawValue)),
            .init("markDone", .bool(row["markDone"].bool == true)), .init("server", row["server"]), .init("me", row["me"]),
            .init("capabilities", .array(profile.capabilities.map { .string($0.rawValue) })),
            .init("capabilityWords", .array(profile.capabilities.map { .string($0.words) })),
            .init("statuses", .array(profile.statuses.map(NativeRPCValue.string))),
            .init("doneStatus", profile.doneStatus.map(NativeRPCValue.string) ?? .null),
            .init("tokenEnding", row["tokenEnding"]), .init("docsUrl", row["docsUrl"]),
            .init("refreshedAt", cached["at"]), .init("total", cached["total"]),
            .init("taskCount", .number(Double(cached["tasks"].elements?.count ?? 0))),
            .init("problem", row["problem"]), .init("createdAt", row["createdAt"]),
        ])
        if Self.explicitProjectId(row) == nil {
            value = value.setting("projectIdInferred", .bool(true))
            if let folder = row["folder"].string ?? row["startIn"].string { value = value.setting("folder", .string(folder)) }
        }
        return value
    }

    public func state(projectId: String? = nil) throws -> NativeRPCValue {
        try requireStarted()
        return .object([.init("connections", .array(connections.filter { projectId == nil || Self.projectId($0) == projectId }.map(view)))])
    }

    /// The cached rows of one system (read again only when asked).
    public func tasks(_ id: String) throws -> NativeRPCValue {
        let row = try connection(id), cached = cache[id] ?? .object([])
        let mine = handoffs.filter { $0["connection"].string == id }
        return .object([
            .init("connection", view(row)), .init("tasks", cached["tasks"].elements.map(NativeRPCValue.array) ?? .array([])),
            .init("refreshedAt", cached["at"]), .init("total", cached["total"]),
            .init("people", people[id]?["people"] ?? .array([])),
            .init("handoffs", .array(mine.map(handoffView))),
        ])
    }

    private func handoffView(_ row: NativeRPCValue) -> NativeRPCValue {
        .object([.init("remoteId", row["remoteId"]), .init("localTaskId", row["localTaskId"]), .init("agent", row["agent"]),
                 .init("agentName", row["agentName"]), .init("markDone", row["markDone"]), .init("createdAt", row["createdAt"]),
                 .init("postedAt", row["postedAt"]), .init("statusSetAt", row["statusSetAt"]), .init("problem", row["problem"]),
                 .init("closedAt", row["closedAt"])])
    }

    // MARK: Connecting

    func client(_ id: String, row: NativeRPCValue) throws -> BackendConnectedTasksClient {
        guard let address = row["url"].string, let url = URL(string: address) else {
            throw NativeRPCError.invalidArguments("This connection has no address.")
        }
        guard let token = try secrets.read(id), !token.isEmpty else {
            throw NativeRPCError(code: "unauthorized", message: "This connection has no saved access token. Paste one in Settings → Tasks.")
        }
        let key = address + "\u{0}" + token
        if let existing = clients[id], existing.key == key { return existing.client }
        let made = try BackendConnectedTasksClient(endpoint: url, token: token, transport: transport)
        clients[id] = (key, made)
        return made
    }

    /// Checks an address and token without saving anything: who answers, as whom, what it can do.
    public func test(_ input: NativeRPCValue) async throws -> NativeRPCValue {
        let (url, token) = try Self.addressAndToken(input)
        let client = try BackendConnectedTasksClient(endpoint: url, token: token, transport: transport)
        return try await probe(client, url: url).report
    }

    private struct Probe: Sendable {
        var report: NativeRPCValue
        var profile: BackendConnectedTasksProfile
        var server: NativeRPCValue
        var me: NativeRPCValue
        var people: NativeRPCValue?
        var docs: String?
    }

    private func probe(_ client: BackendConnectedTasksClient, url: URL) async throws -> Probe {
        let server = try await client.open()
        let tools = try await client.tools()
        let profile = BackendConnectedTasksProfile.discover(tools)
        guard profile.list != nil else {
            throw NativeRPCError(code: "no-tasks", message: "This system answers, but it offers no tool that lists tasks, so there is nothing to show here.")
        }
        var me = NativeRPCValue.null, peopleValue: NativeRPCValue?
        if let tool = profile.people {
            if let answer = try? await client.call(tool.name, .object([])) {
                let read = BackendConnectedTasksMapping.people(answer.data)
                let name = read.people.first { $0["id"].string == read.me }?["name"] ?? .null
                if let id = read.me { me = .object([.init("id", .string(id)), .init("name", name)]) }
                peopleValue = .object([.init("at", .number(now())), .init("people", .array(read.people))])
            }
        }
        let docs = await Self.documentation(url, transport: transport)
        let serverValue = NativeRPCValue.object([.init("name", .string(server.name)),
                                                 .init("title", server.title.map(NativeRPCValue.string) ?? .null)])
        let report = NativeRPCValue.object([
            .init("server", serverValue), .init("me", me),
            .init("capabilities", .array(profile.capabilities.map { .string($0.rawValue) })),
            .init("capabilityWords", .array(profile.capabilities.map { .string($0.words) })),
            .init("statuses", .array(profile.statuses.map(NativeRPCValue.string))),
            .init("toolCount", .number(Double(tools.count))), .init("docsUrl", docs.map(NativeRPCValue.string) ?? .null),
        ])
        return Probe(report: report, profile: profile, server: serverValue, me: me, people: peopleValue, docs: docs)
    }

    /// The system's own page for making a token, from its protected-resource metadata (best effort).
    static func documentation(_ endpoint: URL, transport: any BackendConnectedTasksTransport) async -> String? {
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path == "/" ? "" : parts.path
        parts.path = "/.well-known/oauth-protected-resource" + path; parts.query = nil; parts.fragment = nil
        guard let url = parts.url,
              let answer = try? await transport.send(.init(method: "GET", url: url, headers: ["Accept": "application/json"])),
              answer.status == 200, let value = try? NativeRPCValue.parseJSON(answer.body, maximumBytes: 256 * 1024),
              let docs = value["resource_documentation"].string, let link = URL(string: docs), link.scheme == "https" else { return nil }
        return docs
    }

    static func addressAndToken(_ input: NativeRPCValue) throws -> (URL, String) {
        let address = (input["url"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.count <= 2_048, let url = URL(string: address) else {
            throw NativeRPCError.invalidArguments("Give the full address of the system's MCP server, starting with https://.")
        }
        try BackendConnectedTasksClient.checkEndpoint(url)
        let token = (input["token"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw NativeRPCError.invalidArguments("Paste the access token the system gave you.") }
        return (url, token)
    }

    static func cleanName(_ value: NativeRPCValue) throws -> String {
        let name = (value.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        guard !name.isEmpty else { throw NativeRPCError.invalidArguments("Give the system a name, as you want to see it on its tasks.") }
        return String(name.prefix(40))
    }

    static func changes(_ value: NativeRPCValue) throws -> Changes {
        if value.isNullish { return .ask }
        guard let raw = value.string, let mode = Changes(rawValue: raw) else {
            throw NativeRPCError.invalidArguments("Changes made here are ask, allow or off.")
        }
        return mode
    }

    /// Tests, then saves: the token into the secret store, the rest into the settings file.
    public func connect(_ input: NativeRPCValue) async throws -> NativeRPCValue {
        try requireStarted()
        let name = try Self.cleanName(input["name"]), mode = try Self.changes(input["changes"])
        let (url, token) = try Self.addressAndToken(input)
        guard connections.count < Self.maximumConnections else {
            throw NativeRPCError.invalidArguments("Up to \(Self.maximumConnections) task systems can be connected.")
        }
        guard !connections.contains(where: { $0["url"].string == url.absoluteString }) else {
            throw NativeRPCError.invalidArguments("That address is already connected. Change it in its own row instead.")
        }
        let client = try BackendConnectedTasksClient(endpoint: url, token: token, transport: transport)
        let probe = try await probe(client, url: url)
        let id = "cts-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)
        try secrets.write(id, token: token)
        let row = NativeRPCValue.object([
            .init("projectId", .string(Self.projectId(input))), .init("id", .string(id)), .init("name", .string(name)), .init("url", .string(url.absoluteString)),
            .init("enabled", .bool(true)), .init("changes", .string(mode.rawValue)), .init("markDone", .bool(input["markDone"].bool == true)),
            .init("profile", probe.profile.wire), .init("server", probe.server), .init("me", probe.me),
            .init("tokenEnding", .string("…" + String(token.suffix(4)))), .init("docsUrl", probe.docs.map(NativeRPCValue.string) ?? .null),
            .init("problem", .null), .init("createdAt", .number(now())),
        ])
        connections.append(row)
        clients[id] = (url.absoluteString + "\u{0}" + token, client)
        if let value = probe.people { people[id] = value }
        do { try save() } catch { connections.removeAll { $0["id"].string == id }; try? secrets.remove(id); throw error }
        await changed()
        return view(row)
    }

    /// Name, on/off, Changes made here, mark-done default; a new address or token is tested first.
    public func update(_ id: String, _ patch: NativeRPCValue) async throws -> NativeRPCValue {
        let before = try connection(id)
        var simple: [(String, NativeRPCValue)] = []
        if patch.has("projectId") { simple.append(("projectId", .string(PROJProjects.resolve(projectID: try patch["projectId"].requireString("projectId", nonempty: true), folder: nil)))) }
        if patch.has("name") { simple.append(("name", .string(try Self.cleanName(patch["name"])))) }
        if patch.has("enabled") {
            guard let on = patch["enabled"].bool else { throw NativeRPCError.invalidArguments("enabled is true or false.") }
            simple.append(("enabled", .bool(on)))
        }
        if patch.has("changes") { simple.append(("changes", .string(try Self.changes(patch["changes"]).rawValue))) }
        if patch.has("markDone") {
            guard let on = patch["markDone"].bool else { throw NativeRPCError.invalidArguments("markDone is true or false.") }
            simple.append(("markDone", .bool(on)))
        }
        var probed: (url: URL, token: String, client: BackendConnectedTasksClient, probe: Probe)?
        if patch.has("token") || patch.has("url") {
            let token = try patch["token"].string ?? secrets.read(id) ?? ""
            let (url, clean) = try Self.addressAndToken(.object([.init("url", patch["url"].string.map(NativeRPCValue.string) ?? before["url"]),
                                                                 .init("token", .string(token))]))
            let client = try BackendConnectedTasksClient(endpoint: url, token: clean, transport: transport)
            probed = (url, clean, client, try await probe(client, url: url))
        }
        var row = try connection(id) // as it is now, after any probe
        if patch.has("projectId") { row = row.removing("projectIdInferred") }
        for (key, value) in simple { row = row.setting(key, value) }
        if let probed {
            row = row.setting("url", .string(probed.url.absoluteString)).setting("profile", probed.probe.profile.wire)
                .setting("server", probed.probe.server).setting("me", probed.probe.me)
                .setting("tokenEnding", .string("…" + String(probed.token.suffix(4))))
                .setting("docsUrl", probed.probe.docs.map(NativeRPCValue.string) ?? .null).setting("problem", .null)
            try secrets.write(id, token: probed.token)
            clients[id] = (probed.url.absoluteString + "\u{0}" + probed.token, probed.client)
            if let value = probed.probe.people { people[id] = value }
        }
        replace(row)
        try save()
        await changed()
        return view(row)
    }

    public func remove(_ id: String) async throws {
        _ = try connection(id)
        connections.removeAll { $0["id"].string == id }
        cache[id] = nil; people[id] = nil; clients[id] = nil; owners[id] = nil
        forget(id, nil)
        handoffs.removeAll { $0["connection"].string == id }
        try secrets.remove(id)
        try save()
        await changed()
    }

    // MARK: Reading

    /// Reads the system's list again (as the connected person) and keeps it.
    @discardableResult
    public func refresh(_ id: String) async throws -> NativeRPCValue {
        let row = try connection(id)
        guard row["enabled"].bool != false else { throw NativeRPCError(code: "off", message: "This connection is switched off.") }
        let profile = profile(row)
        guard let list = profile.list else { throw NativeRPCError(code: "no-tasks", message: "This system offers no task list.") }
        var arguments: [NativeRPCValue.Field] = []
        if let limit = profile.listLimit { arguments.append(.init(limit, .number(Double(Self.listLimit)))) }
        if let done = profile.listIncludeDone { arguments.append(.init(done, .bool(true))) }
        do {
            let client = try client(id, row: row)
            let answer = try await client.call(list.name, .object(arguments))
            let me = row["me"]["id"].string
            // A creation date never changes: one read by the task's own page is kept across list reads.
            var created: [String: String] = [:]
            for old in cache[id]?["tasks"].elements ?? [] { if let task = old["id"].string, let at = old["createdAt"].string, !at.isEmpty { created[task] = at } }
            let rows = BackendConnectedTasksMapping.rows(answer.data).prefix(BackendConnectedTasksMapping.maximumRows)
                .compactMap { BackendConnectedTasksMapping.task($0, me: me) }
                .map { task -> NativeRPCValue in
                    guard task["createdAt"].string?.isEmpty != false, let at = task["id"].string.flatMap({ created[$0] }) else { return task }
                    return task.setting("createdAt", .string(at))
                }
            let total = answer.data["total"].number ?? Double(rows.count)
            cache[id] = .object([.init("at", .number(now())), .init("total", .number(total)), .init("tasks", .array(rows))])
            if (people[id]?["at"].number ?? 0) < now() - 10 * 60_000, let tool = profile.people,
               let answer = try? await client.call(tool.name, .object([])) {
                people[id] = .object([.init("at", .number(now())), .init("people", .array(BackendConnectedTasksMapping.people(answer.data).people))])
            }
            replace(try connection(id).setting("problem", .null))
            try save()
        } catch {
            replace((try? connection(id))?.setting("problem", .string(error.localizedDescription)) ?? row)
            try? save()
            await changed()
            throw error
        }
        await changed()
        return try tasks(id)
    }

    /// One task, opened: everything its page shows. The list's copy of the row is updated too.
    public func detail(_ id: String, remoteID: String) async throws -> NativeRPCValue {
        let row = try connection(id), profile = profile(row)
        let remote = try Self.remoteID(remoteID)
        guard let get = profile.get, let argument = get.idArgument else {
            guard let cached = cachedRow(id, remote) else { throw NativeRPCError.invalidArguments("That task is not in the last list read from this system.") }
            return cached.setting("connection", view(row)).setting("handoff", handoff(id, remote).map(handoffView) ?? .null)
        }
        let answer = try await client(id, row: row).call(get.name, .object([.init(argument, .string(remote))]))
        guard let detail = BackendConnectedTasksMapping.detail(answer.data, me: row["me"]["id"].string) else {
            throw NativeRPCError(code: "malformed", message: "The system's answer for that task could not be read.")
        }
        keep(id, detail)
        return detail.setting("connection", view(try connection(id))).setting("handoff", handoff(id, remote).map(handoffView) ?? .null)
    }

    func cachedRow(_ id: String, _ remote: String) -> NativeRPCValue? {
        cache[id]?["tasks"].elements?.first { $0["id"].string == remote }
    }

    /// Keeps the list's copy of a task in step with what was just read (row fields only).
    func keep(_ id: String, _ detail: NativeRPCValue) {
        guard let remote = detail["id"].string, var current = cache[id] else { return }
        let fields = ["id", "title", "status", "priority", "startDate", "dueDate", "board", "labels", "assignee", "assignedToMe", "raisedByMe", "url", "createdAt",
                      "createdBy", "description", "taskType", "startTime", "dueTime", "archivedAt"]
        var row = NativeRPCValue.object(fields.compactMap { detail.has($0) ? .init($0, detail[$0]) : nil })
        if let old = current["tasks"].elements?.first(where: { $0["id"].string == remote }) {
            for key in fields where !detail.has(key) && old.has(key) { row = row.setting(key, old[key]) }
        }
        row = row.setting("readAt", .number(now()))
        var tasks = current["tasks"].elements ?? []
        if let index = tasks.firstIndex(where: { $0["id"].string == remote }) { tasks[index] = row } else { tasks.insert(row, at: 0) }
        current = current.setting("tasks", .array(tasks))
        cache[id] = current
        saveCacheSoon()
    }

    static func remoteID(_ value: String) throws -> String {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 200, !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeRPCError.invalidArguments("Name the task by its id from the list.")
        }
        return id
    }

    private func handoff(_ id: String, _ remote: String) -> NativeRPCValue? {
        handoffs.last { $0["connection"].string == id && $0["remoteId"].string == remote }
    }

    // MARK: Changing

    /// The gate every change from here passes. Off refuses; Ask needs the owner's yes in the app.
    func gate(_ row: NativeRPCValue, via: Via, confirmed: Bool, what: String) throws {
        guard row["enabled"].bool != false else { throw NativeRPCError(code: "off", message: "This connection is switched off.") }
        let mode = Changes(rawValue: row["changes"].string ?? "ask") ?? .ask
        if mode == .off {
            throw NativeRPCError(code: "read-only", message: "\(row["name"].string ?? "This system") is connected read only. Change “Changes made here” in Settings → Tasks to send changes.")
        }
        if mode == .ask, via == .app, !confirmed {
            throw NativeRPCError(code: "needs-confirmation", message: "Send this to \(row["name"].string ?? "the system"): \(what)?")
        }
    }

    /// Status, due date and/or assignee of one task. `change` = {status?, dueDate?, assignee?, confirm?}.
    public func change(_ id: String, remoteID: String, change: NativeRPCValue, via: Via, confirmed: Bool = false) async throws -> NativeRPCValue {
        let row = try connection(id), profile = profile(row), remote = try Self.remoteID(remoteID)
        var updates: [NativeRPCValue.Field] = [], words: [String] = []
        var status: String?
        if change.has("status") {
            guard let value = change["status"].string, !value.isEmpty else { throw NativeRPCError.invalidArguments("status is one of the system's status words.") }
            guard let tool = profile.status, tool.idArgument != nil, profile.statusArgument != nil else {
                throw NativeRPCError(code: "not-offered", message: "This system does not let its status be changed from outside.")
            }
            if !profile.statuses.isEmpty, !profile.statuses.contains(value) {
                throw NativeRPCError.invalidArguments("Status is one of: \(profile.statuses.joined(separator: ", ")).")
            }
            status = value; words.append("status → \(value)")
        }
        if change.has("dueDate") {
            guard let argument = profile.dueArgument, profile.update != nil else {
                throw NativeRPCError(code: "not-offered", message: "This system does not let due dates be changed from outside.")
            }
            let value = change["dueDate"].isNullish ? "" : (change["dueDate"].string ?? "?")
            guard value.isEmpty || value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("A due date is YYYY-MM-DD, or empty to clear it.")
            }
            updates.append(.init(argument, .string(value))); words.append(value.isEmpty ? "clear the due date" : "due \(value)")
        }
        if change.has("assignee") {
            guard let argument = profile.assigneeArgument, profile.update != nil else {
                throw NativeRPCError(code: "not-offered", message: "This system does not let the assignee be changed from outside.")
            }
            guard let person = change["assignee"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !person.isEmpty, person.count <= 200 else {
                throw NativeRPCError.invalidArguments("Name the person by their id or name from the system's people list.")
            }
            updates.append(.init(argument, .string(person)))
            let name = people[id]?["people"].elements?.first { $0["id"].string == person }?["name"].string ?? person
            words.append("assign to \(name)")
        }
        guard !words.isEmpty else { throw NativeRPCError.invalidArguments("Say what to change: status, dueDate or assignee.") }
        try gate(row, via: via, confirmed: confirmed, what: words.joined(separator: ", "))
        let client = try client(id, row: row)
        if !updates.isEmpty, let update = profile.update, let argument = update.idArgument {
            var arguments = [NativeRPCValue.Field(argument, .string(remote))] + updates
            if change["confirm"].bool == true, let confirm = profile.confirmArgument { arguments.append(.init(confirm, .bool(true))) }
            do { _ = try await client.call(update.name, .object(arguments)) }
            catch let error as NativeRPCError where error.code == "refused" && profile.confirmArgument != nil && change["confirm"].bool != true
                        && error.message.range(of: "confirm", options: .caseInsensitive) != nil {
                // The system wants an explicit yes (e.g. replacing someone's task). Only a click on "Replace" sends it.
                throw NativeRPCError(code: "confirm-needed", message: error.message.replacingOccurrences(of: #"\s*[—-]?\s*pass confirm: true[^.]*\.?"#, with: "", options: .regularExpression))
            }
        }
        func applied(_ row: NativeRPCValue, status: String?) -> NativeRPCValue {
            var row = row
            if let status { row = row.setting("status", .string(status)) }
            if change.has("dueDate") { row = row.setting("dueDate", change["dueDate"].string.map { $0.isEmpty ? .null : .string($0) } ?? .null) }
            return row
        }
        if let status, let tool = profile.status, let argument = tool.idArgument, let statusArgument = profile.statusArgument {
            do { _ = try await client.call(tool.name, .object([.init(argument, .string(remote)), .init(statusArgument, .string(status))])) }
            catch where !updates.isEmpty {
                // The date or assignee really changed: show it, and say plainly that only the status did not.
                _ = try? await reread(id, remote: remote, fallback: { applied($0, status: nil) })
                await changed()
                let sent = words.filter { !$0.hasPrefix("status → ") }.joined(separator: ", ")
                throw NativeRPCError(code: (error as? NativeRPCError)?.code ?? "failed",
                                     message: "Changed (\(sent)), but the status was not: \(error.localizedDescription)")
            }
        }
        let after = try await reread(id, remote: remote, fallback: { applied($0, status: status) })
        await changed()
        return after
    }

    /// Adds a comment, written as the connected person.
    public func comment(_ id: String, remoteID: String, body: String, via: Via, confirmed: Bool = false) async throws -> NativeRPCValue {
        let row = try connection(id), profile = profile(row), remote = try Self.remoteID(remoteID)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NativeRPCError.invalidArguments("Write the comment first.") }
        guard text.count <= Self.commentLimit else { throw NativeRPCError.invalidArguments("A comment is at most \(Self.commentLimit) characters.") }
        guard let tool = profile.comment, let argument = tool.idArgument, let bodyArgument = profile.commentBody else {
            throw NativeRPCError(code: "not-offered", message: "This system does not take comments from outside.")
        }
        try gate(row, via: via, confirmed: confirmed, what: "a comment")
        _ = try await client(id, row: row).call(tool.name, .object([.init(argument, .string(remote)), .init(bodyArgument, .string(text))]))
        let after = try await reread(id, remote: remote, fallback: { $0 })
        await changed()
        return after
    }

    private func reread(_ id: String, remote: String, fallback: (NativeRPCValue) -> NativeRPCValue) async throws -> NativeRPCValue {
        if profile(try connection(id)).get != nil {
            do { return try await detail(id, remoteID: remote) } catch { problem("A connected task changed but could not be read again: " + error.localizedDescription) }
        }
        guard let cached = cachedRow(id, remote) else { return .object([.init("id", .string(remote))]) }
        let row = fallback(cached); keep(id, row)
        return row
    }

    // MARK: Handing to an agent

    /// Makes a local task for one of the app's task agents from this remote task. When the
    /// agent finishes, its answer is posted back as a comment (and the status set to done
    /// if `markDone`). Handing over is the yes for that comment.
    public func handToAgent(_ id: String, remoteID: String, agent agentID: String, project: String?, markDone: Bool?,
                            via: Via, confirmed: Bool = false) async throws -> NativeRPCValue {
        let row = try connection(id), profile = profile(row), remote = try Self.remoteID(remoteID)
        guard profile.comment != nil, profile.commentBody != nil else {
            throw NativeRPCError(code: "not-offered", message: "This system does not take comments, so an agent's answer could not be posted back.")
        }
        guard let agent = try await agents.agent(agentID) else {
            throw NativeRPCError.invalidArguments("There is no task agent called \(agentID). Settings → Tasks lists them.")
        }
        let done = markDone ?? (row["markDone"].bool == true)
        if done, profile.doneStatus == nil || profile.status == nil {
            throw NativeRPCError(code: "not-offered", message: "This system does not let its status be set to done from outside.")
        }
        if let open = handoff(id, remote), open["postedAt"].isNullish, open["closedAt"].isNullish {
            throw NativeRPCError.invalidArguments("This task is already with \(open["agentName"].string ?? "an agent"). Wait for its answer first.")
        }
        let name = row["name"].string ?? "the system"
        try gate(row, via: via, confirmed: confirmed,
                 what: "when \(agent.name) finishes, its answer as a comment" + (done ? " and status \(profile.doneStatus!)" : ""))
        let detail = try await detail(id, remoteID: remote)
        let folder = (project?.isEmpty == false ? project : agent.project) ?? ""
        guard !folder.isEmpty else {
            throw NativeRPCError.invalidArguments("Choose the project folder \(agent.name) works in (it has no default project).")
        }
        let brief = Self.brief(detail, system: name, markDone: done ? profile.doneStatus : nil)
        let local = try await agents.create(.object([
            .init("title", .string(String((detail["title"].string ?? "Task").prefix(300)))),
            .init("instructions", .string(brief)), .init("assignee", .string(agentID)), .init("project", .string(folder)),
            .init("board", .string(name)),
        ]))
        let record = NativeRPCValue.object([
            .init("connection", .string(id)), .init("remoteId", .string(remote)), .init("localTaskId", .string(local)),
            .init("agent", .string(agentID)), .init("agentName", .string(agent.name)), .init("markDone", .bool(done)),
            .init("title", detail["title"]), .init("createdAt", .number(now())), .init("postedAt", .null),
            .init("statusSetAt", .null), .init("problem", .null), .init("closedAt", .null),
        ])
        handoffs.append(record)
        try save()
        await changed()
        return handoffView(record)
    }

    /// The local task's instructions: the remote task in plain text, bounded.
    static func brief(_ task: NativeRPCValue, system: String, markDone: String?) -> String {
        var lines = ["This task comes from \(system), a connected task system. Do the work here. When you finish, your final answer is posted back to \(system) as a comment on the task" + (markDone.map { " and its status is set to \($0)" } ?? "") + ", so end with a short, clear summary of what you did and what is left.", ""]
        lines.append("Task: " + (task["title"].string ?? "Untitled task"))
        let facts = [task["status"].string.map { "Status: \($0)" }, task["priority"].string.map { "Priority: \($0)" },
                     task["dueDate"].string.map { "Due: \($0)" }, task["board"].string.map { "Board: \($0)" },
                     task["assignee"]["name"].string.map { "Assigned to: \($0)" }].compactMap { $0 }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        if let labels = task["labels"].elements?.compactMap(\.string), !labels.isEmpty { lines.append("Labels: " + labels.joined(separator: ", ")) }
        if let description = task["description"].string, !description.isEmpty { lines += ["", "Details:", description] }
        let subtasks = task["subtasks"].elements ?? []
        if !subtasks.isEmpty {
            lines += ["", "Subtasks:"] + subtasks.prefix(50).map { "- [\($0["done"].bool == true ? "x" : " ")] \($0["title"].string ?? "")" }
        }
        for list in (task["checklists"].elements ?? []).prefix(10) {
            lines += ["", "Checklist: " + (list["title"].string ?? "")] + (list["items"].elements ?? []).prefix(50).map { "- [\($0["done"].bool == true ? "x" : " ")] \($0["title"].string ?? "")" }
        }
        let comments = (task["comments"].elements ?? []).suffix(10)
        if !comments.isEmpty {
            lines += ["", "Latest comments:"] + comments.map { "- \($0["by"].string ?? "someone")\($0["at"].string.map { " (\(String($0.prefix(10))))" } ?? ""): \(String(($0["body"].string ?? "").prefix(800)))" }
        }
        return String(lines.joined(separator: "\n").prefix(19_000))
    }

    /// Called whenever local tasks change: posts each finished agent's answer back, once.
    public func agentResults() async {
        guard started else { return }
        if checking { checkAgain = true; return }
        checking = true
        defer { checking = false }
        repeat {
            checkAgain = false
            for record in handoffs where record["postedAt"].isNullish && record["closedAt"].isNullish {
                await settle(record)
            }
        } while checkAgain
    }

    private func settle(_ record: NativeRPCValue) async {
        guard let local = record["localTaskId"].string, let id = record["connection"].string, let remote = record["remoteId"].string else { return }
        let outcome: AgentOutcome?
        do { outcome = try await agents.outcome(local) } catch { return }
        guard let outcome else { return }
        func update(_ patch: [(String, NativeRPCValue)]) {
            guard let index = handoffs.firstIndex(where: { $0["localTaskId"].string == local && $0["remoteId"].string == remote }) else { return }
            var row = handoffs[index]; for (key, value) in patch { row = row.setting(key, value) }; handoffs[index] = row
            try? save()
        }
        if outcome.stopped || outcome.answer == nil {
            update([("closedAt", .number(now())), ("problem", .string("The agent stopped without an answer, so nothing was posted."))])
            await changed(); return
        }
        update([("closedAt", .number(now()))]) // claimed: never posted twice, even if this fails half way
        do {
            let row = try connection(id), profile = profile(row)
            try gate(row, via: .tool, confirmed: true, what: "")
            guard let tool = profile.comment, let argument = tool.idArgument, let body = profile.commentBody else {
                throw NativeRPCError(code: "not-offered", message: "The system no longer takes comments.")
            }
            let agentName = record["agentName"].string ?? "A task agent"
            let head = "\(agentName) (a Terminal Deck task agent) finished this task:\n\n"
            var text = head + (outcome.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > Self.commentLimit {
                let tail = "\n\n… (shortened; the full answer is in Terminal Deck)"
                text = String(text.prefix(Self.commentLimit - tail.count)) + tail
            }
            let client = try client(id, row: row)
            _ = try await client.call(tool.name, .object([.init(argument, .string(remote)), .init(body, .string(text))]))
            update([("postedAt", .number(now())), ("problem", .null)])
            if record["markDone"].bool == true, let done = profile.doneStatus, let status = profile.status, let statusID = status.idArgument,
               let statusArgument = profile.statusArgument {
                _ = try await client.call(status.name, .object([.init(statusID, .string(remote)), .init(statusArgument, .string(done))]))
                update([("statusSetAt", .number(now()))])
            }
            _ = try? await reread(id, remote: remote, fallback: { $0 })
        } catch {
            update([("problem", .string("Not posted back: " + error.localizedDescription))])
            problem("A connected task's agent answer was not posted back: " + error.localizedDescription)
        }
        await changed()
    }
}
