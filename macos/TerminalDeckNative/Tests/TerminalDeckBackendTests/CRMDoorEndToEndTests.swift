import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CRMDoorBox: @unchecked Sendable { var control: BackendDeckCoreSecurityControl? }

/// CRM-LINK end to end through the REAL door (installs 11-13 each found the next blocker): a key made as
/// "Connect a CRM" makes it (CRM-only, level Look), internet access on, the relay's request door
/// (answerRelay), deck-control with tools_run, crm.task's own consent decision (BackendCrmLink.ownerMustAnswer)
/// and the real task API. Roster, a create from the owner's profile, a comment, a status change, and a
/// refused non-owner actor; and nothing but crm_task is reachable.
struct CRMDoorEndToEndTests {
    static let owner = "user:00000000-0000-4000-8000-0000000000aa"

    @Test func aCRMOnlyKeyRunsCrmTaskThroughToolsRunAndOnlyTheOwnerIsHeard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CRMDOOR-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The key, exactly as "Connect a CRM" makes it.
        let keys = BackendDeckCoreSecurityAccessKeys(directory: root.appendingPathComponent("keys"))
        let made = try await keys.create(.object([.init("name", .string("iLoop CRM (staging)")), .init("level", .string("look")), .init("crmOnly", .bool(true))]))
        let secret = try #require(made["key"].string), keyID = try #require(made["view"]["id"].string)
        _ = try await keys.setInternet(.bool(true))
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys); await door.activate()
        // The task side: the connection bound to that key, the owner pinned, the linked projects' agent.
        let taskRoot = root.appendingPathComponent("tasks")
        try FileManager.default.createDirectory(at: taskRoot, withIntermediateDirectories: true)
        let persistence = try BackendTaskPersistence(directory: taskRoot, ownership: .exclusive)
        try persistence.write("task-config.json", value: routinesTaskObject([("v", .number(1)), ("connections", .array([routinesTaskObject([
            ("keyId", .string(keyID)), ("name", .string("iLoop CRM")), ("enabled", .bool(true)), ("eventsUrl", .null), ("eventsSecret", .string(BackendRoutinesTaskStoreParityRig.secret)),
            ("statuses", BackendTaskConfiguration.defaultStatuses), ("hootIdentity", .string("agent:hoot")), ("identities", .object([])),
            ("allowedSenders", routinesTaskText([Self.owner])), ("folders", routinesTaskText(["/work/crm"])), ("maxHops", .number(3)),
            ("ownerProfile", .string(Self.owner)), ("projects", routinesTaskText(["imatch", "crm"]))])])),
            ("agents", .array([routinesTaskObject([("id", .string("builder")), ("name", .string("Builder")), ("projectId", .string("crm")), ("defaultProject", .string("/work/crm"))])]))]))
        let rig = try await BackendRoutinesTaskStoreParityRig.make(root: taskRoot)
        let api = BackendTaskAPI(store: rig.store, configuration: rig.config, engine: rig.recorder)
        // deck-control with tools_run and crm.task as production wires them (tier act, audience keys, its consent rule).
        let box = CRMDoorBox()
        let object = NativeRPCValue.object([.init("type", .string("object"))])
        let crmTool = try BackendMCPTool(id: "crm.task", wireName: "crm_task", description: "CRM task API", inputSchema: object, tier: .act)
        let crm = BackendDeckCoreSecurityToolPolicy(tool: crmTool, audience: "keys", summary: { _, _ in "CRM task" }, run: { args, context in
            let ask = BackendCrmLink.ownerMustAnswer(tool: "crm.task", caller: context.caller, otherwise: true)
            _ = try await box.control!.prepareEffect(context: context, tool: "crm.task", arguments: args, tier: .act, sentence: "Use crm.task", ownerMustAnswer: ask)
            guard let key = context.caller.keyID else { throw NativeRPCError(code: "not-granted", message: "This caller is not a CRM key.") }
            let answer = try await api.call(try args["op"].requireString("op"), keyID: key, input: args.removing("op"))
            guard answer.ok else { throw NativeRPCError(code: answer.code ?? "not-permitted", message: answer.message ?? "CRM task refused") }
            return .init(value: answer.value, summary: .object([]))
        })
        let runTool = try BackendMCPTool(id: "tools.run", wireName: "tools_run", description: "Run a tool by name", inputSchema: object, tier: .read)
        let run = BackendDeckCoreSecurityToolPolicy(tool: runTool, summary: { _, _ in "Run a tool" }, run: { _, _ in throw NativeRPCError(code: "internal", message: "dispatched by the control") })
        let sessionsTool = try BackendMCPTool(id: "sessions.list", wireName: "sessions_list", description: "sessions", inputSchema: object, tier: .read)
        let sessions = BackendDeckCoreSecurityToolPolicy(tool: sessionsTool, summary: { _, _ in "List sessions" }, run: { _, _ in .init(value: .object([]), summary: .object([])) })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: root.appendingPathComponent("log")), consent: .init(ask: { _ in false }), policies: [run, crm, sessions])
        box.control = control
        let server = BackendDeckCoreSecurityServer(control: control, keys: door, ownPorts: .init())

        var nextID = 0.0
        func rpc(_ method: String, _ params: NativeRPCValue) async throws -> NativeRPCValue {
            nextID += 1
            let body = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(nextID)), .init("method", .string(method)), .init("params", params)]).encodedJSON()
            let response = await server.answerRelay(authorization: "Bearer " + secret, pathKey: nil, userAgent: "iloop", protocolVersion: "2025-06-18", body: body, cancellation: .init())
            #expect(response.status == 200, "\(method): HTTP \(response.status)")
            return try NativeRPCValue.parseJSON(response.body)["result"]
        }
        func crmTask(_ arguments: [(String, NativeRPCValue)]) async throws -> NativeRPCValue {
            try await rpc("tools/call", routinesTaskObject([("name", .string("tools_run")), ("arguments", routinesTaskObject([("name", .string("crm_task")), ("arguments", routinesTaskObject(arguments))]))]))
        }
        func text(_ result: NativeRPCValue) -> String { (result["content"].elements ?? []).compactMap { $0["text"].string }.joined(separator: " ") }

        #expect(try await rpc("initialize", routinesTaskObject([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([]))]))["serverInfo"]["name"].string != nil)
        // Roster.
        let roster = try await crmTask([("op", .string("roster"))])
        #expect(roster["isError"].bool != true, "roster: \(text(roster))")
        let agents = roster["structuredContent"]["agents"].elements ?? []
        #expect(agents.first?["handle"].string == "hoot" && agents.contains { $0["handle"].string == "builder" && $0["project"].string == "crm" }, "roster: \(text(roster))")
        // A create from the owner's profile.
        let created = try await crmTask([("op", .string("create")), ("eventId", .string("e-create")), ("externalTaskId", .string("t-1")), ("title", .string("Call the owner")),
                                         ("instructions", .string("Valuation before Friday.")), ("assignee", .string("agent:builder")), ("requestedBy", .string(Self.owner)),
                                         ("creator", .string(Self.owner)), ("dueDate", .string("2026-10-14")), ("priority", .string("High"))])
        #expect(created["isError"].bool != true && created["structuredContent"]["outcome"].string == "accepted", "create: \(text(created))")
        let task = try #require(try await rig.store.byID(keyID + ":t-1"))
        #expect(task.agentID == "builder" && task.value["dueDate"].string == "2026-10-14" && task.value["priority"].string == "High")
        // A comment from the owner that addresses the agent.
        let commented = try await crmTask([("op", .string("comment")), ("eventId", .string("e-comment")), ("externalTaskId", .string("t-1")), ("externalCommentId", .string("c-1")),
                                           ("author", .string(Self.owner)), ("body", .string("@builder use last year's numbers")), ("mentions", routinesTaskText(["agent:builder"]))])
        #expect(commented["isError"].bool != true && commented["structuredContent"]["outcome"].string == "answered", "comment: \(text(commented))")
        let replies = await rig.recorder.replies
        #expect(replies.contains { $0.0 == keyID + ":t-1" && $0.1.contains("last year's numbers") })
        // A status change from the owner.
        let status = try await crmTask([("op", .string("status")), ("eventId", .string("e-status")), ("externalTaskId", .string("t-1")), ("status", .string("In Progress")), ("changedBy", .string(Self.owner))])
        #expect(status["isError"].bool != true && status["structuredContent"]["outcome"].string == "recorded", "status: \(text(status))")
        #expect(try await rig.store.byID(keyID + ":t-1")?.value["crmStatus"].string == "In Progress")
        // Anyone else is refused: nothing made, nobody woken.
        let refused = try await crmTask([("op", .string("create")), ("eventId", .string("e-other")), ("externalTaskId", .string("t-2")), ("title", .string("Not his")),
                                         ("assignee", .string("agent:builder")), ("requestedBy", .string("user:someone-else"))])
        #expect(refused["isError"].bool == true && text(refused).contains("owner"), "non-owner: \(text(refused))")
        #expect(try await rig.store.byID(keyID + ":t-2") == nil)
        // Nothing else is reachable with this key.
        let other = try await rpc("tools/call", routinesTaskObject([("name", .string("sessions_list")), ("arguments", .object([]))]))
        #expect(other["isError"].bool == true)
        let behind = try await rpc("tools/call", routinesTaskObject([("name", .string("tools_run")), ("arguments", routinesTaskObject([("name", .string("sessions_list")), ("arguments", .object([]))]))]))
        #expect(behind["isError"].bool == true)
        let listed = (try await rpc("tools/list", .object([])))["tools"].elements?.compactMap { $0["name"].string } ?? []
        #expect(!listed.contains("sessions_list"))
    }
}
