import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend

final class BackendCodexChildTasksTests: XCTestCase {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func reply(_ id: NativeRPCValue, _ result: NativeRPCValue) -> NativeRPCValue { .object([.init("id", id), .init("result", result)]) }
    private func ready() throws -> BackendHootChatRPC {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch"))
        let hello = try rpc.begin(id: "hello", resume: nil)
        let session = try XCTUnwrap(rpc.receive(reply(hello["id"], .object([]))).send.last)
        XCTAssertTrue(try rpc.receive(reply(session["id"], json(#"{"thread":{"id":"session"}}"#))).ready)
        return rpc
    }
    func testCodexChildThreadsUseAuthoritativeParentLinksAndLateLifecycle() throws {
        var rpc = try ready()
        XCTAssertTrue(try rpc.receive(json(#"{"method":"thread/started","params":{"thread":{"id":"foreign","parentThreadId":"another-root"}}}"#)).records.isEmpty)
        let started = try rpc.receive(json(#"{"method":"thread/started","params":{"thread":{"id":"child","parentThreadId":"session","agentNickname":"Worker"}}}"#)).records
        XCTAssertEqual(started.first?.value["childTask"]["threadId"].string, "child")
        XCTAssertEqual(started.first?.value["childTask"]["title"].string, "Worker")
        XCTAssertEqual(started.first?.value["childTask"]["canStop"].bool, true)
        _ = try rpc.user("work", attachments: [], id: "p")
        _ = try rpc.receive(reply(.string("p"), json(#"{"turn":{"id":"parent-turn"}}"#)))
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"parent-turn","status":"interrupted"}}}"#))
        let stopped = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"id":"child-turn","status":"interrupted"}}}"#)).records
        XCTAssertEqual(stopped.first?.value["childTask"]["status"].string, "stopped")
        let resumed = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"child","turn":{"id":"next-child-turn"}}}"#)).records
        XCTAssertEqual(resumed.first?.value["childTask"]["status"].string, "running")
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"foreign","turn":{"status":"completed"}}}"#)).records.isEmpty)
        let activity = try rpc.receive(json(#"{"method":"item/completed","params":{"threadId":"session","turnId":"parent-turn","item":{"type":"subAgentActivity","id":"activity","kind":"completed","agentThreadId":"child"}}}"#)).records
        XCTAssertEqual(activity.first?.value["childTask"]["status"].string, "completed")
        XCTAssertTrue(try rpc.receive(json(#"{"method":"item/completed","params":{"threadId":"foreign","item":{"type":"subAgentActivity","kind":"started","agentThreadId":"private"}}}"#)).records.isEmpty)
    }
    func testCodexChildIDsSurviveEmptyReceiverLists() throws {
        var rpc = try ready()
        _ = try rpc.user("work", attachments: [], id: "p")
        _ = try rpc.receive(reply(.string("p"), json(#"{"turn":{"id":"turn"}}"#)))
        let records = try rpc.receive(json(#"{"method":"item/completed","params":{"threadId":"session","turnId":"turn","item":{"type":"collabAgentToolCall","id":"wait","tool":"wait","receiverThreadIds":[],"agentsStates":{"child":{"status":"pendingInit"}}}}}"#)).records
        let task = try XCTUnwrap(records.first(where: { $0.kind == .session })?.value["childTask"])
        XCTAssertEqual(task["threadId"].string, "child")
        XCTAssertEqual(task["status"].string, "pending")
        XCTAssertTrue(ChatChildTasks.running(task))
        let completed = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"status":"completed"}}}"#)).records
        XCTAssertEqual(completed.first?.value["childTask"]["status"].string, "completed")
    }
    func testCompletedChildHistoryIsBoundedWithoutLosingActiveThreads() throws {
        var rpc = try ready()
        func notice(_ method: String, _ id: String, parent: String? = nil) -> NativeRPCValue {
            let params: NativeRPCValue
            if let parent {
                params = .object([.init("thread", .object([.init("id", .string(id)), .init("parentThreadId", .string(parent))]))])
            } else {
                params = .object([.init("threadId", .string(id)), .init("turn", .object([.init("id", .string("turn")), .init("status", .string("completed"))]))])
            }
            return .object([.init("method", .string(method)), .init("params", params)])
        }
        _ = try rpc.receive(notice("thread/started", "active", parent: "session"))
        for index in 0...256 {
            let id = "closed-\(index)"
            _ = try rpc.receive(notice("thread/started", id, parent: "session"))
            _ = try rpc.receive(notice("turn/completed", id))
        }
        XCTAssertTrue(try rpc.receive(notice("turn/started", "closed-0")).records.isEmpty)
        XCTAssertTrue(try rpc.receive(notice("thread/started", "foreign-child", parent: "closed-0")).records.isEmpty)
        XCTAssertFalse(try rpc.receive(notice("thread/started", "descendant", parent: "closed-255")).records.isEmpty)
        XCTAssertEqual(try rpc.receive(notice("turn/started", "closed-256")).records.first?.value["childTask"]["status"].string, "running")
        for _ in 0..<4 {
            _ = try rpc.receive(notice("thread/started", "cycling", parent: "session"))
            _ = try rpc.receive(notice("turn/completed", "cycling"))
        }
        for index in 0..<255 {
            let id = "later-\(index)"
            _ = try rpc.receive(notice("thread/started", id, parent: "session"))
            _ = try rpc.receive(notice("turn/completed", id))
        }
        XCTAssertEqual(try rpc.receive(notice("turn/started", "cycling")).records.first?.value["childTask"]["status"].string, "running")
        XCTAssertEqual(try rpc.receive(notice("turn/started", "active")).records.first?.value["childTask"]["status"].string, "running")
        XCTAssertTrue(try rpc.receive(notice("turn/started", "never-seen")).records.isEmpty)
    }

}
