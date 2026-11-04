import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CodexApprovalFormTests: XCTestCase, @unchecked Sendable {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func form(_ schema: String = #"{"type":"object","properties":{}}"#, tagged: Bool = true) throws -> NativeRPCValue {
        try json(#"{"subtype":"mcpServer/elicitation/request","input":{"mode":"form","serverName":"deck-control","message":"Allow the deck-control MCP server to run tool \"tools_run\"?","requestedSchema":\#(schema),"_meta":\#(tagged ? #"{"codex_approval_kind":"mcp_tool_call"}"# : "{}")}}"#)
    }
    private func ready() throws -> BackendHootChatRPC {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch"))
        _ = try rpc.begin(id: "h", resume: nil)
        let next = try rpc.receive(json(#"{"id":"h","result":{}}"#)).send.last!
        _ = try rpc.receive(.object([.init("id", next["id"]), .init("result", try json(#"{"thread":{"id":"fixture"}}"#))]))
        return rpc
    }
    func testBypassFooterAndLaunchOverrideAllAttachedMCPPoliciesWithoutWideningTools() throws {
        let args = BackendSessionChats.withChoices([], provider: .codex, choices: ["permission": "danger-full-access"])
        XCTAssertEqual(args, ["--sandbox", "danger-full-access", "--ask-for-approval", "never"])
        // Include the stale policy written by the old footer: full access must still mean never.
        let plan = try BackendHootChatLaunchPlan(provider: .codex, cwd: "/scratch", sessionID: nil,
            extra: ["--sandbox", "danger-full-access", "--ask-for-approval", "on-request"], privateDirectory: nil)
        XCTAssertEqual(plan.setup?.session["sandbox"].string, "danger-full-access")
        XCTAssertEqual(plan.setup?.session["approvalPolicy"].string, "never")
        XCTAssertEqual(plan.setup?.session["config"]["approval_policy"].string, "never")
        XCTAssertEqual(plan.setup?.session["config"]["sandbox_mode"].string, "danger-full-access")
        let original = try json(#"{"sandbox":"danger-full-access","approvalPolicy":"on-request","config":{"mcp_servers":{"deck-control":{"url":"http://localhost/fixture","disabled_tools":["forbidden"],"tools":{"tools_run":{"approval_mode":"prompt","enabled":false}}},"another-server":{"command":"fixture","enabled":false}}}}"#)
        let mapped = BackendCodexApprovalPolicy.session(original)
        for server in ["deck-control", "another-server"] {
            XCTAssertEqual(mapped["config"]["mcp_servers"][server]["default_tools_approval_mode"].string, "approve")
        }
        XCTAssertEqual(mapped["config"]["mcp_servers"]["deck-control"]["tools"]["tools_run"]["approval_mode"].string, "approve")
        XCTAssertEqual(mapped["config"]["mcp_servers"]["deck-control"]["disabled_tools"], original["config"]["mcp_servers"]["deck-control"]["disabled_tools"])
        XCTAssertEqual(mapped["config"]["mcp_servers"]["deck-control"]["tools"]["tools_run"]["enabled"].bool, false)
        XCTAssertEqual(mapped["config"]["mcp_servers"]["another-server"]["enabled"].bool, false)
        XCTAssertTrue(BackendHootChatStore.autoAllows(mode: "danger-full-access", provider: .codex, request: try form()))
    }
    func testAskExplicitlyReplacesInheritedNeverAndKeepsMCPAsking() throws {
        let args = BackendSessionChats.withChoices(["--sandbox", "danger-full-access", "--ask-for-approval", "never"], provider: .codex, choices: ["permission": "default"])
        XCTAssertEqual(args, ["--ask-for-approval", "on-request"])
        let plan = try BackendHootChatLaunchPlan(provider: .codex, cwd: "/scratch", sessionID: nil, extra: args, privateDirectory: nil)
        XCTAssertEqual(plan.setup?.session["approvalPolicy"].string, "on-request")
        XCTAssertEqual(plan.setup?.session["config"]["approval_policy"].string, "on-request")
        let mapped = BackendCodexApprovalPolicy.session(try json(#"{"approvalPolicy":"on-request","config":{"mcp_servers":{"other":{"tools":{"write":{"approval_mode":"approve"}}}}}}"#))
        XCTAssertEqual(mapped["config"]["mcp_servers"]["other"]["default_tools_approval_mode"].string, "prompt")
        XCTAssertEqual(mapped["config"]["mcp_servers"]["other"]["tools"]["write"]["approval_mode"].string, "prompt")
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "default", provider: .codex, request: try form()))
    }
    func testCurrentEmptySubmitApprovesOnceAndLogsTheRequestKind() async throws {
        var rpc = try ready()
        let request = try form()["input"].setting("threadId", .string("fixture"))
        let update = try rpc.receive(.object([.init("id", .number(7)), .init("method", .string("mcpServer/elicitation/request")), .init("params", request)]))
        let record = try XCTUnwrap(update.records.first)
        XCTAssertEqual(record.value["requestKind"].string, "mcp-tool-approval")
        XCTAssertEqual(BackendChatElicitation.title(record.value), "Permission")
        try await BackendChatElicitation.validate(record.value, answers: .object([]))
        let accepted = try rpc.answer(record, allowed: true)
        XCTAssertEqual(accepted["result"]["action"].string, "accept")
        XCTAssertEqual(accepted["result"]["content"], .object([]))
        XCTAssertFalse(accepted["result"].has("_meta"), "No session/always persistence is requested by {}.")
        XCTAssertEqual(try rpc.answer(record, allowed: false)["result"]["action"].string, "decline")
    }
    func testOnlyTaggedPermissionsBypassNeverRealQuestionsOrSignIn() throws {
        let genuine = try form(tagged: false)
        XCTAssertEqual(BackendChatElicitation.title(genuine), "Question from deck-control")
        XCTAssertEqual(BackendChatElicitation.requestKind(genuine), "elicitation")
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "danger-full-access", provider: .codex, request: genuine), "Question wording must not grant permission.")
        let auth = try json(#"{"subtype":"mcpServer/elicitation/request","input":{"mode":"url","url":"https://example.test/sign-in","_meta":{"codex_approval_kind":"mcp_tool_call"}}}"#)
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "danger-full-access", provider: .codex, request: auth))
    }
    func testTypedFieldsKeepEnumBooleanStringAndNumberWireValues() async throws {
        let request = try form(#"{"type":"object","required":["color","allow","name","count"],"properties":{"color":{"type":"string","enum":["blue","green"]},"allow":{"type":"boolean"},"name":{"type":"string"},"count":{"type":"integer"}}}"#, tagged: false)
        let values = try BackendChatElicitation.answers(request, text: ["name": "Asad", "count": "0"], selected: json(#"{"color":"green","allow":false}"#))
        XCTAssertEqual(values, try json(#"{"color":"green","allow":false,"name":"Asad","count":0}"#))
        try await BackendChatElicitation.validate(request, answers: values)
    }
    func testClaudeAndCodexQuestionsUseSameFieldsAndPreserveTheirOwnReplyFormats() throws {
        for claude in [false, true] {
            let request = try json(claude
                ? #"{"name":"AskUserQuestion","input":{"questions":[{"header":"Destination","question":"Where should it go?","options":[{"label":"Dubai","description":"Local"}]}]}}"#
                : #"{"subtype":"item/tool/requestUserInput","input":{"questions":[{"id":"destination","header":"Destination","question":"Where should it go?","options":[{"label":"Dubai","description":"Local"}]}]}}"#)
            let field = try XCTUnwrap(BackendChatElicitation.fields(request).first)
            XCTAssertEqual(field.title, "Destination")
            XCTAssertEqual(field.choiceTitle(0), "Dubai")
            let values = try BackendChatElicitation.answers(request, text: [:], selected: .object([.init(field.id, .string("Dubai"))]))
            try BackendChatQuestions.validate(request, answers: values)
            XCTAssertEqual(claude ? values[field.id].string : values[field.id]["answers"].elements?.first?.string, "Dubai")
            XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "danger-full-access", provider: .codex, request: request))
        }
    }
}
