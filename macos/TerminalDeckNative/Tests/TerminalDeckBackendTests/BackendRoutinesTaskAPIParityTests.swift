import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendRoutinesTaskAPIParityHarness: Sendable {
    let api: BackendTaskAPI
    let accepted: @Sendable () async -> [String], cancelled: @Sendable () async -> [String], reassigned: @Sendable () async -> [String]
    let replies: @Sendable () async -> [(String, String)]
}
/// The source test's recording engine (accept/reply/cancel/reassign) is the fixture's recorder, which implements the
/// same protocol the API takes; no live engine, process or timer is started.
enum BackendRoutinesTaskAPIParityBindings {
    static let recording: (@Sendable (BackendRoutinesTaskStoreParityRig) async throws -> BackendRoutinesTaskAPIParityHarness)? = { rig in
        let recorder = rig.recorder
        // The source recorder keeps each task's externalTaskId; the protocol is handed the record id (`key:external`).
        let external: @Sendable (String) -> String = { String($0.drop { $0 != ":" }.dropFirst()) }
        return BackendRoutinesTaskAPIParityHarness(api: BackendTaskAPI(store: rig.store, configuration: rig.config, engine: recorder),
            accepted: { await recorder.accepted.map(external) }, cancelled: { await recorder.cancelled.map(external) }, reassigned: { await recorder.reassigned.map(external) },
            replies: { await recorder.replies.map { (external($0.0), $0.1) } })
    }
    /// The genuine host guard: the production security server's own request gate (loopback, local Host, no Origin)
    /// in front of the task route, with a listener that never opens a socket.
    static let noOriginHTTP: (@Sendable (BackendTaskHTTP, NativeRPCValue) async throws -> BackendTaskHTTPAnswer)? = { http, request in
        struct Tasks: BackendDeckCoreSecurityTaskHTTP {
            let http: BackendTaskHTTP
            func answer(method: String, path: String, authorization: String?, body: String) async throws -> BackendDeckCoreSecurityHTTPResponse {
                let answered = try await http.handle(method: method, path: path, authorization: authorization, body: Data(body.utf8)); return .json(answered.body, status: answered.status)
            }
        }
        struct NoSocket: BackendDeckCoreSecurityListening { func start(port: Int) async throws -> Int { 49_999 }; func stop() async {} }
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in false }), log = BackendDeckCoreSecurityActionLog(directory: FileManager.default.temporaryDirectory.appendingPathComponent("routines-no-origin-" + UUID().uuidString))
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: [])
        let server = BackendDeckCoreSecurityServer(control: control, ownPorts: .init(), tasks: Tasks(http: http), listenerFactory: { _ in NoSocket() })
        _ = try await server.start(port: 49_999)
        var headers = ["host": "127.0.0.1:49999"]
        if let authorization = request["authorization"].string { headers["authorization"] = authorization }
        if let origin = request["origin"].string { headers["origin"] = origin }
        var body = Data(); if case .bytes(let sent) = request["body"] { body = sent }
        let response = await server.respond(BackendDeckCoreSecurityHTTPRequest(method: request["method"].string ?? "GET", path: request["path"].string ?? "/", headers: headers, body: body))
        await server.stop(); await consent.stop()
        return BackendTaskHTTPAnswer(status: response.status, body: (try? NativeRPCValue.parseJSON(response.body)) ?? .null)
    }
}
struct BackendRoutinesTaskAPIParityRig: Sendable {
    let core: BackendRoutinesTaskStoreParityRig, api: BackendTaskAPI
    static func make(changed: @escaping @Sendable () async -> Void = {}) async throws -> Self {
        let core = try await BackendRoutinesTaskStoreParityRig.make(memory: true, changed: changed)
        _ = try await core.config.saveConnection("k1", input: routinesTaskObject([("enabled", .bool(true)), ("hootIdentity", .string("u-hoot")), ("identities", routinesTaskObject([("u-builder", .string("builder"))])), ("allowedSenders", routinesTaskText(["u-asad"])), ("folders", routinesTaskText(["/work"]))]))
        return .init(core: core, api: BackendTaskAPI(store: core.store, configuration: core.config, engine: core.engine))
    }
    func payload(_ over: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        routinesTaskObject([("eventId", .string(UUID().uuidString)), ("externalTaskId", .string(UUID().uuidString)), ("title", .string("Fix the login bug")),
            ("instructions", .string("It throws on an empty password.")), ("project", .string("/work/app")), ("assignee", .string("u-builder")), ("requestedBy", .string("u-asad"))]).merging(routinesTaskObject(over))
    }
    func call(_ op: String, _ input: NativeRPCValue, api: BackendTaskAPI? = nil) async throws -> NativeRPCValue { try await (api ?? self.api).call(op, keyID: "k1", input: input).wireValue }
    func seed(_ external: String = "m") async throws {
        _ = try await core.store.put(routinesTaskObject([("id", .string("k1:" + external)), ("keyId", .string("k1")), ("externalTaskId", .string(external)), ("originExternalTaskId", .string(external)),
            ("title", .string("Fix the login bug")), ("project", .string("/work/app")), ("requestedBy", .string("u-asad")),
            ("assignee", routinesTaskObject([("kind", .string("agent")), ("agentId", .string("builder")), ("identity", .string("u-builder"))])),
            ("process", .string("queued")), ("crmStatus", .string("To-Do")), ("result", .null), ("sessionId", .null), ("stopped", .bool(false)), ("hops", .number(0))]))
    }
    func comment(_ over: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        routinesTaskObject([("eventId", .string(UUID().uuidString)), ("externalTaskId", .string("t-task")), ("externalCommentId", .string(UUID().uuidString)), ("author", .string("u-asad")), ("body", .string("Please also add a test."))]).merging(routinesTaskObject(over))
    }
    func recording() async throws -> BackendRoutinesTaskAPIParityHarness {
        let bind = try #require(BackendRoutinesTaskAPIParityBindings.recording)
        return try await bind(core)
    }
}

