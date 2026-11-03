import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane TK (7 Oct 2026): tasks by project in the backend — an old task record with
// no project, the scoping rule, and the agent / Hoot tool defaults (a listing shows
// the calling session's project; all_projects asks for every one; a new task gets
// the caller's project). Tool names and old arguments stay as they were.

/// The task tools with a caller-project seam: session "s-app" works in /work/app,
/// "s-site" in /work/site, Hoot ("hoot", no session project) in none.
private struct TKToolsRig: Sendable {
    let io: BackendCrmTaskDetailParityNativeIO
    let registrations: [(BackendMCPTool, BackendNativeMCPServer.Handler)]

    static func make() async throws -> Self {
        let io = try await BackendCrmTaskDetailParityNativeIO.make(notify: true)
        let f = io.fixture
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] }, start: { _,_,_,_,_ in throw NativeRPCError(code: "test-process", message: "No process may be launched by these tests.") }, send: { _,_ in }, stop: { _ in }, setControl: { _,_,_ in }, check: { _,_ in (true, "fake verification") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: f.store, configuration: f.config, goals: f.goals, access: access, workspace: { $0.project }, problem: { _ in })
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/tk-task-projects-inert"), ownership: .memory)
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil }, post: { _,_ in throw NativeRPCError(code: "test-network", message: "No network may be used by these tests.") }, onCommentID: { _,_ in }, problem: { _ in })
        let view = BackendTaskStateView(store: f.store, configuration: f.config, goals: f.goals, outbox: outbox, keyViews: { [] })
        let planning = BackendGoalPlanning(goals: f.goals, tasks: f.store, configuration: f.config, local: f.local, detail: f.detail)
        let server = BackendNativeMCPServer()
        let homes = ["s-app": "/work/app", "s-site": "/work/site"]
        let authority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { caller in
            if caller.machineID != "hoot" { throw NativeRPCError(code: "not-granted", message: "Hoot’s own tool") }
        }, visible: { _, _ in true }, project: { _, path in
            guard ["/work/app", "/work/site"].contains(where: { BackendTaskProjectScope.within(path, $0) }) else {
                throw NativeRPCError.invalidArguments("The project is not inside a folder Terminal Deck has open")
            }
        }, authorize: { _,_,_,_ in }, actorName: { _ in "hoot" },
           callerProject: { caller in homes[caller.sessionID] })
        _ = try await BackendTaskMCP.register(server: server, view: view, local: f.local, engine: engine, detail: f.detail, planning: planning,
                                              api: nil, indexed: true, authority: authority)
        return Self(io: io, registrations: await server.registrations())
    }

    func call(_ id: String, _ input: [String: Any], session: String = "", caller: String = "hoot") async throws -> NativeRPCValue {
        let handler = try #require(registrations.first { $0.0.id == id }?.1, "Missing native MCP tool: \(id)")
        let context = BackendMCPCallContext(sessionID: session, machineID: caller, projectRoot: nil, attended: true,
                                            allowedTools: Set(registrations.map { $0.0.id }), allowedTiers: [.read, .act, .alter],
                                            cancellation: BackendMCPCancellation())
        return try #require(try await handler(context, crmParityValue(input)).structuredContent)
    }

    func schema(_ id: String) throws -> NativeRPCValue { try #require(registrations.first { $0.0.id == id }?.0).inputSchema }

    func create(_ title: String, _ extra: [String: Any] = [:], session: String = "") async throws -> NativeRPCValue {
        try await call("tasks.local_change", (["do": "create", "title": title] as [String: Any]).merging(extra) { _, new in new }, session: session)["created"]
    }
}

@Suite(.serialized) struct TKTaskProjectScopeTests {
    // MARK: Old records

