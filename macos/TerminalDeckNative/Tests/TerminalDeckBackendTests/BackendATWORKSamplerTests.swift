import XCTest
@testable import TerminalDeckBackend

/// Counter fixtures only: these tests never inspect a real PID or invoke an AI.
final class BackendATWORKSamplerTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_ATWORK_FOCUSED"] == "1" else { throw XCTSkip("WIP ATWORK") }
    }
    private func process(_ pid: Int32, parent: Int32 = 1, birth: UInt64 = 10,
                         cpu: UInt64? = 0, memory: UInt64? = 1024, threads: Int? = 1) -> BackendATWORKProcess {
        BackendATWORKProcess(pid: pid, parentPID: parent, birth: birth,
                             cpuNanoseconds: cpu, memoryBytes: memory, threads: threads)
    }

    func testTreeMetricsSumDescendantsButExcludeUnrelatedProcesses() throws {
        var sampler = BackendATWORKProcessSampler()
        let rows = [process(10, memory: 2000, threads: 2), process(11, parent: 10, memory: 3000, threads: 3),
                    process(12, parent: 11, memory: 4000, threads: 4), process(20, memory: 999999, threads: 99)]
        let metric = try XCTUnwrap(sampler.sample(roots: [10], processes: rows, at: 100)[10])
        XCTAssertEqual(metric.memoryBytes, 9000)
        XCTAssertEqual(metric.threads, 9)
        XCTAssertEqual(metric.processes, 3)
        XCTAssertNil(metric.cpuPercent, "First read has no elapsed-time baseline")
    }

    func testCpuUsesCounterDeltaAndMayExceedOneCore() throws {
        var sampler = BackendATWORKProcessSampler()
        _ = sampler.sample(roots: [10], processes: [process(10, cpu: 4_000_000_000), process(11, parent: 10, cpu: 1_000_000_000)], at: 100)
        let next = sampler.sample(roots: [10], processes: [process(10, cpu: 6_000_000_000), process(11, parent: 10, cpu: 2_000_000_000)], at: 102)
        XCTAssertEqual(try XCTUnwrap(next[10]?.cpuPercent), 150, accuracy: 0.0001)
    }

    func testNewDescendantDoesNotCountItsLifetimeCpuAsNewWork() throws {
        var sampler = BackendATWORKProcessSampler()
        _ = sampler.sample(roots: [10], processes: [process(10, cpu: 0)], at: 100)
        let next = sampler.sample(roots: [10], processes: [process(10, cpu: 1_000_000_000), process(11, parent: 10, birth: 20, cpu: 90_000_000_000)], at: 102)
        XCTAssertEqual(try XCTUnwrap(next[10]?.cpuPercent), 50, accuracy: 0.0001)
        XCTAssertEqual(next[10]?.processes, 2)
    }

    func testRemovedDescendantNeverProducesNegativeCpu() throws {
        var sampler = BackendATWORKProcessSampler()
        _ = sampler.sample(roots: [10], processes: [process(10, cpu: 1_000_000_000), process(11, parent: 10, cpu: 90_000_000_000)], at: 100)
        let next = sampler.sample(roots: [10], processes: [process(10, cpu: 2_000_000_000)], at: 102)
        XCTAssertEqual(try XCTUnwrap(next[10]?.cpuPercent), 50, accuracy: 0.0001)
        XCTAssertEqual(next[10]?.memoryBytes, 1024)
    }

    func testReusedDescendantPidStartsFreshCounterBaseline() throws {
        var sampler = BackendATWORKProcessSampler()
        _ = sampler.sample(roots: [10], processes: [process(10), process(11, parent: 10, birth: 10, cpu: 5_000_000_000)], at: 100)
        let next = sampler.sample(roots: [10], processes: [process(10, cpu: 1_000_000_000), process(11, parent: 10, birth: 99, cpu: 100_000_000_000)], at: 102)
        XCTAssertEqual(try XCTUnwrap(next[10]?.cpuPercent), 50, accuracy: 0.0001)
    }

    func testDeniedDescendantReadDoesNotPretendToHaveCompleteUsage() throws {
        var sampler = BackendATWORKProcessSampler()
        let metric = try XCTUnwrap(sampler.sample(roots: [10], processes: [process(10), process(11, parent: 10, cpu: nil, memory: nil, threads: nil)], at: 100)[10])
        XCTAssertNil(metric.cpuPercent)
        XCTAssertNil(metric.memoryBytes)
        XCTAssertNil(metric.threads)
        XCTAssertEqual(metric.processes, 2)
    }

    func testCycleIsBoundedAndEachProcessIsCountedOnce() throws {
        var sampler = BackendATWORKProcessSampler()
        let metric = try XCTUnwrap(sampler.sample(roots: [10, 10], processes: [process(10, parent: 11), process(11, parent: 10)], at: 100)[10])
        XCTAssertEqual(metric.memoryBytes, 2048)
        XCTAssertEqual(metric.processes, 2)
    }

    func testResetDropsBaselineAndEmptyRootsReturnNoMetrics() throws {
        var sampler = BackendATWORKProcessSampler()
        _ = sampler.sample(roots: [10], processes: [process(10)], at: 100)
        XCTAssertTrue(sampler.sample(roots: [], processes: [process(10)], at: 101).isEmpty)
        sampler.reset()
        let metric = try XCTUnwrap(sampler.sample(roots: [10], processes: [process(10, cpu: 90_000_000_000)], at: 102)[10])
        XCTAssertNil(metric.cpuPercent)
    }
}
