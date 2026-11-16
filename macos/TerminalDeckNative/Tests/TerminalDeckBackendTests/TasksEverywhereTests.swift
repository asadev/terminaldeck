import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Tasks everywhere (15 Nov 2026): his tasks look and count the same on all his Macs. Two scratch stores per test,
/// fixture clocks only (the `CloudKindsTests` sides): the folder is filled later, the parent link and the assignment
/// arrive, an arriving assignment starts nothing, a connection arrives with its token never in the clear, and a
/// closed gate sends the old form. Serialized: one test reads the shared "elsewhere" lines.
@Suite("Tasks everywhere — the same tasks on every Mac; worked on one", .serialized)
struct TasksEverywhereTests {
    typealias Side = CloudKindsTests.Side
    static let names: @Sendable (String) async -> String = { $0 == CloudLeanFixture.deviceA ? "Mac mini" : "MacBook Pro" }

    /// A side whose delete-rule gate is open (every Mac on this build), or closed.
    static func side(_ device: String, _ clock: CloudLeanFixture.Clock, open: Bool = true,
                     projects: CloudLeanFixture.Box<[BackendCloudKindsProject]> = .init([])) async throws -> Side {
        let side = try await CloudKindsTests.side(device, clock: clock, projects: projects)
        side.taskOwner.configureDeleteRule(gate: { open }, macNames: names)
        return side
    }
    /// The engine's queue takes exactly these (`BackendTaskEngine.pumpQueue`): queued, not stopped, given to an agent.
    static func pumpWouldStart(_ row: NativeRPCValue) -> Bool {
        row["process"].string == "queued" && row["stopped"].bool != true && row["assignee"]["kind"].string == "agent"
    }
    static func connected(_ side: Side, secrets: BackendConnectedTasksMemorySecrets) async throws -> BackendConnectedTasksService {
        let service = BackendConnectedTasksService(persistence: try .init(directory: side.mac.root.appendingPathComponent("connected"), ownership: .exclusive),
            secrets: secrets, agents: .init(create: { _ in "" }, outcome: { _ in nil }, agent: { _ in nil }))
        try await service.start()
        return service
    }

    // MARK: 1. the folder fault

