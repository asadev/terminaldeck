import XCTest
@testable import TerminalDeckNative

final class ChatInstructionSourcesTests: XCTestCase {
    func testSourcesArePresentFilesAndNeverClaimedApplied() {
        let files = NativeChatInstructionSources.files(cwd: "/project", agentFile: "/agent/seat.md", exists: { ["/project/AGENTS.md", "/agent/seat.md"].contains($0) })
        XCTAssertEqual(files, ["/project/AGENTS.md", "/agent/seat.md"])
        let state = NativeChatInstructionSources.state(files: files, owner: "lead:project")
        XCTAssertEqual(state["memoryOwner"].string, "lead:project")
        XCTAssertTrue(state["effectiveAppliedSources"].isNullish)
        XCTAssertTrue(NativeChatInstructionSources.state(files: [], owner: nil)["memoryOwner"].isNullish)
    }
}