    @Test func anOldRecordWithoutAProjectLoadsKeepsItsShapeAndReadsAsNoProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TKTaskProjects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive)
        try persistence.write("tasks.json", value: crmParityValue(["v": 1, "tasks": [
            ["id": "local:old", "keyId": "local", "externalTaskId": "old", "title": "Before projects", "local": true, "crmStatus": "To-Do"],
        ], "trash": [Any](), "seen": [Any](), "ours": [Any]()] as [String: Any]))
        let store = BackendTaskStore(persistence: persistence)
        try await store.start()
        let old = try #require(try await store.byID("local:old"))
        #expect(old.project == "" && old.value["title"].string == "Before projects")
        #expect(BackendTaskProjectScope.includes(old, project: nil))
        #expect(!BackendTaskProjectScope.includes(old, project: "/work/app"))
        // A later write keeps the old record as it was: no project is invented for it.
        _ = try await store.put(crmParityValue(["id": "local:new", "keyId": "local", "externalTaskId": "new", "title": "After", "local": true, "project": "/work/app"]))
        let reread = try #require(try persistence.read("tasks.json"))
        let rows = reread["tasks"].elements ?? []
        #expect(rows.count == 2)
        #expect(rows.first { $0["id"].string == "local:old" }.map { $0.has("project") } == false)
        #expect(rows.first { $0["id"].string == "local:new" }?["project"].string == "/work/app")
    }

    // MARK: The rule

    @Test func aListingCoversTheCallersProjectUnlessAskedOtherwise() {
        #expect(BackendTaskProjectScope.listing(crmParityValue([String: Any]()), callerProject: "/work/app/") == "/work/app")
        #expect(BackendTaskProjectScope.listing(crmParityValue(["all_projects": true]), callerProject: "/work/app") == nil)
        #expect(BackendTaskProjectScope.listing(crmParityValue(["all_projects": false]), callerProject: "/work/app") == "/work/app")
        #expect(BackendTaskProjectScope.listing(crmParityValue(["project": "/work/site"]), callerProject: "/work/app") == "/work/site")
        #expect(BackendTaskProjectScope.listing(crmParityValue(["project": "/work/site", "all_projects": true]), callerProject: "/work/app") == nil)
        #expect(BackendTaskProjectScope.listing(crmParityValue([String: Any]()), callerProject: nil) == nil)
        #expect(BackendTaskProjectScope.listing(crmParityValue([String: Any]()), callerProject: "") == nil)
        #expect(BackendTaskProjectScope.within("/work/app/src", "/work/app") && !BackendTaskProjectScope.within("/work/application", "/work/app"))
        #expect(BackendTaskProjectScope.includes(goal: crmParityValue(["id": "g", "project": NSNull()]), project: "/work/app"))
        #expect(!BackendTaskProjectScope.includes(goal: crmParityValue(["id": "g", "project": "/work/site"]), project: "/work/app"))
    }

    @Test func theCallersProjectIsItsTasksElseTheOpenProjectHoldingItsFolder() {
        let open = ["/work/app", "/work/app/packages/ui", "/work/site"]
        #expect(BackendTaskProjectScope.callerProject(sessionID: "s", taskProject: "/work/site", sessionFolder: "/ws/task-1", openProjects: open) == "/work/site")
        #expect(BackendTaskProjectScope.callerProject(sessionID: "s", taskProject: nil, sessionFolder: "/work/app/packages/ui/src", openProjects: open) == "/work/app/packages/ui")
        #expect(BackendTaskProjectScope.callerProject(sessionID: "s", taskProject: "", sessionFolder: "/work/app/src", openProjects: open) == "/work/app")
        #expect(BackendTaskProjectScope.callerProject(sessionID: "s", taskProject: nil, sessionFolder: "/Users/x/hoot-home", openProjects: open) == nil)
        #expect(BackendTaskProjectScope.callerProject(sessionID: "", taskProject: "/work/app", sessionFolder: "/work/app", openProjects: open) == nil)
    }

    @Test func aNewTaskGetsTheCallersProjectUnlessItNamesOne() {
        #expect(BackendTaskProjectScope.createPatch(crmParityValue(["title": "x"]), callerProject: "/work/app")["project"].string == "/work/app")
        #expect(BackendTaskProjectScope.createPatch(crmParityValue(["title": "x", "project": ""]), callerProject: "/work/app")["project"].string == "")
        #expect(BackendTaskProjectScope.createPatch(crmParityValue(["title": "x", "project": "/work/site"]), callerProject: "/work/app")["project"].string == "/work/site")
        #expect(!BackendTaskProjectScope.createPatch(crmParityValue(["title": "x"]), callerProject: nil).has("project"))
    }

    // MARK: The tools

    @Test func agentToolsCreateInAndListTheCallersProject() async throws {
        let rig = try await TKToolsRig.make()
        #expect(try await rig.create("App work", session: "s-app")["project"].string == "/work/app")
        #expect(try await rig.create("Site work", session: "s-site")["project"].string == "/work/site")
        #expect(try await rig.create("Hoot's own")["project"].string == "")
        #expect(try await rig.create("Kept loose", ["project": ""], session: "s-app")["project"].string == "")
        #expect(try await rig.create("Named", ["project": "/work/site/docs"], session: "s-app")["project"].string == "/work/site/docs")

        let mine = try await rig.call("tasks.local", ["do": "list"], session: "s-app")
        #expect(crmParityStrings(mine["tasks"], "title") == ["App work"])
        #expect(mine["showing"].string == "project /work/app")
        let every = try await rig.call("tasks.local", ["do": "list", "all_projects": true], session: "s-app")
        #expect(Set(crmParityStrings(every["tasks"], "title")) == ["App work", "Site work", "Hoot's own", "Kept loose", "Named"])
        #expect(every["showing"].string == "all projects")
        let named = try await rig.call("tasks.local", ["do": "list", "project": "/work/site"], session: "s-app")
        #expect(Set(crmParityStrings(named["tasks"], "title")) == ["Site work", "Named"])
        // A caller with no project of its own (Hoot) still sees everything, as before.
        #expect(crmParityStrings(try await rig.call("tasks.local", ["do": "list"])["tasks"], "title").count == 5)
        // Old arguments still work alongside.
        #expect(Set(crmParityStrings(try await rig.call("tasks.local", ["do": "list", "archived": false, "limit": 10], session: "s-site")["tasks"], "title")) == ["Site work", "Named"])
    }

    @Test func movingATaskByUpdateChangesWhereItLists() async throws {
        let rig = try await TKToolsRig.make()
        let id = try #require(try await rig.create("Wanders", session: "s-app")["task"].string)
        _ = try await rig.call("tasks.local_change", ["do": "update", "task": id, "project": "/work/site"], session: "s-app")
        #expect(crmParityStrings(try await rig.call("tasks.local", ["do": "list"], session: "s-app")["tasks"], "title").isEmpty)
        #expect(crmParityStrings(try await rig.call("tasks.local", ["do": "list"], session: "s-site")["tasks"], "title") == ["Wanders"])
    }

    @Test func hootsListAndTheGoalListFollowTheCallersProject() async throws {
        let rig = try await TKToolsRig.make()
        _ = try await rig.create("App work", session: "s-app")
        _ = try await rig.create("Site work", session: "s-site")
        let hoot = try await rig.call("tasks.list", [:])
        #expect(Set(crmParityStrings(hoot["tasks"], "title")) == ["App work", "Site work"])
        #expect(crmParityStrings(try await rig.call("tasks.list", [:], session: "s-app")["tasks"], "title") == ["App work"])
        #expect(Set(crmParityStrings(try await rig.call("tasks.list", ["all_projects": true], session: "s-app")["tasks"], "title")) == ["App work", "Site work"])
        #expect(crmParityStrings(try await rig.call("tasks.list", ["project": "/work/site"])["tasks"], "title") == ["Site work"])

        for (title, project) in [("App goal", "/work/app"), ("Site goal", "/work/site")] {
            _ = try await rig.call("tasks.goals", ["do": "create", "title": title, "project": project])
        }
        _ = try await rig.call("tasks.goals", ["do": "create", "title": "Everywhere goal"])
        #expect(Set(crmParityStrings(try await rig.call("tasks.goals", ["do": "list"], session: "s-app")["goals"], "title")) == ["App goal", "Everywhere goal"])
        #expect(crmParityStrings(try await rig.call("tasks.goals", ["do": "list", "all_projects": true], session: "s-app")["goals"], "title").count == 3)
        #expect(crmParityStrings(try await rig.call("tasks.goals", ["do": "list"])["goals"], "title").count == 3)
    }

    @Test func toolNamesStayAndTheNewArgumentIsOptional() async throws {
        let rig = try await TKToolsRig.make()
        for id in ["tasks.local", "tasks.list", "tasks.goals"] {
            let schema = try rig.schema(id)
            #expect(schema["properties"]["all_projects"]["type"].string == "boolean")
            #expect(!(schema["required"].elements ?? []).contains(.string("all_projects")))
            #expect(rig.registrations.first { $0.0.id == id }?.0.wireName == id.replacingOccurrences(of: ".", with: "_"))
        }
        #expect(try rig.schema("tasks.list")["properties"]["project"]["type"].string == "string")
        #expect(try rig.schema("tasks.local")["properties"]["limit"].has("type"))
        let description = try #require(rig.registrations.first { $0.0.id == "tasks.local" }?.0.description)
        #expect(description.contains("all_projects") && description.contains("project"))
    }
}
