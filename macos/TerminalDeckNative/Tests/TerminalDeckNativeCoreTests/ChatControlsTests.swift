import XCTest
import TerminalDeckNativeCore

final class ChatControlsTests: XCTestCase {
    func testOneActionForIdleRunningTypedAndStopping() {
        XCTAssertEqual(ChatComposerControl.action(turnRunning: false, hasDraft: false, allowsQueue: true), .send)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: false, hasDraft: true, allowsQueue: true), .send)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: true, hasDraft: false, allowsQueue: true), .stop)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: true, hasDraft: true, allowsQueue: true), .queue)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: true, hasDraft: true, allowsQueue: false), .stop)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: true, hasDraft: true, allowsQueue: true, stopping: true), .stopping)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: true, hasDraft: false, allowsQueue: true, canStop: false), .send)
        XCTAssertEqual(ChatComposerControl.action(turnRunning: true, hasDraft: true, allowsQueue: true, canStop: false), .queue)
    }
    func testTaskClockComesFromFirstStartAndSurvivesProgressAndStopRequest() {
        func event(_ n: Int, status: String) -> HootChatEvent {
            .init(conversationID: "scratch", turnID: "turn", sequence: n, provider: .claude,
                record: .init(.session, value: .object([.init("taskStarted", n == 1 ? .string("one") : .null), .init("childTask", .object([.init("id", .string("one")), .init("status", .string(status))]))])), at: Double(n) * 1000)
        }
        let task = ChatChildTasks.list([event(1, status: "running"), event(2, status: "running"), event(3, status: "stopping")]).first
        XCTAssertEqual(task?["startedAt"].number, 1000)
        XCTAssertEqual(task?["status"].string, "stopping")
        let finishedOnly = ChatChildTasks.list([event(4, status: "completed")]).first
        XCTAssertTrue(finishedOnly?["startedAt"].isNullish == true)
        let progressOnly = ChatChildTasks.list([event(2, status: "running")]).first
        XCTAssertTrue(progressOnly?["startedAt"].isNullish == true, "A progress notice is not a start time")
    }
    func testInternalCodexShellHasNoIndividualStopAndTurnStopKeepsAgent() {
        func event(_ n: Int, _ record: HootChatRecord) -> HootChatEvent {
            .init(conversationID: "scratch", turnID: "turn", sequence: n, provider: .codex, record: record)
        }
        let shell = HootChatRecord(.toolCall, id: "shell", value: .object([.init("input", .object([
            .init("type", .string("commandExecution")), .init("processId", .string("p")), .init("status", .string("inProgress"))]))]))
        let agent = HootChatRecord(.session, value: .object([.init("childTask", ChatChildTasks.codexAgent("child", status: "running"))]))
        let tasks = ChatChildTasks.list([event(1, shell), event(2, agent), event(3, .init(.interrupted))])
        XCTAssertEqual(tasks.first { $0["id"].string == "codex-shell:p" }?["canStop"].bool, false)
        XCTAssertEqual(tasks.first { $0["id"].string == "codex-shell:p" }?["status"].string, "stopped")
        XCTAssertEqual(tasks.first { $0["id"].string == "codex:child" }?["status"].string, "running")
    }
}
