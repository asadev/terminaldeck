import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendCopilotRoleTests: XCTestCase {
    func testRoleGuidanceKeepsAssistantAbleToWorkAndClaimsApartFromEvidence() {
        let role = BackendCopilotRole.section()
        XCTAssertTrue(role.hasPrefix("## How you get work done\n\n"))
        // copilot-role.ts:84 ends the template literal right after "below." (no trailing newline).
        XCTAssertTrue(role.hasSuffix("person's half below."))
        XCTAssertFalse(role.hasSuffix("\n"))
        for phrase in ["nothing stops you", "Do it yourself", "Hand it to an agent", "A result becomes verified only through a review that names its evidence", "stale or conflicting"] { XCTAssertTrue(role.contains(phrase), phrase) }
        for tool in ["tasks_goals", "tasks_plan", "tasks_progress", "tasks_retry", "tasks_reassign", "tasks_review", "knowledge_search", "knowledge_get", "knowledge_record", "knowledge_supersede", "knowledge_note", "hoot_memory"] {
            XCTAssertTrue(role.contains("`" + tool + "`"), tool)
        }
        XCTAssertFalse(role.contains("`memory_search`"))
        XCTAssertFalse(role.contains("`memory_read`"))
        XCTAssertFalse(role.contains("you do not change files"))
        XCTAssertFalse(role.contains("you were started without"))
    }
    func testOnlyExactOldAppWrittenNameParagraphChangesInMemory() {
        let old = "They have not named you yet, and until they do you should not pick a name\nfor yourself. If they ask what you are called, say exactly that. In the\nmeantime this app calls you the Copilot, which is a description\nrather than a name."
        let upgraded = BackendCopilotIdentity.withCurrentDefaultName("before\n" + old + "\nafter")
        XCTAssertTrue(upgraded.hasPrefix("before\n"))
        XCTAssertTrue(upgraded.hasSuffix("\nafter"))
        XCTAssertTrue(upgraded.contains("**Hoot**"))
        let edited = old.replacingOccurrences(of: "yet", with: "ever")
        XCTAssertEqual(BackendCopilotIdentity.withCurrentDefaultName(edited), edited)
        XCTAssertEqual(BackendCopilotIdentity.withCurrentDefaultName(upgraded), upgraded)
    }
}
