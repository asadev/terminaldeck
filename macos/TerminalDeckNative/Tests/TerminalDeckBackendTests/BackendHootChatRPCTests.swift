import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendHootChatRPCTests: XCTestCase, @unchecked Sendable {
    func testCodexReportedUsageKeepsThreadTotalsAndDoesNotInventCost() throws {
        var rpc = try ready(.codex)
        let update = try rpc.receive(json(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"session","tokenUsage":{"total":{"inputTokens":100,"outputTokens":20,"totalTokens":120},"last":{"inputTokens":10,"outputTokens":2,"totalTokens":12}}}}"#))
        let report = try XCTUnwrap(update.records.first(where: { $0.value["cliUsage"].fields != nil }))
        XCTAssertEqual(report.value["cliUsage"]["totalTokens"].number, 120)
        XCTAssertEqual(report.value["cliUsage"]["scope"].string, "Conversation total")
        XCTAssertTrue(report.value["cliUsage"]["costUSD"].isNullish)
        XCTAssertTrue(try rpc.receive(json(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"other","tokenUsage":{"total":{"totalTokens":999}}}}"#)).records.isEmpty)
    }
    func testFinishedChildRetainsAuthorityForAResumedTurn() throws {
        var rpc = try ready(.codex)
        let started = try rpc.receive(json(#"{"method":"thread/started","params":{"thread":{"id":"child","parentThreadId":"session"}}}"#))
        XCTAssertEqual(started.records.count, 1)
        let finished = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"status":"completed"}}}"#))
        XCTAssertEqual(finished.records.count, 1)
        let resumed = try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"child","turn":{"status":"inProgress"}}}"#))
        XCTAssertEqual(resumed.records.first?.value["childTask"]["status"].string, "running")
        XCTAssertEqual(try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"child","turn":{"status":"completed"}}}"#)).records.count, 1)
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/started","params":{"threadId":"foreign","turn":{"status":"inProgress"}}}"#)).records.isEmpty)
    }
    func testRetiredTurnWindowKeepsRecentDuplicatesAndDropsOldIDs() throws {
        var rpc = try ready(.codex)
        func started(_ id: String) -> NativeRPCValue {
            .object([.init("method", .string("turn/started")), .init("params", .object([
                .init("threadId", .string("session")), .init("turn", .object([.init("id", .string(id)), .init("status", .string("inProgress"))]))]))])
        }
        for index in 0..<260 {
            let id = "provider-\(index)"
            XCTAssertFalse(try rpc.receive(started(id)).records.isEmpty)
            _ = try rpc.receive(.object([.init("method", .string("turn/completed")), .init("params", .object([
                .init("threadId", .string("session")), .init("turn", .object([.init("id", .string(id)), .init("status", .string("completed"))]))]))]))
        }
        XCTAssertTrue(try rpc.receive(started("provider-259")).records.isEmpty)
        XCTAssertFalse(try rpc.receive(started("provider-0")).records.isEmpty)
    }
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
    func testCodexNegotiatesCapabilityForNormalAndPlanningTurns() throws {
        for (text, mode) in [("hello", "default"), ("/plan check menus", "plan")] {
            var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch"))
            let hello = try rpc.begin(id: "hello", resume: nil)
            XCTAssertEqual(hello["params"]["capabilities"]["experimentalApi"].bool, true)
            let session = try rpc.receive(reply(hello["id"], .object([]))).send.last!
            _ = try rpc.receive(reply(session["id"], json(#"{"thread":{"id":"session"},"model":"test-model"}"#)))
            let turn = try rpc.user(text, attachments: [], id: "turn")
            XCTAssertEqual(turn["params"]["collaborationMode"]["mode"].string, mode)
            XCTAssertEqual(turn["params"]["collaborationMode"]["settings"]["model"].string, "test-model")
        }
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
    func testCodexDedicatedPlanItemsReplaceDeltasAndHoldForReview() throws {
        var rpc = try ready(.codex)
        _ = try rpc.user("/plan revise", attachments: [], id: "p")
        _ = try rpc.receive(reply(.string("p"), json(#"{"turn":{"id":"turn"}}"#)))
        let delta = try rpc.receive(json(#"{"method":"item/plan/delta","params":{"threadId":"session","turnId":"turn","itemId":"plan","delta":"draft"}}"#)).records
        let final = try rpc.receive(json(#"{"method":"item/completed","params":{"threadId":"session","turnId":"turn","item":{"type":"plan","id":"plan","text":"1. Read\n2. Explain"}}}"#)).records
        let done = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"turn","status":"completed"}}}"#)).records
        let records = [HootChatRecord.text(.user, "/plan revise")] + delta + final + done
        let events = records.enumerated().map { HootChatEvent(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .codex, record: $0.element) }
        XCTAssertEqual(HootChatProjection.rows(events).last?.value["text"].string, "1. Read\n2. Explain")
        XCTAssertEqual(BackendChatPlans.pending(events: events, busy: false, provider: .codex)?["input"]["plan"].string, "1. Read\n2. Explain")
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
    func testCodexApprovalWireUsesOnlyOfferedCommandScopesAndExactAmendments() throws {
        var rpc = try ready(.codex)
        let command = try rpc.receive(json(#"{"id":72,"method":"item/commandExecution/requestApproval","params":{"threadId":"session","command":"cat fixture.txt","availableDecisions":["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["cat","fixture.txt"]}},"decline"]}}"#)).records[0]
        XCTAssertEqual(try rpc.answer(command, allowed: true)["result"]["decision"].string, "accept")
        let session = try rpc.answer(command, allowed: true, answers: json(#"{"scope":"session"}"#))
        XCTAssertEqual(session["id"], .number(72))
        XCTAssertEqual(session["result"]["decision"].string, "acceptForSession")
        let amendment = try rpc.answer(command, allowed: true, answers: json(#"{"scope":"decision:2"}"#))
        XCTAssertEqual(amendment["result"]["decision"], command.value["input"]["availableDecisions"].elements![2])
        XCTAssertThrowsError(try rpc.answer(command, allowed: true, answers: json(#"{"scope":"decision:99"}"#)))
        XCTAssertThrowsError(try rpc.answer(command, allowed: false, answers: json(#"{"comment":"Unsupported Codex comment"}"#)))
        let legacy = try rpc.receive(json(#"{"id":"legacy-command","method":"item/commandExecution/requestApproval","params":{"threadId":"session","command":"cat fixture.txt"}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(legacy, allowed: true, answers: json(#"{"scope":"session"}"#)))
    }
    func testCodexPermissionAndFileApprovalScopesReachTheirDistinctWireContracts() throws {
        var rpc = try ready(.codex)
        let permissions = try rpc.receive(json(#"{"id":"permissions-scoped","method":"item/permissions/requestApproval","params":{"threadId":"session","permissions":{"network":{"enabled":true},"fileSystem":{"read":["/scratch/fixture"]}}}}"#)).records[0]
        let turn = try rpc.answer(permissions, allowed: true)
        XCTAssertEqual(turn["result"]["scope"].string, "turn")
        let session = try rpc.answer(permissions, allowed: true, answers: json(#"{"scope":"session"}"#))
        XCTAssertEqual(session["result"]["scope"].string, "session")
        XCTAssertEqual(session["result"]["permissions"], permissions.value["input"]["permissions"])
        XCTAssertEqual(try rpc.answer(permissions, allowed: false)["result"]["permissions"], .object([]))
        let file = try rpc.receive(json(#"{"id":"files-scoped","method":"item/fileChange/requestApproval","params":{"threadId":"session","itemId":"fixture-edit"}}"#)).records[0]
        XCTAssertEqual(try rpc.answer(file, allowed: true)["result"]["decision"].string, "accept")
        XCTAssertEqual(try rpc.answer(file, allowed: true, answers: json(#"{"scope":"session"}"#))["result"]["decision"].string, "acceptForSession")
        XCTAssertThrowsError(try rpc.answer(file, allowed: false, answers: json(#"{"comment":"Unsupported comment"}"#)))
    }
    func testGeminiApprovalWirePreservesOfferedRememberOptionAndRejectsMadeUpScope() throws {
        var rpc = try ready(.gemini)
        let request = try rpc.receive(json(#"{"id":73,"method":"session/request_permission","params":{"sessionId":"session","toolCall":{"title":"Fixture operation","toolCallId":"fixture-tool"},"options":[{"optionId":"opaque-once/7","name":"Allow fixture once","kind":"allow_once"},{"optionId":"opaque-remember/8","name":"Remember fixture rule","kind":"allow_always"},{"optionId":"opaque-deny/9","name":"Decline fixture","kind":"reject_once"}]}}"#)).records[0]
        let once = try rpc.answer(request, allowed: true)
        XCTAssertEqual(once["result"]["outcome"]["optionId"].string, "opaque-once/7")
        let remembered = try rpc.answer(request, allowed: true, answers: json(#"{"scope":"opaque-remember/8"}"#))
        XCTAssertEqual(remembered["id"], .number(73))
        XCTAssertEqual(remembered["result"]["outcome"]["outcome"].string, "selected")
        XCTAssertEqual(remembered["result"]["outcome"]["optionId"].string, "opaque-remember/8")
        XCTAssertFalse(remembered["result"].has("scope"))
        XCTAssertEqual(try rpc.answer(request, allowed: false)["result"]["outcome"]["optionId"].string, "opaque-deny/9")
        XCTAssertThrowsError(try rpc.answer(request, allowed: true, answers: json(#"{"scope":"session"}"#)))
        XCTAssertThrowsError(try rpc.answer(request, allowed: true, answers: json(#"{"scope":"opaque-deny/9"}"#)))
        XCTAssertThrowsError(try rpc.answer(request, allowed: false, answers: json(#"{"comment":"Unsupported ACP comment"}"#)))
    }
    func testGeminiDuplicatePermissionIDsCancelInsteadOfEmittingAmbiguousDenial() throws {
        var rpc = try ready(.gemini)
        let request = try rpc.receive(json(#"{"id":"duplicate-options","method":"session/request_permission","params":{"sessionId":"session","toolCall":{"title":"Fixture operation","toolCallId":"fixture-tool"},"options":[{"optionId":"same-id","name":"Allow once","kind":"allow_once"},{"optionId":"same-id","name":"Decline","kind":"reject_once"}]}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(request, allowed: true))
        let denied = try rpc.answer(request, allowed: false)
        XCTAssertEqual(denied["result"]["outcome"]["outcome"].string, "cancelled")
        XCTAssertFalse(denied["result"]["outcome"].has("optionId"))
    }
    func testCodexElicitationURLResponseHasNoFormContentAndKeepsNumericID() throws {
        var rpc = try ready(.codex)
        let request = try rpc.receive(json(#"{"id":91,"method":"mcpServer/elicitation/request","params":{"threadId":"session","turnId":null,"serverName":"fixture","mode":"url","message":"Connect the fixture account","url":"https://auth.example.test/connect","elicitationId":"auth-fixture"}}"#)).records[0]
        let accepted = try rpc.answer(request, allowed: true, answers: json(#"{"mustNotBeSent":"fixture"}"#))
        XCTAssertEqual(accepted["id"], .number(91))
        XCTAssertEqual(accepted["result"]["action"].string, "accept")
        XCTAssertEqual(accepted["result"]["content"], .null)
        let declined = try rpc.answer(request, allowed: false)
        XCTAssertEqual(declined["result"]["action"].string, "decline")
        XCTAssertEqual(declined["result"]["content"], .null)
    }
    func testCodexElicitationRejectsScalarAnswersUnknownModesAndUnsafeAuthLinks() throws {
        var rpc = try ready(.codex)
        let form = try rpc.receive(json(#"{"id":"form-scalar","method":"mcpServer/elicitation/request","params":{"threadId":"session","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(form, allowed: true, answers: .string("Asad")))
        let unknown = try rpc.receive(json(#"{"id":"unknown-mode","method":"mcpServer/elicitation/request","params":{"threadId":"session","mode":"future-mode","requestedSchema":{"type":"object"}}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(unknown, allowed: true))
        XCTAssertEqual(try rpc.answer(unknown, allowed: false)["result"]["action"].string, "decline")
        let unsafe = try rpc.receive(json(#"{"id":"unsafe-auth","method":"mcpServer/elicitation/request","params":{"threadId":"session","mode":"url","url":"file:///tmp/auth"}}"#)).records[0]
        XCTAssertThrowsError(try rpc.answer(unsafe, allowed: true))
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
