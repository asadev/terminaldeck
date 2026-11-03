import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// A contract fake of a connected task system: an MCP server over Streamable HTTP that
/// answers like the reference task module does (event-stream answers, a summary line then
/// JSON, refusals in its own words, the same access rules: a person sees tasks assigned
/// to them, raised by them or that they were added to; only the main assignee or the
/// person who raised it may change it; replacing a main assignee needs confirm).
final class ConnectedTasksFake: BackendConnectedTasksTransport, @unchecked Sendable {
    struct Task { var id, title, status: String; var priority: String?; var due: String?; var board: String
        var assignee: String?; var creator: String; var others: [String] = []; var description: String? = nil
        var comments: [(by: String, body: String)] = []; var related: [NativeRPCValue] = [] }
    let lock = NSLock()
    let token: String
    let me = "u-me"
    var tasks: [Task]
    var people = ["u-me": "Owner Person", "u-ali": "Ali Khan", "u-sara": "Sara Lee"]
    var calls: [(tool: String, args: NativeRPCValue)] = []
    var status429 = false
    var refuseStatus = false
    var toolNames = ["list_tasks", "get_task", "set_task_status", "add_comment", "update_task", "list_team", "list_leads"]

    init(token: String = "secret-token-1234") {
        self.token = token
        tasks = [
            Task(id: "t1", title: "Call the landlord", status: "To-Do", priority: "High", due: "2026-10-01", board: "Leads", assignee: "u-me", creator: "u-ali"),
            Task(id: "t2", title: "Photos for the listing", status: "In Progress", priority: nil, due: "2099-01-01", board: "Listings", assignee: "u-ali", creator: "u-me"),
            Task(id: "t3", title: "Old finished one", status: "Done", priority: nil, due: "2026-09-01", board: "Leads", assignee: "u-me", creator: "u-me"),
            Task(id: "t4", title: "Not mine at all", status: "To-Do", priority: nil, due: nil, board: "Ops", assignee: "u-sara", creator: "u-sara"),
            Task(id: "t5", title: "Added to it", status: "Stuck", priority: "Low", due: nil, board: "Follow-ups", assignee: "u-sara", creator: "u-sara", others: ["u-me"]),
        ]
    }

    var writes: [String] { lock.withLock { calls.map(\.tool).filter { !["list_tasks", "get_task", "list_team"].contains($0) } } }
    func task(_ id: String) -> Task? { lock.withLock { tasks.first { $0.id == id } } }

    private func visible(_ t: Task) -> Bool { t.assignee == me || t.creator == me || t.others.contains(me) }
    private func line(_ t: Task) -> NativeRPCValue {
        .object([.init("id", .string(t.id)), .init("title", .string(t.title)), .init("status", .string(t.status)),
                 .init("priority", t.priority.map(NativeRPCValue.string) ?? .null), .init("start_date", .null),
                 .init("due_date", t.due.map(NativeRPCValue.string) ?? .null), .init("board", .string(t.board)),
                 .init("assignee", t.assignee.map { .object([.init("id", .string($0)), .init("name", .string(people[$0] ?? "?"))]) } ?? .null),
                 .init("assigned_to_me", .bool(t.assignee == me || t.others.contains(me))), .init("raised_by_me", .bool(t.creator == me))])
    }
    private func toolResult(_ summary: String, _ data: NativeRPCValue) -> NativeRPCValue {
        .object([.init("content", .array([.object([.init("type", .string("text")), .init("text", .string(summary + "\n\n" + data.compact))])]))])
    }
    private func refusal(_ sentence: String) -> NativeRPCValue {
        .object([.init("isError", .bool(true)), .init("content", .array([.object([.init("type", .string("text")), .init("text", .string(sentence))])]))])
    }
    private func schema(_ props: [String], required: [String] = [], statusEnum: Bool = false) -> NativeRPCValue {
        .object([.init("type", .string("object")), .init("properties", .object(props.map { name in
            .init(name, name == "status" && statusEnum ? .object([.init("type", .string("string")), .init("enum", .array(["To-Do", "Working on it", "In Progress", "Done", "Stuck"].map(NativeRPCValue.string)))])
                       : .object([.init("type", .string("string"))]))
        })), .init("required", .array(required.map(NativeRPCValue.string)))])
    }

    func call(_ name: String, _ a: NativeRPCValue) -> NativeRPCValue {
        lock.withLock {
            calls.append((name, a))
            func find(_ id: String?) -> Int? {
                guard let id, let i = tasks.firstIndex(where: { $0.id == id }), visible(tasks[i]) else { return nil }
                return i
            }
            switch name {
            case "list_tasks":
                let rows = tasks.filter { visible($0) && (a["include_done"].bool == true || $0.status != "Done") }
                let limit = Int(a["limit"].number ?? 50)
                return toolResult("\(rows.count) tasks found.", .object([.init("total", .number(Double(rows.count))), .init("tasks", .array(rows.prefix(limit).map(line)))]))
            case "get_task":
                guard let i = find(a["task_id"].string) else { return refusal("Task not found or not yours") }
                let t = tasks[i]
                return toolResult("“\(t.title)”", .object([
                    .init("task", line(t).setting("description", t.description.map(NativeRPCValue.string) ?? .null).setting("created_by", .string(t.creator)).setting("created_at", .string("2026-09-15T08:00:00Z"))
                        .setting("related", .array(t.related))),
                    .init("people", .object([.init("main", t.assignee.map { .object([.init("id", .string($0)), .init("name", .string(people[$0] ?? "?"))]) } ?? .null),
                                             .init("others", .array(t.others.map { .object([.init("id", .string($0)), .init("name", .string(people[$0] ?? "?"))]) }))])),
                    .init("subtasks", .array([.object([.init("id", .string("s1")), .init("title", .string("First step")), .init("done", .bool(true))])])),
                    .init("checklists", .array([.object([.init("id", .string("c1")), .init("title", .string("Before")), .init("items", .array([.object([.init("id", .string("i1")), .init("title", .string("Check keys")), .init("done", .bool(false))])]))])])),
                    .init("page", .object([.init("labels", .array([.string("urgent")]))])),
                    .init("activity", .array([.object([.init("at", .string("2026-10-01T09:00:00Z")), .init("kind", .string("priority")), .init("by", .string("Ali Khan")), .init("detail", .object([.init("from", .null), .init("to", .string("High"))]))])])),
                    .init("comments", .array(t.comments.enumerated().map { .object([.init("id", .string("m\($0.offset)")), .init("by", .string($0.element.by)), .init("at", .string("2026-10-02T10:00:00Z")), .init("body", .string($0.element.body))]) })),
                ]))
            case "set_task_status":
                guard let i = find(a["task_id"].string) else { return refusal("Task not found or not yours") }
                if refuseStatus { return refusal("Status changes are locked on this board") }
                guard tasks[i].assignee == me || tasks[i].creator == me else { return refusal("Only the task's main assignee or the person who raised it can change its status") }
                tasks[i].status = a["status"].string ?? tasks[i].status
                return toolResult("Status is now \(tasks[i].status).", .object([.init("task_id", .string(tasks[i].id))]))
            case "add_comment":
                guard let i = find(a["task_id"].string) else { return refusal("Task not found or not yours") }
                tasks[i].comments.append((people[me]!, a["body"].string ?? ""))
                return toolResult("Comment added.", .object([.init("comment_id", .string("m\(tasks[i].comments.count)"))]))
            case "update_task":
                guard let i = find(a["task_id"].string) else { return refusal("Task not found or not yours") }
                guard tasks[i].assignee == me || tasks[i].creator == me else { return refusal("Only the task's main assignee or the person who raised it may") }
                if let due = a["due_date"].string { tasks[i].due = due.isEmpty ? nil : due }
                if let related = a["related"].elements {
                    if related.count < tasks[i].related.count, a["confirm"].bool != true { return refusal("This would remove related records. Nothing was saved — pass confirm: true.") }
                    tasks[i].related = related
                }
                if let who = a["assignee"].string {
                    guard people[who] != nil else { return refusal("No teammate called \(who).") }
                    if let current = tasks[i].assignee, current != who, a["confirm"].bool != true {
                        return refusal("This would replace the main assignee \(people[current]!) with \(people[who]!). Nothing was saved — pass confirm: true after checking with the person.")
                    }
                    tasks[i].assignee = who
                }
                return toolResult("Saved.", .object([.init("task_id", .string(tasks[i].id))]))
            case "list_leads":
                let words = (a["search"].string ?? "").lowercased()
                let leads = [("l1", "Danel Ortiz", "New Lead"), ("l2", "Dana Price", "Viewing Scheduled"), ("l3", "Omar Said", "Qualified")].filter { $0.1.lowercased().contains(words) }
                return toolResult("\(leads.count) leads.", .object([.init("total", .number(Double(leads.count))), .init("leads", .array(leads.map {
                    .object([.init("id", .string($0.0)), .init("client", .string($0.1)), .init("stage_label", .string($0.2))]) }))]))
            case "list_team":
                return toolResult("\(people.count) people.", .object([.init("you", .string(me)), .init("people", .array(people.sorted { $0.key < $1.key }.map {
                    .object([.init("id", .string($0.key)), .init("name", .string($0.value))]) }))]))
            default:
                return refusal("Unknown tool")
            }
        }
    }

