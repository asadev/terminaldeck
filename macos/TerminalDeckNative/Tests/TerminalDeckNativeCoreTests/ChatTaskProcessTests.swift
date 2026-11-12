import XCTest
import TerminalDeckNativeCore

/// 9 Nov (Asad, iMatch chat: "Working · 1 running" for two days): which background tasks no live process accounts for.
final class ChatTaskProcessTests: XCTestCase {
    private func event(_ record: HootChatRecord, sequence: Int, at: Double) -> HootChatEvent {
        .init(conversationID: "c", turnID: "t", sequence: sequence, provider: .claude, record: record, at: at)
    }
    private func shell(_ id: String, tool: String) -> HootChatRecord {
        .init(.session, value: .object([.init("taskStarted", .string(id)), .init("childTask", .object([.init("id", .string(id)),
            .init("kind", .string("local_bash")), .init("toolUseId", .string(tool)), .init("status", .string("running"))]))]))
    }
    private func process(_ pid: Int32, _ started: Double) -> ChatProcessTree.Process { .init(pid: pid, started: started) }

    func testAShellCountsOnlyAProcessBornForItAndEachProcessOnce() {
        // AI born at 1 000 s; an MCP server since 1 001 s; two background shells called at 100 s and 200 s later.
        let events = [event(.init(.toolCall, id: "call-a", value: .object([.init("name", .string("Bash"))])), sequence: 1, at: 1_100_000),
                      event(shell("a", tool: "call-a"), sequence: 2, at: 1_100_500),
                      event(.init(.toolCall, id: "call-b", value: .object([.init("name", .string("Bash"))])), sequence: 3, at: 1_200_000),
                      event(shell("b", tool: "call-b"), sequence: 4, at: 1_200_500)]
        let candidates = ChatChildTasks.awaitingProcess(events)
        XCTAssertEqual(candidates.map(\.id), ["a", "b"])
        XCTAssertEqual(candidates.first?.bound, 1_070_000, "no message on record for the turn: 30 s before the call arrived")
        let root = process(10, 1_000_000), mcp = process(11, 1_001_000)
        // Both shells alive: nothing is gone.
        XCTAssertEqual(ChatChildTasks.gone(candidates, tree: .init(root: root, descendants: [mcp, process(12, 1_100_200), process(13, 1_200_100)])), [])
        // Only the MCP server is left: it was born before either command, so both shells are gone.
        XCTAssertEqual(Set(ChatChildTasks.gone(candidates, tree: .init(root: root, descendants: [mcp]))), ["a", "b"])
        // One process born after both calls can be only one of them: the other is gone.
        XCTAssertEqual(ChatChildTasks.gone(candidates, tree: .init(root: root, descendants: [mcp, process(13, 1_200_100)])).count, 1)
        // A task whose finish the AI did report is not a candidate at all.
        let finished = events + [event(.init(.session, value: .object([.init("taskFinished", .string("a")),
            .init("childTask", .object([.init("id", .string("a")), .init("status", .string("completed"))]))])), sequence: 5, at: 1_300_000)]
        XCTAssertEqual(ChatChildTasks.awaitingProcess(finished).map(\.id), ["b"])
    }

    // Release review 0614, finding 2: a busy app received the tool-call line 8 s after the command began.
    func testALateToolCallLineStillCountsItsLiveCommandAndAGoneOneStillClears() {
        // The person's message starts the turn at 1 100 s; the command starts at 1 101 s; its line arrives at 1 109 s.
        let events = [event(.init(.user, value: .object([.init("text", .string("go"))])), sequence: 1, at: 1_100_000),
                      event(.init(.toolCall, id: "call-a", value: .object([.init("name", .string("Bash"))])), sequence: 2, at: 1_109_000),
                      event(shell("a", tool: "call-a"), sequence: 3, at: 1_109_200)]
        let candidates = ChatChildTasks.awaitingProcess(events)
        XCTAssertEqual(candidates.first?.bound, 1_100_000, "the turn's start is the earliest its command can be born")
        let root = process(10, 1_000_000), mcp = process(11, 1_001_000)
        XCTAssertEqual(ChatChildTasks.gone(candidates, tree: .init(root: root, descendants: [mcp, process(12, 1_101_000)])), [],
                       "its command still runs")
        XCTAssertEqual(ChatChildTasks.gone(candidates, tree: .init(root: root, descendants: [mcp])), ["a"], "its process is gone")
    }

    func testNoTaskOutlivesTheAIProcessItRanUnderButARemoteAgentIsNotJudged() {
        let agent = HootChatRecord(.session, value: .object([.init("taskStarted", .string("helper")), .init("childTask", .object([
            .init("id", .string("helper")), .init("kind", .string("local_agent")), .init("status", .string("running"))]))]))
        let remote = HootChatRecord(.session, value: .object([.init("taskStarted", .string("far")), .init("childTask", .object([
            .init("id", .string("far")), .init("kind", .string("remote_agent")), .init("status", .string("running"))]))]))
        let candidates = ChatChildTasks.awaitingProcess([event(agent, sequence: 1, at: 500_000), event(remote, sequence: 2, at: 500_100)])
        XCTAssertEqual(candidates.map(\.id), ["helper"])
        // Still the same AI process: an in-process agent needs no child of its own.
        XCTAssertEqual(ChatChildTasks.gone(candidates, tree: .init(root: process(10, 400_000), descendants: [])), [])
        // A new AI process (born after the agent was last reported): the agent ended with the old one.
        XCTAssertEqual(ChatChildTasks.gone(candidates, tree: .init(root: process(20, 600_000), descendants: [])), ["helper"])
    }
}
