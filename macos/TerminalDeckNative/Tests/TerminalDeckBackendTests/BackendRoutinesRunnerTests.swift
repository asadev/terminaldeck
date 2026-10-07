import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendRoutinesTestProvider: BackendRoutinesLaunchEnvironmentProviding {
    func environment(flags: [String], inherited: [String: String]) async throws -> BackendRoutinesLaunchEnvironment { .init(command: "/fake/claude", args: ["provider-prefix"] + flags, env: inherited.merging(["PATH": "/login/bin"]) { _, new in new }) }
}
actor BackendRoutinesLaunchCapture {
    private(set) var inputs: [BackendRoutinesLaunchInput] = []
    func launch(_ input: BackendRoutinesLaunchInput, text: String, code: Int? = 0, error: Bool = false, stderr: String = "") -> BackendRoutinesLaunchResult {
        inputs.append(input)
        let output = NativeRPCValue.object([.init("result", .string(text)), .init("is_error", .bool(error)), .init("num_turns", .number(3)), .init("session_id", .string("cli-session")), .init("total_cost_usd", .number(0.02))])
        return .init(stdout: output.compact, stderr: stderr, code: code)
    }
}
@MainActor final class BackendRoutinesRunnerTests: XCTestCase {
    private func request(cause: BackendRoutinesCause = .manual(by: "user"), cancellation: BackendMCPCancellation = .init()) -> BackendRoutinesRunRequest {
        .init(routine: .init(id: "blocked-agent", name: "Something is waiting", triggers: [.manual], folder: "/work/api", prompt: "Say which session is blocked."), runId: "run-1", cause: cause, chain: [], cancellation: cancellation)
    }
    private func directory() throws -> URL { let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-routine-runner-" + UUID().uuidString); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); addTeardownBlock { try? FileManager.default.removeItem(at: dir) }; return dir }
    func testStrictUnattendedServerToolRestrictionStdinAndProviderPrefix() async throws {
        let dir = try directory(), capture = BackendRoutinesLaunchCapture(), actions = BackendRoutinesTestActions()
        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/state/unattended config.json" }, copilotRoot: dir, providers: BackendRoutinesTestProvider(), environment: ["PATH": "/old"], launch: { await capture.launch($0, text: "NOTHING-TO-REPORT") }, actions: actions, model: "selected-model"))
        let answer = await runner.run(request()), inputs = await capture.inputs; XCTAssertTrue(answer.ok)
        let input = try XCTUnwrap(inputs.first), args = input.args
        XCTAssertEqual(input.command, "/fake/claude"); XCTAssertEqual(args.first, "provider-prefix"); XCTAssertTrue(args.contains("--strict-mcp-config")); XCTAssertTrue(args.contains("/state/unattended config.json"))
        let allowedStart = try XCTUnwrap(args.firstIndex(of: "--allowedTools")), deniedStart = try XCTUnwrap(args.firstIndex(of: "--disallowedTools"))
        let allowed = Array(args[(allowedStart + 1)..<deniedStart]); XCTAssertEqual(allowed, BackendRoutinesCopilotRunner.allowedTools); XCTAssertFalse(allowed.contains { $0.contains("*") }); XCTAssertFalse(allowed.contains("mcp__deck-control__settings_write"))
        for tool in BackendRoutinesCopilotRunner.deniedNativeTools { XCTAssertTrue(args.contains(tool)) }
        XCTAssertEqual(input.cwd, dir.appendingPathComponent("runs").path); XCTAssertEqual(input.env["PATH"], "/login/bin"); XCTAssertEqual(input.timeoutMs, 300_000)
        XCTAssertTrue(input.stdin.contains("Say which session is blocked.")); XCTAssertFalse(args.joined(separator: " ").contains("Say which session is blocked.")); XCTAssertEqual(Array(args.suffix(2)), ["--model", "selected-model"])
        XCTAssertTrue(actions.rows.isEmpty)
    }
    func testNoServerOrProviderSpendsNothing() async throws {
        let dir = try directory(), capture = BackendRoutinesLaunchCapture(), actions = BackendRoutinesTestActions()
        let noServer = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { nil }, copilotRoot: dir, providers: BackendRoutinesTestProvider(), launch: { await capture.launch($0, text: "anything") }, actions: actions))
        let first = await noServer.run(request()); XCTAssertFalse(first.ok); XCTAssertTrue(first.error?.contains("Nothing was spent") == true)
        let noProvider = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/state/config" }, copilotRoot: dir, launch: { await capture.launch($0, text: "anything") }, actions: actions))
        let second = await noProvider.run(request()); XCTAssertFalse(second.ok); XCTAssertTrue(second.error?.contains("unavailable") == true)
        let inputs = await capture.inputs; XCTAssertTrue(inputs.isEmpty)
    }
    func testSilenceThresholdStripsAllMarkersAndCountsUTF16() {
        XCTAssertFalse(BackendRoutinesCopilotRunner.worthReporting("NOTHING-TO-REPORT")); XCTAssertFalse(BackendRoutinesCopilotRunner.worthReporting("NOTHING-TO-REPORT. All sessions look fine."))
        XCTAssertFalse(BackendRoutinesCopilotRunner.worthReporting(String(repeating: "x", count: 299))); XCTAssertTrue(BackendRoutinesCopilotRunner.worthReporting(String(repeating: "x", count: 300)))
        XCTAssertTrue(BackendRoutinesCopilotRunner.worthReporting(String(repeating: "😀", count: 150)))
    }
    func testReportsAreDistinctRowsAndNonzeroExitPreservesAnswer() async throws {
        let dir = try directory(), capture = BackendRoutinesLaunchCapture(), actions = BackendRoutinesTestActions()
        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/config" }, copilotRoot: dir, providers: BackendRoutinesTestProvider(), launch: { await capture.launch($0, text: String(repeating: "z", count: 400), code: 1) }, actions: actions))
        let answer = await runner.run(request()); XCTAssertTrue(answer.ok); XCTAssertEqual(actions.rows.count, 1)
        let row = try XCTUnwrap(actions.rows.first); XCTAssertEqual(row["action"], .string("routine.report")); XCTAssertEqual(row["sessionId"], .string("cli-session")); XCTAssertFalse(row.has("outcome")); XCTAssertFalse(row.has("routine")); XCTAssertEqual(row["detail"].string?.utf16.count, 300)
    }
    func testEmptyFailedExitNamesCodeAndFirstErrorLine() async throws {
        let dir = try directory(), capture = BackendRoutinesLaunchCapture()
        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/config" }, copilotRoot: dir, providers: BackendRoutinesTestProvider(), launch: { await capture.launch($0, text: "", code: 127, stderr: "claude: command not found\nstack") }, actions: BackendRoutinesTestActions()))
        let answer = await runner.run(request()); XCTAssertEqual(answer.error, "The run exited 127: claude: command not found")
    }
    func testParseEnvelopePlainAuthFailureAndMalformedFields() {
        let parsed = BackendRoutinesCopilotRunner.parseRunOutput(#"{"result":"blocked","is_error":true,"num_turns":4,"session_id":"abc","total_cost_usd":0.1}"#)
        XCTAssertEqual(parsed.text, "blocked"); XCTAssertTrue(parsed.failed); XCTAssertEqual(parsed.turns, 4); XCTAssertEqual(parsed.sessionId, "abc"); XCTAssertEqual(parsed.costUsd, 0.1)
        XCTAssertEqual(BackendRoutinesCopilotRunner.parseRunOutput("Not logged in · Please run /login").text, "Not logged in · Please run /login")
        XCTAssertEqual(BackendRoutinesCopilotRunner.parseRunOutput(#"{"result":42,"is_error":"true"}"#).text, ""); XCTAssertFalse(BackendRoutinesCopilotRunner.parseRunOutput(#"{"is_error":"true"}"#).failed)
        XCTAssertEqual(BackendRoutinesCopilotRunner.parseRunOutput("[]").text, "[]")
    }
    func testPromptNamesCauseUnattendedAndInjectionBoundary() {
        let prompt = BackendRoutinesCopilotRunner.runPrompt(request(cause: .sessionFailed(sessionId: "s1", exitCode: 3)))
        XCTAssertTrue(prompt.contains("Nobody is watching")); XCTAssertTrue(prompt.contains("not-permitted-unattended")); XCTAssertTrue(prompt.contains("not to try it again")); XCTAssertTrue(prompt.contains("untrusted source")); XCTAssertTrue(prompt.contains("session s1 failed with exit code 3"))
        XCTAssertTrue(BackendRoutinesCopilotRunner.runPrompt(request(cause: .schedule(dueAt: 0, missed: 2))).contains("2 earlier runs were missed"))
    }
    func testCancellationDiscardsFindingsAndPrecancelledNativeLaunchStartsNothing() async throws {
        let dir = try directory(), cancellation = BackendMCPCancellation(), actions = BackendRoutinesTestActions(); cancellation.cancel()
        // Invalid command is intentional: pre-cancel must settle before any
        // executable lookup or Process.run, so this launches nothing.
        let result = try await BackendRoutinesNativeLauncher.launch(.init(command: "/does/not/exist", args: [], cwd: dir.path, env: [:], stdin: "", cancellation: cancellation, timeoutMs: 300_000)); XCTAssertNil(result.code)
        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/config" }, copilotRoot: dir, providers: BackendRoutinesTestProvider(), launch: { _ in .init(stdout: String(repeating: "x", count: 400), stderr: "", code: 0) }, actions: actions))
        let answer = await runner.run(request(cancellation: cancellation)); XCTAssertEqual(answer.error, "The run was cancelled before it finished."); XCTAssertTrue(actions.rows.isEmpty)
    }
}