@Suite("Exact task-api.test.ts parity")
struct BackendRoutinesTaskAPIParityTests {
    @Test func refusesEverythingWhenDisabled() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
        _ = try await r.core.config.saveConnection("k1", input: routinesTaskObject([("enabled", .bool(false))]))
        routinesTaskMatches(try await r.call("create", r.payload()), routinesTaskObject([("ok", .bool(false)), ("code", .string("disabled"))]))
        routinesTaskMatches(try await r.call("get", routinesTaskObject([("externalTaskId", .string("x"))])), routinesTaskObject([("ok", .bool(false)), ("code", .string("disabled"))]))
        }
    }
    @Test func allowsOnlyPermittedCRMUser() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
        for who in ["u-employee", "u-hoot"] { routinesTaskMatches(try await r.call("create", r.payload([("requestedBy", .string(who))])), routinesTaskObject([("ok", .bool(false)), ("code", .string("not_allowed"))])) }
        let h = try await r.recording(); #expect(await h.accepted().isEmpty)
        routinesTaskMatches(try await r.call("create", r.payload(), api: h.api), routinesTaskObject([("ok", .bool(true)), ("value", routinesTaskObject([("outcome", .string("accepted"))]))]))
        }
    }
    @Test func refusesDotAndUnmappedAssignees() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
        routinesTaskMatches(try await r.call("create", r.payload([("assignee", .string("u-dot"))])), routinesTaskObject([("ok", .bool(false)), ("code", .string("not_mine"))]))
        }
    }
    @Test func resolvesFoldersBeforeAllowingThem() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
        for folder in ["/work/../etc", "/workshop", "work/app"] { routinesTaskMatches(try await r.call("create", r.payload([("project", .string(folder))])), routinesTaskObject([("ok", .bool(false)), ("code", .string("folder_not_allowed"))])) }
        }
    }
    @Test func allowsHootChildrenOnlyUnderAllowedHootRootWithinHopLimit() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; let h = try await r.recording()
        _ = try await r.call("create", r.payload([("externalTaskId", .string("root")), ("assignee", .string("u-hoot"))]), api: h.api)
        routinesTaskMatches(try await r.call("create", r.payload([("externalTaskId", .string("c1")), ("parentExternalTaskId", .string("root")), ("requestedBy", .string("u-hoot")), ("project", .missing)]), api: h.api), routinesTaskObject([("ok", .bool(true))]))
        routinesTaskMatches(try await r.core.store.byID("k1:c1")!.value, routinesTaskObject([("hops", .number(1)), ("project", .string("/work/app")), ("originExternalTaskId", .string("root"))]))
        routinesTaskMatches(try await r.call("create", r.payload([("parentExternalTaskId", .string("c1")), ("requestedBy", .string("u-hoot"))]), api: h.api), routinesTaskObject([("ok", .bool(false)), ("code", .string("not_allowed"))]))
        _ = try await r.core.config.saveConnection("k1", input: routinesTaskObject([("maxHops", .number(1))]))
        _ = try await r.call("create", r.payload([("externalTaskId", .string("mid")), ("parentExternalTaskId", .string("root")), ("assignee", .string("u-hoot"))]), api: h.api)
        routinesTaskMatches(try await r.call("create", r.payload([("parentExternalTaskId", .string("mid"))]), api: h.api), routinesTaskObject([("ok", .bool(false)), ("code", .string("too_many_hops"))]))
        }
    }
    @Test func duplicateEventAndTaskStartOnlyOnce() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; let h = try await r.recording()
        let payload = r.payload([("eventId", .string("same")), ("externalTaskId", .string("A")), ("title", .string("x"))])
        let first = try await r.call("create", payload, api: h.api), again = try await r.call("create", payload, api: h.api)
        #expect(first["ok"].bool == true && again["ok"].bool == true)
        routinesTaskMatches(again, routinesTaskObject([("ok", .bool(true)), ("value", routinesTaskObject([("duplicate", .bool(true)), ("outcome", .string("accepted"))]))]))
        _ = try await r.call("create", payload.setting("eventId", .string("other")), api: h.api)
        #expect(await h.accepted() == ["A"]); #expect(try await r.core.store.all().count == 1)
        }
    }
    @Test func refusalCanBeRetriedAfterSettingFix() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
        let payload = r.payload([("eventId", .string("r")), ("externalTaskId", .string("R")), ("title", .string("x")), ("project", .string("/other"))])
        #expect(try await r.call("create", payload)["ok"].bool == false)
        _ = try await r.core.config.saveConnection("k1", input: routinesTaskObject([("folders", routinesTaskText(["/work", "/other"]))]))
        let h = try await r.recording(); #expect(try await r.call("create", payload, api: h.api)["ok"].bool == true)
        }
    }
    @Test func ignoresEveryOwnIdentityAndPostedComment() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed("t-task")
        for (author, mentions) in [("u-builder", ["u-hoot"]), ("u-hoot", ["u-builder"])] { #expect(try await r.call("comment", r.comment([("author", .string(author)), ("mentions", routinesTaskText(mentions))]))["value"]["outcome"].string == "ignored_own_agent") }
        try await r.core.store.markOurs(keyID: "k1", eventID: "crm-comment-we-posted")
        #expect(try await r.call("comment", r.comment([("externalCommentId", .string("crm-comment-we-posted")), ("mentions", routinesTaskText(["u-builder"]))]))["value"]["outcome"].string == "ignored_own_agent")
        #expect(await r.core.recorder.replies.isEmpty)
        }
    }
    @Test func repliesOnlyToAllowedAddressedComments() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed("t-task")
        #expect(try await r.call("comment", r.comment([("author", .string("u-employee")), ("mentions", routinesTaskText(["u-builder"]))]))["value"]["outcome"].string == "ignored_not_allowed")
        #expect(try await r.call("comment", r.comment())["value"]["outcome"].string == "ignored_not_addressed")
        let h = try await r.recording(); #expect(try await r.call("comment", r.comment([("mentions", routinesTaskText(["u-builder"]))]), api: h.api)["value"]["outcome"].string == "answered")
        try await r.core.store.markOurs(keyID: "k1", eventID: "our-question")
        #expect(try await r.call("comment", r.comment([("inReplyTo", .string("our-question"))]), api: h.api)["value"]["outcome"].string == "answered")
        #expect(await h.replies().count == 2)
        }
    }
    @Test func commentIDIsDeduplicatedAcrossNewEvents() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed("t-task"); let h = try await r.recording()
        for _ in 0..<2 { _ = try await r.call("comment", r.comment([("externalCommentId", .string("twice")), ("mentions", routinesTaskText(["u-builder"]))]), api: h.api) }
        #expect(await h.replies().count == 1)
        }
    }
    @Test func boardNotifiedOnceForNewStatusEvent() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let told = BackendRoutinesTaskStoreParitySignal(), r = try await BackendRoutinesTaskAPIParityRig.make(changed: { await told.hit() }); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed()
        let before = await told.count, input = routinesTaskObject([("eventId", .string("w1")), ("externalTaskId", .string("m")), ("status", .string("In Progress")), ("changedBy", .string("u-asad"))])
        _ = try await r.call("status", input); #expect(await told.count - before == 1)
        _ = try await r.call("status", input); #expect(await told.count - before == 1)
        }
    }
    @Test func statusRecordsButDoesNotAct() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed()
        #expect(try await r.call("status", routinesTaskObject([("eventId", .string("s1")), ("externalTaskId", .string("m")), ("status", .string("In Progress")), ("changedBy", .string("u-asad"))]))["value"]["outcome"].string == "recorded")
        #expect(try await r.core.store.byID("k1:m")?.value["crmStatus"].string == "In Progress")
        #expect(try await r.call("status", routinesTaskObject([("eventId", .string("s2")), ("externalTaskId", .string("m")), ("status", .string("Done")), ("changedBy", .string("u-builder"))]))["value"]["outcome"].string == "ignored_own_agent")
        routinesTaskMatches(try await r.call("status", routinesTaskObject([("eventId", .string("s3")), ("externalTaskId", .string("m")), ("status", .string("Cancelled"))])), routinesTaskObject([("ok", .bool(false)), ("code", .string("bad_request"))]))
        #expect(await r.core.recorder.cancelled.isEmpty); #expect(await r.core.recorder.replies.isEmpty); #expect(await r.core.recorder.reassigned.isEmpty)
        }
    }
    @Test func foreignAssignmentStopsWorkAndExplicitCancelCancels() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed(); let h = try await r.recording()
        #expect(try await r.call("assign", routinesTaskObject([("eventId", .string("a1")), ("externalTaskId", .string("m")), ("assignee", .string("u-dot")), ("requestedBy", .string("u-asad"))]), api: h.api)["value"]["outcome"].string == "released")
        #expect(await h.cancelled() == ["m"])
        routinesTaskMatches(try await r.call("assign", routinesTaskObject([("eventId", .string("a2")), ("externalTaskId", .string("m")), ("assignee", .string("u-hoot")), ("requestedBy", .string("u-employee"))]), api: h.api), routinesTaskObject([("ok", .bool(false)), ("code", .string("not_allowed"))]))
        _ = try await r.call("create", r.payload([("externalTaskId", .string("k"))]), api: h.api)
        #expect(try await r.call("cancel", routinesTaskObject([("eventId", .string("x1")), ("externalTaskId", .string("k")), ("requestedBy", .string("u-asad"))]), api: h.api)["value"]["outcome"].string == "cancelled")
        }
    }
    @Test func readsTaskAndResultUsingExternalID() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; try await r.seed()
        routinesTaskMatches(try await r.call("get", routinesTaskObject([("externalTaskId", .string("m"))])), routinesTaskObject([("ok", .bool(true)), ("value", routinesTaskObject([("task", routinesTaskObject([("externalTaskId", .string("m")), ("agent", .string("Builder")), ("crmStatus", .string("To-Do")), ("process", .string("queued")), ("finished", .bool(false))]))]))]))
        routinesTaskMatches(try await r.call("result", routinesTaskObject([("externalTaskId", .string("m"))])), routinesTaskObject([("ok", .bool(true)), ("value", routinesTaskObject([("finished", .bool(false)), ("answer", .null)]))]))
        routinesTaskMatches(try await r.call("get", routinesTaskObject([("externalTaskId", .string("nope"))])), routinesTaskObject([("ok", .bool(false)), ("code", .string("not_found"))]))
        }
    }
}
