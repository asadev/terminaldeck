import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSessionTestPortRules: XCTestCase, @unchecked Sendable {
    func testProbePathEvidence() { let value = BackendAppSessionToolProbe.result(bin: "claude", command: "which claude", stdout: "/Users/apple/.local/bin/claude\n", stderr: "", exitCode: 0); XCTAssertTrue(value.found); XCTAssertEqual(value.line, "/Users/apple/.local/bin/claude") }
    func testProbeOutputThreeLinesAnd240Units() { let value = BackendAppSessionToolProbe.result(bin: "gemini", command: "which gemini", stdout: "a\nb\nc\nd\ne\n", stderr: String(repeating: "x", count: 500) + "\n", exitCode: 1); XCTAssertEqual(value.output.components(separatedBy: "\n").count, 3); XCTAssertLessThanOrEqual(value.output.utf16.count, 240) }
    func testUnsafeNameNeverReachesFakeExecutor() async {
        let executor = BackendAppSessionTestPortExecutor([]), probe = BackendAppSessionToolProbe(executor: executor, environment: [:], home: "/fixture")
        let value = await probe.probe("claude; rm -rf ~", path: "/fixture/bin")
        XCTAssertFalse(value.found); XCTAssertTrue(value.line.contains("not a name this app is willing to run"))
        let calls = await executor.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testMacLaunchSpecUsesDirectNameEvenForOddCmdExtension() {
        let ordinary = BackendAppSessionToolProbe.macLaunchSpec("claude", resolved: "/opt/homebrew/bin/claude")
        XCTAssertEqual(ordinary.command, "claude"); XCTAssertFalse(ordinary.shell)
        XCTAssertFalse(BackendAppSessionToolProbe.macLaunchSpec("claude", resolved: "/opt/homebrew/bin/claude.cmd").shell)
        let absent = BackendAppSessionToolProbe.macLaunchSpec("copilot")
        XCTAssertEqual(absent.command, "copilot"); XCTAssertFalse(absent.shell)
    }
}
