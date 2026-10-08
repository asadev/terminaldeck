import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendHootChatRPCTests: XCTestCase, @unchecked Sendable {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func reply(_ id: NativeRPCValue, _ result: NativeRPCValue) -> NativeRPCValue { .object([.init("id", id), .init("result", result)]) }
    private func ready(_ provider: HootChatProvider, resume: String? = nil) throws -> BackendHootChatRPC {
        var rpc = BackendHootChatRPC(provider: provider, setup: .init(cwd: "/scratch"))
        let request = try rpc.begin(id: "hello", resume: resume)
        let result = provider == .codex ? try json("{}") : try json(#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"mcpCapabilities":{"http":true}}}"#)
        let next = try rpc.receive(reply(request["id"], result)).send.last!
        XCTAssertEqual(next["method"].string, provider == .codex ? (resume == nil ? "thread/start" : "thread/resume") : (resume == nil ? "session/new" : "session/load"))
        let created = provider == .codex ? try json(#"{"thread":{"id":"session","sessionId":"root-session"}}"#) : try json(#"{"sessionId":"session"}"#)
        XCTAssertTrue(try rpc.receive(reply(next["id"], created)).ready)
        return rpc
    }
    func testCodexResumeAndMCPMustPreserveExactConversationAndEveryTool() throws {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch", expectedTools: ["deck-control": ["sessions_list", "tasks_list"]]))
        _ = try rpc.begin(id: "h", resume: "exact")
        let next = try rpc.receive(reply(.string("h"), .object([])))
        XCTAssertEqual(next.send[0]["method"].string, "initialized")
        XCTAssertEqual(next.send[1]["params"]["threadId"].string, "exact")
        let catalog = try rpc.receive(reply(next.send[1]["id"], json(#"{"thread":{"id":"exact"}}"#)))
        XCTAssertFalse(catalog.ready)
        XCTAssertEqual(catalog.send[0]["method"].string, "mcpServerStatus/list")
        XCTAssertThrowsError(try rpc.receive(reply(catalog.send[0]["id"], json(#"{"data":[{"name":"deck-control","tools":{"sessions_list":{}},"runtimeStatus":"ready"}]}"#))))
        var other = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch"))
        _ = try other.begin(id: "h", resume: "exact")
        let session = try other.receive(reply(.string("h"), .object([]))).send.last!
        XCTAssertThrowsError(try other.receive(reply(session["id"], json(#"{"thread":{"id":"wrong"}}"#))))
    }
    func testCodexMCPWaitUsesEventsAndBoundedCursorThenBecomesReady() throws {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch", expectedTools: ["deck-control": ["read"]]))
        _ = try rpc.begin(id: "h", resume: nil)
        let session = try rpc.receive(reply(.string("h"), .object([]))).send.last!
        let catalog = try rpc.receive(reply(session["id"], json(#"{"thread":{"id":"session"}}"#))).send[0]
        XCTAssertFalse(try rpc.receive(reply(catalog["id"], json(#"{"data":[{"name":"deck-control","tools":{},"runtimeStatus":"starting"}]}"#))).ready)
        let refresh = try rpc.receive(json(#"{"method":"mcpServerStatus/updated","params":{"threadId":null,"name":"deck-control","status":"ready"}}"#)).send[0]
        XCTAssertTrue(try rpc.receive(reply(refresh["id"], json(#"{"data":[{"name":"deck-control","tools":{"read":{}},"runtimeStatus":"ready"}]}"#))).ready)
    }
    func testCodexStreamScopesTurnAndFinalTextReplacesDeltas() throws {
        var rpc = try ready(.codex)
        let prompt = try rpc.user("hello", attachments: [], id: "prompt")
        XCTAssertEqual(prompt["params"]["threadId"].string, "session")
        _ = try rpc.receive(reply(.string("prompt"), json(#"{"turn":{"id":"turn"}}"#)))
        let a = try rpc.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"session","turnId":"turn","itemId":"a","delta":"par"}}"#)).records
        let b = try rpc.receive(json(#"{"method":"item/completed","params":{"threadId":"session","turnId":"turn","item":{"id":"a","type":"agentMessage","text":"part"}}}"#)).records
        let foreign = try rpc.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"other","turnId":"turn","itemId":"a","delta":"PRIVATE"}}"#))
        XCTAssertTrue(foreign.records.isEmpty)
        let rows = HootChatProjection.rows((a + b).enumerated().map { .init(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .codex, record: $0.element) })
        XCTAssertEqual(rows[0].value["text"].string, "part")
        let cancel = try rpc.interrupt()
        XCTAssertEqual(cancel["method"].string, "turn/interrupt"); XCTAssertEqual(cancel["params"]["turnId"].string, "turn")
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"turn","status":"completed"}}}"#))
        _ = try rpc.user("next", attachments: [], id: "next")
        XCTAssertTrue(try rpc.receive(json(#"{"method":"item/agentMessage/delta","params":{"threadId":"session","turnId":"turn","itemId":"old","delta":"STALE"}}"#)).records.isEmpty)
    }
    func testCodexNumericApprovalsKeepOriginalIDAndNeverGrantPersistence() throws {
        var rpc = try ready(.codex)
        let request = try rpc.receive(json(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"session","turnId":"t","itemId":"cmd","command":"echo original"}}"#)).records[0]
        XCTAssertEqual(request.messageID, "7")
        let answer = try rpc.answer(request, allowed: true)
        XCTAssertEqual(answer["id"], .number(7)); XCTAssertEqual(answer["result"]["decision"].string, "accept")
        let stringID = try rpc.receive(json(#"{"id":"7","method":"item/fileChange/requestApproval","params":{"threadId":"session","turnId":"t","itemId":"file"}}"#)).records[0]
        XCTAssertNotEqual(request.messageID, stringID.messageID)
        XCTAssertEqual(try rpc.answer(stringID, allowed: false)["result"]["decision"].string, "decline")
        let perms = try rpc.receive(json(#"{"id":8,"method":"item/permissions/requestApproval","params":{"threadId":"session","turnId":"t","permissions":{"network":{"enabled":true}}}}"#)).records[0]
        let grant = try rpc.answer(perms, allowed: true)
        XCTAssertEqual(grant["result"]["scope"].string, "turn")
        XCTAssertEqual(grant["result"]["permissions"]["network"]["enabled"].bool, true)
    }
    func testCodexUserQuestionsNeedAnswersAndUnknownRPCIsDenied() throws {
        var rpc = try ready(.codex)
        let question = try rpc.receive(json(#"{"id":"q","method":"item/tool/requestUserInput","params":{"threadId":"session","turnId":"t","questions":[{"id":"color","header":"Color","question":"Which?"}]}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(question, allowed: true))
        let answered = try rpc.answer(question, allowed: true, answers: json(#"{"color":{"answers":["blue"]}}"#))
        XCTAssertEqual(answered["result"]["answers"]["color"]["answers"].elements?.first?.string, "blue")
        let unknown = try rpc.receive(json(#"{"id":10,"method":"terminal/create","params":{"threadId":"session"}}"#))
        XCTAssertEqual(unknown.send[0]["error"]["code"].number, -32601)
        XCTAssertEqual(unknown.send[0]["id"], .number(10))
        let form = try rpc.receive(json(#"{"id":"form","method":"mcpServer/elicitation/request","params":{"threadId":"session","mode":"form","requestedSchema":{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(form, allowed: true))
        XCTAssertEqual(try rpc.answer(form, allowed: true, answers: json(#"{"name":"Asad"}"#))["result"]["content"]["name"].string, "Asad")
    }
    func testToolOutputStreamsBeforeCompletionAndFinalOutputReplacesIt() throws {
        var rpc = try ready(.codex)
        _ = try rpc.user("run", attachments: [], id: "p")
        _ = try rpc.receive(reply(.string("p"), json(#"{"turn":{"id":"t"}}"#)))
        let start = try rpc.receive(json(#"{"method":"item/started","params":{"threadId":"session","turnId":"t","item":{"id":"tool","type":"commandExecution","command":"run"}}}"#)).records
        let part = try rpc.receive(json(#"{"method":"item/commandExecution/outputDelta","params":{"threadId":"session","turnId":"t","itemId":"tool","delta":"partial"}}"#)).records
        let done = try rpc.receive(json(#"{"method":"item/completed","params":{"threadId":"session","turnId":"t","item":{"id":"tool","type":"commandExecution","command":"run","status":"completed","aggregatedOutput":"whole output"}}}"#)).records
        func rows(_ records: [HootChatRecord]) -> [HootChatRow] { HootChatProjection.rows(records.enumerated().map { .init(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .codex, record: $0.element) }) }
        XCTAssertEqual(rows(start + part)[0].value["output"].string, "partial")
        XCTAssertEqual(rows(start + part)[0].value["finished"].bool, false)
        XCTAssertEqual(rows(start + part + done)[0].value["output"].string, "whole output")
        XCTAssertEqual(rows(start + part + done)[0].value["finished"].bool, true)
    }
    func testGeminiCapabilitiesResumeAndChunksAreTyped() throws {
        var rpc = try ready(.gemini, resume: "session")
        let prompt = try rpc.user("hello", attachments: [], id: "p")
        XCTAssertEqual(prompt["method"].string, "session/prompt")
        let messages = try rpc.receive(json(#"{"method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}}"#)).records
        XCTAssertEqual(messages[0].kind, .textDelta)
        let tool = try rpc.receive(json(#"{"method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"tool_call","toolCallId":"tool","title":"Read","status":"pending","rawInput":{"path":"original"}}}}"#)).records
        XCTAssertEqual(tool[0].value["input"]["path"].string, "original")
        let done = try rpc.receive(json(#"{"method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"tool_call_update","toolCallId":"tool","status":"completed","rawOutput":"contents"}}}"#)).records
        XCTAssertEqual(done[0].value["name"].string, "Read"); XCTAssertEqual(done[1].kind, .toolResult)
        XCTAssertEqual(done[1].value["output"].string, "contents")
        XCTAssertEqual(try rpc.interrupt()["method"].string, "session/cancel")
        XCTAssertEqual(try rpc.receive(reply(.string("p"), json(#"{"stopReason":"cancelled"}"#))).records.map(\.kind), [.interrupted, .completed])
    }
    func testGeminiApprovalsSelectOnlyOfferedOneUseOptions() throws {
        var rpc = try ready(.gemini)
        let request = try rpc.receive(json(#"{"id":42,"method":"session/request_permission","params":{"sessionId":"session","toolCall":{"title":"Write","toolCallId":"t"},"options":[{"kind":"allow_always","optionId":"forever"},{"kind":"allow_once","optionId":"once"},{"kind":"reject_once","optionId":"no"}]}}"#)).records[0]
        XCTAssertEqual(try rpc.answer(request, allowed: true)["result"]["outcome"]["optionId"].string, "once")
        XCTAssertEqual(try rpc.answer(request, allowed: false)["result"]["outcome"]["optionId"].string, "no")
        let persistent = try rpc.receive(json(#"{"id":43,"method":"session/request_permission","params":{"sessionId":"session","options":[{"kind":"allow_always","optionId":"forever"}]}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(persistent, allowed: true))
        XCTAssertEqual(try rpc.answer(persistent, allowed: false)["result"]["outcome"]["outcome"].string, "cancelled")
    }
    func testAuthenticationErrorIsVisibleAndNeverStartsAnotherSession() throws {
        var rpc = BackendHootChatRPC(provider: .gemini, setup: .init(cwd: "/scratch"))
        _ = try rpc.begin(id: "h", resume: "saved")
        let request = try rpc.receive(reply(.string("h"), json(#"{"protocolVersion":1,"agentCapabilities":{"loadSession":true}}"#))).send[0]
        XCTAssertEqual(request["method"].string, "session/load")
        XCTAssertThrowsError(try rpc.receive(json(#"{"id":"h:session","error":{"code":-32000,"message":"Authentication required"}}"#)))
        XCTAssertThrowsError(try rpc.user("hello", attachments: [], id: "p"))
    }
    func testLaunchPlanKeepsToolsInstructionsAndProviderPoliciesWithoutWritingConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-rpc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let mcp = root.appendingPathComponent("mcp.json"), instructions = root.appendingPathComponent("hoot.md")
        try Data(#"{"mcpServers":{"deck-control":{"type":"http","url":"http://127.0.0.1:8765/mcp","headers":{"Authorization":"scratch-only"}}}}"#.utf8).write(to: mcp)
        try Data("Hoot contract".utf8).write(to: instructions)
        let common = ["--mcp-config", mcp.path, "--strict-mcp-config", "--append-system-prompt-file", instructions.path]
        let codex = try BackendHootChatLaunchPlan(provider: .codex, cwd: root.path, sessionID: "saved", extra: ["--model", "chosen", "-c", #"developer_instructions="Profile identity""#] + common, expectedTools: ["read"])
        XCTAssertEqual(codex.arguments, ["app-server", "--stdio"])
        XCTAssertEqual(codex.setup?.session["model"].string, "chosen")
        XCTAssertEqual(codex.setup?.session["developerInstructions"].string, "Profile identity\n\nHoot contract")
        XCTAssertEqual(codex.setup?.session["config"]["mcp_servers"]["deck-control"]["required"].bool, true)
        XCTAssertEqual(codex.setup?.session["config"]["mcp_servers"]["deck-control"]["http_headers"]["Authorization"].string, "scratch-only")
        let gemini = try BackendHootChatLaunchPlan(provider: .gemini, cwd: root.path, sessionID: nil, extra: ["--approval-mode", "plan", "-c", #"developer_instructions="Gemini profile""#] + common)
        XCTAssertEqual(gemini.arguments, ["--acp", "--approval-mode", "plan"])
        XCTAssertEqual(gemini.setup?.instructions, "Gemini profile\n\nHoot contract")
        XCTAssertEqual(gemini.setup?.session["mcpServers"].elements?.first?["headers"].elements?.first?["value"].string, "scratch-only")
        XCTAssertThrowsError(try BackendHootChatLaunchPlan(provider: .codex, cwd: root.path, sessionID: nil, extra: ["--disallowedTools", "Write"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.toml").path))
    }
}
