import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Runs the actual Hoot routine runner with provider/launch/action stubs only.
/// The ownership guard must fire before config reads, folder setup or AI work.
struct ROUTINESWrongAgentGuardChecks {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var config = 0, providers = 0, launches = 0, actions = 0
        func configRead() -> String? { lock.withLock { config += 1 }; return "stub-only-mcp-config" }
        func providerRead() { lock.withLock { providers += 1 } }
        func launch() { lock.withLock { launches += 1 } }
        func action() { lock.withLock { actions += 1 } }
        func snapshot() -> [Int] { lock.withLock { [config, providers, launches, actions] } }
    }
    private struct Actions: BackendRoutinesActionAppending {
        let calls: Calls
        func appendRoutineAction(_ value: NativeRPCValue) { calls.action() }
    }
    private func assertNoHootFallback(unknown: [String: [String]]) async {
        let calls = Calls()
        // This unique, test-owned temporary location is never created when the
        // guard works. Cleanup also protects a failed stale-source test run.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ROUTINES-wrong-agent-" + UUID().uuidString + ".noindex")
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { calls.configRead() }, copilotRoot: root,
            launch: { _ in calls.launch(); throw NativeRPCError(code: "stub-only", message: "No AI process is allowed in this test.") }, actions: Actions(calls: calls), hoot: { _ in
                calls.providerRead()
                return .init(provider: "claude", command: "/stub-only-no-AI", model: nil, effort: nil, environment: [:])
            }))
        let routine = BackendRoutinesRoutine(id: "audit", name: "Audit", triggers: [.manual], folder: "/work/fleet", prompt: "Read logs", unknown: unknown)
        let result = await runner.run(.init(routine: routine, runId: "guard-test", cause: .manual(by: "user"), chain: ["audit"]))
        #expect(!result.ok)
        #expect(result.error == "The assigned agent’s scoped routine runner is unavailable. Nothing was started.")
        #expect(calls.snapshot() == [0, 0, 0, 0])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func assignedProfileCannotFallBackToTheHootProcess() async {
        await assertNoHootFallback(unknown: ["agent-id": ["critic"]])
    }
    @Test func malformedOwnershipCannotAcquireLegacyHootDefault() async {
        await assertNoHootFallback(unknown: ["agent-id": ["@hoot", "critic"]])
    }
}
