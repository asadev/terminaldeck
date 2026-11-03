import Foundation
import XCTest
@testable import TerminalDeckBackend

/// U31: a sign-in code pasted just after the AI's sign-in command ended is refused in words, never a crash.
final class AccountSignInCodeTests: XCTestCase {
    func testCodeAfterTheSignInEndedIsRefusedNotACrash() async throws {
        // Still running, but its input is already closed: the write meets a pipe nobody reads.
        let closed = BackendAccountSignInFlow(profileID: "fixture", provider: "claude")
        try closed.start(runnable: "/bin/sh", arguments: ["-c", "exec 0<&-; echo 'Paste the code here'; sleep 10"], environment: ["PATH": "/usr/bin:/bin"], cwd: "/")
        defer { closed.cancel() }
        for _ in 0..<250 where closed.wire["state"].string != "needs-code" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(closed.wire["state"].string, "needs-code"); XCTAssertTrue(closed.isRunning)
        XCTAssertThrowsError(try closed.submit(code: "fixture-code")) { XCTAssertEqual($0.localizedDescription, BackendAccountSignInFlow.ended) }
        XCTAssertFalse(try closed.submit(code: "   "), "an empty field is not a code")
        // Already ended: the same words, not "paste the code".
        let gone = BackendAccountSignInFlow(profileID: "fixture", provider: "claude")
        try gone.start(runnable: "/usr/bin/true", arguments: [], environment: [:], cwd: "/")
        for _ in 0..<250 where gone.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertThrowsError(try gone.submit(code: "fixture-code")) { XCTAssertEqual($0.localizedDescription, BackendAccountSignInFlow.ended) }
    }
}
