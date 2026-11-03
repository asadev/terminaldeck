import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatTodosTests: XCTestCase {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func events(_ rows: [(String, HootChatRecord)]) -> [HootChatEvent] {
        rows.enumerated().map { .init(conversationID: "c", turnID: $0.element.0, sequence: $0.offset + 1, provider: .claude, record: $0.element.1) }
    }
    func testTaskCreateAndUpdateCarryTheirRealIDAcrossTurns() throws {
        let rows = events([
            ("a", .text(.user, "Plan")),
            ("a", .init(.toolCall, id: "create", value: try json(#"{"name":"TaskCreate","input":{"subject":"Read fixture","activeForm":"Reading fixture"}}"#))),
            ("a", .init(.toolResult, id: "create", value: try json(#"{"output":"Task #1 created successfully: Read fixture"}"#))),
            ("b", .text(.user, "Continue")),
            ("b", .init(.toolCall, id: "update", value: try json(#"{"name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}"#))),
            ("b", .init(.toolResult, id: "update", value: try json(#"{"output":"Updated task #1"}"#)))
        ])
        let todo = try XCTUnwrap(BackendChatTodos.list(rows).first)
        XCTAssertEqual(todo["id"].string, "task:1")
        XCTAssertEqual(todo["text"].string, "Reading fixture")
        XCTAssertEqual(todo["state"].string, "current")
    }
    func testFailedCreationNeverInventsATaskAndStructuredIDWorks() throws {
        let create = HootChatRecord(.toolCall, id: "create", value: try json(#"{"name":"TaskCreate","input":{"subject":"Owned fixture"}}"#))
        XCTAssertTrue(BackendChatTodos.list(events([("a", .text(.user, "Plan")), ("a", create),
            ("a", .init(.toolResult, id: "create", value: try json(#"{"isError":true,"output":"Task #1 created successfully"}"#)))])).isEmpty)
        let rows = events([("a", .text(.user, "Plan")), ("a", create),
            ("a", .init(.toolResult, id: "create", value: try json(#"{"output":{"task":{"id":"owned"}}}"#))),
            ("a", .init(.toolCall, id: "delete", value: try json(#"{"name":"TaskUpdate","input":{"taskId":"owned","status":"deleted"}}"#))),
            ("a", .init(.toolResult, id: "delete", value: try json(#"{"output":"Deleted"}"#)))])
        XCTAssertTrue(BackendChatTodos.list(rows).isEmpty)
    }
    func testTaskToolOptInNeverOverridesExplicitUserChoices() {
        XCTAssertEqual(BackendHootChatCLI.planningEnvironment([:])["CLAUDE_CODE_ENABLE_TODO_TOOLS"], "1")
        XCTAssertEqual(BackendHootChatCLI.planningEnvironment(["CLAUDE_CODE_ENABLE_TODO_TOOLS": "0"])["CLAUDE_CODE_ENABLE_TODO_TOOLS"], "0")
        XCTAssertNil(BackendHootChatCLI.planningEnvironment(["CLAUDE_CODE_ENABLE_TASKS": "false"])["CLAUDE_CODE_ENABLE_TODO_TOOLS"])
    }
    func testOneCardKeepsItsAnchorAcrossTurnsAndCountsOnlyItsRunningAgents() throws {
        var rows = events([
            ("a", .text(.user, id: "question", "Plan")),
            ("a", .init(.toolCall, id: "create", value: try json(#"{"name":"TaskCreate","input":{"subject":"Read fixture","activeForm":"Reading fixture"}}"#))),
            ("a", .init(.toolResult, id: "create", value: try json(#"{"output":"Task #1 created successfully"}"#))),
            ("a", .init(.toolCall, id: "update", value: try json(#"{"name":"TaskUpdate","input":{"taskId":"1","status":"in_progress"}}"#))),
            ("a", .init(.toolResult, id: "update", value: try json(#"{"output":"Updated task #1"}"#))),
            ("a", .init(.toolCall, id: "launch", value: try json(#"{"name":"Agent","input":{"run_in_background":true}}"#))),
            ("a", .init(.session, value: try json(#"{"childTask":{"id":"real-child","kind":"local_agent","toolUseId":"launch","status":"running"}}"#)))
        ])
        let first = BackendChatTodos.progress(rows)
        XCTAssertEqual(first.anchorRowID, "a:question")
        XCTAssertEqual(first.rows.first?["runningTasks"].number, 1)
        XCTAssertEqual(first.rows.first?["childTaskIds"].elements?.compactMap(\.string), ["real-child"])
        rows += events([("b", .text(.user, id: "next", "Continue")),
            ("b", .init(.toolCall, id: "done", value: try json(#"{"name":"TaskUpdate","input":{"taskId":"1","status":"completed"}}"#))),
            ("b", .init(.toolResult, id: "done", value: try json(#"{"output":"Updated"}"#))),
            ("b", .init(.session, value: try json(#"{"childTask":{"id":"real-child","kind":"local_agent","status":"completed"}}"#)))])
        let next = BackendChatTodos.progress(rows)
        XCTAssertEqual(next.anchorRowID, first.anchorRowID)
        XCTAssertEqual(next.rows.first?["state"].string, "done")
        XCTAssertEqual(next.rows.first?["runningTasks"].number, 0)
    }
    func testCodexPlanUsesTheSameStableThreeStepCardAndRealChildID() throws {
        let plan = try json(#"{"todoPlan":[{"step":"Read check","status":"completed"},{"step":"Inspect card","status":"in_progress"},{"step":"Report","status":"pending"}]}"#)
        let rows = events([("a", .text(.user, id: "question", "Plan")), ("a", .init(.session, value: plan)),
            ("a", .init(.session, value: try json(#"{"childTask":{"id":"codex:thread-real","kind":"agent","status":"running"}}"#)))])
        let projection = BackendChatTodos.progress(rows)
        XCTAssertEqual(projection.rows.map { $0["state"].string }, ["done", "current", "next"])
        XCTAssertEqual(projection.rows[1]["childTaskIds"].elements?.compactMap(\.string), ["codex:thread-real"])
        XCTAssertEqual(projection.rows[1]["runningTasks"].number, 1)
        XCTAssertEqual(projection.wire["id"].string, "task-progress")
    }
}
