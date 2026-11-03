import Foundation
import Testing
@testable import TerminalDeckBackend

/// PERF round 6: a readability handler left installed on a pipe at end-of-file is
/// re-fired by dispatch in a tight loop (the installed 0.20.1 app sat at ~100% CPU
/// for hours after a simulator session closed). These tests count how often the
/// handler body runs after EOF; a spinning handler runs thousands of times.
@Suite struct BackendPipeDrainTests {
    private final class Owner: @unchecked Sendable {
        let lock = NSLock()
        var bytes = Data()
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Wraps the drain so every handler run is counted, including empty EOF reads.
    private func install(_ pipe: Pipe, owner: Owner, runs: Counter) {
        BackendPipeDrain.install(on: pipe.fileHandleForReading, owner: owner) { owner, data in
            owner.lock.lock(); owner.bytes.append(data); owner.lock.unlock()
        }
        let drain = pipe.fileHandleForReading.readabilityHandler
        pipe.fileHandleForReading.readabilityHandler = { handle in runs.bump(); drain?(handle) }
    }

    @Test func eofRemovesTheHandlerWhileTheOwnerLives() async throws {
        let pipe = Pipe(), owner = Owner(), runs = Counter()
        install(pipe, owner: owner, runs: runs)
        try pipe.fileHandleForWriting.write(contentsOf: Data("last words".utf8))
        try pipe.fileHandleForWriting.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(String(decoding: owner.bytes, as: UTF8.self) == "last words")
        #expect(runs.count <= 3, "handler ran \(runs.count) times after EOF: it is spinning")
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
    }

    @Test func eofAfterTheOwnerIsGoneDoesNotSpin() async throws {
        let pipe = Pipe(), runs = Counter()
        do { let owner = Owner(); install(pipe, owner: owner, runs: runs) }
        // The owner is released (the session closed); then the child exits.
        try pipe.fileHandleForWriting.close()
        try await Task.sleep(for: .milliseconds(400))
        #expect(runs.count <= 3, "handler ran \(runs.count) times after EOF with no owner: it is spinning")
        #expect(pipe.fileHandleForReading.readabilityHandler == nil)
    }
}

/// End to end, through the real simulator-engine start path: an engine that never
/// opens its socket makes `start` give up, stop the child and release its owner —
/// exactly the moment the shipped 0.20.1 began spinning. Measures this process's
/// CPU over the following 1.5 s. A control installs the OLD handler shape to prove
/// the measurement sees a spin. CPU timing is load-sensitive, so this runs on
/// request: `TD_PERF_E2E=1 swift test --filter BackendPipeDrainEndToEndTests`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TD_PERF_E2E"] == "1"))
struct BackendPipeDrainEndToEndTests {
    private final class Gone: @unchecked Sendable {}

    private static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private static func cpuOver(seconds: Double) async throws -> Double {
        let before = cpuSeconds()
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        return cpuSeconds() - before
    }

    @Test func controlTheOldHandlerShapeSpins() async throws {
        let pipe = Pipe()
        do {
            let owner = Gone()
            pipe.fileHandleForReading.readabilityHandler = { [weak owner] handle in
                let data = handle.availableData
                guard owner != nil else { return } // the 0.20.1 shape: bail before the EOF check
                if data.isEmpty { handle.readabilityHandler = nil }
            }
        }
        try pipe.fileHandleForWriting.close()
        try await Task.sleep(for: .milliseconds(100))
        let used = try await Self.cpuOver(seconds: 1.5)
        pipe.fileHandleForReading.readabilityHandler = nil
        print("PERF control (old shape): \(String(format: "%.2f", used)) CPU-s over 1.5 s")
        #expect(used > 0.75, "the measurement should see the old handler spin")
    }
}
