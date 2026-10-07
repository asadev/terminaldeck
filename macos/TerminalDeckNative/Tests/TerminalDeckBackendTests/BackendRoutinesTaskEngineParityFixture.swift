import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRoutinesTaskEngineParityClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 1_800_000_000_000.0
    private var timers: [UUID: (Double, @Sendable () -> Void)] = [:]
    func now() -> Double { lock.withLock { instant } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID { let id = UUID(); lock.withLock { timers[id] = (instant + max(0, milliseconds), run) }; return id }
    func cancel(_ handle: UUID) { lock.withLock { timers[handle] = nil } }
    var pending: Int { lock.withLock { timers.count } }
    var nextDue: Double? { lock.withLock { timers.values.map(\.0).min() } }
    /// Tests call the production owner's wake after moving this clock. This
    /// avoids waiting for tasks scheduled by a callback on a real executor.
    func move(by milliseconds: Double) { lock.withLock { instant += milliseconds } }
}

actor BackendRoutinesTaskEngineParityProbe {
    struct Start: Sendable { let task: BackendTaskRecord, agent: NativeRPCValue, cwd: String, brief: String, resume: String? }
    private(set) var launches: [Start] = [], controls: [NativeRPCValue] = [], sends: [NativeRPCValue] = [], stops: [String] = [], told: [String] = [], posts: [NativeRPCValue] = [], checked: [NativeRPCValue] = [], knowledgeAsked: [NativeRPCValue] = [], knowledgeEvents: [NativeRPCValue] = [], problems: [String] = []
    private var live: [BackendSessionMeta] = [], checkOK = true, checkOutput = "all tests passed", rejectEffort = false, expectedPosts = 0
    private var postWaiters: [(UUID, Int, CheckedContinuation<Void, any Error>)] = []
    func sessions() -> [BackendSessionMeta] { live }
    func launch(_ task: BackendTaskRecord, agent: NativeRPCValue, cwd: String, brief: String, resume: String?, clock: BackendRoutinesTaskEngineParityClock) -> BackendSessionMeta {
        launches.append(.init(task: task, agent: agent, cwd: cwd, brief: brief, resume: resume))
        let n = launches.count, input = BackendCreateSessionInput(cwd: cwd, provider: agent["provider"].string ?? "claude")
        let spawn = BackendSpawnSpec(provider: input.provider!, command: "/fake/no-process", args: [], path: "/fake", agentSessionId: resume ?? "conv-\(n)", resumed: resume != nil)
        let meta = BackendSessionMeta(id: "s-\(n)", input: input, spawn: spawn, now: Date(timeIntervalSince1970: clock.now() / 1000)); live.append(meta); return meta
    }
    func send(_ id: String, _ text: String) { sends.append(.object([.init("sessionId", .string(id)), .init("text", .string(text))])) }
    func stop(_ id: String) { stops.append(id); if let n = live.firstIndex(where: { $0.id == id }) { live[n].exitCode = 0 } }
    func exit(_ id: String, code: Int) { if let n = live.firstIndex(where: { $0.id == id }) { live[n].exitCode = code } }
    func forgetSessions() { live = [] }
    func control(_ id: String, _ key: String, _ value: String) throws {
        controls.append(.object([.init("sessionId", .string(id)), .init("control", .string(key)), .init("value", .string(value))]))
        if key == "effort", rejectEffort { throw NativeRPCError(code: "unsupported", message: "this agent has no effort setting") }
    }
    func refuseEffort() { rejectEffort = true }
    func check(_ command: String, _ cwd: String) -> (ok: Bool, output: String) { checked.append(.object([.init("command", .string(command)), .init("cwd", .string(cwd))])); return (checkOK, checkOutput) }
    func checkResult(ok: Bool, output: String) { checkOK = ok; checkOutput = output }
    func tell(_ text: String) { told.append(text) }
    func problem(_ text: String) { problems.append(text) }
    func askKnowledge(_ task: BackendTaskRecord) -> String {
        var input = NativeRPCValue.object([.init("project", .string(task.project)), .init("query", .string((task.value["title"].string ?? "") + "\n" + (task.value["instructions"].string ?? "")))])
        if let goal = task.value["goalId"].string { input = input.setting("goalId", .string(goal)) }; knowledgeAsked.append(input)
        return "- This project builds with pnpm (verified)."
    }
    func noteKnowledge(_ value: NativeRPCValue) { knowledgeEvents.append(value) }
    func expectPost() -> Int { expectedPosts += 1; return expectedPosts }
    func refusedPost() { expectedPosts = max(posts.count, expectedPosts - 1) }
    func post(_ event: NativeRPCValue) -> BackendTaskWebhookAnswer {
        posts.append(event)
        let ready = postWaiters.filter { $0.1 <= posts.count }; postWaiters.removeAll { $0.1 <= posts.count }; ready.forEach { $0.2.resume() }
        return .init(status: 200, body: "")
    }
    func waitForPosts(_ count: Int) async throws {
        guard posts.count < count else { return }; let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { postWaiters.append((token, count, $0)) }
        } onCancel: { Task { await self.cancelPostReceipt(token) } }
    }
    private func cancelPostReceipt(_ id: UUID) { if let index = postWaiters.firstIndex(where: { $0.0 == id }) { postWaiters.remove(at: index).2.resume(throwing: CancellationError()) } }
    func statuses() -> [String] { posts.filter { $0["type"].string == "task.status" }.compactMap { $0["status"].string } }
    func comments(_ kind: String? = nil) -> [NativeRPCValue] { posts.filter { $0["type"].string == "task.comment" && (kind == nil || $0["comment"]["kind"].string == kind) }.map { $0["comment"].merging(.object([.init("actor", $0["actor"]), .init("externalTaskId", $0["externalTaskId"]), .init("originExternalTaskId", $0["originExternalTaskId"])])) } }
}

