import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderChildrenTests: XCTestCase, @unchecked Sendable {
    private actor Fixture {
        enum Mode: Equatable, Sendable { case normal, identity, folder, parent, tree, conflictingParent, missingParent, descendant, active, temporary, clipped }
        let mode: Mode
        private(set) var calls: [NativeRPCValue] = []
        init(_ mode: Mode = .normal) { self.mode = mode }
        func request(_ method: String, _ params: NativeRPCValue) throws -> NativeRPCValue {
            calls.append(.object([.init("method", .string(method)), .init("params", params)]))
            if method == "thread/read" {
                if params["threadId"].string == "root" {
                    return .object([.init("thread", .object([.init("id", .string("root")), .init("cwd", .string("/project")), .init("sessionId", .string("tree"))]))])
                }
                guard params["threadId"].string == "child" else { throw NativeRPCError.invalidArguments("Unexpected provider thread request") }
                let parent = mode == .parent ? "unowned" : mode == .descendant ? "middle" : "root"
                let source: NativeRPCValue = mode == .missingParent ? .string("appServer") : .object([.init("subAgent", .object([.init("thread_spawn", .object([
                    .init("parent_thread_id", .string(mode == .conflictingParent ? "different" : parent)), .init("depth", .number(1)),
                    .init("agent_path", .string("/root/worker")), .init("env", .string("SECRET_SOURCE_ENV"))]))]))])
                return .object([.init("thread", .object([
                    .init("id", .string(mode == .identity ? "different-child" : "child")), .init("cwd", .string(mode == .folder ? "/outside" : "/project")),
                    .init("sessionId", .string(mode == .tree ? "another-tree" : "tree")),
                    .init("parentThreadId", mode == .missingParent ? .null : .string(parent)), .init("source", source),
                    .init("ephemeral", .bool(mode == .temporary)), .init("status", .object([.init("type", .string(mode == .active ? "active" : "idle"))])),
                    .init("model", .string("configured-model")), .init("modelProvider", .string("openai")),
                    .init("path", .string("/private/provider/transcript")), .init("config", .string("SECRET_CONFIG"))]))])
            }
            guard method == "thread/turns/list", params["threadId"].string == "child" else { throw NativeRPCError.invalidArguments("Unexpected provider child operation") }
            let answer = mode == .clipped ? String(repeating: "😀", count: 20_000) : "Exact child answer"
            return .object([.init("data", .array([.object([.init("id", .string("turn")), .init("itemsView", .string("full")), .init("items", .array([
                .object([.init("type", .string("userMessage")), .init("id", .string("u")), .init("content", .array([.object([.init("type", .string("text")), .init("text", .string("Exact child question"))])]))]),
                .object([.init("type", .string("commandExecution")), .init("id", .string("tool")), .init("aggregatedOutput", .string("SECRET_TOOL_PAYLOAD"))]),
                .object([.init("type", .string("agentMessage")), .init("id", .string("a")), .init("text", .string(answer))])
            ]))])])), .init("nextCursor", .string("page-two"))])
        }
    }
    private func task(parent: String? = "root") -> NativeRPCValue { ChatChildTasks.codexAgent("child", status: "completed", parentThreadId: parent) }
    private func args(_ fields: [NativeRPCValue.Field] = []) -> NativeRPCValue { .object([.init("taskId", .string("codex:child"))] + fields) }
    private func call(_ operation: String, fixture: Fixture, args: NativeRPCValue? = nil,
                      tasks: [NativeRPCValue]? = nil, provider: HootChatProvider = .codex) async throws -> NativeRPCValue {
        try await BackendChatProviderChildren.invoke(operation: operation, args: args ?? self.args(), provider: provider,
            conversation: "root", cwd: "/project", ownedTasks: tasks ?? [task()]) { method, params in try await fixture.request(method, params) }
    }

    func testListUsesEmittedIdentityAndMetadataWithoutProviderRequests() async throws {
        let fixture = Fixture()
        let tasks = [task().setting("appTaskId", .string("app-task")), ChatChildTasks.codexAgent("unknown-parent", status: "running"),
                     NativeRPCValue.object([.init("id", .string("shell")), .init("kind", .string("shell")), .init("status", .string("running"))])]
        let result = try await call("children/list", fixture: fixture, args: .object([]), tasks: tasks)
        let items = try XCTUnwrap(result["items"].elements)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0]["parentThreadId"].string, "root")
        XCTAssertEqual(items[0]["appTaskId"].string, "app-task")
        XCTAssertTrue(items[1]["parentThreadId"].isNullish)
        XCTAssertEqual(items[2]["canRead"].bool, false)
        let calls = await fixture.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testReadVerifiesExactChildAndProducesBoundedTextOnlyPage() async throws {
        let fixture = Fixture()
        let result = try await call("children/read", fixture: fixture, args: args([.init("cursor", .string("page-one")), .init("limit", .number(5))]))
        XCTAssertEqual(result["conversationId"].string, "child")
        XCTAssertEqual(result["parentThreadId"].string, "root")
        XCTAssertEqual(result["messages"].elements?.compactMap { $0["text"].string }, ["Exact child question", "Exact child answer"])
        XCTAssertEqual(result["nextCursor"].string, "page-two")
        XCTAssertFalse(result.compact.contains("SECRET_"))
        XCTAssertFalse(result.compact.contains("/private/provider/transcript"))
        XCTAssertEqual(result["thread"]["configuredModel"].string, "configured-model")
        let calls = await fixture.calls
        XCTAssertEqual(calls.map { $0["method"].string }, ["thread/read", "thread/read", "thread/turns/list"])
        XCTAssertEqual(calls.last?["params"]["threadId"].string, "child")
        XCTAssertEqual(calls.last?["params"]["cursor"].string, "page-one")
        XCTAssertEqual(calls.last?["params"]["limit"].number, 5)
    }

    func testCallerCannotSupplyArbitraryThreadPathOrUnknownTask() async throws {
        for arguments in [args([.init("threadId", .string("other"))]), args([.init("path", .string("/tmp/private"))]),
                          NativeRPCValue.object([.init("taskId", .string("codex:not-owned"))]), args([.init("limit", .number(51))])] {
            let fixture = Fixture()
            do { _ = try await call("children/read", fixture: fixture, args: arguments); XCTFail("Unowned child input was accepted") } catch { }
            let calls = await fixture.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testIdentityFolderTreeAndReportedParentMismatchesFailClosed() async throws {
        for mode in [Fixture.Mode.identity, .folder, .tree, .parent, .conflictingParent] {
            let fixture = Fixture(mode)
            do { _ = try await call("children/read", fixture: fixture); XCTFail("A mismatched child was returned") } catch { }
            let calls = await fixture.calls
            XCTAssertFalse(calls.contains { $0["method"].string == "thread/turns/list" })
        }
        let missing = try await call("children/read", fixture: Fixture(.missingParent), tasks: [task(parent: nil)])
        XCTAssertTrue(missing["parentThreadId"].isNullish)
        XCTAssertTrue(missing["parentVerification"].string?.hasPrefix("not-reported") == true)
        let middle = ChatChildTasks.codexAgent("middle", status: "completed", parentThreadId: "root")
        let nested = try await call("children/read", fixture: Fixture(.descendant), tasks: [middle, task(parent: "middle")])
        XCTAssertEqual(nested["parentThreadId"].string, "middle")
    }

    func testResumeReturnsOwnedLaunchFactsWithoutResumingOrPromptingParentPipe() async throws {
        let fixture = Fixture()
        let result = try await call("children/resume", fixture: fixture)
        XCTAssertEqual(result["prepared"].bool, true)
        XCTAssertEqual(result["resumed"].bool, false)
        XCTAssertEqual(result["resume"]["conversationId"].string, "child")
        XCTAssertEqual(result["resume"]["requiresOwnedLaunch"].bool, true)
        XCTAssertEqual(result["resume"]["requiresConfirmedResume"].bool, true)
        let calls = await fixture.calls
        XCTAssertEqual(calls.map { $0["method"].string }, ["thread/read", "thread/read"])
        for mode in [Fixture.Mode.active, .temporary] {
            do { _ = try await call("children/resume", fixture: Fixture(mode)); XCTFail("Active or ephemeral child prepared for another owner") } catch { }
        }
    }

    func testClaudeTranscriptPathsAreNeverOpenedAndClippedUnicodeStaysValid() async throws {
        let fixture = Fixture()
        let child = NativeRPCValue.object([.init("id", .string("codex:child")), .init("kind", .string("agent")), .init("outputFile", .string("/private/transcript"))])
        do { _ = try await call("children/read", fixture: fixture, tasks: [child], provider: .claude); XCTFail("Unverified Claude child transcript accepted") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable") }
        let calls = await fixture.calls
        XCTAssertTrue(calls.isEmpty)
        let result = try await call("children/read", fixture: Fixture(.clipped))
        let text = try XCTUnwrap(result["messages"].elements?.last?["text"].string)
        XCTAssertLessThanOrEqual(text.utf8.count, 32_768)
        XCTAssertFalse(text.contains("�"))
        XCTAssertEqual(result["textClipped"].bool, true)
    }

    func testCorePreservesOnlyReportedParentAndTaskMetadata() throws {
        let item = try NativeRPCValue.parseJSON(Data(#"{"type":"subAgentActivity","agentThreadId":"child","kind":"started","agentPath":"/root/worker","parentThreadId":"actual-parent","source":{"subAgent":{"thread_spawn":{"parent_thread_id":"actual-parent","depth":1}}}}"#.utf8))
        let child = try XCTUnwrap(ChatChildTasks.codexAgents(item).first)
        XCTAssertEqual(child["parentThreadId"].string, "actual-parent")
        XCTAssertEqual(child["agentPath"].string, "/root/worker")
        let collab = try NativeRPCValue.parseJSON(Data(#"{"type":"collabAgentToolCall","tool":"sendInput","senderThreadId":"sender","receiverThreadIds":["child"],"agentsStates":{"child":{"status":"running"}}}"#.utf8))
        let target = try XCTUnwrap(ChatChildTasks.codexAgents(collab).first)
        XCTAssertEqual(target["senderThreadId"].string, "sender")
        XCTAssertTrue(target["parentThreadId"].isNullish, "A sender is not automatically a parent")
        var decoder = HootChatDecoder(provider: .claude)
        let records = try decoder.decode(.parseJSON(Data(#"{"type":"system","subtype":"task_started","task_id":"child","task_type":"agent","parent_task_id":"parent","app_task_id":"app-task","parent_tool_use_id":"tool-only"}"#.utf8)))
        XCTAssertEqual(records.first?.value["childTask"]["parentTaskId"].string, "parent")
        XCTAssertEqual(records.first?.value["childTask"]["appTaskId"].string, "app-task")
        XCTAssertTrue(records.first?.value["childTask"]["parentThreadId"].isNullish == true)
    }
}
