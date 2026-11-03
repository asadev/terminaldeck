import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendATWORKMonitorTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_ATWORK_FOCUSED"] == "1" else { throw XCTSkip("WIP ATWORK") }
    }
    private func monitor(_ stub: ATWORKMonitorStub) -> BackendATWORKMonitor {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return BackendATWORKMonitor(readTargets: { stub.readTargets() }, readProcesses: { stub.readProcesses($0) },
            readSystem: { stub.readSystem() }, now: { stub.now() }, uptime: { stub.uptime() }, calendar: calendar,
            watchProcessEvents: false, publish: { stub.publish($0) })
    }

    func testWallClockJumpDoesNotChangeCpuDeltaClock() async throws {
        let stub = ATWORKMonitorStub(), monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        stub.wallJump(to: 50, uptime: 102, cpu: 1_000_000_000)
        await monitor.sampleNow()
        let snapshot = await monitor.snapshot()
        XCTAssertEqual(snapshot["metrics"].elements?.first?["cpuPercent"].number, 50)
        XCTAssertEqual(snapshot["load"]["at"].number, 50000)
        await monitor.stop()
    }

    func testMidnightRefreshesTokenInventoryOnceAndResetsRateBaseline() async throws {
        let stub = ATWORKMonitorStub()
        stub.wallJump(to: 86399, uptime: 100, cpu: 0)
        let monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        XCTAssertEqual(stub.counts()[0], 1)
        stub.wallJump(to: 86401, uptime: 102, cpu: 1_000_000_000)
        await monitor.sampleNow()
        XCTAssertEqual(stub.counts()[0], 2)
        let snapshot = await monitor.snapshot()
        XCTAssertNil(snapshot["load"]["tokensPerMinute"].number)
        await monitor.sampleNow()
        XCTAssertEqual(stub.counts()[0], 2, "Same-day ticks must not reread token inventory")
        await monitor.stop()
    }

    func testHiddenMonitorDoesNoInventoryProcessSystemReadsOrEvents() async {
        let stub = ATWORKMonitorStub(), monitor = monitor(stub)
        await monitor.invalidate()
        await monitor.sampleNow()
        await monitor.setVisible("unknown", visible: false)
        XCTAssertEqual(stub.counts(), [0, 0, 0, 0])
        let count = await monitor.watcherCount()
        XCTAssertEqual(count, 0)
    }

    func testUnmeasuredActiveAgentAndIdleHootKeepAggregateUsageUnknown() async throws {
        let stub = ATWORKMonitorStub()
        stub.setTargets([.init(id: "working", pid: nil, agent: .object([.init("state", .string("working"))])),
                         .init(id: "hoot", pid: nil, agent: .object([.init("state", .string("idle"))]))])
        let monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        let snapshot = await monitor.snapshot()
        for key in ["agentCPU", "agentMemoryBytes", "processes"] {
            XCTAssertNil(snapshot["load"][key].number, "Unknown liveness cannot claim zero \(key)")
        }
        for row in snapshot["metrics"].elements ?? [] {
            XCTAssertNil(row["cpuPercent"].number)
            XCTAssertNil(row["memoryBytes"].number)
            XCTAssertNil(row["isRunning"].bool)
        }
        await monitor.stop()
    }

    func testProvedDormantHootDoesNotHideAnotherAgentsMeasuredUsage() async throws {
        let stub = ATWORKMonitorStub()
        stub.setTargets([.init(id: "fixture", pid: 10), .init(id: "hoot", pid: nil,
            agent: .object([.init("state", .string("idle"))]), running: false)])
        let monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        stub.advance(to: 102, cpu: 1_000_000_000, tokens: 0)
        await monitor.sampleNow()
        let snapshot = await monitor.snapshot()
        XCTAssertEqual(snapshot["load"]["agentCPU"].number, 25)
        XCTAssertEqual(snapshot["load"]["agentMemoryBytes"].number, 1024)
        XCTAssertEqual(snapshot["load"]["processes"].number, 1)
        let hoot = try XCTUnwrap(snapshot["metrics"].elements?.first { $0["id"].string == "hoot" })
        XCTAssertEqual(hoot["cpuPercent"].number, 0)
        XCTAssertEqual(hoot["memoryBytes"].number, 0)
        XCTAssertEqual(hoot["isRunning"].bool, false)
        let inactive = await monitor.inactiveIDs()
        XCTAssertEqual(inactive, ["hoot"])
        await monitor.stop()
    }

    func testRetainedFinishedAndOfflineRowsAreProvedInactiveAndConsumeZero() async {
        let stub = ATWORKMonitorStub()
        stub.setTargets([.init(id: "ended", pid: nil, agent: .object([.init("state", .string("finished"))])),
                         .init(id: "offline", pid: nil, agent: .object([.init("state", .string("offline"))]))])
        let monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        let snapshot = await monitor.snapshot()
        for key in ["agentCPU", "agentMemoryBytes", "processes"] { XCTAssertEqual(snapshot["load"][key].number, 0) }
        let inactive = await monitor.inactiveIDs()
        XCTAssertEqual(inactive, ["ended", "offline"])
        await monitor.stop()
    }

    func testEmptyInventoryIsMeasuredZeroRatherThanUnknown() async {
        let stub = ATWORKMonitorStub(); stub.setTargets([])
        let monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        let snapshot = await monitor.snapshot()
        XCTAssertTrue(snapshot["metrics"].elements?.isEmpty == true)
        for key in ["agentCPU", "agentMemoryBytes", "processes"] { XCTAssertEqual(snapshot["load"][key].number, 0) }
        await monitor.stop()
    }

    func testVisibleLeasesAreIdempotentAndLastHideStopsAllReads() async {
        let stub = ATWORKMonitorStub(), monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        await monitor.setVisible("one", visible: true)
        await monitor.setVisible("two", visible: true)
        let count = await monitor.watcherCount()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(stub.counts()[0], 1, "Joining a second screen must not reread inventory")
        await monitor.setVisible("one", visible: false)
        let remaining = await monitor.watcherCount()
        XCTAssertEqual(remaining, 1)
        await monitor.sampleNow()
        XCTAssertEqual(stub.counts()[0], 1, "Metrics tick must reuse event-driven inventory")
        await monitor.setVisible("two", visible: false)
        let before = stub.counts()
        await monitor.invalidate()
        await monitor.sampleNow()
        XCTAssertEqual(stub.counts(), before)
    }

    func testEmptyWatcherCannotStartClockOrKernelReads() async {
        let stub = ATWORKMonitorStub(), monitor = monitor(stub)
        await monitor.setVisible("", visible: true)
        await monitor.setVisible(String(repeating: "x", count: 201), visible: true)
        XCTAssertEqual(stub.counts(), [0, 0, 0, 0])
        let count = await monitor.watcherCount()
        XCTAssertEqual(count, 0)
    }

    func testTokenRateAndProcessMetricsArriveThroughOneEvent() async throws {
        let stub = ATWORKMonitorStub(), monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        stub.advance(to: 102, cpu: 1_000_000_000, tokens: 120)
        await monitor.invalidate()
        let snapshot = await monitor.snapshot()
        let row = try XCTUnwrap(snapshot["metrics"].elements?.first)
        XCTAssertEqual(row["id"].string, "fixture")
        XCTAssertEqual(row["pid"].number, 10)
        XCTAssertEqual(row["cpuPercent"].number, 50)
        XCTAssertEqual(row["memoryBytes"].number, 1024)
        XCTAssertEqual(row["tokensToday"].number, 120)
        XCTAssertEqual(snapshot["load"]["tokensPerMinute"].number, 600)
        XCTAssertEqual(snapshot["load"]["agentCPU"].number, 25, "Footer CPU is divided by the Mac's two cores")
        XCTAssertEqual(snapshot["load"]["otherCPU"].number, 25)
        XCTAssertEqual(snapshot["load"]["agentMemoryBytes"].number, 1024)
        XCTAssertEqual(snapshot["load"]["freeMemoryBytes"].number, 8192)
        await monitor.stop()
    }

    func testHideThenReopenDuringSlowInventoryDoesNotLoseNewVisibility() async throws {
        let gate = ATWORKInventoryGate(), stub = ATWORKMonitorStub()
        let monitor = BackendATWORKMonitor(readTargets: { await gate.read() },
            readProcesses: { stub.readProcesses($0) }, readSystem: { stub.readSystem() },
            now: { stub.now() }, uptime: { stub.uptime() }, watchProcessEvents: false, publish: { stub.publish($0) })
        let opening = Task { await monitor.setVisible("first", visible: true) }
        await gate.waitForFirstRead()
        await monitor.setVisible("first", visible: false)
        await monitor.setVisible("second", visible: true)
        await gate.releaseFirst()
        await opening.value
        await monitor.sampleNow()
        let reads = await gate.readCount()
        XCTAssertGreaterThanOrEqual(reads, 2, "New visibility needs a fresh inventory, even when an old request is suspended")
        let snapshot = await monitor.snapshot()
        XCTAssertEqual(snapshot["metrics"].elements?.first?["id"].string, "new")
        await monitor.stop()
    }

    func testSharedAppProcessDoesNotInventSeparatePerAgentUsage() async throws {
        let stub = ATWORKMonitorStub()
        stub.setTargets([.init(id: "first", pid: 10), .init(id: "second", pid: 10)])
        let monitor = monitor(stub)
        await monitor.setVisible("one", visible: true)
        let snapshot = await monitor.snapshot()
        let rows = try XCTUnwrap(snapshot["metrics"].elements)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertTrue(row["sharedProcess"].bool == true)
            XCTAssertNil(row["cpuPercent"].number)
            XCTAssertNil(row["memoryBytes"].number)
        }
        XCTAssertEqual(snapshot["load"]["agentMemoryBytes"].number, 1024, "Shared app usage is counted once in the footer")
        await monitor.stop()
    }
}

