import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// HOOTFIX 2026-10-09: "a second agent's task stays queued forever". A finished local task is
/// handed back to the person while its worker is kept open; the next task for that folder must
/// close that worker. The gate refused the stop (owner looked up by the CURRENT assignee, "me"),
/// the refusal escaped pump(), and every queued task behind it — for every agent — never started.
/// This runs many tasks across several agents through the REAL engine and the REAL gate.
final class HOOTFIXTaskQueueTests: XCTestCase {
    actor Fleet {
        private(set) var live: [BackendSessionMeta] = [], started = 0, stopped: [String] = [], exitedNoted: Set<String> = []
        private var concurrentByAgent: [String: Int] = [:]
        private(set) var maxConcurrentSeen: [String: Int] = [:]
        func sessions() -> [BackendSessionMeta] { live }
        func launch(_ task: BackendTaskRecord, agent: NativeRPCValue, cwd: String) -> BackendSessionMeta {
            started += 1
            let input = BackendCreateSessionInput(cwd: cwd, provider: agent["provider"].string ?? "claude")
            let spawn = BackendSpawnSpec(provider: input.provider!, command: "/fake/no-process", args: [], path: "/fake", agentSessionId: "conv-\(started)")
            let meta = BackendSessionMeta(id: "s-\(started)", input: input, spawn: spawn)
            live.append(meta); return meta
        }
        func stop(_ id: String) { stopped.append(id); if let n = live.firstIndex(where: { $0.id == id }) { live[n].exitCode = 0 } }
        /// Exits the engine has not been told about yet (the session event the monitor relays).
        func takeExits() -> [String] {
            let ids = live.filter { $0.exitCode != nil && !exitedNoted.contains($0.id) }.map(\.id); ids.forEach { exitedNoted.insert($0) }; return ids
        }
        func observe(running: [String: String]) {
            var counts: [String: Int] = [:]
            for (_, agent) in running { counts[agent, default: 0] += 1 }
            for (agent, count) in counts { maxConcurrentSeen[agent] = max(maxConcurrentSeen[agent] ?? 0, count) }
        }
    }

