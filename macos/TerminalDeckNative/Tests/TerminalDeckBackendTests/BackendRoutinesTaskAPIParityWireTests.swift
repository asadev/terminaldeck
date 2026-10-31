import Foundation
import CryptoKit
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendRoutinesTaskAPIParityWireBindings {
    /// The production delivery's own request builder (no network, the fake clock supplies the timestamp).
    static let signedRequest: (@Sendable (BackendTaskWebhookTarget, NativeRPCValue) throws -> URLRequest)? = { target, event in try BackendTaskWebhookTransport.signedRequest(target: target, event: event) }
    /// The per-key tools/list the production security server serves: the source catalogue metadata over the tools this
    /// server registered, listed for a key caller (audience, key grant and the tools_run index applied), no listener.
    static let listForCRM: (@Sendable (BackendNativeMCPServer, BackendMCPCallContext) async throws -> NativeRPCValue)? = { server, context in
        let known = Set(try BackendDeckCoreSupplementMetadata.sourceDescriptors().compactMap { $0["id"].string })
        let specs = await server.registrations().map(\.0).filter { known.contains($0.id) }
        let metadata = try BackendDeckCoreSupplementMetadata.entries(specs: specs) + BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: context.allowedTiers, keyID: context.machineID, keyName: "Example CRM")
        return .array(try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata, caller: caller, granted: nil))
    }
}
actor BackendRoutinesTaskAPIParityPosts {
    var posts: [NativeRPCValue] = [], ids: [String] = []
    let status: Int
    init(_ status: Int) { self.status = status }
    func post(_ event: NativeRPCValue) -> BackendTaskWebhookAnswer { posts.append(event); return .init(status: status, body: #"{"externalCommentId":"crm-c-9"}"#) }
    func note(_ id: String) { ids.append(id) }
}
struct BackendRoutinesTaskAPIParityOutbox {
    let outbox: BackendTaskOutbox, posts: BackendRoutinesTaskAPIParityPosts, finished: BackendRoutinesTaskStoreParitySignal, target: BackendTaskWebhookTarget
    static let secret = "whsec_" + Data(repeating: 5, count: 32).base64EncodedString()
    static var body: NativeRPCValue { routinesTaskObject([("type", .string("task.comment")), ("externalTaskId", .string("t")), ("originExternalTaskId", .string("t")), ("externalThreadId", .null), ("actor", .string("u-builder")), ("comment", routinesTaskObject([("kind", .string("progress")), ("body", .string("Started.")), ("inReplyTo", .null)]))]) }
    static func make(_ persistence: BackendTaskPersistence, status: Int) async throws -> Self {
        let posts = BackendRoutinesTaskAPIParityPosts(status), finished = BackendRoutinesTaskStoreParitySignal(), target = try BackendTaskWebhookTarget(url: URL(string: "https://crm.example.com/events")!, signingSecret: secret)
        let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in target }, post: { _, event in await posts.post(event) }, onCommentID: { _, id in await posts.note(id) }, changed: { await finished.hit() }, problem: { _ in })
        try await outbox.start(); return .init(outbox: outbox, posts: posts, finished: finished, target: target)
    }
}
@Suite("Exact task-wire.test.ts parity")
struct BackendRoutinesTaskAPIParityWireTests {
    @Test func newConnectionIsOffPrivateAndSecretShownOnce() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let made = try await r.config.saveConnection("key-1", input: .object([]))
        routinesTaskMatches(made["view"], routinesTaskObject([("enabled", .bool(false)), ("allowedSenders", .array([])), ("folders", .array([])), ("hasEventsSecret", .bool(true))]))
        #expect(made["view"]["statuses"] == BackendTaskConfiguration.defaultStatuses); let secret = try #require(made["secret"].string); #expect(secret.hasPrefix("whsec_"))
        #expect(try await r.config.saveConnection("key-1", input: routinesTaskObject([("enabled", .bool(true))]))["secret"] == .null)
        #expect(try await !NativeRPCValue.array(r.config.connectionViews()).compact.contains(secret))
        #expect((try FileManager.default.attributesOfItem(atPath: r.root.appendingPathComponent("task-config.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let again = try BackendTaskConfiguration(persistence: r.persistence); try await again.start(); #expect(try await again.connection("key-1")?["enabled"].bool == true)
        }
    }
    @Test func customStatusSpellingIsPreservedAndMappingValidated() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(await routinesTaskError { _ = try await r.config.saveConnection("k", input: routinesTaskObject([("statuses", BackendTaskConfiguration.defaultStatuses.setting("onStarted", .string("Doing")))])) }.contains("has to be one of"))
        let custom = routinesTaskObject([("statuses", routinesTaskText(["Open", "Doing", "Closed"])), ("initial", .string("Open")), ("completed", .string("Closed")), ("onStarted", .string("Doing")), ("onVerified", .string("Closed")), ("onBlocked", .null)])
        #expect(try await r.config.saveConnection("k", input: routinesTaskObject([("statuses", custom)]))["view"]["statuses"]["onBlocked"] == .null)
        }
    }
    @Test func missingAgentIdentityRefusedAndRemovedAgentForgotten() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(memory: true); defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(await routinesTaskError { _ = try await r.config.saveConnection("k", input: routinesTaskObject([("identities", routinesTaskObject([("u-x", .string("ghost"))]))])) }.contains("does not exist"))
        _ = try await r.config.saveConnection("k", input: routinesTaskObject([("identities", routinesTaskObject([("u-b", .string("builder"))]))])); try await r.config.removeAgent("builder")
        #expect(try await r.config.connection("k")?["identities"] == .object([]))
        }
    }
    @Test func instructionsToolsSkillsEffortPersistAndLimitsRefuse() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        let saved = try await r.config.saveAgent(routinesTaskObject([("id", .string("reviewer")), ("name", .string("Reviewer")), ("effort", .string("xhigh")), ("instructions", .string("Read the diff first.")), ("toolsPreferred", routinesTaskText(["Read", "Read", "Grep"])), ("toolsAvoided", routinesTaskText(["Bash"])), ("skills", routinesTaskText(["code-review"]))]))
        routinesTaskMatches(saved, routinesTaskObject([("effort", .string("xhigh")), ("toolsPreferred", routinesTaskText(["Read", "Grep"])), ("toolsAvoided", routinesTaskText(["Bash"])), ("skills", routinesTaskText(["code-review"]))]))
        let again = try BackendTaskConfiguration(persistence: r.persistence); try await again.start()
        routinesTaskMatches(try await again.agent("reviewer")!, routinesTaskObject([("instructions", .string("Read the diff first.")), ("skills", routinesTaskText(["code-review"]))]))
        #expect(await routinesTaskError { _ = try await r.config.saveAgent(routinesTaskObject([("id", .string("x")), ("name", .string("X")), ("effort", .string("turbo"))])) }.contains("effort has to be one of"))
        #expect(await routinesTaskError { _ = try await r.config.saveAgent(routinesTaskObject([("id", .string("x")), ("name", .string("X")), ("skills", routinesTaskText((0..<21).map { "s\($0)" }))])) }.contains("at most 20"))
        routinesTaskMatches(try await r.config.saveAgent(routinesTaskObject([("id", .string("plain")), ("name", .string("Plain"))])), routinesTaskObject([("effort", .null), ("instructions", .null), ("toolsPreferred", .array([])), ("skills", .array([]))]))
        }
    }
    @Test func enforcedLimitsUseOwnerSelectedClaudeRealToolNames() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        routinesTaskMatches(try await r.config.saveAgent(routinesTaskObject([("id", .string("old")), ("name", .string("Old")), ("toolsAvoided", routinesTaskText(["Bash"]))])), routinesTaskObject([("blockedTools", .array([])), ("skillsOff", .bool(false))]))
        let locked = try await r.config.saveAgent(routinesTaskObject([("id", .string("locked")), ("name", .string("Locked")), ("provider", .string("claude")), ("blockedTools", routinesTaskText(["WebFetch", "mcp__deck-control__browser_open"])), ("skillsOff", .bool(true))]))
        let again = try BackendTaskConfiguration(persistence: r.persistence); try await again.start(); routinesTaskMatches(try await again.agent("locked")!, routinesTaskObject([("blockedTools", locked["blockedTools"]), ("skillsOff", .bool(true))]))
        for name in ["Bash(rm *)", "--allowedTools"] { #expect(await routinesTaskError { _ = try await r.config.saveAgent(routinesTaskObject([("id", .string("x")), ("name", .string("X")), ("blockedTools", routinesTaskText([name]))])) }.contains("not a tool name")) }
        #expect(await routinesTaskError { _ = try await r.config.saveAgent(routinesTaskObject([("id", .string("x")), ("name", .string("X")), ("provider", .string("codex")), ("skillsOff", .bool(true))])) }.contains("Only Claude Code"))
        }
    }
    @Test func namesConnectionAndReadsLegacyUnnamedByKey() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskStoreParityRig.make(); defer { try? FileManager.default.removeItem(at: r.root) }
        _ = try await r.config.saveConnection("key-named", input: routinesTaskObject([("name", .string("  Sales CRM "))])); _ = try await r.config.saveConnection("key-old", input: .object([]))
        let again = try BackendTaskConfiguration(persistence: r.persistence); try await again.start()
        #expect(try await again.connection("key-named")?["name"].string == "Sales CRM"); #expect(try await again.connection("key-old")?["name"] == .null)
        }
    }
    @Test func folderAllowsSelfAndDescendantsButNotPrefixSiblingOrEscape() {
        let connection = routinesTaskObject([("folders", routinesTaskText(["/work/app"]))])
        #expect(BackendTaskAPI.folderAllowed(connection, path: "/work/app")); #expect(BackendTaskAPI.folderAllowed(connection, path: "/work/app/src"))
        #expect(!BackendTaskAPI.folderAllowed(connection, path: "/work/app2")); #expect(!BackendTaskAPI.folderAllowed(connection, path: "/work/app/../secrets"))
    }
    @Test func outboxSignsAndRetriesAtExactFiveThirtyAndOneTwentySeconds() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let root = try routinesTaskScratch(); defer { try? FileManager.default.removeItem(at: root) }; let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), clock = try #require(BackendTaskClockContext.clock as? BackendRoutinesTaskEngineParityClock)
        let r = try await BackendRoutinesTaskAPIParityOutbox.make(persistence, status: 503), event = try await r.outbox.send(keyID: "k", body: BackendRoutinesTaskAPIParityOutbox.body, sequence: 0); await r.finished.wait(2)
        for (index, step) in [5_000.0, 30_000, 120_000].enumerated() {
            let raw = try #require(try persistence.read("task-outbox.json"))["items"].elements!.first!; #expect(raw["nextAt"].number == clock.now() + step)
            clock.move(by: step); await r.outbox.wake(); await r.finished.wait(index + 3)
        }
        #expect(await r.posts.posts.count == 4); let rows = await r.outbox.list(); routinesTaskMatches(rows[0], routinesTaskObject([("state", .string("undelivered")), ("attempts", .number(4))])); #expect(clock.pending == 0); try await r.outbox.stop()
        let signed = try #require(BackendRoutinesTaskAPIParityWireBindings.signedRequest)
        for post in await r.posts.posts {
            let request = try signed(r.target, post), stamp = try #require(request.value(forHTTPHeaderField: "webhook-timestamp")), body = try #require(request.httpBody)
            #expect(request.value(forHTTPHeaderField: "webhook-id") == event["eventId"].string)
            var bytes = Data((event["eventId"].string! + "." + stamp + ".").utf8); bytes.append(body)
            let signature = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: Data(repeating: 5, count: 32)))).base64EncodedString()
            #expect(request.value(forHTTPHeaderField: "webhook-signature") == "v1," + signature)
            #expect(abs(Double(stamp)! - floor(clock.now() / 1_000)) <= 300)
        }
        }
    }
    @Test func outboxNeverRetries400AndRecordsCRMCommentID() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let root = try routinesTaskScratch(); defer { try? FileManager.default.removeItem(at: root) }; let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), clock = try #require(BackendTaskClockContext.clock as? BackendRoutinesTaskEngineParityClock)
        let refused = try await BackendRoutinesTaskAPIParityOutbox.make(persistence, status: 400)
        _ = try await refused.outbox.send(keyID: "k", body: BackendRoutinesTaskAPIParityOutbox.body, sequence: 0); await refused.finished.wait(2); clock.move(by: 200_000); await refused.outbox.wake()
        #expect(await refused.posts.posts.count == 1); #expect(await refused.outbox.list().first?["state"].string == "undelivered"); try await refused.outbox.stop()
        let taken = try await BackendRoutinesTaskAPIParityOutbox.make(persistence, status: 200)
        _ = try await taken.outbox.send(keyID: "k", body: BackendRoutinesTaskAPIParityOutbox.body, sequence: 1); await taken.finished.wait(2); #expect(await taken.posts.ids == ["crm-c-9"]); try await taken.outbox.stop()
        }
    }
    @Test func outboxRestartPreservesPrivatePendingEventAndItsID() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let root = try routinesTaskScratch(); defer { try? FileManager.default.removeItem(at: root) }; let persistence = try BackendTaskPersistence(directory: root, ownership: .exclusive), clock = try #require(BackendTaskClockContext.clock as? BackendRoutinesTaskEngineParityClock)
        let first = try await BackendRoutinesTaskAPIParityOutbox.make(persistence, status: 503), event = try await first.outbox.send(keyID: "k", body: BackendRoutinesTaskAPIParityOutbox.body, sequence: 0); await first.finished.wait(2); try await first.outbox.stop()
        #expect((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("task-outbox.json").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let second = try await BackendRoutinesTaskAPIParityOutbox.make(persistence, status: 200); clock.move(by: 5_000); await second.outbox.wake(); await second.finished.wait(1)
        #expect(await second.posts.posts.first?["eventId"] == event["eventId"]); try await second.outbox.stop()
        }
    }
    @Test func taskHTTPRequiresValidKeyAndNoBrowserOrigin() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }; let h = try await r.recording()
        let http = BackendTaskHTTP(api: h.api, authenticate: { $0 == "Bearer ak_test" ? "k1" : nil }), body = try r.payload([("eventId", .string("e1")), ("externalTaskId", .string("T-1")), ("title", .string("Fix it"))]).encodedJSON()
        for auth in [nil, "Bearer ak_wrong"] { #expect(try await http.handle(method: "POST", path: "/tasks", authorization: auth, body: body).status == 403) }
        let made = try await http.handle(method: "POST", path: "/tasks", authorization: "Bearer ak_test", body: body); #expect(made.status == 200); routinesTaskMatches(made.body, routinesTaskObject([("outcome", .string("accepted")), ("task", routinesTaskObject([("externalTaskId", .string("T-1"))]))]))
        routinesTaskMatches(try await http.handle(method: "GET", path: "/tasks/T-1", authorization: "Bearer ak_test", body: Data()).body, routinesTaskObject([("task", routinesTaskObject([("externalTaskId", .string("T-1")), ("crmStatus", .string("To-Do"))]))]))
        let dot = try await http.handle(method: "POST", path: "/tasks", authorization: "Bearer ak_test", body: r.payload([("eventId", .string("e2")), ("externalTaskId", .string("T-2")), ("assignee", .string("u-dot"))]).encodedJSON()); #expect(dot.status == 409); #expect(dot.body["error"]["code"].string == "not_mine")
        let noOrigin = try #require(BackendRoutinesTaskAPIParityBindings.noOriginHTTP)
        #expect(try await noOrigin(http, routinesTaskObject([("method", .string("POST")), ("path", .string("/tasks")), ("authorization", .string("Bearer ak_test")), ("origin", .string("https://evil.example")), ("body", .bytes(body))])).status == 403)
        }
    }
    @Test func CRMToolHidesHootToolsAndUsesSameAPIDoor() async throws {
        try await BackendTaskClockContext.withClock(BackendRoutinesTaskEngineParityClock()) {
        let r = try await BackendRoutinesTaskAPIParityRig.make(); defer { try? FileManager.default.removeItem(at: r.core.root) }
        let server = BackendNativeMCPServer(), planning = BackendGoalPlanning(goals: r.core.goals, tasks: r.core.store, configuration: r.core.config, local: r.core.local, detail: r.core.detail)
        let authority = BackendTaskToolAuthority(requireTasks: { _ in }, requireHoot: { if $0.machineID == "crm" { throw NativeRPCError(code: "not-permitted", message: "Hoot’s own tool") } }, visible: { _, _ in true }, project: { _, _ in }, authorize: { _, _, _, _ in }, actorName: { _ in "Hoot" }, crmKeyID: { guard $0.machineID == "crm" else { throw NativeRPCError(code: "not-permitted", message: "CRM connected with an access key") }; return "k1" })
        _ = try await BackendTaskMCP.register(server: server, view: r.core.view, local: r.core.local, engine: r.core.engine, detail: r.core.detail, planning: planning, api: r.api, indexed: true, authority: authority)
        let registered = await server.registrations(), key = BackendMCPCallContext(sessionID: "", machineID: "crm", projectRoot: nil, attended: true, allowedTools: ["crm_task"], allowedTiers: [.read, .act, .alter], cancellation: .init()), hoot = BackendMCPCallContext(sessionID: "", machineID: "local", projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init())
        let verify = try #require(registered.first { $0.0.wireName == "tasks_verify" }), crm = try #require(registered.first { $0.0.wireName == "crm_task" })
        #expect(await routinesTaskError { _ = try await verify.1(key, routinesTaskObject([("task", .string("x")), ("verified", .bool(true))])) }.contains("Hoot’s own tool"))
        #expect(await routinesTaskError { _ = try await crm.1(hoot, routinesTaskObject([("op", .string("get"))])) }.contains("CRM connected with an access key"))
        let list = try #require(BackendRoutinesTaskAPIParityWireBindings.listForCRM)
        let everything = try await list(server, key).compact
        for name in ["tasks_list", "tasks_get", "tasks_delegate", "tasks_comment", "tasks_verify", "tasks_set_status"] { #expect(!everything.contains(name)) }; #expect(everything.contains("crm_task"))
        let h = try await r.recording()
        let activeServer = BackendNativeMCPServer()
        _ = try await BackendTaskMCP.register(server: activeServer, view: r.core.view, local: r.core.local, engine: r.core.engine, detail: r.core.detail, planning: planning, api: h.api, indexed: true, authority: authority)
        let activeCrm = try #require(await activeServer.registrations().first { $0.0.wireName == "crm_task" })
        let made = try await activeCrm.1(key, r.payload([("eventId", .string("m1")), ("externalTaskId", .string("M-1")), ("title", .string("Fix it"))]).setting("op", .string("create")))
        #expect(!made.isError); #expect(try await r.core.store.byID("k1:M-1") != nil)
        #expect(await routinesTaskErrorCode { _ = try await activeCrm.1(key, r.payload([("eventId", .string("m2")), ("externalTaskId", .string("M-2")), ("requestedBy", .string("u-employee"))]).setting("op", .string("create"))) } == "not_allowed")
        #expect(!(await routinesTaskError { _ = try await verify.1(key, routinesTaskObject([("task", .string("x")), ("verified", .bool(true))])) }).isEmpty)
        }
    }
}
