import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTTaskPolicyTests: XCTestCase, @unchecked Sendable {
    private func row(_ id: String, project: String = "/work", patch: NativeRPCValue = .object([])) throws -> BackendTaskRecord {
        try .init(.object([.init("id", .string("local:" + id)), .init("keyId", .string("local")),
            .init("externalTaskId", .string(id)), .init("local", .bool(true)), .init("project", .string(project)),
            .init("title", .string("Scoped work " + id)), .init("instructions", .string("Do this scoped work and report the result after checking it.")),
            .init("assignee", BackendTaskLocalService.assignment("worker", kind: "agent"))]).merging(patch))
    }
    private var agent: NativeRPCValue { .object([.init("id", .string("worker")), .init("name", .string("Worker")),
        .init("provider", .string("codex")), .init("account", .string("Work")), .init("keepAliveMinutes", .number(0))]) }
    private var settings: AGSAgentSettings { .init(provider: "codex", model: "default-model", effort: "medium", efficiency: .init(completion: "park", agentTokenBudget: 200, taskTokenBudget: 100)) }

    func testParkedConversationIsExactAndNeverBorrowedAcrossAccountFolderAgentOrConnection() throws {
        let next = try row("next")
        let snapshot = BackendAGOPTTaskPolicy.snapshot(agent: agent, cwd: "/work", settings: settings)
            .merging(.object([.init("conversationId", .string("kept-thread")), .init("result", .object([.init("at", .number(2))]))]))
        let prior = try row("prior", patch: snapshot)
        XCTAssertEqual(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: settings, records: [prior]), "kept-thread")
        for field in ["agoptAgentID", "agoptProvider", "agoptAccount", "agoptCwd"] {
            let foreign = try row("foreign", patch: snapshot.setting(field, .string("other")))
            XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: settings, records: [foreign]), field)
        }
        let live = try row("live", patch: snapshot.setting("sessionId", .string("s-running")))
        let stopped = try row("stopped", patch: snapshot.setting("agoptCompletion", .string("stop")))
        let otherProject = try row("other", project: "/elsewhere", patch: snapshot)
        let foreignConnection = try BackendTaskRecord(prior.value.setting("id", .string("crm:prior")).setting("keyId", .string("crm")))
        XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: settings, records: [live, stopped, otherProject, foreignConnection]))
        let externalCaller = try row("external", patch: snapshot.setting("notificationKeyId", .string("other-key")))
        XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: settings, records: [externalCaller]))
        for field in ["skillsOff", "claudeAgent", "instructionsFile", "instructions", "sourceFile", "extraTaskInstructions", "projectId"] {
            let changed = agent.setting(field, field == "skillsOff" ? .bool(true) : .string("changed-launch-setting"))
            XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: changed, cwd: "/work", settings: settings, records: [prior]), field)
        }
        let otherProjectID = try BackendTaskRecord(prior.value.setting("projectId", .string("different-project")))
        XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: settings, records: [otherProjectID]))
        var restricted = settings; restricted.deniedTools = ["mcp__private__write"]
        XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: restricted, records: [prior]))
        var noReuse = settings; noReuse.efficiency?.reuseContext = false
        XCTAssertNil(BackendAGOPTTaskPolicy.parkedConversation(for: next, agent: agent, cwd: "/work", settings: noReuse, records: [prior]))
    }

    func testTaskChoicesValidateBeforeLaunchAndKeepOwnerTools() throws {
        var owner = settings; owner.deniedTools = ["mcp__private__write"]
        let task = try row("override", patch: .object([.init("model", .string("task-model")), .init("effort", .string("high"))]))
        let effective = try BackendAGOPTTaskPolicy.applying(task, to: owner)
        XCTAssertEqual(effective.model, "task-model"); XCTAssertEqual(effective.effort, "high")
        XCTAssertEqual(effective.deniedTools, owner.deniedTools)
        let invalid = try row("bad", patch: .object([.init("effort", .string("nonsense"))]))
        XCTAssertThrowsError(try BackendAGOPTTaskPolicy.applying(invalid, to: owner))
        let raisedBudget = try row("raised", patch: .object([.init("tokenBudget", .number(101))]))
        let removedBudget = try row("removed", patch: .object([.init("tokenBudget", .number(0))]))
        XCTAssertThrowsError(try BackendAGOPTTaskPolicy.applying(raisedBudget, to: owner))
        XCTAssertThrowsError(try BackendAGOPTTaskPolicy.applying(removedBudget, to: owner))
    }

    actor Fleet {
        var sessions: [BackendSessionMeta] = [], resumes: [String?] = [], agents: [NativeRPCValue] = [], controls: [String] = [], deliveries: [String] = []
        var failDelivery = false
        func send(_ id: String) throws { deliveries.append(id); if failDelivery { throw NativeRPCError(code: "stub-refused", message: "stub delivery refused") } }
        func refuseDelivery() { failDelivery = true }
        func launch(_ task: BackendTaskRecord, agent: NativeRPCValue, cwd: String, resume: String?) -> BackendSessionMeta {
            resumes.append(resume); agents.append(agent)
            let provider = agent["provider"].string ?? "codex"
            let input = BackendCreateSessionInput(cwd: cwd, provider: provider)
            let spawn = BackendSpawnSpec(provider: provider, command: "/stub/no-process", args: [], path: "/stub", profile: provider == "gemini" ? nil : .init(id: "work-id", name: "Work"), agentSessionId: resume ?? "thread-1")
            let meta = BackendSessionMeta(id: "s-\(resumes.count)", input: input, spawn: spawn); sessions.append(meta); return meta
        }
        func stop(_ id: String) { if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].exitCode = 0 } }
        func control(_ key: String) { controls.append(key) }
    }


    func testStopCompletionClosesAndClearsConversation() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-stop-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start(); _ = try await config.saveAgent(agent)
        let fleet = Fleet()
        var selected = settings; selected.efficiency?.completion = "stop"
        let owner = selected
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let task = try await store.put(row("stop").value); try await engine.accept(task.id)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "stop-turn", answer: "Finished")
        let stored = try await store.byID(task.id)
        XCTAssertNil(stored?.sessionID); XCTAssertNil(stored?.value["conversationId"].string)
        let second = try await store.put(row("next-after-stop").value); try await engine.accept(second.id)
        let resumes = await fleet.resumes; XCTAssertEqual(resumes.count, 2); XCTAssertNil(resumes[1])
        try await engine.stop()
    }

    func testApprovedUntilCloseProfileRetainsLiveSessionAndStillWarns() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-retained-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)))
        let fleet = Fleet()
        var selected = settings; selected.keepOpen = true
        let owner = selected
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let task = try await store.put(row("retained").value); try await engine.accept(task.id)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 80)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "retained-turn", answer: "Finished")
        let stored = try await store.byID(task.id), sessions = await fleet.sessions
        XCTAssertEqual(stored?.sessionID, "s-1"); XCTAssertEqual(stored?.value["keepAliveUntilClose"].bool, true)
        XCTAssertNil(sessions.first?.exitCode); XCTAssertEqual(stored?.value["tokenUsage"].number, 80)
        XCTAssertEqual(stored?.value["agoptTaskBudgetWarned"].bool, true)
        let instructions = BackendAGOPTTaskPolicy.instructions(owner, profileID: "worker", retained: true)
        XCTAssertTrue(instructions.contains("keep this session open")); XCTAssertFalse(instructions.contains("stop the process"))
        try await engine.stop()
    }

    func testRetainedTwoTasksReuseExactLiveSessionAndChangedModelStartsFreshProcess() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-live-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)))
        let fleet = Fleet()
        var selected = settings; selected.keepOpen = true
        let owner = selected
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { id, _ in try await fleet.send(id) },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let first = try await store.put(row("live-first").value); try await engine.accept(first.id)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 50)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "live-one", answer: "Finished first")
        let second = try await store.put(row("live-second").value); try await engine.accept(second.id)
        let old = try await store.byID(first.id), current = try await store.byID(second.id), starts = await fleet.resumes, delivered = await fleet.deliveries
        XCTAssertNil(old?.sessionID); XCTAssertEqual(old?.value["result"]["answer"].string, "Finished first")
        XCTAssertEqual(current?.sessionID, "s-1"); XCTAssertEqual(starts.count, 1); XCTAssertEqual(delivered, ["s-1"])
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 70)
        let counted = try await store.byID(second.id); XCTAssertEqual(counted?.value["tokenUsage"].number, 20)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "live-two", answer: "Finished second")
        let third = try await store.put(row("live-third", patch: .object([.init("model", .string("task-other-model"))])).value)
        try await engine.accept(third.id)
        let final = try await store.byID(third.id), restarts = await fleet.resumes, sessions = await fleet.sessions
        XCTAssertEqual(final?.sessionID, "s-2"); XCTAssertEqual(restarts.count, 2); XCTAssertEqual(restarts[1], "thread-1")
        XCTAssertEqual(sessions.first?.exitCode, 0)
        try await engine.stop()
    }

    /// Rule since 10 Oct (Asad's bug: a delivery doubt killed the worker and the task hung): a brief that could
    /// not be handed to a reused session never stops that session. The task goes Stuck and still points at it,
    /// so the person or Hoot can open it and send the brief; the finished task keeps its result.
    func testFailedReusedDeliveryLeavesTransferredWorkerOpenAndKeepsOriginalResult() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-live-failure"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)))
        let fleet = Fleet(), owner = settings
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { id, _ in try await fleet.send(id) },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let first = try await store.put(row("failed-first").value); try await engine.accept(first.id)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "failed-one", answer: "Original finished result")
        await fleet.refuseDelivery()
        let second = try await store.put(row("failed-second").value); try await engine.accept(second.id)
        let old = try await store.byID(first.id), next = try await store.byID(second.id), sessions = await fleet.sessions
        XCTAssertEqual(old?.value["result"]["answer"].string, "Original finished result"); XCTAssertNil(old?.sessionID)
        XCTAssertEqual(next?.sessionID, "s-1"); XCTAssertEqual(next?.value["crmStatus"].string, "Stuck"); XCTAssertNil(sessions.first?.exitCode)
        let said = (next?.value["notes"].elements ?? []).compactMap { $0["text"].string ?? $0.string }.joined(separator: " ")
        XCTAssertTrue(said.contains("left open") || (next?.value["lastError"].string ?? next?.value["stuckReason"].string ?? "").contains("left open"), "the task must say the session was left open: \(next?.value.compact ?? "")")
        try await engine.stop()
    }

    actor AccountChoice { var current = "work-id"; func change() { current = "other-account-id" } }
    actor GeminiAccountChoice { var current = "account-a"; func change() { current = "account-b" } }
    func testGeminiRealNilProfileMetadataReusesTrustedAccountAndRefusesChangedDefault() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-gemini-live"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("provider", .string("gemini")).setting("account", .null).setting("keepAliveUntilClose", .bool(true)))
        let fleet = Fleet(), account = GeminiAccountChoice()
        let owner = AGSAgentSettings(provider: "gemini", model: "gemini-3-pro", effort: "high", keepOpen: true, efficiency: .init(completion: "park"))
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { id, _ in try await fleet.send(id) },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in await account.current }, problem: { _ in })
        try await engine.start()
        let first = try await store.put(row("gemini-first").value); try await engine.accept(first.id)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "gemini-one", answer: "First Gemini result")
        let firstSnapshot = try await store.byID(first.id), initial = await fleet.sessions
        XCTAssertNil(initial.first?.profileId); XCTAssertEqual(firstSnapshot?.value["agoptProfileID"].string, "account-a")
        let second = try await store.put(row("gemini-second").value); try await engine.accept(second.id)
        let reused = try await store.byID(second.id), starts = await fleet.resumes, deliveries = await fleet.deliveries
        XCTAssertEqual(reused?.sessionID, "s-1"); XCTAssertEqual(starts.count, 1); XCTAssertEqual(deliveries, ["s-1"])
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "gemini-two", answer: "Second Gemini result")
        await account.change()
        let third = try await store.put(row("gemini-third").value); try await engine.accept(third.id)
        let queued = try await store.byID(third.id), alive = await fleet.sessions, finalDeliveries = await fleet.deliveries
        XCTAssertEqual(queued?.process, "queued"); XCTAssertNil(queued?.sessionID)
        XCTAssertNil(alive.first?.exitCode); XCTAssertEqual(finalDeliveries, ["s-1"])
        try await engine.stop()
    }
    func testChangedAccountPreservesUntilCloseSessionQueuesOnceAndExitClearsWait() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-live-account"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)))
        let fleet = Fleet(), owner = settings, account = AccountChoice()
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { id, _ in try await fleet.send(id) },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in await account.current }, problem: { _ in })
        try await engine.start()
        let first = try await store.put(row("account-first").value); try await engine.accept(first.id)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "account-one", answer: "Original account result")
        await account.change()
        let second = try await store.put(row("account-second").value); try await engine.accept(second.id); try await engine.pump()
        let queued = try await store.byID(second.id), live = await fleet.sessions, deliveries = await fleet.deliveries
        XCTAssertEqual(queued?.process, "queued"); XCTAssertNil(queued?.sessionID); XCTAssertTrue(deliveries.isEmpty)
        XCTAssertNil(live.first?.exitCode); XCTAssertEqual(queued?.value["agoptWaitingForSession"].bool, true)
        XCTAssertEqual(queued?.value["notes"].elements?.filter { $0["text"].string?.hasPrefix("Waiting for a kept-open session") == true }.count, 1)
        await fleet.stop("s-1"); try await engine.noteExit(sessionID: "s-1", exitCode: 0); try await engine.pump()
        let started = try await BackendTaskFixtureWait.running(second.id, in: store)
        XCTAssertEqual(started.sessionID, "s-2"); XCTAssertEqual(started.value["agoptWaitingForSession"].bool, false)
        try await engine.stop()
    }

    func testAtomicStoreTransferIsUniqueAndRefusesChangedIdentityOrChoices() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-transfer-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory); try await store.start()
        let snapshot = BackendAGOPTTaskPolicy.snapshot(agent: agent, cwd: "/work", settings: settings, profileID: "work-id")
        let prior = try await store.put(row("transfer-old", patch: snapshot.setting("sessionId", .string("live-session"))
            .setting("result", .object([.init("answer", .string("kept result"))])).setting("agoptUsageTotal", .number(50))).value)
        let next = try await store.put(row("transfer-new", patch: snapshot).value)
        let duplicate = try await store.claim(next.id, sessionID: "live-session", liveSessionIDs: ["live-session"])
        XCTAssertFalse(duplicate)
        _ = try await store.update(next.id, patch: .object([.init("agoptAccount", .string("another-account"))]))
        let wrongAccount = try await store.transferSession(from: prior.id, to: next.id, expectedAssignee: next.value["assignee"], liveSessionIDs: ["live-session"])
        XCTAssertFalse(wrongAccount)
        _ = try await store.update(next.id, patch: snapshot.setting("model", .string("changed")))
        let changed = try await store.transferSession(from: prior.id, to: next.id, expectedAssignee: next.value["assignee"], liveSessionIDs: ["live-session"], expectedChoices: next.value)
        XCTAssertFalse(changed)
        _ = try await store.update(next.id, patch: .object([.init("model", .null)]))
        let moved = try await store.transferSession(from: prior.id, to: next.id, expectedAssignee: next.value["assignee"], liveSessionIDs: ["live-session"], expectedChoices: next.value)
        XCTAssertTrue(moved)
        let all = try await store.all(), old = try await store.byID(prior.id), new = try await store.bySession("live-session")
        XCTAssertEqual(all.filter { $0.sessionID == "live-session" }.count, 1); XCTAssertEqual(new?.id, next.id)
        XCTAssertEqual(new?.value["agoptUsageTotal"].number, 50); XCTAssertEqual(old?.value["result"]["answer"].string, "kept result")
    }

    func testSameTaskReplyKeepsSessionUnlessModelChangesThenResumesExactConversation() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-reply-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)))
        let fleet = Fleet(), owner = settings
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { id, _ in try await fleet.send(id) },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let task = try await store.put(row("reply").value); try await engine.accept(task.id)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "reply-one", answer: "First result")
        try await engine.reply(task.id, text: "Please continue with the same task choices.")
        let continuing = try await store.byID(task.id), firstStarts = await fleet.resumes
        XCTAssertEqual(continuing?.sessionID, "s-1"); XCTAssertEqual(firstStarts.count, 1)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "reply-two", answer: "Second result")
        _ = try await store.update(task.id, patch: .object([.init("model", .string("new-task-model"))]))
        try await engine.reply(task.id, text: "Continue using the new selected model.")
        let restarted = try await store.byID(task.id), starts = await fleet.resumes, choices = await fleet.agents, sessions = await fleet.sessions
        XCTAssertEqual(restarted?.sessionID, "s-2"); XCTAssertEqual(starts.count, 2); XCTAssertEqual(starts[1], "thread-1")
        XCTAssertEqual(choices[1]["model"].string, "new-task-model"); XCTAssertEqual(sessions.first?.exitCode, 0)
        try await engine.stop()
    }

    func testReassignmentKeepsEachAgentsOwnUsageAndCumulativeTaskBudget() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-reassignment-budget"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent)
        _ = try await config.saveAgent(agent.setting("id", .string("second")).setting("name", .string("Second agent")))
        let fleet = Fleet()
        var selected = settings; selected.efficiency?.agentTokenBudget = 50
        let owner = selected
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let task = try await store.put(row("reassigned-budget").value); try await engine.accept(task.id)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 50)
        try await engine.reassign(task.id, assignee: BackendTaskLocalService.assignment("second", kind: "agent"))
        try await engine.noteTokenUsage(sessionID: "s-2", totalTokens: 30)
        let current = try await store.byID(task.id), all = try await store.all(includeTrash: true)
        XCTAssertEqual(current?.value["agoptAgentID"].string, "second"); XCTAssertEqual(current?.value["tokenUsage"].number, 80)
        XCTAssertEqual(current?.value["tokenUsageByAgent"]["worker"].number, 50)
        XCTAssertEqual(current?.value["tokenUsageByAgent"]["second"].number, 30)
        XCTAssertEqual(all.reduce(0.0) { $0 + (BackendAGOPTTaskPolicy.usageByAgent($1)["worker"].number ?? 0) }, 50)
        XCTAssertEqual(all.reduce(0.0) { $0 + (BackendAGOPTTaskPolicy.usageByAgent($1)["second"].number ?? 0) }, 30)
        XCTAssertEqual(current?.value["notes"].elements?.filter { $0["text"].string?.hasPrefix("Monthly budget warning: this agent") == true }.count, 1,
            "only the first agent crossed its own warning threshold")
        try await engine.stop()
    }

    /// #344: the monthly budget warning lands on the task whose work crossed it, not on the agent's last task in store order.
    func testMonthlyBudgetWarningLandsOnTheWorkingTask() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-budget-warning-task"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent)
        let fleet = Fleet()
        var selected = settings; selected.efficiency?.agentTokenBudget = 50
        let owner = selected
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let working = try await store.put(row("working").value); try await engine.accept(working.id)
        let restored = try await store.put(row("restored", patch: .object([.init("agoptAgentID", .string("worker")), .init("result", .object([.init("at", .number(1))]))])).value)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 50)
        func warnings(_ id: String) async throws -> Int {
            try await store.byID(id)?.value["notes"].elements?.filter { $0["text"].string?.hasPrefix("Monthly budget warning") == true }.count ?? 0
        }
        let onWorking = try await warnings(working.id), onRestored = try await warnings(restored.id)
        XCTAssertEqual(onWorking, 1); XCTAssertEqual(onRestored, 0)
        try await engine.stop()
    }

    actor DelayedChecks {
        var ordinal = 0, waiters: [Int: CheckedContinuation<(ok: Bool, output: String), Never>] = [:], cancelled: [Int: Bool] = [:]
        let started: @Sendable (Int) -> Void
        init(started: @escaping @Sendable (Int) -> Void) { self.started = started }
        func run() async -> (ok: Bool, output: String) {
            ordinal += 1; let id = ordinal
            let value = await withCheckedContinuation { waiters[id] = $0; started(id) }
            cancelled[id] = Task.isCancelled; return value
        }
        func release(_ id: Int) { waiters.removeValue(forKey: id)?.resume(returning: (true, "delayed stub check")) }
    }
    func testOldDelayedCompletionCannotFinishNewReplyOrEraseItsCheckHandle() async throws {
        let firstStarted = expectation(description: "First delayed verification"), secondStarted = expectation(description: "Replacement verification")
        let checks = DelayedChecks(started: { id in if id == 1 { firstStarted.fulfill() } else if id == 2 { secondStarted.fulfill() } })
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-completion-run-fence"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start()
        _ = try await config.saveAgent(agent.setting("keepAliveUntilClose", .bool(true)).setting("verifyCommand", .string("stub-check")))
        let fleet = Fleet(), owner = settings
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, _, _ in }, check: { _, _ in await checks.run() }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let task = try await store.put(row("fenced-check").value); try await engine.accept(task.id)
        let firstStored = try await store.byID(task.id)
        let first = try XCTUnwrap(firstStored)
        let oldFinish = Task { try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "old-check-turn", answer: "Old result",
            expectedTaskID: first.id, expectedAssignee: first.value["assignee"], expectedRunID: first.value["agoptRunID"].string) }
        await fulfillment(of: [firstStarted], timeout: 3)
        try await engine.reply(task.id, text: "Start the newly requested continuation.")
        let nextStored = try await store.byID(task.id)
        let next = try XCTUnwrap(nextStored)
        let lockState = await BackendAGOPTCoordinator.shared.status(owner: "agopt-fence-observer")
        let revision = UInt64(lockState["revision"].number ?? 0)
        let newFinish = Task { try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "new-check-turn", answer: "New result",
            expectedTaskID: next.id, expectedAssignee: next.value["assignee"], expectedRunID: next.value["agoptRunID"].string) }
        _ = await BackendAGOPTCoordinator.shared.wait(after: revision, seconds: 3)
        let queued = await BackendAGOPTCoordinator.shared.status(owner: "agopt-fence-observer")
        XCTAssertGreaterThanOrEqual(queued["waiting"].number ?? 0, 1, "replacement check is registered before the old defer finishes")
        await checks.release(1)
        do { try await oldFinish.value; XCTFail("old completion must be cancelled") } catch is CancellationError {} catch { throw error }
        await fulfillment(of: [secondStarted], timeout: 3)
        let running = try await store.byID(task.id)
        XCTAssertTrue(running?.value["result"].isNullish == true); XCTAssertEqual(running?.assigneeKind, "agent")
        try await engine.cancel(task.id, reason: "Cancel the current check")
        await checks.release(2)
        do { try await newFinish.value; XCTFail("cancelled new completion must not write a result") } catch is CancellationError {} catch { throw error }
        let current = try await store.byID(task.id), secondCancelled = await checks.cancelled[2]
        XCTAssertEqual(secondCancelled, true, "old check defer must not erase the replacement cancellation handle")
        XCTAssertTrue(current?.value["result"].isNullish == true); XCTAssertEqual(current?.value["stopped"].bool, true)
        try await engine.stop()
    }

    func testRealTaskEngineParksResumesCountsOnlyDeltasAndWarnsOnce() async throws {
        let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-memory"), ownership: .memory)
        let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
        try await store.start(); try await config.start(); try await goals.start(); _ = try await config.saveAgent(agent)
        let fleet = Fleet(), owner = settings
        let access = BackendTaskSessionAccess(readiness: .ready, sessions: { await fleet.sessions },
            start: { await fleet.launch($0, agent: $1, cwd: $2, resume: $4) }, send: { _, _ in },
            stop: { await fleet.stop($0) }, setControl: { _, key, _ in await fleet.control(key) }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
        let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
            workspace: { $0.project }, settings: { _ in owner }, profileID: { _, _ in "work-id" }, problem: { _ in })
        try await engine.start()
        let first = try await store.put(row("first", patch: .object([.init("effort", .string("high")), .init("tokenBudget", .number(50))])).value)
        try await engine.accept(first.id)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 40)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 50)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 45)
        try await engine.noteTokenUsage(sessionID: "s-1", totalTokens: 50)
        try await engine.noteFinishedTurn(sessionID: "s-1", turnID: "turn-one", answer: "Finished")
        let storedFirst = try await store.byID(first.id)
        let saved = try XCTUnwrap(storedFirst)
        XCTAssertNil(saved.sessionID); XCTAssertEqual(saved.value["conversationId"].string, "thread-1")
        XCTAssertEqual(saved.value["tokenUsage"].number, 50)
        XCTAssertEqual(saved.value["notes"].elements?.filter { $0["text"].string?.hasPrefix("Token budget warning:") == true }.count, 1)
        let second = try await store.put(row("second").value); try await engine.accept(second.id)
        let resumes = await fleet.resumes, choices = await fleet.agents, controls = await fleet.controls
        XCTAssertEqual(resumes.count, 2); XCTAssertEqual(resumes[1], "thread-1")
        XCTAssertEqual(choices[0]["effort"].string, "high"); XCTAssertTrue(controls.isEmpty, "settings must be selected before the brief")
        try await engine.noteTokenUsage(sessionID: "s-2", totalTokens: 70)
        let storedSecond = try await store.byID(second.id)
        let next = try XCTUnwrap(storedSecond); XCTAssertEqual(next.value["tokenUsage"].number, 20)
        try await engine.stop()
    }
}
