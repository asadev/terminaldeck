import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGSHookQueueTests: XCTestCase {
    func testBurstQueuesBeyondFourAndRunsEveryHook() async throws {
        let started = expectation(description: "Four hooks are running"); started.expectedFulfillmentCount = 4
        let gate = HookQueueGate(started: started)
        let runner = BackendAGSHookRunner(execute: { _, _ in await gate.run() })
        let hook = AGSAppHook(event: "session.started", command: "true", enabled: true)
        let jobs = (0..<8).map { index in Task { await runner.deliver(.init(id: "burst-\(index)", event: "session.started"), hooks: [hook]) } }
        await fulfillment(of: [started], timeout: 5)
        await gate.open()
        for job in jobs { let rows = await job.value; XCTAssertEqual(rows.count, 1); XCTAssertTrue(rows.first?.ok == true) }
        let counts = await gate.counts()
        XCTAssertEqual(counts.total, 8); XCTAssertEqual(counts.maximum, 4)
        await runner.stop()
    }

    func testStopCancelsWaitingAndRunningHooks() async throws {
        let started = expectation(description: "Four hooks are running"); started.expectedFulfillmentCount = 4
        let gate = HookQueueGate(started: started)
        let runner = BackendAGSHookRunner(execute: { _, _ in await gate.run() })
        let hook = AGSAppHook(event: "session.started", command: "true", enabled: true)
        let jobs = (0..<8).map { _ in Task { await runner.test(hook) } }
        await fulfillment(of: [started], timeout: 5)
        await runner.stop(); await gate.open()
        for job in jobs { let result = await job.value; XCTAssertFalse(result.ok); XCTAssertEqual(result.message, "Hook cancelled.") }
        let counts = await gate.counts(); XCTAssertEqual(counts.total, 4)
    }

    func testCancelledWaiterDoesNotRunAndNextHookCanUseItsSlot() async throws {
        let started = expectation(description: "Four hooks are running"); started.expectedFulfillmentCount = 4
        let gate = HookQueueGate(started: started)
        let runner = BackendAGSHookRunner(execute: { _, _ in await gate.run() })
        let hook = AGSAppHook(event: "session.started", command: "true", enabled: true)
        let jobs = (0..<4).map { _ in Task { await runner.test(hook) } }
        await fulfillment(of: [started], timeout: 5)
        let cancelled = Task { await runner.test(hook) }
        cancelled.cancel()
        let result = await cancelled.value; XCTAssertFalse(result.ok); XCTAssertEqual(result.message, "Hook cancelled.")
        let next = Task { await runner.test(hook) }
        await gate.open()
        for job in jobs { let result = await job.value; XCTAssertTrue(result.ok) }
        let final = await next.value; XCTAssertTrue(final.ok)
        let counts = await gate.counts(); XCTAssertEqual(counts.total, 5); XCTAssertLessThanOrEqual(counts.maximum, 4)
        await runner.stop()
    }
}

private actor HookQueueGate {
    private let started: XCTestExpectation
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false, active = 0, maximum = 0, total = 0
    init(started: XCTestExpectation) { self.started = started }
    func run() async {
        active += 1; total += 1; maximum = max(maximum, active)
        if total <= 4 { started.fulfill() }
        if !opened { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
    }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func counts() -> (total: Int, maximum: Int) { (total, maximum) }
}
