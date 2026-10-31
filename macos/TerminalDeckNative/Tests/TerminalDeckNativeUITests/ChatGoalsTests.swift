import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatGoalsTests: XCTestCase {
    func testGoalContextUsesTaskProgressPreservesDraftAndRejectsMissingGoal() throws {
        let goal = GoalRow(id: "g1", title: "Ship", description: "Keep quality", progress: .init(total: 4, done: 2, verified: 1))
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("goal-chat"))]))
        model.composerDraft.text = "Existing draft"
        model.composerDraft.add([URL(fileURLWithPath: "/scratch/reference.txt")])
        let files = model.composerDraft
        let state = try model.goalTool("insert", request: "g1", goals: [goal])
        XCTAssertTrue(model.composerDraft.text.hasPrefix("Existing draft\n\nApp goal: Ship"))
        XCTAssertTrue(model.composerDraft.text.contains("Keep quality"))
        var expected = files; expected.text = model.composerDraft.text
        XCTAssertEqual(model.composerDraft, expected)
        XCTAssertEqual(state["goals"].elements?.first?["doneTasks"].number, 2)
        XCTAssertEqual(state["providerGoal"], .null)
        XCTAssertThrowsError(try model.goalTool("insert", request: "missing", goals: [goal]))
    }
}