struct BackendRoutinesTaskEngineParityFixture: Sendable {
    let clock: BackendRoutinesTaskEngineParityClock, store: BackendTaskStore, config: BackendTaskConfiguration, goals: BackendGoalStore, engine: BackendTaskEngine, local: BackendTaskLocalService, api: BackendTaskAPI, outbox: BackendTaskOutbox, delegation: BackendTaskDelegation, probe: BackendRoutinesTaskEngineParityProbe
    let knowledgeService: BackendKnowledgeService?, knowledgeRoot: URL?
    static let key = "key-1"
    static func make(clock: BackendRoutinesTaskEngineParityClock, knowledge: Bool = false, knowledgeThrows: Bool = false, knowledgeEventFailure: Bool = false,
                     goalsEnabled: Bool = true, workspace: (@Sendable (BackendTaskRecord) async throws -> String)? = nil,
                     persistence: BackendTaskPersistence? = nil) async throws -> Self {
        let memory = try persistence ?? BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/unused-task-parity"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory), probe = BackendRoutinesTaskEngineParityProbe()
        try await store.start(); try await config.start(); try await goals.start()
        for (id, name, provider, check) in [("builder", "Builder", "claude", NativeRPCValue.null), ("fixer", "Fixer", "claude", .null), ("tester", "Tester", "codex", .string("npm test"))] {
            var agent = obj([("id", .string(id)), ("name", .string(name)), ("role", .string(id == "tester" ? "tester" : "builder")), ("provider", .string(provider)), ("verifyCommand", check)])
            if id == "builder" { agent = agent.setting("account", .string("Work")).setting("model", .string("opus")) }; _ = try await config.saveAgent(agent)
        }
        _ = try await config.saveConnection(key, input: obj([("enabled", .bool(true)), ("eventsUrl", .string("https://crm.example.com/td-events")), ("hootIdentity", .string("u-hoot")), ("identities", obj([("u-builder", .string("builder")), ("u-tester", .string("tester"))])), ("allowedSenders", .array([.string("u-asad")])), ("folders", .array([.string("/work")]))]))
        let target = try BackendTaskWebhookTarget(url: URL(string: "https://crm.example.com/td-events")!, signingSecret: "whsec_" + Data(repeating: 3, count: 32).base64EncodedString())
        let outbox = BackendTaskOutbox(persistence: memory, target: { _ in target }, post: { _, event in await probe.post(event) }, onCommentID: { try await store.markOurs(keyID: $0, eventID: $1) }, problem: { await probe.problem($0) })
        try await outbox.start(); let realOutgoing = BackendTaskOutbox.outgoing(store: store, outbox: outbox)
        let outgoing: @Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void = { record, value in let count = await probe.expectPost(); do { try await realOutgoing(record, value) } catch { await probe.refusedPost(); throw error }; try await probe.waitForPosts(count) }
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await probe.sessions() }, start: { await probe.launch($0, agent: $1, cwd: $2, brief: $3, resume: $4, clock: clock) }, send: { await probe.send($0, $1) }, stop: { await probe.stop($0) }, setControl: { try await probe.control($0, $1, $2) }, check: { await probe.check($0, $1) }, tellHoot: { await probe.tell($0) })
        let engineGoals: BackendGoalStore
        if goalsEnabled { engineGoals = goals } else { engineGoals = BackendGoalStore(persistence: try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/unused-engine-goals"), ownership: .memory)); try await engineGoals.start() }
        let knowledgeLookup: (@Sendable (BackendTaskRecord) async throws -> String)?
        if knowledge || knowledgeThrows {
            knowledgeLookup = { @Sendable (task: BackendTaskRecord) async throws -> String in
                if knowledgeThrows { throw NativeRPCError(code: "index", message: "index is rebuilding") }
                return await probe.askKnowledge(task)
            }
        } else { knowledgeLookup = nil }
        let knowledgeRoot = knowledge ? FileManager.default.temporaryDirectory.appendingPathComponent("task-knowledge-parity-" + UUID().uuidString) : nil
        let knowledgeService = knowledgeRoot.map { BackendKnowledgeService(userData: $0.path, now: { clock.now() }, statMtime: { _ in nil }, newID: { if knowledgeEventFailure { throw NativeRPCError(code: "knowledge", message: "disk full") }; return "kp-" + UUID().uuidString.lowercased() }, onError: { message, context in Task { await probe.problem(context + ": " + message) } }) }
        let adapter = knowledgeService.map { BackendTaskKnowledgeAdapter(service: $0) }
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: engineGoals, access: access, workspace: workspace ?? { $0.project }, knowledge: knowledgeLookup, knowledgeAdapter: adapter, outgoing: outgoing, problem: { await probe.problem($0) })
        let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine), api = BackendTaskAPI(store: store, configuration: config, engine: engine)
        await local.setUpdateObserver { _, _, _, _ in try await engine.pump() }
        let delegation = BackendTaskDelegation(store: store, configuration: config, local: local, engine: engine, outgoing: outgoing)
        try await engine.start(); return .init(clock: clock, store: store, config: config, goals: goals, engine: engine, local: local, api: api, outbox: outbox, delegation: delegation, probe: probe, knowledgeService: knowledgeService, knowledgeRoot: knowledgeRoot)
    }
    static func withFixture(knowledge: Bool = false, knowledgeThrows: Bool = false, knowledgeEventFailure: Bool = false, goalsEnabled: Bool = true,
                            workspace: (@Sendable (BackendTaskRecord) async throws -> String)? = nil,
                            _ operation: @escaping @Sendable (Self) async throws -> Void) async throws {
        let clock = BackendRoutinesTaskEngineParityClock()
        try await BackendTaskClockContext.withClock(clock) {
            let rig = try await make(clock: clock, knowledge: knowledge, knowledgeThrows: knowledgeThrows, knowledgeEventFailure: knowledgeEventFailure, goalsEnabled: goalsEnabled, workspace: workspace)
            do { try await operation(rig); try await rig.stop() } catch { try? await rig.stop(); throw error }
        }
    }
    func stop() async throws { try await engine.stop(); try await outbox.stop(); if let knowledgeRoot { try? FileManager.default.removeItem(at: knowledgeRoot) } }
    func record(_ id: String) async throws -> BackendTaskRecord { let found = try await store.byID(id); return try XCTUnwrap(found) }
    func give(_ assignee: String, id: String = UUID().uuidString, patch: NativeRPCValue = .object([])) async throws -> String {
        let input = Self.obj([("eventId", .string("e-" + id)), ("externalTaskId", .string(id)), ("externalThreadId", .string("th-" + id)), ("title", .string("Task " + id)), ("instructions", .string("Fix the login bug.")), ("project", .string("/work/app")), ("assignee", .string(assignee)), ("requestedBy", .string("u-asad"))]).merging(patch)
        let answer = try await api.call("create", keyID: Self.key, input: input); XCTAssertTrue(answer.ok, answer.message ?? ""); return Self.key + ":" + id
    }
    func finish(_ session: String, answer: String = "Fixed.", turn: String = "turn-1") async throws { try await engine.noteStatus(sessionID: session, status: .working); try await engine.noteFinishedTurn(sessionID: session, turnID: turn, answer: answer) }
    func move(_ milliseconds: Double) async { clock.move(by: milliseconds); await engine.wake() }
    func notes(_ id: String) async throws -> [String] { try await record(id).value["notes"].elements?.map { ($0["by"].string ?? "") + "/" + ($0["kind"].string ?? "") + ": " + ($0["text"].string ?? "").components(separatedBy: "\n").first! } ?? [] }
    static func obj(_ rows: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(rows.map { .init($0.0, $0.1) }) }
}

/// Ordinary evaluated argument, unlike XCTest's synchronous autoclosure.
func BackendRoutinesTaskEngineParityUnwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

/// Raw-event observation of the production knowledge seam: the real
/// BackendTaskKnowledgeAdapter reports each event it hands the knowledge owner.
enum BackendRoutinesTaskEngineParityBindings {
    typealias KnowledgeEvents = @Sendable (BackendKnowledgeService, @escaping @Sendable (NativeRPCValue) async throws -> Void) async throws -> NativeRPCSubscription
    static let knowledgeEvents: KnowledgeEvents? = { service, handler in BackendTaskKnowledgeAdapter.observe(service, handler) }
}
