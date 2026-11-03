import Testing
import Foundation
@testable import TerminalDeckNativeCore

/// 2 Nov (install #25): the Agents page's list is read at most once per spacing, never two at once, and the last change
/// is always read.
@Suite("AGT refresh pacing")
@MainActor
struct AGTRefreshPacerTests {
    @MainActor final class Box<Value> { var value: Value; init(_ value: Value) { self.value = value } }
    /// Waits (up to `limit`) for a condition the pacer reaches on its own.
    private func until(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async {
        let clock = ContinuousClock(), deadline = clock.now + limit
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aBurstReadsOnceAtOnceAndOnceMoreAfterTheSpacing() async {
        let finished = Box(0)
        let pacer = AGTRefreshPacer(spacing: .milliseconds(200)) { finished.value += 1 }
        let clock = ContinuousClock(), start = clock.now
        for _ in 0..<50 { pacer.request() }
        #expect(pacer.reads == 1)               // the first change after a quiet spell reads at once
        await until { pacer.reads == 2 && finished.value == 2 }
        #expect(pacer.reads == 2)               // the other 49 fold into one trailing read
        #expect(clock.now - start >= .milliseconds(190))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(pacer.reads == 2)               // nothing left over
    }

    @Test func aChangeAfterAQuietSpellReadsAtOnce() async {
        let finished = Box(0)
        let pacer = AGTRefreshPacer(spacing: .milliseconds(100)) { finished.value += 1 }
        pacer.request()
        await until { finished.value == 1 }
        try? await Task.sleep(for: .milliseconds(150))
        pacer.request()
        #expect(pacer.reads == 2)
    }

    @Test func onlyOneReadIsInFlight() async {
        let gate = Box<CheckedContinuation<Void, Never>?>(nil)
        let finished = Box(0)
        let pacer = AGTRefreshPacer(spacing: .milliseconds(50)) {
            await withCheckedContinuation { gate.value = $0 }
            finished.value += 1
        }
        pacer.request()
        await until { gate.value != nil }
        for _ in 0..<10 { pacer.request(); try? await Task.sleep(for: .milliseconds(20)) }
        #expect(pacer.reads == 1)               // a slow read is never overlapped
        let first = gate.value; gate.value = nil; first?.resume()
        await until { gate.value != nil }
        #expect(pacer.reads == 2)               // the changes during it are read once it ends
        gate.value?.resume()
        await until { finished.value == 2 }
        #expect(finished.value == 2)
    }

    @Test func cancelDropsTheWaitingRead() async {
        let pacer = AGTRefreshPacer(spacing: .milliseconds(100)) {}
        pacer.request(); pacer.request()
        pacer.cancel()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(pacer.reads == 1)
    }
}
