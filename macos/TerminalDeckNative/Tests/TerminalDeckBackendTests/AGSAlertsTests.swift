import Foundation
import XCTest
@testable import TerminalDeckBackend

private final class AGSAlertTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 1_000_000
    private struct Job { let due: Double; let run: @Sendable () async -> Void }
    private var jobs: [UUID: Job] = [:]
    private var history: [UUID: Job] = [:]
    var scheduler: BackendAGSAlertScheduler {
        BackendAGSAlertScheduler(now: { self.lock.withLock { self.time } }, schedule: { delay, work in
            let id = UUID()
            self.lock.withLock {
                let job = Job(due: self.time + delay, run: work)
                self.jobs[id] = job; self.history[id] = job
            }
            return BackendAGSAlertDeadline { self.lock.withLock { self.jobs[id] = nil } }
        })
    }
    var count: Int { lock.withLock { jobs.count } }
    var scheduled: [UUID] { lock.withLock { Array(history.keys) } }
    func advance(_ by: Double) async {
        let ready = lock.withLock { () -> [Job] in
            time += by
            let due = jobs.filter { $0.value.due <= time }
            for key in due.keys { jobs[key] = nil }
            return due.values.sorted { $0.due < $1.due }
        }
        for job in ready { await job.run() }
    }
    func fireEvenIfCanceled(_ id: UUID) async { if let job = lock.withLock({ history[id] }) { await job.run() } }
}

private actor AGSAlertFacts {
    var baseline: [BackendAGSAlertSession]
    var statuses: [String: BackendSessionStatus]
    var enabled: Bool
    var failRead = false
    init(baseline: [BackendAGSAlertSession], enabled: Bool) {
        self.baseline = baseline; self.enabled = enabled
        statuses = Dictionary(uniqueKeysWithValues: baseline.compactMap { row in row.status.map { (row.id, $0) } })
    }
    func snapshot() -> [BackendAGSAlertSession] { baseline }
    func status(_ id: String) -> BackendSessionStatus? { statuses[id] }
    func set(_ id: String, _ status: BackendSessionStatus?) { statuses[id] = status }
    func setEnabled(_ value: Bool) { enabled = value }
    func fail() { failRead = true }
    func hooks() throws -> Bool { if failRead { throw NSError(domain: "private-read-failed", code: 1) }; return enabled }
}

private actor AGSAlertOutput {
    var events: [BackendAGSAcceptedAlert] = []
    func append(_ event: BackendAGSAcceptedAlert) { events.append(event) }
}

