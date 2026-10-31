import XCTest
@testable import TerminalDeckNativeCore

final class HootChatProtocolTests: XCTestCase {
    func testFragmentedUTF8AndFinalLine() throws {
        let bytes = Data("{\"text\":\"🦉\"}\n{\"text\":\"last\"}".utf8)
        var lines = HootChatJSONLines(), values: [NativeRPCValue] = []
        for byte in bytes { values += try lines.append(Data([byte])) }
        values += try lines.append(Data(), end: true)
        XCTAssertEqual(values.map { $0["text"].string }, ["🦉", "last"])
    }
    func testMalformedAndOversizedLinesFail() {
        var lines = HootChatJSONLines()
        XCTAssertThrowsError(try lines.append(Data("not json\n".utf8)))
        var large = HootChatJSONLines()
        XCTAssertThrowsError(try large.append(Data(repeating: 32, count: HootChatJSONLines.maximumLineBytes + 1)))
    }
    func testClaudeFinalSnapshotReplacesDeltasAndToolResultsMatch() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let input = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"t1","name":"Read","input":{"path":"x"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"contents"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"s1"}"#,
        ]
        let records = try input.flatMap { try decoder.decode(NativeRPCValue.parseJSON(Data($0.utf8))) }
        let events = records.enumerated().map { HootChatEvent(conversationID: "c", turnID: "turn", sequence: $0.offset + 1, provider: .claude, record: $0.element) }
        let rows = HootChatProjection.rows(events)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].value["text"].string, "Hello")
        XCTAssertEqual(rows[1].value["name"].string, "Read")
        XCTAssertEqual(rows[1].value["output"].string, "contents")
        XCTAssertEqual(rows[1].value["finished"].bool, true)
        XCTAssertEqual(records.last?.kind, .completed)
        XCTAssertEqual(try HootChatEvent(wire: events[0].wireValue), events[0])
    }
    func testErrorResultIsNotSuccessfulCompletion() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let value = try NativeRPCValue.parseJSON(Data(#"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#.utf8))
        let records = try decoder.decode(value)
        XCTAssertEqual(records.map(\.kind), [.error, .completed])
        XCTAssertEqual(records[0].value["text"].string, "Not logged in")
    }
    func testCodexItemUpdatesReplaceAndUnknownEventsAreIgnored() throws {
        var decoder = HootChatDecoder(provider: .codex)
        let records = try [
            #"{"type":"thread.started","thread_id":"thread1"}"#,
            #"{"type":"item.updated","item":{"id":"a","type":"agent_message","text":"part"}}"#,
            #"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"complete"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1}}"#,
        ].flatMap { try decoder.decode(NativeRPCValue.parseJSON(Data($0.utf8))) }
        XCTAssertEqual(records.first?.value["sessionId"].string, "thread1")
        let rows = HootChatProjection.rows(records.enumerated().map { .init(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .codex, record: $0.element) })
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].value["text"].string, "complete")
        XCTAssertEqual(try decoder.decode(.object([.init("type", .string("future"))])), [])
    }
    func testApprovalIsTypedAndCancelledByRequestID() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let records = try decoder.decode(NativeRPCValue.parseJSON(Data(#"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"path":"a","text":"b"}}}"#.utf8)))
        XCTAssertEqual(records.first?.kind, .approval)
        XCTAssertEqual(records.first?.messageID, "q1")
        XCTAssertEqual(records.first?.value["input"]["text"].string, "b")
        let cancelled = try decoder.decode(NativeRPCValue.parseJSON(Data(#"{"type":"control_cancel_request","request_id":"q1"}"#.utf8)))
        XCTAssertEqual(cancelled.first?.kind, .approvalResolved)
    }
    func testClaudeApprovalKeepsOfferedPermissionsAndOperationDetailsOutsideToolInput() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let row = try NativeRPCValue.parseJSON(Data(#"{"type":"control_request","request_id":"permission-1","request":{"subtype":"can_use_tool","tool_name":"Bash","tool_use_id":"tool-1","input":{"command":"cat fixture.txt"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"cat fixture.txt"}],"behavior":"allow","destination":"session"}],"blocked_path":"/scratch/fixture.txt","decision_reason":"This path needs approval","decision_reason_type":"rule","description":"Read fixture file","title":"Read fixture","display_name":"Fixture tool","mcp_server":{"name":"fixture-server","source":"project"}}}"#.utf8))
        let record = try XCTUnwrap(decoder.decode(row).first)
        XCTAssertEqual(record.value["input"], row["request"]["input"])
        XCTAssertEqual(record.value["permissionSuggestions"], row["request"]["permission_suggestions"])
        XCTAssertFalse(record.value["input"].has("permissionSuggestions"))
        XCTAssertEqual(record.value["blockedPath"].string, "/scratch/fixture.txt")
        XCTAssertEqual(record.value["reason"].string, "This path needs approval")
        XCTAssertEqual(record.value["decisionReasonType"].string, "rule")
        XCTAssertEqual(record.value["description"].string, "Read fixture file")
        XCTAssertEqual(record.value["title"].string, "Read fixture")
        XCTAssertEqual(record.value["displayName"].string, "Fixture tool")
        XCTAssertEqual(record.value["mcpServer"], row["request"]["mcp_server"])
        XCTAssertEqual(record.value["toolId"].string, "tool-1")
    }
    func testClaudeElicitationNormalizesSchemaAndPreservesRequestIdentity() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let row = try NativeRPCValue.parseJSON(Data(#"{"type":"control_request","request_id":"form-1","request":{"subtype":"elicitation","mcp_server_name":"fixture-server","message":"Choose the fixture settings","requested_schema":{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]},"property_order":["enabled"],"title":"Fixture request","display_name":"Fixture","description":"Review these settings"}}"#.utf8))
        let record = try XCTUnwrap(decoder.decode(row).first)
        XCTAssertEqual(record.kind, .approval)
        XCTAssertEqual(record.messageID, "form-1")
        XCTAssertEqual(record.value["requestId"].string, "form-1")
        XCTAssertEqual(record.value["subtype"].string, "elicitation")
        XCTAssertEqual(record.value["name"].string, "Fixture request")
        let input = record.value["input"]
        XCTAssertEqual(input["serverName"].string, "fixture-server")
        XCTAssertEqual(input["message"].string, "Choose the fixture settings")
        XCTAssertEqual(input["requestedSchema"]["properties"]["enabled"]["type"].string, "boolean")
        XCTAssertTrue(input["mode"].isNullish, "An omitted mode retains the default form semantics.")
        XCTAssertEqual(input["propertyOrder"].elements?.first?.string, "enabled")
        XCTAssertEqual(input["displayName"].string, "Fixture")
        XCTAssertEqual(input["description"].string, "Review these settings")
        let cancelled = try decoder.decode(NativeRPCValue.parseJSON(Data(#"{"type":"control_cancel_request","request_id":"form-1"}"#.utf8)))
        XCTAssertEqual(cancelled.first?.messageID, "form-1")
        XCTAssertEqual(cancelled.first?.kind, .approvalResolved)
    }
    func testClaudeURLElicitationKeepsAuthenticationLinkAndServer() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let row = try NativeRPCValue.parseJSON(Data(#"{"type":"control_request","request_id":"auth-1","request":{"subtype":"elicitation","mcp_server_name":"fixture-server","message":"Connect fixture account","mode":"url","url":"https://auth.example.test/connect","elicitation_id":"fixture-auth"}}"#.utf8))
        let record = try XCTUnwrap(decoder.decode(row).first)
        XCTAssertEqual(record.value["name"].string, "fixture-server")
        XCTAssertEqual(record.value["subtype"].string, "elicitation")
        XCTAssertEqual(record.value["input"]["mode"].string, "url")
        XCTAssertEqual(record.value["input"]["url"].string, "https://auth.example.test/connect")
        XCTAssertEqual(record.value["input"]["elicitationId"].string, "fixture-auth")
    }
    func testResetKeepsWholeLongReplyAndSubagentDeltasStaySeparate() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let inputs = [
            #"{"type":"stream_event","event":{"type":"message_start","message":{"id":"root"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent","event":{"type":"message_start","message":{"id":"child"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"root text"}}}"#,
            #"{"type":"stream_event","parent_tool_use_id":"agent","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"child text"}}}"#,
        ]
        let records = try inputs.flatMap { try decoder.decode(NativeRPCValue.parseJSON(Data($0.utf8))) }
        XCTAssertEqual(records.map(\.messageID), ["root", "child"])
        let long = (1...700).map { HootChatEvent(conversationID: "c", turnID: "t", sequence: $0, provider: .claude, record: .text(.textDelta, id: "m", "a")) }
        let replay = HootChatProjection.snapshotEvents(long)
        XCTAssertEqual(replay.count, 1)
        XCTAssertEqual(replay[0].record.kind, .message)
        XCTAssertEqual(replay[0].record.value["text"].string?.count, 700)
        XCTAssertEqual(replay[0].sequence, 700)
    }
    func testGeminiChunksToolsAndResultsUseSharedEnvelope() throws {
        var decoder = HootChatDecoder(provider: .gemini)
        let records = try [
            #"{"type":"init","session_id":"g1"}"#,
            #"{"type":"message","role":"user","content":"echo"}"#,
            #"{"type":"message","role":"assistant","content":"Hi ","delta":true}"#,
            #"{"type":"message","role":"assistant","content":"there","delta":true}"#,
            #"{"type":"tool_use","tool_id":"t1","tool_name":"read_file","parameters":{"path":"x"}}"#,
            #"{"type":"tool_result","tool_id":"t1","status":"success","output":"contents"}"#,
            #"{"type":"result","status":"success","stats":{"total_tokens":2}}"#,
        ].flatMap { try decoder.decode(NativeRPCValue.parseJSON(Data($0.utf8))) }
        let events = records.enumerated().map { HootChatEvent(conversationID: "c", turnID: "t", sequence: $0.offset + 1, provider: .gemini, record: $0.element) }
        let rows = HootChatProjection.rows(events)
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows[0].value["text"].string, "Hi there")
        XCTAssertEqual(rows[1].value["name"].string, "read_file"); XCTAssertEqual(rows[1].value["output"].string, "contents")
        XCTAssertEqual(records.last?.kind, .completed)
    }
}