    @Test func aTaskWhoseProjectHadNoFolderHereIsFiledUnderItAndGetsTheFolderLater() async throws {
        let clock = CloudLeanFixture.Clock()
        let projectsA = CloudLeanFixture.Box([BackendCloudKindsProject(id: "imatch", folders: ["/Users/a/imatch"])])
        let projectsB = CloudLeanFixture.Box([BackendCloudKindsProject(id: "imatch", folders: [])])
        let a = try await Self.side(CloudLeanFixture.deviceA, clock, projects: projectsA)
        let b = try await Self.side(CloudLeanFixture.deviceB, clock, projects: projectsB)
        defer { CloudKindsTests.cleanup(a, b) }
        _ = try await a.tasks.put(CloudKindsTests.task("f", title: "Filed", project: "/Users/a/imatch/app"), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        // No folder on B yet: still filed under its project (never Independent, never another project).
        let arrived = try #require(try await b.tasks.byID("local:f"))
        #expect(arrived.value["project"].string == "")
        #expect(BackendTaskStateView.taskView(arrived, agents: [], all: [])["projectId"].string == "imatch")

        // A task that arrived before this build (project ref kept, no projectId, no folder) is filed by the ref.
        try await b.tasks.cloudKindsWrite(CloudKindsTests.task("old", title: "Older arrival").setting("project", .string(""))
            .setting("cloudProjectRef", .object([.init("projectId", .string("imatch"))])).setting("sessionId", .null), trash: false)
        let older = try #require(try await b.tasks.byID("local:old"))
        #expect(BackendTaskStateView.taskView(older, agents: [], all: [])["projectId"].string == "imatch")

        // The project gets its folder on B: both tasks take it at the next pass, and nothing of local:f travels back.
        projectsB.value = [BackendCloudKindsProject(id: "imatch", folders: ["/Users/b/imatch"])]
        let back = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        #expect(!CloudLeanFixture.text(back).contains("local:f "))
        for id in ["local:f", "local:old"] {
            let row = try #require(try await b.tasks.byID(id)?.value)
            #expect(row["project"].string == "/Users/b/imatch" && row["projectId"].string == "imatch", "\(id)")
        }
        #expect(!CloudLeanFixture.text(back).contains("/Users/b"), "A folder path never travels")
    }

    // MARK: 2 and 3. the parent link and the assignment arrive; nothing starts

    @Test func theParentLinkAndTheAssignmentArriveAndStartNothing() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock), b = try await Self.side(CloudLeanFixture.deviceB, clock)
        defer { CloudKindsTests.cleanup(a, b) }
        _ = try await a.tasks.put(CloudKindsTests.task("p", title: "Parent").setting("sessionId", .null).setting("process", .string("idle")), now: true)
        // The child is queued and being worked on A (its session runs there), given to the agent "worker".
        _ = try await a.tasks.put(CloudKindsTests.task("c", title: "Child").setting("parentTaskId", .string("local:p"))
            .setting("mainAssignee", .string("agent:worker")).setting("stopped", .bool(false)), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        let child = try #require(try await b.tasks.byID("local:c")?.value)
        #expect(child["parentTaskId"].string == "local:p", "B shows the same sub-task and drop-down")
        #expect(child["assignee"]["agentId"].string == "worker" && child["mainAssignee"].string == "agent:worker", "Same agent on the card")
        #expect(child[BackendCloudKindsTasks.workingOnNameField].string == "Mac mini", "The card says where it is worked")
        // The guard: inert here. Nothing on B can start it by itself.
        #expect(child["stopped"].bool == true && child["process"].string == "stopped" && child["sessionId"] == .null)
        #expect(!Self.pumpWouldStart(child))
        // A is untouched: still queued, still its own session.
        let onA = try #require(try await a.tasks.byID("local:c")?.value)
        #expect(onA["process"].string == "queued" && onA["sessionId"].string == "session-c" && onA[BackendCloudKindsTasks.workingOnNameField].isNullish)

        // Reassigned on A to another agent: on B the card follows, the task stays inert.
        _ = try await a.tasks.put(onA.setting("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("writer"))]))
            .setting("mainAssignee", .string("agent:writer")), now: true)
        let sent = try await CloudLeanFixture.sync(startedA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.taskAdapter)
        let moved = try #require(try await b.tasks.byID("local:c")?.value)
        #expect(moved["assignee"]["agentId"].string == "writer" && !Self.pumpWouldStart(moved))

        // A's session ends: B's card no longer says it is being worked on.
        let done = try #require(try await a.tasks.byID("local:c")?.value)
        _ = try await a.tasks.put(done.setting("sessionId", .null).setting("process", .string("exited")), now: true)
        try await CloudLeanFixture.deliver(try await CloudLeanFixture.sync(startedA.activation, on: a.mac), from: a.mac.device, to: b.taskAdapter)
        #expect(try await b.tasks.byID("local:c")?.value[BackendCloudKindsTasks.workingOnNameField].isNullish == true)
    }

    /// The guard itself (`BackendCloudKindsTasks.arrivingAssignmentGuard`): a task this Mac had queued for one agent
    /// is never started for the agent another Mac gave it to; a task worked here keeps its work; an unrelated edit
    /// leaves this Mac's own queue alone.
    @Test func anArrivingAssignmentNeverStartsWorkHere() {
        let queued = CloudKindsTests.task("q", title: "Queued here").setting("sessionId", .null).setting("stopped", .bool(false))
        #expect(Self.pumpWouldStart(queued))
        let reassigned = queued.setting("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("writer"))]))
        let guarded = BackendCloudKindsTasks.arrivingAssignmentGuard(reassigned, existing: queued)
        #expect(!Self.pumpWouldStart(guarded) && guarded["stopped"].bool == true && guarded["process"].string == "stopped")
        // Unchanged assignment (a title edit arrived): this Mac's own queue is not disturbed.
        let retitled = queued.setting("title", .string("Renamed"))
        #expect(BackendCloudKindsTasks.arrivingAssignmentGuard(retitled, existing: queued) == retitled)
        // A task new to this Mac is inert whatever it carries.
        #expect(!Self.pumpWouldStart(BackendCloudKindsTasks.arrivingAssignmentGuard(queued, existing: nil)))
        // Worked on this Mac (its session runs here): the guard leaves the running work alone.
        let working = CloudKindsTests.task("w", title: "Working here").setting("stopped", .bool(false)).setting("process", .string("running"))
        let over = working.setting("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("writer"))]))
        #expect(BackendCloudKindsTasks.arrivingAssignmentGuard(over, existing: working)["process"].string == "running")
    }

    /// While B works a task, an assignment made on A waits on B (named in plain words) instead of changing the agent
    /// of the session running here.
    @Test func anAssignmentWaitsWhileThisMacWorksTheTask() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock), b = try await Self.side(CloudLeanFixture.deviceB, clock)
        defer { CloudKindsTests.cleanup(a, b) }
        _ = try await a.tasks.put(CloudKindsTests.task("h", title: "Here").setting("sessionId", .null).setting("process", .string("idle")), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))
        // B starts working it (a session here).
        let onB = try #require(try await b.tasks.byID("local:h")?.value)
        try await b.tasks.cloudKindsWrite(onB.setting("sessionId", .string("session-b")).setting("process", .string("running")).setting("stopped", .bool(false)), trash: false)
        let reassigned = BackendCloudKindsTasks.shared(try #require(try await a.tasks.byID("local:h")?.value), place: "tasks", projects: [],
            everywhere: true, own: a.mac.device).setting("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("writer"))]))
        let plan = try await b.taskOwner.cloudPlan(entity: "task:local:h", cloud: reassigned)
        #expect(plan.held["assignee"] == BackendCloudKindsTasks.workedHereLine)
        #expect(plan.store?["assignee"]["agentId"].string == "worker")
    }

    // MARK: 4. connections

    @Test func aConnectionArrivesAndItsTokenIsNeverInTheClear() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock), b = try await Self.side(CloudLeanFixture.deviceB, clock)
        defer { CloudKindsTests.cleanup(a, b) }
        let tokensA = BackendConnectedTasksMemorySecrets(), tokensB = BackendConnectedTasksMemorySecrets()
        let systemsA = try await Self.connected(a, secrets: tokensA), systemsB = try await Self.connected(b, secrets: tokensB)
        let token = "tok-SECRET-Zq9876"
        try tokensA.write("cts-0123456789", token: token)
        try await systemsA.cloudPutConnection(.object([.init("id", .string("cts-0123456789")), .init("name", .string("Tracker")),
            .init("url", .string("https://tasks.example.com/mcp")), .init("enabled", .bool(true)), .init("changes", .string("ask")),
            .init("markDone", .bool(false)), .init("createdAt", .number(1))]))
        await a.taskOwner.setConnectedSystems(systemsA, links: nil)
        await b.taskOwner.setConnectedSystems(systemsB, links: nil)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        let text = CloudLeanFixture.text(startedA.sent)
        #expect(text.contains("task-system:cts-0123456789"))
        #expect(!text.contains("SECRET") && !text.contains("9876"), "No token, no token ending, in a record")
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        let rows = try await systemsB.cloudConnectionRows()
        #expect(rows.count == 1 && rows.first?["url"].string == "https://tasks.example.com/mcp" && rows.first?["name"].string == "Tracker")
        #expect(try tokensB.read("cts-0123456789") == nil, "The token never comes with the connection")

