import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTAgentRuntimeTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Sendable {
        let store: BackendTaskStore, config: BackendTaskConfiguration, engine: BackendTaskEngine
        let fleet: AGOPTTaskPolicyTests.Fleet
    }
    private func fixture(billing: String = "unknown", limit: Int = 100, pause: Bool = false) async throws -> Fixture {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-runtime-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory)
        let goals = BackendGoalStore(persistence: memory), fleet = AGOPTTaskPolicyTests.Fleet()
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(.object([.init("id", .string("worker")), .init("name", .string("Worker")),
            .init("provider", .string("codex")), .init("account", .string("Work")), .init("keepAliveUntilClose", .bool(true))]))
        let owner = AGSAgentSettings(provider: "codex", model: "default-model", effort: "medium", keepOpen: true,
            efficiency: .init(agentTokenBudget: limit, taskTokenBudget: 100, monthlyBudgetUSD: 5, onExhaustion: pause ? "pause" : "warn"))
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" },
            runtime: .init(billing: { _, _ in .object([.init("kind", .string(billing)), .init("source", .string("cached-owned-account"))]) }), problem: { _ in })
        try await engine.start(); return Fixture(store: store, config: config, engine: engine, fleet: fleet)
    }
    private func task(_ fixture: Fixture, id: String) async throws -> BackendTaskRecord {
        try await fixture.store.put(.object([.init("id", .string("local:" + id)), .init("keyId", .string("local")),
            .init("externalTaskId", .string(id)), .init("local", .bool(true)), .init("project", .string("/work")),
            .init("projectId", .string("project-work")), .init("title", .string(id)), .init("instructions", .string("Complete this scoped task and report the outcome.")),
            .init("assignee", BackendTaskLocalService.assignment("worker", kind: "agent"))]))
    }
    func testActualWarmRunsKeepBothTaskAssociationsAndMeasuredBaselineExcludesOldContext() async throws {
        let fixture = try await fixture(), first = try await task(fixture, id: "first")
        try await fixture.engine.accept(first.id)
        let unmeasured = try await fixture.engine.runs(profileID: "worker")
        XCTAssertTrue(unmeasured.first?["tokens"].isNullish == true)
        try await fixture.store.seedRunUsageBaseline(taskID: first.id, sessionID: "s-1", totalTokens: 1_000)
        try await fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 1_010)
        try await fixture.engine.noteFinishedTurn(sessionID: "s-1", turnID: "first", answer: "First done")
        let second = try await task(fixture, id: "second"); try await fixture.engine.accept(second.id)
        try await fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 1_025)
        let runs = try await fixture.engine.runs(profileID: "worker")
        XCTAssertEqual(runs.count, 2); XCTAssertEqual(Set(runs.compactMap { $0["session_id"].string }), ["s-1"])
        XCTAssertEqual(runs.first { $0["task_id"].string == first.id }?["tokens"].number, 10)
        XCTAssertEqual(runs.first { $0["task_id"].string == second.id }?["tokens"].number, 15)
        let unknown = try await fixture.engine.budget(profileID: "worker")
        XCTAssertTrue(unknown["isAPIAccount"].isNullish); XCTAssertTrue(unknown["cost_usd"].isNullish)
        XCTAssertEqual(unknown["tokens"].number, 25)
        try await fixture.engine.stop()
    }
    func testMonthlyPauseResumeOnceAndUnsupportedResetPreserveRetainedSession() async throws {
        let fixture = try await fixture(billing: "subscription", limit: 10, pause: true)
        let first = try await task(fixture, id: "over-limit"); try await fixture.engine.accept(first.id)
        try await fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 10)
        let paused = try await fixture.config.agent("worker"); XCTAssertEqual(paused?["status"].string, "paused")
        let second = try await task(fixture, id: "once")
        try await fixture.engine.accept(second.id)
        do { try await fixture.engine.resumeAgent("worker"); XCTFail("Exhausted budget resumed without owner override") } catch {}
        try await fixture.engine.resumeAgent("worker", once: true)
        let current = try await fixture.store.bySession("s-2")
        XCTAssertEqual(current?.id, first.id, "Resume once follows the actual FIFO continuation")
        let stillQueued = try await fixture.store.byID(second.id); XCTAssertNil(stillQueued?.sessionID)
        try await fixture.engine.noteTokenUsage(sessionID: "s-2", totalTokens: 3)
        try await fixture.engine.noteFinishedTurn(sessionID: "s-2", turnID: "once", answer: "Done")
        let again = try await fixture.config.agent("worker"); XCTAssertEqual(again?["status"].string, "paused")
        let reset = try await fixture.engine.resetAgentSessions("worker")
        XCTAssertEqual(reset["deferred_until_close"].bool, true)
        let sessions = await fixture.fleet.sessions; XCTAssertNil(sessions.last?.exitCode)
        try await fixture.engine.stop()
    }
    func testTrustedReportedMoneyIsIdempotentAndSubscriptionMoneyRefused() async throws {
        let fixture = try await fixture(billing: "api"), now = BackendTaskValues.time()
        let report = NativeRPCValue.object([.init("id", .string("routine-owned-run")), .init("agent_id", .string("worker")),
            .init("provider", .string("codex")), .init("account_id", .string("work-id")), .init("session_id", .string("routine-session")),
            .init("cwd", .string("/work")), .init("started_at", .number(now - 100)), .init("ended_at", .number(now)),
            .init("source", .string("verified-cli-total_cost_usd")), .init("confirmed_api", .bool(true)), .init("cost_usd", .number(0.75)), .init("tokens", .number(75))])
        _ = try await fixture.engine.recordAttributedRunResult(report); _ = try await fixture.engine.recordAttributedRunResult(report)
        let budget = try await fixture.engine.budget(profileID: "worker")
        XCTAssertEqual(budget["cost_usd"].number, 0.75); XCTAssertEqual(budget["isAPIAccount"].bool, true)
        try await fixture.engine.stop()
        let plan = try await self.fixture(billing: "subscription")
        do { _ = try await plan.engine.recordAttributedRunResult(report); XCTFail("Plan money was recorded") } catch {}
        let planBudget = try await plan.engine.budget(profileID: "worker"); XCTAssertTrue(planBudget["cost_usd"].isNullish)
        try await plan.engine.stop()
    }
    func testAtomicUsageStaysMonotonicAndRejectsPriorRunAfterHandover() async throws {
        let fixture = try await fixture(), first = try await task(fixture, id: "racing")
        try await fixture.engine.accept(first.id)
        let storedBinding = try await fixture.store.bySession("s-1"), binding = try XCTUnwrap(storedBinding)
        async let higher: Void = fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 120,
            expectedTaskID: binding.id, expectedAssignee: binding.value["assignee"], expectedRunID: binding.value["agoptRunID"].string)
        async let lower: Void = fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 100,
            expectedTaskID: binding.id, expectedAssignee: binding.value["assignee"], expectedRunID: binding.value["agoptRunID"].string)
        _ = try await (higher, lower)
        try await fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 120)
        let counted = try await fixture.store.byID(first.id), history = try await fixture.engine.runs(profileID: "worker")
        XCTAssertEqual(counted?.value["agoptUsageTotal"].number, 120); XCTAssertEqual(counted?.value["tokenUsage"].number, 120)
        XCTAssertEqual(history.first?["tokens"].number, 120)
        XCTAssertEqual(counted?.value["notes"].elements?.filter { $0["text"].string?.hasPrefix("Token budget warning: this task") == true }.count, 1)
        try await fixture.engine.noteFinishedTurn(sessionID: "s-1", turnID: "racing", answer: "Done")
        let second = try await task(fixture, id: "new-owner"); try await fixture.engine.accept(second.id)
        try await fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 200,
            expectedTaskID: binding.id, expectedAssignee: binding.value["assignee"], expectedRunID: binding.value["agoptRunID"].string)
        let after = try await fixture.store.byID(second.id); XCTAssertNil(after?.value["tokenUsage"].number)
        try await fixture.engine.noteTokenUsage(sessionID: "s-1", totalTokens: 130)
        let fresh = try await fixture.store.byID(second.id); XCTAssertEqual(fresh?.value["tokenUsage"].number, 10)
        try await fixture.engine.stop()
    }
}