    func send(_ request: BackendConnectedTasksHTTPRequest) async throws -> BackendConnectedTasksHTTPResponse {
        if request.method == "GET" {
            guard request.url.path.hasPrefix("/.well-known/oauth-protected-resource") else { return .init(status: 404, body: Data()) }
            return .init(status: 200, headers: ["Content-Type": "application/json"],
                         body: Data(#"{"resource":"https://tasks.example/api/mcp","resource_documentation":"https://tasks.example/me/ai"}"#.utf8))
        }
        guard request.headers["Authorization"] == "Bearer " + token else { return .init(status: 401, body: Data(#"{"error":"invalid_token"}"#.utf8)) }
        if lock.withLock({ status429 }) { return .init(status: 429, headers: ["Retry-After": "12"], body: Data()) }
        let message = try NativeRPCValue.parseJSON(request.body)
        guard let id = message["id"].number else { return .init(status: 202, body: Data()) }
        let result: NativeRPCValue
        switch message["method"].string {
        case "initialize":
            result = .object([.init("protocolVersion", .string("2025-06-18")), .init("capabilities", .object([.init("tools", .object([]))])),
                              .init("serverInfo", .object([.init("name", .string("fake-tasks")), .init("title", .string("Fake Tasks"))]))])
        case "tools/list":
            let all: [String: NativeRPCValue] = [
                "list_tasks": schema(["ownership", "status", "due", "search", "include_done", "limit"]),
                "get_task": schema(["task_id"], required: ["task_id"]),
                "set_task_status": schema(["task_id", "status"], required: ["task_id", "status"], statusEnum: true),
                "add_comment": schema(["task_id", "body", "reply_to"], required: ["task_id", "body"]),
                "update_task": schema(["task_id", "text", "due_date", "assignee", "confirm"], required: ["task_id"])
                    .setting("properties", schema(["task_id", "text", "due_date", "assignee", "confirm"])["properties"].setting("related", .object([
                        .init("type", .string("array")), .init("items", .object([.init("type", .string("object")), .init("properties", .object([
                            .init("area", .object([.init("type", .string("string")), .init("enum", .array(["person", "listing", "lead"].map(NativeRPCValue.string)))])),
                            .init("id", .object([])), .init("label", .object([]))]))]))]))),
                "list_leads": schema(["search", "page_size"]),
                "list_team": schema([]),
            ]
            let names = lock.withLock { toolNames }
            result = .object([.init("tools", .array(names.compactMap { name in all[name].map {
                .object([.init("name", .string(name)), .init("description", .string(name)), .init("inputSchema", $0)]) } }))])
        case "tools/call":
            result = call(message["params"]["name"].string ?? "", message["params"]["arguments"])
        default:
            result = .object([])
        }
        let envelope = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(id)), .init("result", result)]).encodedJSON()
        return .init(status: 200, headers: ["Content-Type": "text/event-stream"],
                     body: Data("event: message\ndata: ".utf8) + envelope + Data("\n\n".utf8))
    }
}

@Suite("Connected task systems: discovery, reading, changes back, agents, MCP tools")
struct ConnectedTasksTests {
    static let address = "https://tasks.example/api/mcp"

    actor Agents {
        var made: [NativeRPCValue] = []
        var outcomes: [String: BackendConnectedTasksService.AgentOutcome] = [:]
        func create(_ input: NativeRPCValue) -> String { made.append(input); return "local:\(made.count)" }
        func finish(_ id: String, _ outcome: BackendConnectedTasksService.AgentOutcome) { outcomes[id] = outcome }
        func outcome(_ id: String) -> BackendConnectedTasksService.AgentOutcome? { outcomes[id] }
    }

    func service(_ fake: ConnectedTasksFake, agents: Agents = Agents(), secrets: BackendConnectedTasksMemorySecrets = .init(),
                 directory: URL? = nil) async throws -> BackendConnectedTasksService {
        let persistence = try BackendTaskPersistence(directory: directory ?? URL(fileURLWithPath: "/ConnectedTasks-memory"),
                                                     ownership: directory == nil ? .memory : .exclusive)
        let service = BackendConnectedTasksService(persistence: persistence, secrets: secrets, transport: fake,
            agents: .init(create: { await agents.create($0) }, outcome: { await agents.outcome($0) },
                          agent: { id in id == "builder" ? (name: "Builder", project: "/work/app") : id == "loose" ? (name: "Loose", project: nil) : nil }))
        try await service.start()
        return service
    }

    func connect(_ service: BackendConnectedTasksService, changes: String = "ask", token: String = "secret-token-1234") async throws -> String {
        let view = try await service.connect(.object([.init("name", .string("Work CRM")), .init("url", .string(Self.address)),
                                                      .init("token", .string(token)), .init("changes", .string(changes))]))
        return try view["id"].requireString("id")
    }

    // MARK: Wire

    @Test func readsEventStreamsAndTheSummaryThenJSONShape() throws {
        #expect(BackendConnectedTasksClient.events("event: message\ndata: {\"a\":1}\n\nevent: message\ndata: {\"b\":\ndata: 2}\n\n") == ["{\"a\":1}", "{\"b\":\n2}"])
        let answer = try BackendConnectedTasksClient.answer(.object([.init("content", .array([.object([.init("type", .string("text")),
            .init("text", .string("2 tasks found.\n\n{\"tasks\":[]}"))])]))]))
        #expect(answer.summary == "2 tasks found." && answer.data["tasks"].elements == [])
        let structured = try BackendConnectedTasksClient.answer(.object([.init("content", .array([])), .init("structuredContent", .object([.init("x", .number(1))]))]))
        #expect(structured.data["x"].number == 1)
        do { _ = try BackendConnectedTasksClient.answer(.object([.init("isError", .bool(true)), .init("content", .array([.object([.init("type", .string("text")), .init("text", .string("Task not found or not yours"))])]))])); Issue.record("Refusal read as success") }
        catch { #expect((error as? NativeRPCError)?.code == "refused" && error.localizedDescription == "Task not found or not yours") }
        for bad in ["http://tasks.example/mcp", "ftp://x/y", "https://user:pw@x/y", "notaurl"] {
            #expect(throws: (any Error).self) { try BackendConnectedTasksClient.checkEndpoint(URL(string: bad) ?? URL(fileURLWithPath: "/")) }
        }
        try BackendConnectedTasksClient.checkEndpoint(URL(string: "http://127.0.0.1:3000/mcp")!)
    }

    @Test func discoversCapabilitiesFromToolNamesAndSchemas() async throws {
        let fake = ConnectedTasksFake()
        let client = try BackendConnectedTasksClient(endpoint: URL(string: Self.address)!, token: fake.token, transport: fake)
        let profile = BackendConnectedTasksProfile.discover(try await client.tools())
        #expect(profile.capabilities == [.list, .read, .status, .comment, .dueDate, .assignee, .people])
        #expect(profile.statuses == ["To-Do", "Working on it", "In Progress", "Done", "Stuck"] && profile.doneStatus == "Done")
        #expect(profile.get?.idArgument == "task_id" && profile.commentBody == "body" && profile.confirmArgument == "confirm")
        #expect(BackendConnectedTasksProfile(wire: profile.wire) == profile)
        // Another product's spelling works too; a missing tool is simply not offered.
        let other = BackendConnectedTasksProfile.discover([
            .init(name: "tasks_list", inputSchema: .object([.init("properties", .object([.init("max", .object([]))]))])),
            .init(name: "tasks_get", inputSchema: .object([.init("properties", .object([.init("id", .object([]))]))])),
            .init(name: "add_task_comment", inputSchema: .object([.init("properties", .object([.init("id", .object([])), .init("text", .object([]))]))])),
        ])
        #expect(other.capabilities == [.list, .read, .comment] && other.listLimit == "max" && other.commentBody == "text")
    }

    // MARK: Connecting

    @Test func aWrongTokenSavesNothingAndTheRightOneIsKeptOnlyInTheSecretStore() async throws {
        let fake = ConnectedTasksFake(), secrets = BackendConnectedTasksMemorySecrets()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connected-tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try await service(fake, secrets: secrets, directory: directory)
        do { _ = try await connect(tasks, token: "wrong-token"); Issue.record("Wrong token connected") }
        catch { #expect((error as? NativeRPCError)?.code == "unauthorized") }
        #expect(try await tasks.state()["connections"].elements?.isEmpty == true)
        let id = try await connect(tasks)
        #expect(try secrets.read(id) == fake.token)
        let state = try await tasks.state()
        let system = try #require(ConnectedTaskSystem(state["connections"].elements![0]))
        #expect(system.me?.name == "Owner Person" && system.docsURL == "https://tasks.example/me/ai" && system.tokenEnding == "…1234")
        #expect(system.capabilities.count == 7 && system.changes == .ask)
        // The token is in no answer and not in the settings file.
        #expect(!state.compact.contains(fake.token))
        let file = try String(contentsOf: directory.appendingPathComponent(BackendConnectedTasksService.fileName), encoding: .utf8)
        #expect(!file.contains(fake.token) && file.contains("Work CRM"))
        // A restart reads the same connection back.
        let again = try await service(fake, secrets: secrets, directory: directory)
        #expect(try await again.state()["connections"].elements?.first?["id"].string == id)
        try await again.remove(id)
        #expect(try secrets.read(id) == nil)
    }

    @Test func aSystemWithoutATaskListIsRefused() async throws {
        let fake = ConnectedTasksFake(); fake.toolNames = ["get_task", "add_comment"]
        let tasks = try await service(fake)
        do { _ = try await connect(tasks); Issue.record("Connected without a list tool") }
        catch { #expect((error as? NativeRPCError)?.code == "no-tasks") }
    }

    // MARK: Reading

    @Test func readsTheListIntoPilesAndOpensOneTask() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake)
        let id = try await connect(tasks)
        let list = try #require(ConnectedTaskList(try await tasks.refresh(id)))
        #expect(Set(list.tasks.map(\.id)) == ["t1", "t2", "t3", "t5"]) // never someone else's task
        #expect(fake.calls.first { $0.tool == "list_tasks" }?.args["include_done"].bool == true)
        let t1 = try #require(list.tasks.first { $0.id == "t1" })
        #expect(t1.assignedToMe && !t1.raisedByMe && t1.dueDate == "2026-10-01" && t1.board == "Leads" && t1.assigneeName == "Owner Person")
        let counts = ConnectedTasksFilter.counts(list.tasks, doneStatus: "Done")
        #expect(counts[.all] == 3 && counts[.assignedToMe] == 2 && counts[.raisedByMe] == 1 && counts[.withOthers] == 1)
        let shown = ConnectedTasksFilter.apply(list.tasks, doneStatus: "Done", today: "2026-10-09")
        #expect(shown.map(\.id) == ["t1", "t2", "t5"]) // overdue first, undated last, Done folded
        #expect(ConnectedTasksFilter.due(t1, today: "2026-10-09", doneStatus: "Done") == .overdue)
        #expect(ConnectedTasksFilter.apply(list.tasks, showDone: true, doneStatus: "Done", today: "2026-10-09").last?.id == "t3")
        #expect(ConnectedTasksFilter.apply(list.tasks, search: "photos", doneStatus: "Done", today: "2026-10-09").map(\.id) == ["t2"])
        let detail = try #require(ConnectedTaskDetail(try await tasks.detail(id, remoteID: "t1")))
        #expect(detail.subtasks.first?.done == true && detail.checklists.first?.items.first?.title == "Check keys")
        #expect(detail.row.labels == ["urgent"] && detail.activity.first?.text == "priority: High")
        do { _ = try await tasks.detail(id, remoteID: "t4"); Issue.record("Opened someone else's task") }
        catch { #expect(error.localizedDescription == "Task not found or not yours") }
        #expect(fake.writes.isEmpty)
    }

    // MARK: Changes back

    @Test func askModeNeedsTheOwnersYesOffRefusesAllowSends() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake)
        let id = try await connect(tasks)
        _ = try await tasks.refresh(id)
        do { _ = try await tasks.change(id, remoteID: "t1", change: .object([.init("status", .string("Done"))]), via: .app); Issue.record("Sent without a yes") }
        catch { #expect((error as? NativeRPCError)?.code == "needs-confirmation" && error.localizedDescription.contains("status → Done")) }
        #expect(fake.writes.isEmpty)
        let after = try await tasks.change(id, remoteID: "t1", change: .object([.init("status", .string("Done"))]), via: .app, confirmed: true)
        #expect(fake.task("t1")?.status == "Done" && after["status"].string == "Done")
        #expect(try await tasks.tasks(id)["tasks"].elements?.first { $0["id"].string == "t1" }?["status"].string == "Done")
        do { _ = try await tasks.change(id, remoteID: "t1", change: .object([.init("status", .string("Archived"))]), via: .app, confirmed: true); Issue.record("Unknown status sent") }
        catch { #expect(error.localizedDescription.contains("To-Do")) }
        _ = try await tasks.update(id, .object([.init("changes", .string("off"))]))
        do { _ = try await tasks.comment(id, remoteID: "t1", body: "hi", via: .tool); Issue.record("Read-only sent a comment") }
        catch { #expect((error as? NativeRPCError)?.code == "read-only") }
        _ = try await tasks.update(id, .object([.init("changes", .string("allow"))]))
        _ = try await tasks.change(id, remoteID: "t1", change: .object([.init("dueDate", .string("2026-10-20"))]), via: .app)
        #expect(fake.task("t1")?.due == "2026-10-20")
        _ = try await tasks.change(id, remoteID: "t1", change: .object([.init("dueDate", .string(""))]), via: .app)
        #expect(fake.task("t1")?.due == nil)
        _ = try await tasks.comment(id, remoteID: "t1", body: "On it", via: .app)
        #expect(fake.task("t1")?.comments.map(\.body) == ["On it"])
        #expect(fake.writes == ["set_task_status", "update_task", "update_task", "add_comment"])
    }

    @Test func replacingSomeonesTaskNeedsAnExplicitConfirmAndRefusalsKeepTheirWords() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake)
        let id = try await connect(tasks, changes: "allow")
        _ = try await tasks.refresh(id)
        do { _ = try await tasks.change(id, remoteID: "t2", change: .object([.init("assignee", .string("u-sara"))]), via: .app); Issue.record("Replaced without confirm") }
        catch {
            #expect((error as? NativeRPCError)?.code == "confirm-needed")
            #expect(error.localizedDescription.contains("replace the main assignee Ali Khan with Sara Lee") && !error.localizedDescription.contains("pass confirm"))
        }
        #expect(fake.task("t2")?.assignee == "u-ali")
        _ = try await tasks.change(id, remoteID: "t2", change: .object([.init("assignee", .string("u-sara")), .init("confirm", .bool(true))]), via: .app)
        #expect(fake.task("t2")?.assignee == "u-sara")
        do { _ = try await tasks.change(id, remoteID: "t5", change: .object([.init("status", .string("Done"))]), via: .app); Issue.record("Changed a task only added to") }
        catch { #expect(error.localizedDescription.contains("main assignee or the person who raised it")) }
        fake.status429 = true
        do { _ = try await tasks.refresh(id); Issue.record("429 read as success") }
        catch { #expect((error as? NativeRPCError)?.code == "rate-limited" && error.localizedDescription.contains("12 seconds")) }
        #expect(try await tasks.state()["connections"].elements?.first?["problem"].string?.contains("too many") == true)
    }

    @Test func aDateThatChangedWhileTheStatusFailedIsShownAndSaidSo() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake)
        let id = try await connect(tasks, changes: "allow")
        _ = try await tasks.refresh(id)
        fake.refuseStatus = true
        do {
            _ = try await tasks.change(id, remoteID: "t1", change: .object([.init("status", .string("Done")), .init("dueDate", .string("2026-11-11"))]), via: .app)
            Issue.record("A half-done change read as done")
        } catch { #expect(error.localizedDescription.contains("due 2026-11-11") && error.localizedDescription.contains("status was not")) }
        #expect(fake.task("t1")?.due == "2026-11-11" && fake.task("t1")?.status == "To-Do")
        #expect(try await tasks.tasks(id)["tasks"].elements?.first { $0["id"].string == "t1" }?["dueDate"].string == "2026-11-11")
    }

    // MARK: Small costs (U84)

    @Test func aCreationDateIsReadOnceAndATaskReadWritesTheFileLater() async throws {
        let fake = ConnectedTasksFake()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connected-tasks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = try await service(fake, directory: directory)
        let id = try await connect(tasks)
        _ = try await tasks.refresh(id)
        func saved() throws -> NativeRPCValue? {
            try BackendTaskPersistence(directory: directory).read(BackendConnectedTasksService.fileName)?["cache"][id]["tasks"].elements?.first { $0["id"].string == "t1" }
        }
        _ = try await tasks.detail(id, remoteID: "t1")
        #expect(try saved()?["createdAt"].string == nil) // not written on every read
        await tasks.flushCache()
        #expect(try saved()?["createdAt"].string == "2026-09-15T08:00:00Z")
        // The next list read (which carries no creation dates) keeps the one already read.
        let list = try #require(ConnectedTaskList(try await tasks.refresh(id)))
        #expect(list.tasks.first { $0.id == "t1" }?.createdAt == "2026-09-15T08:00:00Z")
    }

    @Test func remembersOnlyRecentTasksItemsAndChecksEveryFileBeforeAttaching() async throws {
        let fake = ConnectedTasksFake()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("connected-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [("a.txt", 10), ("big.bin", BackendConnectedTasksService.uploadLimit + 1), ("c.txt", 10)].map { name, size in
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
            return url
        }
        let tasks = BackendConnectedTasksService(persistence: try .init(directory: URL(fileURLWithPath: "/ConnectedTasks-files"), ownership: .memory),
            secrets: BackendConnectedTasksMemorySecrets(), transport: fake,
            agents: .init(create: { _ in "" }, outcome: { _ in nil }, agent: { _ in nil }), chooseFiles: { files })
        try await tasks.start()
        let id = try await connect(tasks, changes: "allow")
        let picked = await tasks.popup(id, function: "chooseTaskFiles", arguments: [.string("t1")], confirmed: true)
        #expect(picked["ok"].bool == false && picked["error"].string?.contains("big.bin is over 10 MB, so nothing was attached") == true)
        #expect(!fake.calls.contains { $0.tool == "upload_task_file" })
        // Items are remembered for the most recent tasks only, and never past their connection.
        _ = await tasks.popup(id, function: "fetchTaskDetailBundle", arguments: [.string("t1")], confirmed: false)
        #expect(await tasks.ownerTask(id, "i1") == "t1")
        for n in 0..<BackendConnectedTasksService.ownersTasks { await tasks.own(id, ["x\(n)"], "other\(n)") }
        #expect(await tasks.ownerTask(id, "i1") == nil)
        #expect(await tasks.ownerTask(id, "x0") == "other0")
        try await tasks.remove(id)
        #expect(await tasks.ownerTask(id, "x0") == nil)
        #expect(await tasks.reads.isEmpty)
    }

    // MARK: Agents

    @Test func aHandedTaskRunsLocallyAndItsAnswerIsPostedBackOnce() async throws {
        let fake = ConnectedTasksFake(), agents = Agents(), tasks = try await service(fake, agents: agents)
        let id = try await connect(tasks)
        _ = try await tasks.refresh(id)
        do { _ = try await tasks.handToAgent(id, remoteID: "t1", agent: "builder", project: nil, markDone: true, via: .app); Issue.record("Handed over without a yes") }
        catch { #expect((error as? NativeRPCError)?.code == "needs-confirmation") }
        do { _ = try await tasks.handToAgent(id, remoteID: "t1", agent: "loose", project: nil, markDone: false, via: .app, confirmed: true); Issue.record("No project accepted") }
        catch { #expect(error.localizedDescription.contains("project folder")) }
        let handed = try await tasks.handToAgent(id, remoteID: "t1", agent: "builder", project: nil, markDone: true, via: .app, confirmed: true)
        #expect(handed["localTaskId"].string == "local:1")
        let made = try #require(await agents.made.first)
        #expect(made["assignee"].string == "builder" && made["project"].string == "/work/app" && made["board"].string == "Work CRM")
        let brief = made["instructions"].string ?? ""
        #expect(brief.contains("Task: Call the landlord") && brief.contains("- [x] First step") && brief.contains("Checklist: Before") && brief.contains("set to Done"))
        do { _ = try await tasks.handToAgent(id, remoteID: "t1", agent: "builder", project: nil, markDone: nil, via: .tool); Issue.record("Handed twice") }
        catch { #expect(error.localizedDescription.contains("already with Builder")) }
        await tasks.agentResults()
        #expect(fake.writes.isEmpty) // still working: nothing posted
        await agents.finish("local:1", .init(answer: "Called them; viewing booked for Monday."))
        await tasks.agentResults(); await tasks.agentResults()
        #expect(fake.task("t1")?.comments.map(\.body) == ["Builder (a Terminal Deck task agent) finished this task:\n\nCalled them; viewing booked for Monday."])
        #expect(fake.task("t1")?.status == "Done")
        #expect(fake.writes == ["add_comment", "set_task_status"])
        let list = try #require(ConnectedTaskList(try await tasks.tasks(id)))
        #expect(list.handoff("t1")?.posted == true && list.handoff("t1")?.line.contains("posted") == true)
        // A stopped agent posts nothing.
        _ = try await tasks.handToAgent(id, remoteID: "t2", agent: "builder", project: nil, markDone: false, via: .tool)
        await agents.finish("local:2", .init(answer: nil, stopped: true))
        await tasks.agentResults()
        #expect(fake.task("t2")?.comments.isEmpty == true)
    }

    // MARK: The task popup on a connected task

    @Test func thePopupReadsDecodeAndItsWritesPassTheGate() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake)
        let id = try await connect(tasks)
        _ = try await tasks.refresh(id)
        let bundle = await tasks.popup(id, function: "fetchTaskDetailBundle", arguments: [.string("t1")], confirmed: false)
        let decoded = try #require(CrmDecode.bundle(bundle["bundle"].foundation))
        #expect(decoded.subtasks.first?.title == "First step" && decoded.subtasks.first?.done == true)
        #expect(decoded.checklists.first?.items.first?.title == "Check keys" && decoded.people.primary?.name == "Owner Person")
        let extras = await tasks.popup(id, function: "fetchTaskPageExtras", arguments: [.string("t1")], confirmed: false)
        #expect(CrmDecode.extras(extras["extras"].foundation)?.labels == ["urgent"])
        let fields = await tasks.popup(id, function: "listTaskFields", arguments: [.string("t1")], confirmed: false)
        #expect(fields["ok"].bool == true && fields["viewerId"].string == "u-me")
        #expect(fake.calls.filter { $0.tool == "get_task" }.count == 1) // three reads, one call
        // Ask each time: an unconfirmed change asks first and sends nothing.
        let asked = await tasks.popup(id, function: "setTaskStatus", arguments: [.string("t1"), .string("Done")], confirmed: false)
        #expect(asked["needsConfirmation"].bool == true && fake.writes.isEmpty)
        let sent = await tasks.popup(id, function: "setTaskStatus", arguments: [.string("t1"), .string("Done")], confirmed: true)
        #expect(sent["ok"].bool == true && fake.task("t1")?.status == "Done")
        let commented = await tasks.popup(id, function: "addTaskComment", arguments: [.string("t1"), .string("From the popup")], confirmed: true)
        #expect(commented["ok"].bool == true && fake.task("t1")?.comments.last?.body == "From the popup")
        // Destructive ones need a yes even when changes go straight.
        _ = try await tasks.update(id, .object([.init("changes", .string("allow"))]))
        let archive = await tasks.popup(id, function: "setArchived", arguments: [.string("t1"), .bool(true)], confirmed: false)
        #expect(archive["needsConfirmation"].bool == true)
        let due = await tasks.popup(id, function: "updateTask", arguments: [.string("t1"), .object([.init("dueDate", .string("2026-12-01"))])], confirmed: false)
        #expect(due["ok"].bool == true && fake.task("t1")?.due == "2026-12-01")
        let links = await tasks.popup(id, function: "fetchTaskLinks", arguments: [.string("t1")], confirmed: false)
        #expect(links["supported"].bool == true && links["areas"].elements == [.string("person"), .string("lead")])
        let found = await tasks.popup(id, function: "searchTags", arguments: [.string("lead"), .string("dan")], confirmed: false)
        #expect(found["hits"].elements?.compactMap { $0["label"].string } == ["Danel Ortiz", "Dana Price"])
        let people = await tasks.popup(id, function: "searchTags", arguments: [.string("person"), .string("ali")], confirmed: false)
        #expect(people["hits"].elements?.first?["id"].string == "u-ali")
        let linked = await tasks.popup(id, function: "setTaskLinks", arguments: [.string("t1"), .array([.object([.init("area", .string("lead")), .init("id", .string("l1")), .init("label", .string("Danel Ortiz"))])])], confirmed: false)
        #expect(linked["ok"].bool == true && fake.task("t1")?.related.first?["id"].string == "l1")
        let unlinked = await tasks.popup(id, function: "setTaskLinks", arguments: [.string("t1"), .array([])], confirmed: false)
        #expect(unlinked["ok"].bool == true && fake.task("t1")?.related.isEmpty == true)
        let unknown = await tasks.popup(id, function: "setTaskProject", arguments: [.string("t1"), .string("/tmp")], confirmed: true)
        #expect(unknown["ok"].bool == false && unknown["error"].string?.contains("this Mac's own tasks") == true)
        _ = try await tasks.update(id, .object([.init("changes", .string("off"))]))
        let off = await tasks.popup(id, function: "addTaskSubtask", arguments: [.string("t1"), .string("x")], confirmed: true)
        #expect(off["ok"].bool == false && off["error"].string?.contains("read only") == true)
        let read = await tasks.popup(id, function: "fetchTaskDetailBundle", arguments: [.string("t1")], confirmed: false)
        #expect(read["ok"].bool == true) // reads stay free when read only
    }

    // MARK: MCP tools

    actor Calls {
        var tiers: [(String, BackendMCPTier)] = []
        func add(_ tool: String, _ tier: BackendMCPTier) { tiers.append((tool, tier)) }
    }

    func authority(_ calls: Calls, deny: Bool = false) -> BackendTaskToolAuthority {
        BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { _ in }, visible: { _, _ in true }, project: { _, _ in },
            authorize: { _, tool, _, tier in
                await calls.add(tool, tier)
                if deny && tier != .read { throw NativeRPCError(code: "not-granted", message: "The owner said no.") }
            }, actorName: { _ in "Key" })
    }
    func context(tiers: Set<BackendMCPTier> = [.read, .act, .alter]) -> BackendMCPCallContext {
        BackendMCPCallContext(sessionID: "s", machineID: "", projectRoot: nil, attended: true, allowedTools: Set(BackendConnectedTasksTools.ids),
                              allowedTiers: tiers, cancellation: BackendMCPCancellation())
    }

    @Test func theConnectToolAsksFirstAndReadsTheTokenFromAPrivateFile() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake), calls = Calls()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".connected-tasks-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("token.env")
        try "# test\nSYSTEM_TOKEN=\(fake.token)\n".write(to: file, atomically: true, encoding: .utf8)
        func connect(deny: Bool = false) async throws -> NativeRPCValue {
            try await BackendConnectedTasksTools.invoke("connected_tasks.connect", arguments: .object([.init("name", .string("Work CRM")),
                .init("url", .string(Self.address)), .init("token_file", .string(file.path))]), caller: context(), service: tasks, authority: authority(calls, deny: deny))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        do { _ = try await connect(); Issue.record("Read a world-readable token file") } catch { #expect(error.localizedDescription.contains("chmod 600")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        do { _ = try await connect(deny: true); Issue.record("Connected without the owner") } catch { #expect(fake.calls.isEmpty) }
        let view = try await connect()
        #expect(view["name"].string == "Work CRM" && view["changes"].string == "ask" && !view.compact.contains(fake.token))
        #expect(await calls.tiers.map(\.1) == [.alter, .alter, .alter]) // asked before anything was read, every time
    }

    @Test func toolsReadFreelyAndChangesAskTheOwnerFirst() async throws {
        let fake = ConnectedTasksFake(), tasks = try await service(fake), calls = Calls()
        let id = try await connect(tasks)
        func run(_ tool: String, _ args: [(String, NativeRPCValue)], deny: Bool = false, tiers: Set<BackendMCPTier> = [.read, .act, .alter]) async throws -> NativeRPCValue {
            try await BackendConnectedTasksTools.invoke(tool, arguments: .object(args.map { .init($0.0, $0.1) }), caller: context(tiers: tiers),
                                                        service: tasks, authority: authority(calls, deny: deny))
        }
        let systems = try await run("connected_tasks.systems", [])
        #expect(systems["systems"].elements?.first?["name"].string == "Work CRM" && !systems.compact.contains(fake.token))
        let list = try await run("connected_tasks.list", [("refresh", .bool(true)), ("pile", .string("assigned_to_me"))], tiers: [.read])
        #expect(list["tasks"].elements?.compactMap { $0["id"].string } == ["t1", "t5"])
        let byName = try await run("connected_tasks.get", [("system", .string("work crm")), ("task", .string("t2"))], tiers: [.read])
        #expect(byName["title"].string == "Photos for the listing")
        #expect(await calls.tiers.allSatisfy { $0.1 == .read })
        do { _ = try await run("connected_tasks.update", [("task", .string("t1")), ("status", .string("Done"))], tiers: [.read]); Issue.record("Read tier changed a task") }
        catch { #expect((error as? NativeRPCError)?.code == "not-granted") }
        do { _ = try await run("connected_tasks.update", [("task", .string("t1")), ("status", .string("Done"))], deny: true); Issue.record("Changed without the owner") }
        catch { #expect(fake.writes.isEmpty) }
        // Approved through the approval path: sent even in Ask mode (the owner already answered).
        _ = try await run("connected_tasks.update", [("task", .string("t1")), ("status", .string("Working on it")), ("due_date", .string("2026-11-01"))])
        #expect(fake.task("t1")?.status == "Working on it" && fake.task("t1")?.due == "2026-11-01")
        _ = try await run("connected_tasks.comment", [("task", .string("t1")), ("body", .string("From a session"))])
        #expect(fake.task("t1")?.comments.last?.body == "From a session")
        #expect(await calls.tiers.filter { $0.1 == .alter }.map(\.0) == ["connected_tasks.update", "connected_tasks.update", "connected_tasks.comment"])
        _ = try await tasks.update(id, .object([.init("changes", .string("off"))]))
        do { _ = try await run("connected_tasks.comment", [("task", .string("t1")), ("body", .string("x"))]); Issue.record("Read only ignored") }
        catch { #expect((error as? NativeRPCError)?.code == "read-only") }
        #expect(try BackendConnectedTasksTools.specs().map(\.wireName) == ["connected_tasks_systems", "connected_tasks_list", "connected_tasks_get",
                                                                         "connected_tasks_update", "connected_tasks_comment", "connected_tasks_connect", "connected_tasks_hand_to_agent"])
    }
}

/// Live: the whole task popup against a STAGING system, on one test task made for it.
/// CONNECTED_TASKS_LIVE_URL + CONNECTED_TASKS_LIVE_TOKEN + CONNECTED_TASKS_LIVE_POPUP_TASK.
@Suite("Connected task systems: live popup (staging)")
struct ConnectedTasksLivePopupTests {
    @Test func everyPopupSectionWorksAgainstStaging() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["CONNECTED_TASKS_LIVE_URL"], let token = env["CONNECTED_TASKS_LIVE_TOKEN"], let task = env["CONNECTED_TASKS_LIVE_POPUP_TASK"] else { return }
        let service = BackendConnectedTasksService(persistence: try .init(directory: URL(fileURLWithPath: "/ConnectedTasks-popup"), ownership: .memory),
            secrets: BackendConnectedTasksMemorySecrets(), agents: .init(create: { _ in "" }, outcome: { _ in nil }, agent: { _ in nil }))
        try await service.start()
        let id = try await service.connect(.object([.init("name", .string("Staging")), .init("url", .string(address)), .init("token", .string(token)),
                                                    .init("changes", .string("allow"))]))["id"].requireString("id")
        _ = try await service.refresh(id)
        var failures: [String] = [], log: [String] = []
        func call(_ fn: String, _ args: [NativeRPCValue], confirmed: Bool = true) async -> NativeRPCValue {
            try? await Task.sleep(for: .milliseconds(2_100)) // the system allows 60 calls a minute; a write here is a call and a re-read
            let answer = await service.popup(id, function: fn, arguments: args, confirmed: confirmed)
            log.append("\(fn): \(answer["ok"].bool == true ? "ok" : "REFUSED " + (answer["error"].string ?? ""))")
            if answer["ok"].bool != true { failures.append(fn + ": " + (answer["error"].string ?? "")) }
            return answer
        }
        func bundle() async -> TaskDetailBundle? { CrmDecode.bundle(await call("fetchTaskDetailBundle", [.string(task)])["bundle"].foundation) }
        let t = NativeRPCValue.string(task)
        // Reads, each decoded by the popup's own decoders.
        #expect(await bundle() != nil)
        #expect(CrmDecode.extras(await call("fetchTaskPageExtras", [t])["extras"].foundation) != nil)
        #expect(CrmDecode.more(await call("fetchTaskMore", [t])["more"].foundation) != nil)
        #expect(CrmDecode.routine(await call("fetchRoutine", [t])["routine"].foundation) != nil)
        #expect(((await call("listTaskComments", [t]))["comments"].elements ?? []).allSatisfy { CrmDecode.comment($0.foundation) != nil })
        #expect(CrmDecode.commentExtras(await call("fetchCommentExtras", [t])["extras"].foundation) != nil)
        #expect(((await call("listTaskActivity", [t]))["rows"].elements ?? []).allSatisfy { CrmDecode.activity($0.foundation) != nil })
        #expect(((await call("listTaskFields", [t]))["fields"].elements ?? []).allSatisfy { TaskFields.decode($0.foundation) != nil })
        // The task itself.
        _ = await call("setTaskStatus", [t, .string("In Progress")])
        _ = await call("updateTask", [t, .object([.init("description", .string("Popup check from Terminal Deck.")), .init("priority", .string("High")), .init("dueDate", .string("2026-10-30"))])])
        _ = await call("setTaskType", [t, .string("milestone")]); _ = await call("setTaskType", [t, .string("task")])
        _ = await call("setTaskLabels", [t, .array([.string("td-popup-check")])])
        _ = await call("setLabelColor", [.string("td-popup-check"), .string("teal")])
        _ = await call("setTaskTimes", [t, .object([.init("dueTime", .string("17:30"))])])
        _ = await call("setTimeEstimate", [t, .number(45)])
        // Subtasks.
        let sub = await call("addTaskSubtask", [t, .string("Popup subtask")])
        if let s = sub["id"].string {
            _ = await call("setTaskSubtaskDone", [t, .string(s), .bool(true)])
            _ = await call("setSubtaskMeta", [t, .string(s), .object([.init("priority", .string("Low")), .init("dueDate", .string("2026-10-25"))])])
            _ = await call("deleteTaskSubtask", [t, .string(s)])
        }
        // Checklists.
        let list = await call("addChecklist", [t, .string("Popup list")])
        let item = await call("addChecklistItem", [list["id"], .string("Popup item")])
        if let i = item["id"].string {
            _ = await call("setChecklistItemDone", [.string(i), .bool(true)])
            _ = await bundle()
            if let made = (await bundle())?.checklists.first(where: { $0.title == "Popup list" }) {
                _ = await call("renameChecklist", [.string(made.id), .string("Popup list (renamed)")])
                _ = await call("deleteChecklistItem", [.string(i)])
            } else { failures.append("checklist not found after adding") }
        }
        // Comments with a reply, a reaction and resolve.
        let comment = await call("addTaskComment", [t, .string("Popup comment")])
        if let c = comment["id"].string {
            _ = await call("addTaskCommentWith", [t, .string("Popup reply"), .object([.init("parentId", .string(c))])])
            _ = await call("toggleCommentReaction", [t, .string(c), .string("👍")])
            _ = await call("setCommentResolved", [t, .string(c), .bool(true)])
            let extras = CrmDecode.commentExtras(await call("fetchCommentExtras", [t])["extras"].foundation)
            #expect(extras?.meta.values.contains { $0.parentId == c } == true)
        }
        // Time.
        _ = await call("startTaskTimer", [t]); _ = await call("stopTaskTimer", [t])
        let entry = await call("addTaskTimeEntry", [t, .object([.init("seconds", .number(1800)), .init("note", .string("popup check"))])])
        if let e = entry["entry"]["id"].string {
            _ = await call("setTimeEntryTags", [t, .string(e), .array([.string("check")])])
            _ = await call("deleteTaskTimeEntry", [t, .string(e)])
        } else { failures.append("time entry not returned") }
        // Files.
        let file = await call("uploadTaskFile", [t, .object([.init("name", .string("popup-check.txt")), .init("type", .string("text/plain")), .init("bytes", .bytes(Data("popup check\n".utf8)))])])
        if let f = file["attachment"]["id"].string {
            _ = await call("openTaskFile", [t, .string(f)])
            _ = await call("detachTaskAttachment", [.string(f)])
        }
        // Fields.
        let field = await call("createTaskField", [t, .object([.init("label", .string("Popup field")), .init("kind", .string("text")), .init("value", .string("one"))])])
        if let f = field["field"]["id"].string {
            _ = await call("updateTaskFieldValue", [.string(f), .string("two")])
            _ = await call("renameTaskField", [.string(f), .string("Popup field (renamed)")])
            #expect(TaskFields.decode(field["field"].foundation) != nil)
            _ = await call("deleteTaskField", [.string(f)])
        }
        // Destructive: only with a yes (asked first without it), on copies made for the check.
        let unconfirmed = await service.popup(id, function: "setArchived", arguments: [t, .bool(true)], confirmed: false)
        #expect(unconfirmed["needsConfirmation"].bool == true)
        _ = await call("setArchived", [t, .bool(true)]); _ = await call("setArchived", [t, .bool(false)])
        for verb in ["mergeTaskInto", "convertToSubtask", "deleteTask"] {
            let copy = await call("duplicateTask", [t])
            guard let c = copy["id"].string else { failures.append("duplicate gave no id"); continue }
            if verb == "deleteTask" { _ = await call(verb, [.string(c)]) }
            else { _ = await call(verb, [.string(c), t]) }
        }
        _ = await call("deleteLabelEverywhere", [.string("td-popup-check")])
        // Follow and routine.
        _ = await call("setFollowing", [t, .bool(false)]); _ = await call("setFollowing", [t, .bool(true)])
        _ = await call("saveRoutine", [t, .object([.init("frequency", .string("weekly")), .init("interval", .number(1)), .init("weekdays", .array([.number(1)])),
                                                  .init("trigger", .string("status")), .init("triggerStatus", .string("Done")), .init("createNew", .bool(true))]), .number(0)])
        let routine = CrmDecode.routine(await call("fetchRoutine", [t])["routine"].foundation)
        #expect(routine?.rule != nil)
        _ = await call("pauseRoutine", [t, .bool(true)]); _ = await call("stopRoutine", [t])
        // Dependencies need another task: a copy, linked then unlinked, then deleted.
        let other = await call("duplicateTask", [t])
        if let o = other["id"].string {
            _ = await call("addTaskDependency", [t, .string(o), .string("blocked_by")])
            #expect((await bundle())?.dependencies.contains { $0.otherTaskId == o } == true)
            _ = await call("removeTaskDependency", [t, .string(o), .string("blocked_by")])
            _ = await call("deleteTask", [.string(o)])
        }
        // People (only the owner's own test person on staging, so nobody else is notified), boards, dates, more field kinds.
        if let helper = env["CONNECTED_TASKS_LIVE_HELPER"] {
            let h = NativeRPCValue.string(helper)
            // A follower has to be able to see the task (the system's rule), so follow while they are on it.
            _ = await call("addTaskAssignee", [t, h]); _ = await call("addFollower", [t, h])
            _ = await call("removeFollower", [t, h]); _ = await call("removeTaskAssignee", [t, h])
            let sub2 = await call("addTaskSubtask", [t, .string("Popup subtask 2")])
            if let s2 = sub2["id"].string { _ = await call("setTaskSubtaskAssignee", [t, .string(s2), h]); _ = await call("setTaskSubtaskAssignee", [t, .string(s2), .null]) }
            let list2 = await call("addChecklist", [t, .string("Popup list 2")])
            let item2 = await call("addChecklistItem", [list2["id"], .string("Popup item 2")])
            if let i2 = item2["id"].string { _ = await call("setChecklistItemAssignee", [.string(i2), h]); _ = await call("setChecklistItemAssignee", [.string(i2), .null]) }
            if let made = (await bundle())?.checklists.first(where: { $0.title == "Popup list 2" }) { _ = await call("deleteChecklist", [.string(made.id)]) }
        }
        _ = await call("moveTask", [t, .string("Viewings")]); _ = await call("moveTask", [t, .string("Follow-ups")])
        _ = await call("setSyncSubtaskDates", [t, .bool(true)]); _ = await call("setSyncSubtaskDates", [t, .bool(false)])
        let a = await call("createTaskField", [t, .object([.init("label", .string("Popup A")), .init("kind", .string("number"))])])
        let b = await call("createTaskField", [t, .object([.init("label", .string("Popup B")), .init("kind", .string("voting"))])])
        if let fa = a["field"]["id"].string, let fb = b["field"]["id"].string {
            _ = await call("reorderTaskFields", [t, .array([.string(fb), .string(fa)])])
            _ = await call("toggleTaskFieldVote", [.string(fb)])
            _ = await call("deleteTaskField", [.string(fa)]); _ = await call("deleteTaskField", [.string(fb)])
        }
        let d = await call("createTaskField", [t, .object([.init("label", .string("Popup C")), .init("kind", .string("dropdown")),
                                                           .init("config", .object([.init("options", .array([.object([.init("id", .string("o1")), .init("label", .string("One"))])]))]))])])
        if let fd = d["field"]["id"].string {
            _ = await call("updateTaskFieldConfig", [.string(fd), .object([.init("options", .array([.object([.init("id", .string("o1")), .init("label", .string("One")), .init("color", .string("blue"))]),
                                                                                                  .object([.init("id", .string("o2")), .init("label", .string("Two")), .init("color", .string("green"))])]))])])
            _ = await call("deleteTaskField", [.string(fd)])
        }
        // Related records: search a lead, a listing and a person, link all three, read them back, unlink.
        let linksBefore = await call("fetchTaskLinks", [t])
        #expect(linksBefore["supported"].bool == true)
        var picked: [NativeRPCValue] = []
        for (area, words) in [("lead", "an"), ("listing", "ma"), ("person", "as")] {
            let hits = await call("searchTags", [.string(area), .string(words)])
            if let hit = hits["hits"].elements?.first { picked.append(.object([.init("area", hit["area"]), .init("id", hit["id"]), .init("label", hit["label"])])) }
            else { failures.append("no \(area) found for \(words)") }
        }
        _ = await call("setTaskLinks", [t, .array(picked)])
        let linksAfter = await call("fetchTaskLinks", [t])
        #expect(Set((linksAfter["links"].elements ?? []).compactMap { $0["id"].string }) == Set(picked.compactMap { $0["id"].string }))
        _ = await call("setTaskLinks", [t, .array([])])
        #expect((await call("fetchTaskLinks", [t]))["links"].elements?.isEmpty == true)
        print("LIVE POPUP\n" + log.joined(separator: "\n"))
        #expect(failures.isEmpty, "\(failures)")
    }
}

/// Live checks against a real system, skipped unless asked for with environment variables:
/// CONNECTED_TASKS_LIVE_URL + CONNECTED_TASKS_LIVE_TOKEN (read-only: lists your own tasks);
/// add CONNECTED_TASKS_LIVE_WRITE_TASK (a test task id on a STAGING system) to also send a
/// status, a due date, a comment and an agent answer to that one task.
@Suite("Connected task systems: live")
struct ConnectedTasksLiveTests {
    @Test func liveReadAndOptionalStagingWrites() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let address = env["CONNECTED_TASKS_LIVE_URL"], let token = env["CONNECTED_TASKS_LIVE_TOKEN"] else { return }
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/ConnectedTasks-live"), ownership: .memory)
        actor Made { var input: NativeRPCValue?; var done = false; func set(_ v: NativeRPCValue) { input = v }; func finish() { done = true } }
        let made = Made()
        let service = BackendConnectedTasksService(persistence: persistence, secrets: BackendConnectedTasksMemorySecrets(),
            agents: .init(create: { await made.set($0); return "local:live" },
                          outcome: { _ in await made.done ? .init(answer: "Live check: an agent's answer posted from Terminal Deck's test run.") : nil },
                          agent: { _ in (name: "Live check agent", project: "/tmp") }))
        try await service.start()
        let view = try await service.connect(.object([.init("name", .string("Live")), .init("url", .string(address)), .init("token", .string(token)),
                                                      .init("changes", .string("allow"))]))
        let id = try view["id"].requireString("id")
        let list = try #require(ConnectedTaskList(try await service.refresh(id)))
        print("LIVE read: connected as \(list.system.me?.name ?? "?"), \(list.tasks.count) tasks, \(list.tasks.filter(\.assignedToMe).count) assigned to me, capabilities \(list.system.capabilities)")
        guard let task = env["CONNECTED_TASKS_LIVE_WRITE_TASK"] else { return }
        let before = try await service.detail(id, remoteID: task)
        print("LIVE write target: \(before["title"].string ?? "?") status \(before["status"].string ?? "?")")
        _ = try await service.change(id, remoteID: task, change: .object([.init("status", .string("In Progress"))]), via: .app)
        _ = try await service.change(id, remoteID: task, change: .object([.init("dueDate", .string("2026-10-31"))]), via: .app)
        _ = try await service.comment(id, remoteID: task, body: "Terminal Deck connected-tasks check: a comment sent from the test run.", via: .app)
        _ = try await service.handToAgent(id, remoteID: task, agent: "live", project: nil, markDone: true, via: .app)
        await made.finish()
        await service.agentResults()
        let after = try #require(ConnectedTaskDetail(try await service.detail(id, remoteID: task)))
        print("LIVE write after: status \(after.row.status ?? "?"), due \(after.row.dueDate ?? "-"), comments \(after.comments.count), last: \(after.comments.last?.body.prefix(80) ?? "")")
        #expect(after.row.status == list.system.doneStatus && after.row.dueDate == "2026-10-31")
        #expect(after.comments.contains { $0.body.contains("Terminal Deck connected-tasks check") })
        #expect(after.comments.contains { $0.body.contains("Live check agent (a Terminal Deck task agent) finished") })
    }
}