private actor AGSAlertReadGate {
    private var begun = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<BackendSessionStatus?, Never>?
    func read() async -> BackendSessionStatus? {
        begun = true
        for waiter in waiters { waiter.resume() }; waiters = []
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitForRead() async { if !begun { await withCheckedContinuation { waiters.append($0) } } }
    func finish(_ value: BackendSessionStatus?) { continuation?.resume(returning: value); continuation = nil }
}

private actor AGSAlertBaselineGate {
    private var begun = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<[BackendAGSAlertSession], Never>?
    func read() async -> [BackendAGSAlertSession] {
        begun = true
        for waiter in waiters { waiter.resume() }; waiters = []
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitForRead() async { if !begun { await withCheckedContinuation { waiters.append($0) } } }
    func finish(_ value: [BackendAGSAlertSession]) { continuation?.resume(returning: value); continuation = nil }
}

final class AGSAlertsTests: XCTestCase, @unchecked Sendable {
    private func fixture(baseline: [BackendAGSAlertSession] = [], enabled: Bool = true) async throws
        -> (BackendAGSAlerts, AGSAlertTestClock, AGSAlertFacts, AGSAlertOutput) {
        let clock = AGSAlertTestClock(), facts = AGSAlertFacts(baseline: baseline, enabled: enabled), output = AGSAlertOutput()
        let source = BackendAGSAlerts(snapshot: { await facts.snapshot() }, currentStatus: { await facts.status($0) },
            hooksEnabled: { try await facts.hooks() }, accepted: { await output.append($0) }, scheduler: clock.scheduler)
        try await source.start()
        return (source, clock, facts, output)
    }
    private func input(_ source: BackendAGSAlerts, _ facts: AGSAlertFacts, id: String = "session-one") async {
        await facts.set(id, .input)
        await source.receive(.status(sessionID: id, status: .input, source: "hook"))
    }

    func testAcceptedInputRaisesOnceAfterExistingTenMinuteCriterion() async throws {
        let (source, clock, facts, output) = try await fixture()
        await input(source, facts)
        XCTAssertEqual(clock.count, 1)
        await clock.advance(599_999)
        let early = await output.events; XCTAssertTrue(early.isEmpty)
        await clock.advance(1)
        let events = await output.events; XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.alertID, "session-blocked:session-one")
        XCTAssertEqual(events.first?.sessionID, "session-one")
        XCTAssertEqual(events.first?.acceptedAt, 1_600_000)
        XCTAssertTrue(events.first?.id.hasPrefix("session-blocked:session-one:") == true)
        XCTAssertEqual(clock.count, 0)
        await clock.advance(10_000_000)
        let repeated = await output.events; XCTAssertEqual(repeated.count, 1)
        await source.stop()
    }

    func testUnknownBaselineCannotCreateAnAlertWithoutAcceptedStatus() async throws {
        let (source, clock, facts, output) = try await fixture(baseline: [.init(id: "session-one", status: nil)])
        await facts.set("session-one", .input) // A current lookup alone is not an accepted transition.
        XCTAssertEqual(clock.count, 0)
        await clock.advance(900_000)
        let none = await output.events; XCTAssertTrue(none.isEmpty)
        await input(source, facts)
        await clock.advance(600_000)
        let accepted = await output.events; XCTAssertEqual(accepted.count, 1)
        await source.stop()
    }

    func testKnownInputBaselineIsUnderAgedRatherThanPublishedImmediately() async throws {
        let (source, clock, _, output) = try await fixture(baseline: [.init(id: "session-one", status: .input)])
        let initial = await output.events; XCTAssertTrue(initial.isEmpty)
        XCTAssertEqual(clock.count, 1)
        await clock.advance(599_999)
        let early = await output.events; XCTAssertTrue(early.isEmpty)
        await clock.advance(1)
        let accepted = await output.events; XCTAssertEqual(accepted.count, 1)
        await source.stop()
    }

    func testRawPTYStatusDataAndDuplicateReceiptsDoNotRestartOrRaise() async throws {
        let (source, clock, facts, output) = try await fixture()
        await source.receive(.process(.status(id: "session-one", status: .input)))
        await source.receive(.process(.data(id: "session-one", text: "alerts:project session-blocked")))
        XCTAssertEqual(clock.count, 0)
        await input(source, facts)
        await clock.advance(300_000)
        await input(source, facts)
        XCTAssertEqual(clock.count, 1)
        await clock.advance(300_000)
        let first = await output.events; XCTAssertEqual(first.count, 1)
        await input(source, facts)
        XCTAssertEqual(clock.count, 0)
        let unchanged = await output.events; XCTAssertEqual(unchanged.map(\.id), first.map(\.id))
        await source.stop()
    }

    func testLeavingInputCancelsTimerAndLateCanceledCallbackCannotPublish() async throws {
        let (source, clock, facts, output) = try await fixture()
        await input(source, facts)
        let token = try XCTUnwrap(clock.scheduled.first)
        await clock.advance(599_999)
        await facts.set("session-one", .working)
        await source.receive(.status(sessionID: "session-one", status: .working, source: "input"))
        XCTAssertEqual(clock.count, 0)
        await clock.advance(1)
        await clock.fireEvenIfCanceled(token)
        let events = await output.events; XCTAssertTrue(events.isEmpty)
        await source.stop()
    }

    func testExitRemovalAndCurrentUnknownPreventPublication() async throws {
        for mode in 0..<3 {
            let (source, clock, facts, output) = try await fixture()
            await input(source, facts)
            let token = try XCTUnwrap(clock.scheduled.first)
            if mode == 0 { await source.receive(.process(.exit(id: "session-one", exitCode: 0))) }
            if mode == 1 { await source.receive(.process(.removed(id: "session-one", reason: .stopped))) }
            await facts.set("session-one", nil)
            await clock.advance(600_000)
            await clock.fireEvenIfCanceled(token)
            let events = await output.events, state = await source.state()
            XCTAssertTrue(events.isEmpty); XCTAssertEqual(state.sessions, 0); XCTAssertEqual(state.deadlines, 0)
            await source.stop()
        }
    }

    func testOffHooksUseNoDeadlinesAndDoNotReplayOldThresholdOnEnable() async throws {
        let (source, clock, facts, output) = try await fixture(enabled: false)
        await input(source, facts)
        XCTAssertEqual(clock.count, 0)
        await clock.advance(900_000)
        await facts.setEnabled(true); try await source.refreshHooks()
        XCTAssertEqual(clock.count, 0)
        let old = await output.events; XCTAssertTrue(old.isEmpty)
        await facts.set("session-one", .working)
        await source.receive(.status(sessionID: "session-one", status: .working, source: "input"))
        await input(source, facts)
        await clock.advance(600_000)
        let next = await output.events; XCTAssertEqual(next.count, 1)
        await source.stop()
    }

    func testDisableReenableRetainsEpisodeButInvalidatesOldDeadlineToken() async throws {
        let (source, clock, facts, output) = try await fixture()
        await input(source, facts)
        let old = try XCTUnwrap(clock.scheduled.first)
        await clock.advance(300_000)
        await facts.setEnabled(false); try await source.refreshHooks(); XCTAssertEqual(clock.count, 0)
        await facts.setEnabled(true); try await source.refreshHooks(); XCTAssertEqual(clock.count, 1)
        await clock.fireEvenIfCanceled(old)
        XCTAssertEqual(clock.count, 1)
        await clock.advance(300_000)
        let events = await output.events; XCTAssertEqual(events.count, 1)
        await facts.setEnabled(false); try await source.refreshHooks()
        await facts.setEnabled(true); try await source.refreshHooks()
        XCTAssertEqual(clock.count, 0)
        await source.stop()
    }

    func testNewInputEpisodeGetsANewStableAcceptedIdentity() async throws {
        let (source, clock, facts, output) = try await fixture()
        await input(source, facts); await clock.advance(600_000)
        await facts.set("session-one", .completed)
        await source.receive(.status(sessionID: "session-one", status: .completed, source: "hook"))
        await input(source, facts); await clock.advance(600_000)
        let events = await output.events
        XCTAssertEqual(events.count, 2); XCTAssertNotEqual(events[0].id, events[1].id)
        XCTAssertEqual(events[0].alertID, events[1].alertID)
        await source.stop()
    }

    func testDisableDuringCurrentStatusRecheckPreventsCommandEvent() async throws {
        let clock = AGSAlertTestClock(), gate = AGSAlertReadGate(), output = AGSAlertOutput()
        let facts = AGSAlertFacts(baseline: [], enabled: true)
        let source = BackendAGSAlerts(snapshot: { [] }, currentStatus: { _ in await gate.read() },
            hooksEnabled: { try await facts.hooks() }, accepted: { await output.append($0) }, scheduler: clock.scheduler)
        try await source.start(); await input(source, facts)
        let firing = Task { await clock.advance(600_000) }
        await gate.waitForRead()
        await facts.setEnabled(false); try await source.refreshHooks()
        await gate.finish(.input); await firing.value
        let events = await output.events; XCTAssertTrue(events.isEmpty)
        await source.stop()
    }

    func testSettingsReadFailureCancelsDeadlinesAndFailsClosed() async throws {
        let (source, clock, facts, output) = try await fixture()
        await input(source, facts)
        let token = try XCTUnwrap(clock.scheduled.first)
        await facts.fail()
        do { try await source.refreshHooks(); XCTFail("settings read failure was swallowed") } catch {}
        XCTAssertEqual(clock.count, 0)
        await clock.advance(600_000); await clock.fireEvenIfCanceled(token)
        let state = await source.state(), events = await output.events
        XCTAssertFalse(state.enabled); XCTAssertTrue(events.isEmpty)
        await source.stop()
    }

    func testStartupRemovalCannotBeResurrectedBySlowBaseline() async throws {
        let clock = AGSAlertTestClock(), gate = AGSAlertBaselineGate(), output = AGSAlertOutput()
        let source = BackendAGSAlerts(snapshot: { await gate.read() }, currentStatus: { _ in .input },
            hooksEnabled: { true }, accepted: { await output.append($0) }, scheduler: clock.scheduler)
        let starting = Task { try await source.start() }
        await gate.waitForRead()
        await source.receive(.process(.removed(id: "session-one", reason: .stopped)))
        await gate.finish([.init(id: "session-one", status: .input)])
        try await starting.value
        let state = await source.state(); XCTAssertEqual(state.sessions, 0); XCTAssertEqual(clock.count, 0)
        await source.stop()
    }

    func testAcceptedWorkingReceiptWinsOverStaleInputBaseline() async throws {
        let clock = AGSAlertTestClock(), gate = AGSAlertBaselineGate(), output = AGSAlertOutput()
        let source = BackendAGSAlerts(snapshot: { await gate.read() }, currentStatus: { _ in .working },
            hooksEnabled: { true }, accepted: { await output.append($0) }, scheduler: clock.scheduler)
        let starting = Task { try await source.start() }
        await gate.waitForRead()
        await source.receive(.status(sessionID: "session-one", status: .working, source: "input"))
        await gate.finish([.init(id: "session-one", status: .input)])
        try await starting.value
        let state = await source.state(); XCTAssertEqual(state.sessions, 1); XCTAssertEqual(clock.count, 0)
        await clock.advance(600_000)
        let events = await output.events; XCTAssertTrue(events.isEmpty)
        await source.stop()
    }

    func testSavedChangeRelayStartsAndCancelsOnlyEnabledHookDeadlines() async throws {
        let (source, clock, facts, output) = try await fixture(enabled: false)
        let relay = BackendAGSAlertSettingsChanges()
        await relay.bind(source)
        await input(source, facts)
        XCTAssertEqual(clock.count, 0)
        await facts.setEnabled(true); try await relay.saved()
        XCTAssertEqual(clock.count, 1)
        await facts.setEnabled(false); try await relay.saved()
        XCTAssertEqual(clock.count, 0)
        await relay.bind(nil)
        await facts.setEnabled(true); try await relay.saved()
        XCTAssertEqual(clock.count, 0)
        await clock.advance(600_000)
        let events = await output.events; XCTAssertTrue(events.isEmpty)
        await source.stop()
    }

    func testSessionTimerCapacityIsBoundedAndStopCancelsEverything() async throws {
        let (source, clock, _, output) = try await fixture()
        for index in 0..<(BackendAGSAlerts.maximumSessions + 20) {
            await source.receive(.status(sessionID: "session-\(index)", status: .input, source: "screen"))
        }
        let state = await source.state()
        XCTAssertEqual(state.sessions, BackendAGSAlerts.maximumSessions)
        XCTAssertEqual(state.deadlines, BackendAGSAlerts.maximumSessions)
        XCTAssertEqual(clock.count, BackendAGSAlerts.maximumSessions)
        await source.stop(); XCTAssertEqual(clock.count, 0)
        await clock.advance(600_000)
        await source.receive(.status(sessionID: "after-stop", status: .input, source: "hook"))
        let final = await source.state(), events = await output.events
        XCTAssertEqual(final.sessions, 0); XCTAssertFalse(final.enabled); XCTAssertTrue(events.isEmpty)
    }
}
