import XCTest
@testable import TerminalDeckNativeCore

final class SessionChatToolPolicyTests: XCTestCase {
    private func args(_ pairs: [(String, NativeRPCValue)] = []) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    func testEveryVerbHasOneRuleAndRejectsUnknownPanelDirections() throws {
        let operations = SessionChatToolPolicy.operations
        XCTAssertEqual(operations.count, 32); XCTAssertEqual(Set(operations.map(\.name)).count, 32)
        XCTAssertThrowsError(try SessionChatToolPolicy.operation("invented"))
        for operation in operations where operation.isPanel {
            XCTAssertTrue(operation.directions.contains("read"))
            let key = operation.name == "attachments" ? "attachmentAction" : "direction"
            XCTAssertThrowsError(try operation.direction(args([(key, .string("invented"))])))
            for direction in operation.directions {
                XCTAssertEqual(try operation.changes(args([(key, .string(direction))])), direction != "read", operation.name + ":" + direction)
            }
        }
    }
    func testReadsStayReadOnlyAndWritesRemainActions() throws {
        for name in ["read", "turn", "options", "files", "history", "attachments", "children", "recovery"] {
            XCTAssertFalse(try SessionChatToolPolicy.operation(name).changes(args()), name)
        }
        for name in ["say", "answer", "stop", "stop-job", "mention"] {
            XCTAssertTrue(try SessionChatToolPolicy.operation(name).changes(args()), name)
        }
        XCTAssertFalse(try SessionChatToolPolicy.operation("options").changes(args([("options", .null)])))
        XCTAssertTrue(try SessionChatToolPolicy.operation("options").changes(args([("options", .object([]))])))
        XCTAssertTrue(try SessionChatToolPolicy.operation("draft").changes(args([("text", .string(""))])))
        for name in ["find", "detail"] { XCTAssertTrue(try SessionChatToolPolicy.operation(name).changes(args([("query", .string(""))])), name) }
        XCTAssertFalse(try SessionChatToolPolicy.operation("history").changes(args([("query", .string("prompt"))])))
    }
    func testOwnerRulesKeepScopedReadsAndRefuseMacOnlyActions() throws {
        for name in ["voice", "routines", "goals", "editor-context", "limits", "connections", "skills"] {
            let operation = try SessionChatToolPolicy.operation(name)
            XCTAssertNotNil(try operation.refusal(args(), local: false), name)
            XCTAssertNil(try operation.refusal(args(), local: true), name)
        }
        for name in ["side", "diagnostics", "account", "artifacts", "sources", "detail", "export", "review"] {
            XCTAssertNil(try SessionChatToolPolicy.operation(name).refusal(args(), local: false), name)
        }
        for (name, direction) in [("side", "prepare"), ("export", "copy"), ("detail", "copy"), ("review", "reveal"), ("sources", "open")] {
            XCTAssertNotNil(try SessionChatToolPolicy.operation(name).refusal(args([("direction", .string(direction))]), local: false), name)
        }
    }
}