/// Synchronous injected kernel reads use a small lock. Every value is a fixture.
private final class ATWORKMonitorStub: @unchecked Sendable {
    private let lock = NSLock()
    private var at = 100.0, elapsed = 100.0, cpu: UInt64 = 0, tokens = 100.0
    private var targetOverride: [BackendATWORKTarget]?
    private var readCounts = [0, 0, 0, 0]
    func readTargets() -> [BackendATWORKTarget] {
        lock.lock(); defer { lock.unlock() }
        readCounts[0] += 1
        return targetOverride ?? [.init(id: "fixture", pid: 10, tokensToday: tokens)]
    }
    func readProcesses(_ roots: [Int32]) -> [BackendATWORKProcess] {
        lock.lock(); defer { lock.unlock() }
        readCounts[1] += 1
        return roots.contains(10) ? [.init(pid: 10, parentPID: 1, birth: 10, cpuNanoseconds: cpu, memoryBytes: 1024, threads: 2)] : []
    }
    func readSystem() -> BackendATWORKSystem {
        lock.lock(); defer { lock.unlock() }
        readCounts[2] += 1
        let offset = UInt64(max(0, at - 100))
        return .init(cpuBusy: 10 + offset * 5, cpuTotal: 100 + offset * 10,
                     freeMemoryBytes: 8192, memoryPressure: 0.5, processes: 40, cores: 2)
    }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return at }
    func uptime() -> Double { lock.lock(); defer { lock.unlock() }; return elapsed }
    func publish(_ value: NativeRPCValue) { lock.lock(); defer { lock.unlock() }; readCounts[3] += 1 }
    func counts() -> [Int] { lock.lock(); defer { lock.unlock() }; return readCounts }
    func advance(to at: Double, cpu: UInt64, tokens: Double) {
        lock.lock(); defer { lock.unlock() }; self.at = at; self.elapsed = at; self.cpu = cpu; self.tokens = tokens
    }
    func wallJump(to at: Double, uptime: Double, cpu: UInt64) {
        lock.lock(); defer { lock.unlock() }; self.at = at; self.elapsed = uptime; self.cpu = cpu
    }
    func setTargets(_ rows: [BackendATWORKTarget]) { lock.lock(); defer { lock.unlock() }; targetOverride = rows }
}

private actor ATWORKInventoryGate {
    private var reads = 0, began = false
    private var first: CheckedContinuation<[BackendATWORKTarget], Never>?
    private var started: CheckedContinuation<Void, Never>?
    func read() async -> [BackendATWORKTarget] {
        reads += 1
        if reads == 1 {
            began = true; started?.resume(); started = nil
            return await withCheckedContinuation { first = $0 }
        }
        return [.init(id: "new", pid: 10, tokensToday: 100)]
    }
    func waitForFirstRead() async {
        if began { return }
        await withCheckedContinuation { started = $0 }
    }
    func releaseFirst() { first?.resume(returning: [.init(id: "stale", pid: 10)]); first = nil }
    func readCount() -> Int { reads }
}
