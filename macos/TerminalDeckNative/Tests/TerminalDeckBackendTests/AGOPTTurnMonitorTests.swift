import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTTurnMonitorTests: XCTestCase, @unchecked Sendable {
    final class Clock: BackendDeckCoreEventsClock, @unchecked Sendable {
        private let lock = NSLock()
        private var timers: [UUID: (Double, @Sendable () -> Void)] = [:]
        var fallbackScheduled: (@Sendable () -> Void)?
        func now() -> Double { 1_800_000_000_000 }
        func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
            let id = UUID(); lock.withLock { timers[id] = (milliseconds, run) }
            if milliseconds == 3_000 { fallbackScheduled?() }; return id
        }
        func cancel(_ id: UUID) { _ = lock.withLock { timers.removeValue(forKey: id) } }
        func fireFallback() {
            let events = lock.withLock { () -> [@Sendable () -> Void] in
                let ids = timers.filter { $0.value.0 == 3_000 }.map(\.key)
                return ids.compactMap { timers.removeValue(forKey: $0)?.1 }
            }
            events.forEach { $0() }
        }
        var fallbackCount: Int { lock.withLock { timers.values.filter { $0.0 == 3_000 }.count } }
    }
    actor Answers {
        var value: BackendTaskAnswer?, reads = 0
        var observer: (@Sendable () -> Void)?
        let onFirstRead: @Sendable () -> Void
        init(onFirstRead: @escaping @Sendable () -> Void) { self.onFirstRead = onFirstRead }
        func read() -> BackendTaskAnswer? { reads += 1; if reads == 1 { onFirstRead() }; return value }
        func observe(_ callback: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            observer = callback
            return { [weak self] in Task { await self?.clearObserver() } }
        }
        func clearObserver() { observer = nil }
        func arrive() { value = .init(text: "REAL_LATE_ANSWER", at: 1_800_000_000_000); observer?() }
        func seedPrior() { value = .init(text: "PRIOR_TASK_ANSWER", at: 1_800_000_000_000) }
        func fire() { observer?() }
    }
    struct Fixture: Sendable {
        let store: BackendTaskStore, engine: BackendTaskEngine, monitor: BackendTaskTurnMonitor, manager: BackendPTYManager
        let answers: Answers, taskID: String
        static func make(answers: Answers, watch: Bool, retained: Bool = false,
                         tokenUsage: (@Sendable (BackendSessionMeta) async throws -> Double?)? = nil,
                         completed: @escaping @Sendable () -> Void) async throws -> Fixture {
            let memory = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/agopt-late-record-memory"), ownership: .memory)
            let store = BackendTaskStore(persistence: memory), config = try BackendTaskConfiguration(persistence: memory), goals = BackendGoalStore(persistence: memory)
            try await store.start(); try await config.start(); try await goals.start()
            _ = try await config.saveAgent(.object([.init("id", .string("worker")), .init("name", .string("Worker")),
                .init("provider", .string("codex")), .init("keepAliveMinutes", .number(0)), .init("keepAliveUntilClose", .bool(retained))]))
            let manager = BackendPTYManager(inheritedEnvironment: ["HOME": "/tmp", "PATH": "/usr/bin:/bin"], onEvent: { _ in })
            let access = BackendTaskSessionAccess(readiness: .ready, sessions: { manager.list() }, start: { _, _, cwd, _, _ in
                let session = try manager.create(.init(cwd: cwd, provider: "codex"), spawn: .init(provider: "codex", command: "/bin/cat", args: [], path: "/usr/bin:/bin", profile: .init(id: "work-id", name: "Work"), agentSessionId: "stub-thread"))
                try manager.write(session.id, data: "WRONG_SCREEN\r"); return session
            }, send: { _, _ in }, stop: { manager.kill($0) }, setControl: { _, _, _ in }, check: { _, _ in (true, "stub") }, tellHoot: { _ in })
            let engine = try BackendTaskEngine(store: store, configuration: config, goals: goals, access: access,
                workspace: { $0.project }, notifications: { _, event in if event["type"].string == "task.finished" { completed() } },
                settings: { _ in .init(provider: "codex", keepOpen: retained, efficiency: .init(completion: "park")) }, profileID: { _, _ in "work-id" }, problem: { _ in })
            let events: (@Sendable (BackendSessionMeta, @escaping @Sendable () -> Void) async throws -> (@Sendable () -> Void)?)?
            if watch { events = { _, callback in await answers.observe(callback) } } else { events = nil }
            let monitor = BackendTaskTurnMonitor(store: store, engine: engine, manager: manager, answer: { _ in await answers.read() }, tokenUsage: tokenUsage, usageEvents: events, problem: { _ in })
            _ = try await store.put(.object([.init("id", .string("local:late")), .init("keyId", .string("local")), .init("externalTaskId", .string("late")),
                .init("local", .bool(true)), .init("project", .string("/tmp")), .init("title", .string("Late answer")),
                .init("instructions", .string("Read the stub answer and finish this focused test task.")), .init("notificationKeyId", .string("agopt-stub-key")),
                .init("assignee", BackendTaskLocalService.assignment("worker", kind: "agent"))]))
            return .init(store: store, engine: engine, monitor: monitor, manager: manager, answers: answers, taskID: "local:late")
        }
        func begin() async throws -> String {
            try await engine.start(); await monitor.start(); try await engine.accept(taskID)
            let row = try await store.byID(taskID), session = row?.sessionID
            guard let session else { throw NativeRPCError(code: "stub-missing", message: "The stub task did not start.") }
            await monitor.noteSend(sessionID: session)
            try await monitor.noteStatus(sessionID: session, status: .working)
            try await monitor.noteStatus(sessionID: session, status: .completed)
            return session
        }
        func stop() async { await monitor.stop(); try? await engine.stop(); manager.beginShutdown(); _ = await manager.drain() }
    }
    actor DelayedUsage {
        var armed = false, continuation: CheckedContinuation<Double?, Never>?
        let started: @Sendable () -> Void
        init(started: @escaping @Sendable () -> Void) { self.started = started }
        func arm() { armed = true }
        func read() async -> Double? {
            guard armed else { return nil }; armed = false
            return await withCheckedContinuation { continuation = $0; started() }
        }
        func resolve() { continuation?.resume(returning: 100); continuation = nil }
    }
    func testDelayedUsageReadCannotChargeNewOwnerOfActualRetainedSession() async throws {
        let readStarted = expectation(description: "Usage read captured old run")
        let usage = DelayedUsage(started: { readStarted.fulfill() }), answers = Answers(onFirstRead: {})
        let fixture = try await Fixture.make(answers: answers, watch: false, retained: true,
            tokenUsage: { _ in await usage.read() }, completed: {})
        try await fixture.engine.start(); await fixture.monitor.start(); try await fixture.engine.accept(fixture.taskID)
        let initial = try await fixture.store.byID(fixture.taskID), session = try XCTUnwrap(initial?.sessionID)
        await usage.arm()
        let reading = Task { try await fixture.monitor.noteStatus(sessionID: session, status: .working) }
        await fulfillment(of: [readStarted], timeout: 3)
        try await fixture.engine.noteFinishedTurn(sessionID: session, turnID: "old-finished", answer: "Old job done")
        _ = try await fixture.store.put(.object([.init("id", .string("local:handover")), .init("keyId", .string("local")),
            .init("externalTaskId", .string("handover")), .init("local", .bool(true)), .init("project", .string("/tmp")),
            .init("title", .string("Next exact task")), .init("instructions", .string("Continue only this next task using the existing context.")),
            .init("notificationKeyId", .string("agopt-stub-key")), .init("assignee", BackendTaskLocalService.assignment("worker", kind: "agent"))]))
        try await fixture.engine.accept("local:handover")
        await usage.resolve(); try await reading.value
        let after = try await fixture.store.byID("local:handover")
        XCTAssertEqual(after?.sessionID, session); XCTAssertNil(after?.value["tokenUsage"].number)
        try await fixture.store.seedRunUsageBaseline(taskID: "local:handover", sessionID: session, totalTokens: 100)
        try await fixture.engine.noteTokenUsage(sessionID: session, totalTokens: 110)
        let measured = try await fixture.store.byID("local:handover"); XCTAssertEqual(measured?.value["tokenUsage"].number, 10)
        await fixture.stop()
    }

    func testAcceptedCompletionWaitsForSingleLateRecordEventAndUsesActualAnswer() async throws {
        let first = expectation(description: "Initial accepted read"), deadline = expectation(description: "One fallback deadline"), done = expectation(description: "Real answer completed")
        let clock = Clock(); clock.fallbackScheduled = { deadline.fulfill() }
        let answers = Answers(onFirstRead: { first.fulfill() })
        let fixture = try await Fixture.make(answers: answers, watch: true, completed: { done.fulfill() })
        try await BackendTaskClockContext.withClock(clock) {
            _ = try await fixture.begin()
            await self.fulfillment(of: [first, deadline], timeout: 3)
            let waiting = try await fixture.store.byID(fixture.taskID)
            XCTAssertTrue(waiting?.value["result"].isNullish == true, "wrong screen must not become a premature result")
            await answers.arrive()
            await self.fulfillment(of: [done], timeout: 3)
            let row = try await fixture.store.byID(fixture.taskID), readCount = await answers.reads
            XCTAssertEqual(row?.value["result"]["answer"].string, "REAL_LATE_ANSWER"); XCTAssertEqual(readCount, 2)
            XCTAssertEqual(clock.fallbackCount, 0)
            clock.fireFallback(); await answers.fire()
            await fixture.stop()
            let finalReads = await answers.reads; XCTAssertEqual(finalReads, 2, "no timer or idle event rereads after completion")
        }
    }
    func testMissingRecordUsesOneDeadlineWithoutRepeatedTranscriptReads() async throws {
        let first = expectation(description: "One accepted read"), deadline = expectation(description: "Bounded fallback installed"), done = expectation(description: "Fallback completed")
        let clock = Clock(); clock.fallbackScheduled = { deadline.fulfill() }
        let answers = Answers(onFirstRead: { first.fulfill() })
        let fixture = try await Fixture.make(answers: answers, watch: false, completed: { done.fulfill() })
        try await BackendTaskClockContext.withClock(clock) {
            _ = try await fixture.begin()
            await self.fulfillment(of: [first, deadline], timeout: 3)
            clock.fireFallback(); await self.fulfillment(of: [done], timeout: 3)
            let row = try await fixture.store.byID(fixture.taskID), readCount = await answers.reads
            XCTAssertFalse(row?.value["result"].isNullish ?? true); XCTAssertEqual(readCount, 1)
            clock.fireFallback(); await fixture.stop()
            let finalReads = await answers.reads; XCTAssertEqual(finalReads, 1)
        }
    }

    final class Completions: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var count = 0
        let first: XCTestExpectation, second: XCTestExpectation
        init(first: XCTestExpectation, second: XCTestExpectation) { self.first = first; self.second = second }
        func fire() { let value = lock.withLock { count += 1; return count }; if value == 1 { first.fulfill() } else if value == 2 { second.fulfill() } }
        var total: Int { lock.withLock { count } }
    }
    func testRetainedReplyRejectsPriorAnswerInsideSlackAndFinishesNewRecordOnce() async throws {
        let firstRead = expectation(description: "Prior accepted answer read"), firstDone = expectation(description: "Prior task complete")
        let pending = expectation(description: "Stale answer waits"), nextDone = expectation(description: "New answer complete")
        let clock = Clock(); clock.fallbackScheduled = { pending.fulfill() }
        let completed = Completions(first: firstDone, second: nextDone)
        let answers = Answers(onFirstRead: { firstRead.fulfill() }); await answers.seedPrior()
        let fixture = try await Fixture.make(answers: answers, watch: true, retained: true, completed: { completed.fire() })
        try await BackendTaskClockContext.withClock(clock) {
            let session = try await fixture.begin()
            await self.fulfillment(of: [firstRead, firstDone], timeout: 3)
            let pid = fixture.manager.pidOf(session); XCTAssertNotNil(pid)
            try await fixture.engine.reply(fixture.taskID, text: "Continue the next scoped part of this task.")
            XCTAssertEqual(fixture.manager.pidOf(session), pid, "unchanged reply keeps the actual stub process")
            await fixture.monitor.noteSend(sessionID: session)
            try await fixture.monitor.noteStatus(sessionID: session, status: .working)
            try await fixture.monitor.noteStatus(sessionID: session, status: .completed)
            await self.fulfillment(of: [pending], timeout: 3)
            let waiting = try await fixture.store.byID(fixture.taskID)
            XCTAssertTrue(waiting?.value["result"].isNullish == true); XCTAssertEqual(completed.total, 1)
            await answers.arrive(); await self.fulfillment(of: [nextDone], timeout: 3)
            let row = try await fixture.store.byID(fixture.taskID), reads = await answers.reads
            XCTAssertEqual(row?.value["result"]["answer"].string, "REAL_LATE_ANSWER"); XCTAssertEqual(completed.total, 2)
            XCTAssertEqual(reads, 3, "prior answer, rejected duplicate and one changed record")
            XCTAssertEqual(clock.fallbackCount, 0)
            clock.fireFallback(); await answers.fire(); await fixture.stop()
            XCTAssertEqual(completed.total, 2)
        }
    }
}