    func testManyTasksAcrossSeveralAgentsAllRunToCompletion() async throws {
        let clock = Clock()
        try await BackendTaskClockContext.withClock(clock) {
            let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/unused-hootfix-queue"), ownership: .memory)
            let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
            try await store.start(); try await config.start(); try await goals.start()
            // Four agents on all three AIs, default keep-open (30 min) so finished workers stay
            // open and must be closed by the next task in their folder.
            let agents = [("alpha", "claude"), ("bravo", "codex"), ("charlie", "gemini"), ("delta", "codex")]
            for (id, provider) in agents {
                // One job at a time per agent, set explicitly: since 12 Oct "Tasks at once" defaults to no limit (parallel jobs).
                _ = try await config.saveAgent(.object([.init("id", .string(id)), .init("name", .string(id.capitalized)), .init("provider", .string(provider)), .init("maxConcurrent", .number(1))]))
            }
            let folders = agents.map { "/work/\($0.0)" } + ["/work/shared"]
            let fleet = Fleet()
            let gate = BackendTaskSessionGate(store: store, config: config, connectionKeyExists: { _ in false }, openProjects: { folders })
            let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions() },
                start: { task, agent, cwd, brief, _ in
                    try await gate.authorize("sessions.start", .object([.init("cwd", .string(cwd)), .init("provider", agent["provider"]), .init("account", agent["account"]), .init("brief", .string(brief)), .init("task", .string(task.id))]))
                    return await fleet.launch(task, agent: agent, cwd: cwd)
                },
                send: { id, text in try await gate.authorize("sessions.send", .object([.init("sessionId", .string(id)), .init("text", .string(text))])) },
                stop: { id in try await gate.authorize("sessions.stop", .object([.init("sessionId", .string(id))])); await fleet.stop(id) },
                setControl: { _, _, _ in }, check: { _, _ in (true, "") }, tellHoot: { _ in })
            let problems = ProblemLog()
            let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access, workspace: { $0.project },
                problem: { await problems.add($0) })
            let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
            try await engine.start()

            // Five tasks per agent: mostly the agent's own folder, some in one shared folder.
            var created: [String] = []
            for round in 1...5 {
                for (id, _) in agents {
                    let folder = round % 3 == 0 ? "/work/shared" : "/work/\(id)"
                    let record = try await local.create(.object([.init("title", .string("\(id) task \(round)")),
                        .init("instructions", .string("Do round \(round) of the work for \(id) and report back when it is finished.")),
                        .init("assignee", .string(id)), .init("project", .string(folder))]))
                    created.append(record.id)
                }
            }
            XCTAssertEqual(created.count, 20)

            // Drive the fleet: every live worker finishes its turn; every stop is relayed as an exit.
            var finished: Set<String> = []
            for _ in 0..<400 {
                for id in await fleet.takeExits() { try await engine.noteExit(sessionID: id, exitCode: 0) }
                var running: [String: String] = [:]
                for session in await fleet.sessions() where session.exitCode == nil && !finished.contains(session.id) {
                    guard let task = try await store.bySession(session.id) else { continue }
                    running[session.id] = task.agentID
                    try await engine.noteStatus(sessionID: session.id, status: .working)
                    try await engine.noteFinishedTurn(sessionID: session.id, turnID: "turn-\(session.id)", answer: "Finished \(task.value["title"].string ?? "")")
                    finished.insert(session.id)
                }
                await fleet.observe(running: running)
                try await engine.pump()
                let rows = try await store.all().filter { created.contains($0.id) }
                if rows.allSatisfy({ !($0.value["result"].isNullish) }) { break }
                await Task.yield()
            }
            let rows = try await store.all().filter { created.contains($0.id) }
            let stuck = rows.filter { $0.value["result"].isNullish }.map { "\($0.value["title"].string ?? $0.id)=\($0.process)" }
            XCTAssertEqual(stuck, [], "every task, for every agent, must run to completion")
            XCTAssertEqual(rows.count, 20)
            let started = await fleet.started
            XCTAssertEqual(started, 20, "one worker per task")
            let seen = await fleet.maxConcurrentSeen
            XCTAssertTrue(seen.values.allSatisfy { $0 <= 1 }, "each agent keeps its one-at-a-time limit: \(seen)")
            let said = await problems.all
            XCTAssertFalse(said.contains { $0.contains("no current configured task/agent owner") }, said.joined(separator: "\n"))
            try await engine.stop()
        }
    }

    /// The gate itself: a handed-back task's kept-open worker can be stopped (only its own
    /// session); a start for a handed-back task, or a foreign session, is still refused.
    func testGateLetsTheEngineCloseAHandedBackWorkerOnly() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/unused-hootfix-gate"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory)
        try await store.start(); try await config.start()
        _ = try await config.saveAgent(.object([.init("id", .string("worker")), .init("name", .string("Worker")), .init("provider", .string("codex"))]))
        let handed = try await store.put(.object([.init("id", .string("local:h1")), .init("keyId", .string("local")), .init("externalTaskId", .string("h1")), .init("local", .bool(true)), .init("project", .string("/work")),
            .init("assignee", BackendTaskLocalService.assignment("me", kind: "human")), .init("handedFrom", .string("worker")),
            .init("sessionId", .string("s-1")), .init("process", .string("running"))]))
        XCTAssertEqual(BackendTaskSessionGate.ownerAgentID(handed), "worker")
        let gate = BackendTaskSessionGate(store: store, config: config, connectionKeyExists: { _ in false }, openProjects: { [] })
        try await gate.authorize("sessions.stop", .object([.init("sessionId", .string("s-1"))]))
        do { try await gate.authorize("sessions.stop", .object([.init("sessionId", .string("s-unknown"))])); XCTFail("foreign session stopped") } catch {}
        do { try await gate.authorize("sessions.start", .object([.init("task", .string("local:h1")), .init("provider", .string("codex")), .init("account", .null)])); XCTFail("closed project started") } catch {}
        do { try await gate.authorize("sessions.delete", .object([.init("sessionId", .string("s-1"))])); XCTFail("unknown action") } catch {}
    }

    /// U70 (18 Oct): while one agent's session is slow to start, other task edits, a new task and another
    /// agent's start go ahead; before, all of them waited ("saving…") until that session was up.
    func testOneSlowStartHoldsNeitherEditsNorAnotherAgentsStart() async throws {
        try await BackendTaskClockContext.withClock(Clock()) {
            let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/unused-hootfix-slow-start"), ownership: .memory)
            let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
            try await store.start(); try await config.start(); try await goals.start()
            for id in ["alpha", "bravo"] {
                _ = try await config.saveAgent(.object([.init("id", .string(id)), .init("name", .string(id.capitalized)), .init("provider", .string("codex")), .init("maxConcurrent", .number(1))]))
            }
            let fleet = Fleet(), slowStart = SlowStart(), quickDone = SlowStart()
            let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions() },
                start: { task, agent, cwd, _, _ in
                    if agent["id"].string == "alpha" { await slowStart.hold() }
                    return await fleet.launch(task, agent: agent, cwd: cwd)
                }, send: { _, _ in }, stop: { id in await fleet.stop(id) }, setControl: { _, _, _ in }, check: { _, _ in (true, "") }, tellHoot: { _ in })
            let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access, workspace: { $0.project }, problem: { _ in })
            let local = BackendTaskLocalService(store: store, configuration: config, goals: goals, engine: engine)
            try await engine.start()
            func input(_ agent: String) -> NativeRPCValue {
                .object([.init("title", .string("\(agent) task")), .init("instructions", .string("Do the \(agent) work and report back when it is finished.")),
                         .init("assignee", .string(agent)), .init("project", .string("/work/\(agent)"))])
            }
            let alphaInput = input("alpha"), bravoInput = input("bravo")
            let slow = Task { try await local.create(alphaInput) }
            await slowStart.waitUntilHeld()
            let quick = Task {
                let record = try await local.create(bravoInput)
                let renamed = try await local.update(record.id, input: .object([.init("title", .string("bravo task, renamed"))]))
                await quickDone.hold(); return renamed
            }
            var waited = 0
            while !(await quickDone.held), waited < 500 { try await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
            let wentAhead = await quickDone.held
            await slowStart.release(); await quickDone.release()
            let alpha = try await slow.value, bravo = try await quick.value
            XCTAssertTrue(wentAhead, "a new task, its edit and another agent's start must not wait for a slow session start")
            XCTAssertNotNil(bravo.sessionID, "bravo started while alpha's session was still starting")
            XCTAssertEqual(bravo.value["title"].string, "bravo task, renamed")
            XCTAssertNotNil(alpha.sessionID)
            try await engine.stop()
        }
    }
    actor SlowStart {
        private(set) var held = false
        private var released = false, holding: [CheckedContinuation<Void, Never>] = [], watching: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            held = true; watching.forEach { $0.resume() }; watching = []
            if !released { await withCheckedContinuation { holding.append($0) } }
        }
        func waitUntilHeld() async { if !held { await withCheckedContinuation { watching.append($0) } } }
        func release() { released = true; holding.forEach { $0.resume() }; holding = [] }
    }

    /// A still clock: the run never waits on wall time (keep-open never expires on its own here).
    final class Clock: BackendDeckCoreEventsClock, @unchecked Sendable {
        func now() -> Double { 1_800_000_000_000 }
        func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID { UUID() }
        func cancel(_ handle: UUID) {}
    }
    actor ProblemLog { private(set) var all: [String] = []; func add(_ text: String) { all.append(text) } }
}
