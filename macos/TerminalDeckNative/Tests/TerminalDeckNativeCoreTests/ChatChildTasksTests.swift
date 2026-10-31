import XCTest
import TerminalDeckNativeCore

final class ChatChildTasksTests: XCTestCase {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func event(_ record: HootChatRecord, turn: String, sequence: Int) -> HootChatEvent {
        .init(conversationID: "c", turnID: turn, sequence: sequence, provider: .codex, record: record)
    }
    func testInterruptedShellEndsWithoutStoppingAgentsOrOtherTurns() throws {
        let shell = HootChatRecord(.toolCall, id: "command", value: try json(#"{"input":{"type":"commandExecution","processId":"shell","status":"inProgress"}}"#))
        let older = HootChatRecord(.toolCall, id: "older", value: try json(#"{"input":{"type":"commandExecution","processId":"older-shell","status":"inProgress"}}"#))
        let agent = HootChatRecord(.session, value: .object([.init("childTask", ChatChildTasks.codexAgent("child", status: "running"))]))
        let events = [event(older, turn: "old", sequence: 1), event(shell, turn: "active", sequence: 2), event(agent, turn: "active", sequence: 3),
                      event(.init(.interrupted), turn: "active", sequence: 4), event(shell, turn: "active", sequence: 5)]
        let tasks = ChatChildTasks.list(events)
        XCTAssertEqual(tasks.first { $0["id"].string == "codex-shell:shell" }?["status"].string, "stopped")
        XCTAssertEqual(tasks.first { $0["id"].string == "codex-shell:shell" }?["canStop"].bool, false)
        XCTAssertEqual(tasks.first { $0["id"].string == "codex-shell:older-shell" }?["status"].string, "inProgress")
        XCTAssertEqual(tasks.first { $0["id"].string == "codex:child" }?["status"].string, "running")
    }
    func testAgentActivityAndStateKeysRetainRealIDsAndExcludeRoot() throws {
        let activity = HootChatRecord(.toolCall, value: try json(#"{"input":{"type":"subAgentActivity","kind":"started","agentThreadId":"child"}}"#))
        let states = HootChatRecord(.toolCall, value: try json(#"{"input":{"type":"collabAgentToolCall","receiverThreadIds":[],"agentsStates":{"child":{"status":"interrupted"},"session":{"status":"running"}}}}"#))
        let tasks = ChatChildTasks.list([event(.init(.session, value: try json(#"{"sessionId":"session"}"#)), turn: "t", sequence: 1),
                                        event(activity, turn: "t", sequence: 2), event(states, turn: "t", sequence: 3)])
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?["id"].string, "codex:child")
        XCTAssertEqual(tasks.first?["threadId"].string, "child")
        XCTAssertEqual(tasks.first?["status"].string, "stopped")
    }
}
