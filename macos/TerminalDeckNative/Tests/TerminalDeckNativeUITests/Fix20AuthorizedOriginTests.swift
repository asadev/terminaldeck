import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class Fix20AuthorizedOriginTests: XCTestCase {
    func testSavedAgentLaunchKeepsItsSeatAndUsesOnlyTheCheckedCall() throws {
        var input = BackendCreateSessionInput(cwd: "/scratch", provider: "codex")
        input.agentProfileID = "saved-worker"
        input.projectId = "scratch-project"
        input.originRunId = "untrusted-old-value"
        input.teamJob = .init(fromID: "lead", fromName: "Lead", agentID: "saved-worker", agentName: "Agent", title: "Question")
        let authorized = try NativeTeamChatStartPolicy.authorized(input, callID: "checked-tool-call")
        XCTAssertEqual(authorized.agentProfileID, "saved-worker")
        XCTAssertEqual(authorized.projectId, "scratch-project")
        XCTAssertEqual(authorized.teamJob, input.teamJob)
        XCTAssertEqual(authorized.origin, .copilot)
        XCTAssertEqual(authorized.originRunId, "checked-tool-call")
    }
    func testNoRequestCannotClaimTheAuthorizedLaunchPath() {
        let input = BackendCreateSessionInput(cwd: "/scratch", provider: "codex")
        XCTAssertThrowsError(try NativeTeamChatStartPolicy.authorized(input, callID: ""))
    }
}
