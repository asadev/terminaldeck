import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U160: the Apps pages share one change runner and one engine time limit.
@Suite("Apps change runner")
@MainActor
struct NativeAppsChangeRunnerTests {
    enum Part: Equatable { case one, two }

    static func settle(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// One change at a time; its note lands in the part that made it.
    @Test func oneChangeAtATime() async throws {
        let runner = NativeAppsChangeRunner<Part>()
        runner.run(.one, "Saving") { try await Task.sleep(for: .milliseconds(30)); return "Saved." }
        runner.run(.two, "Other") { "No." }
        #expect(runner.busy == "Saving" && runner.resultPart == .one)
        try await Self.settle { runner.busy == nil }
        #expect(runner.note == "Saved." && runner.problem == nil)
        runner.run(.two, "Blocked", writesDisabled: true) { "No." }
        #expect(runner.busy == nil && runner.resultPart == .one)
        runner.clear(.one)
        #expect(runner.note == nil)
    }

    /// A reply that arrives after a newer read is not shown.
    @Test func newerReadDropsOldReply() async throws {
        let runner = NativeAppsChangeRunner<Part>()
        runner.run(.one, "Saving") {
            try await Task.sleep(for: .milliseconds(30))
            throw NativeRPCError(code: "conflict", message: "Old answer.")
        }
        _ = runner.advance()
        try await Self.settle { runner.busy == nil }
        #expect(runner.problem == nil)
        runner.run(.two, "Saving") { throw NativeRPCError(code: "conflict", message: "Current answer.") }
        try await Self.settle { runner.busy == nil }
        #expect(runner.problem == "Current answer." && runner.resultPart == .two)
    }

    @Test func stagedOperationSharesTheGate() {
        let runner = NativeAppsChangeRunner<Part>()
        #expect(runner.begin(.one, "Creating"))
        runner.relabel("Deploying")
        #expect(runner.busy == "Deploying")
        #expect(!runner.begin(.two, "Other"))
        runner.finish()
        #expect(runner.begin(.two, "Next"))
        runner.finish()
        #expect(!runner.begin(.one, "Blocked", writesDisabled: true))
    }

    @Test func oneTimeLimit() {
        #expect(NativeAppsSRV2Engine.timeout == 120)
    }
}