        // The token: only through saved passwords' task-connection store (sealed there in the app).
        let storeA = BackendCloudSecretsTaskStore(sourceId: "tasks", tokens: tokensA, connectionIds: { try await systemsA.cloudConnectionIDs() },
            insertIfAbsent: { id, value in try await systemsA.cloudInsertTokenIfAbsent(id, value) })
        let storeB = BackendCloudSecretsTaskStore(sourceId: "tasks", tokens: tokensB, connectionIds: { try await systemsB.cloudConnectionIDs() },
            insertIfAbsent: { id, value in try await systemsB.cloudInsertTokenIfAbsent(id, value) })
        let records = try await storeA.capture()
        #expect(records.count == 1 && records.first?.domain == CloudSecretsDomain.taskConnection.rawValue)
        #expect(try await storeB.merge(try #require(records.first)) == .applied)
        #expect(try tokensB.read("cts-0123456789") == token)
        #expect(try await systemsB.cloudConnectionRows().first?["tokenEnding"].string == "…9876")
        #expect(try await storeB.merge(try #require(records.first)) == .alreadyPresent)

        // Removed on A by the person: removed on B too (with its token).
        try await systemsA.remove("cts-0123456789")
        try await CloudLeanFixture.deliver(try await CloudLeanFixture.sync(startedA.activation, on: a.mac), from: a.mac.device, to: b.taskAdapter)
        #expect(try await systemsB.cloudConnectionRows().isEmpty)
        #expect(try tokensB.read("cts-0123456789") == nil)
    }

    /// A CRM task link of another Mac (tasks sent to that Mac's own address) shows a plain line here, by name.
    @Test func aCrmLinkOfAnotherMacShowsAPlainLine() async throws {
        let clock = CloudLeanFixture.Clock()
        let b = try await Self.side(CloudLeanFixture.deviceB, clock)
        defer { CloudKindsTests.cleanup(b) }
        _ = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        let entity = BackendCloudKindsTasks.linkKind.entity("key-1")
        await b.taskOwner.cloudReceiving(entity: entity, device: CloudLeanFixture.deviceA, at: 1)
        let cloud = NativeRPCValue.object([.init("keyId", .string("key-1")), .init("name", .string("iLoop")), .init("enabled", .bool(true))])
        let plan = try await b.taskOwner.cloudPlan(entity: entity, cloud: cloud)
        try await b.taskOwner.cloudWrite(entity: entity, value: try #require(plan.store), expecting: nil)
        let lines = BackendCloudKindsTasks.elsewhere.lines
        #expect(lines.contains { $0.hasPrefix("iLoop sends its tasks to Mac mini") })
        #expect(!lines.joined().contains("key-1") && !lines.joined().contains(CloudLeanFixture.deviceA), "Names, never ids")
        try await b.taskOwner.cloudRemove(entity: entity, expecting: plan.store, removal: .null, device: CloudLeanFixture.deviceA, at: 2)
        #expect(BackendCloudKindsTasks.elsewhere.lines.isEmpty)
    }

    // MARK: 4b. tasks a CRM task link sends to one Mac: read-only copies on the others

    /// The number beside Tasks (`SidebarView`): every task in the list not archived, not in Trash, not Done.
    static func badge(_ store: BackendTaskStore) async throws -> Int {
        try await store.all().filter { $0.value["archivedAt"].isNullish && $0.value["deletedAt"].isNullish && $0.value["crmStatus"].string != "Done" }.count
    }

    @Test func aCrmTaskArrivesAsAReadOnlyCopyCountsAndStartsNothing() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock), b = try await Self.side(CloudLeanFixture.deviceB, clock)
        defer { CloudKindsTests.cleanup(a, b) }
        let id = "iloop-key:crm-7"
        _ = try await a.tasks.put(CloudKindsTests.task("crm-7", title: "From iLoop", local: false, key: "iloop-key").setting("stopped", .bool(false)), now: true)
        _ = try await a.tasks.put(CloudKindsTests.task("mine", title: "Mine").setting("sessionId", .null), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        let copy = try #require(try await b.tasks.byID(id)?.value)
        #expect(copy["title"].string == "From iLoop" && copy["local"].bool == false)
        #expect(copy[BackendTaskStore.copyField]["mac"].string == "Mac mini", "Its card says where it lives")
        #expect(try await Self.badge(b.tasks) == Self.badge(a.tasks), "The same number beside Tasks on both Macs")
        // Starts nothing: inert, and nothing here can change it into work.
        #expect(copy["stopped"].bool == true && copy["process"].string == "stopped" && copy["sessionId"] == .null && !Self.pumpWouldStart(copy))
        // The original on A is untouched.
        #expect(try await a.tasks.byID(id)?.value["sessionId"].string == "session-crm-7")
    }

    @Test func aCrmCopyCannotBeEditedFollowsChangesAndGoesWithTheOriginal() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock), b = try await Self.side(CloudLeanFixture.deviceB, clock)
        defer { CloudKindsTests.cleanup(a, b) }
        let id = "iloop-key:crm-8"
        _ = try await a.tasks.put(CloudKindsTests.task("crm-8", title: "Call back", local: false, key: "iloop-key").setting("sessionId", .null), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))

        // Cannot be edited, assigned, commented, started or deleted here.
        await #expect(throws: NativeRPCError.self) { _ = try await b.tasks.update(id, patch: .object([.init("title", .string("Mine now"))])) }
        await #expect(throws: NativeRPCError.self) {
            _ = try await b.tasks.update(id, patch: .object([.init("assignee", .object([.init("kind", .string("agent")), .init("agentId", .string("writer"))])),
                                                           .init("process", .string("queued")), .init("stopped", .bool(false))]))
        }
        await #expect(throws: NativeRPCError.self) { try await b.tasks.note(id, by: "me", kind: "comment", text: "hello") }
        await #expect(throws: NativeRPCError.self) { _ = try await b.tasks.claim(id, sessionID: "session-b", liveSessionIDs: ["session-b"]) }
        await #expect(throws: NativeRPCError.self) { try await b.tasks.moveToTrash(id) }
        #expect(try await b.tasks.byID(id)?.value["title"].string == "Call back")
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty, "A copy never sends a change of its own")

        // The CRM changes it on A: the copy follows.
        _ = try await a.tasks.update(id, patch: .object([.init("title", .string("Call back today")), .init("crmStatus", .string("Working on it"))]))
        try await CloudLeanFixture.deliver(try await CloudLeanFixture.sync(startedA.activation, on: a.mac), from: a.mac.device, to: b.taskAdapter)
        let followed = try #require(try await b.tasks.byID(id)?.value)
        #expect(followed["title"].string == "Call back today" && followed["crmStatus"].string == "Working on it" && !Self.pumpWouldStart(followed))

        // The original goes on A: the copy goes on B.
        try await a.tasks.moveToTrash(id)
        try await CloudLeanFixture.deliver(try await CloudLeanFixture.sync(startedA.activation, on: a.mac), from: a.mac.device, to: b.taskAdapter)
        #expect(try await b.tasks.byID(id, includeTrash: true) == nil)
        #expect(try await Self.badge(b.tasks) == Self.badge(a.tasks))
    }

    // MARK: 5. mixed versions

    @Test func aClosedGateSendsTheOldFormAndKeepsThisMacsOwnFields() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.side(CloudLeanFixture.deviceA, clock, open: false), b = try await Self.side(CloudLeanFixture.deviceB, clock, open: false)
        defer { CloudKindsTests.cleanup(a, b) }
        let systemsA = try await Self.connected(a, secrets: BackendConnectedTasksMemorySecrets())
        try await systemsA.cloudPutConnection(.object([.init("id", .string("cts-closed0001")), .init("name", .string("Tracker")),
            .init("url", .string("https://tasks.example.com/mcp")), .init("enabled", .bool(true)), .init("changes", .string("ask"))]))
        await a.taskOwner.setConnectedSystems(systemsA, links: nil)
        _ = try await a.tasks.put(CloudKindsTests.task("c", title: "Child").setting("parentTaskId", .string("local:p"))
            .setting("detail", .object([.init("checklists", .array([]))])), now: true)
        let startedA = try await CloudLeanFixture.start(a.adapters, on: a.mac)
        let startedB = try await CloudLeanFixture.start(b.adapters, on: b.mac)
        for op in startedA.sent {
            let version = try CloudBrainMergeVersion(payload: op.payload.raw)
            #expect(version.minTable == 1)
            #expect(CloudBrainMergeTables.taskEverywhereFields.allSatisfy { version.fields[$0] == nil })
        }
        #expect(!CloudLeanFixture.text(startedA.sent).contains("task-system:"))
        try await CloudKindsTests.settle(a, startedA.activation, b, startedB.activation, first: (startedA.sent, startedB.sent))
        let onB = try #require(try await b.tasks.byID("local:c")?.value)
        #expect(onB["parentTaskId"].isNullish && onB["assignee"]["kind"].string == "none", "The old form: links and assignment stay")
    }
}
