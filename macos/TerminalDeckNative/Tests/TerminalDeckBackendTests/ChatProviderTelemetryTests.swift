import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderTelemetryTests: XCTestCase, @unchecked Sendable {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func ready(_ provider: HootChatProvider = .codex) throws -> BackendHootChatRPC {
        var rpc = BackendHootChatRPC(provider: provider, setup: .init(cwd: "/scratch", session: .object([.init("model", .string("saved-model"))])))
        let hello = try rpc.begin(id: "hello", resume: nil)
        let initialized = provider == .codex ? NativeRPCValue.object([]) : try json(#"{"protocolVersion":1,"agentCapabilities":{}}"#)
        let start = try rpc.receive(.object([.init("id", hello["id"]), .init("result", initialized)])).send.last!
        let result = provider == .codex ? try json(#"{"thread":{"id":"session","model":"configured-model"},"model":"selected-model"}"#) : try json(#"{"sessionId":"session"}"#)
        let update = try rpc.receive(.object([.init("id", start["id"]), .init("result", result)]))
        XCTAssertTrue(update.records.allSatisfy { $0.value["appliedModelReceipt"].isNullish })
        return rpc
    }

    func testClaudeModelReceiptRequiresMainAssistantSessionAndMessage() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let initial = try decoder.decode(json(#"{"type":"system","subtype":"init","session_id":"s","model":"selected"}"#))
        XCTAssertTrue(initial.allSatisfy { $0.value["appliedModelReceipt"].isNullish })
        let child = try decoder.decode(json(#"{"type":"assistant","session_id":"s","parent_tool_use_id":"child","message":{"id":"child-msg","model":"child-model","content":[]}}"#))
        XCTAssertTrue(child.allSatisfy { $0.value["appliedModelReceipt"].isNullish })
        let records = try decoder.decode(json(#"{"type":"assistant","session_id":"s","message":{"id":"m","model":"actual-model","content":[]}}"#))
        let receipt = try XCTUnwrap(records.first?["appliedModelReceipt"])
        XCTAssertEqual(receipt["model"].string, "actual-model")
        XCTAssertEqual(receipt["providerSessionId"].string, "s")
        XCTAssertEqual(receipt["providerMessageId"].string, "m")
        XCTAssertNil(HootChatProviderRecords.modelReceipt(.string("<synthetic>"), session: .string("s"), message: .string("m"), source: "test"))
        XCTAssertNil(HootChatProviderRecords.modelReceipt(.string("actual"), session: .null, message: .string("m"), source: "test"))
    }

    func testCodexAppliedModelIsExactTurnReceiptAndLateOldTurnCannotBecomeCurrent() throws {
        var rpc = try ready()
        _ = try rpc.user("one", attachments: [], id: "wire-one", ownerTurnID: "app-one")
        _ = try rpc.receive(json(#"{"id":"wire-one","result":{"turn":{"id":"provider-one"}}}"#))
        let foreign = try rpc.receive(json(#"{"method":"model/rerouted","params":{"threadId":"other","turnId":"provider-one","fromModel":"x","toModel":"private","reason":"test"}}"#))
        XCTAssertTrue(foreign.records.isEmpty)
        let actual = try rpc.receive(json(#"{"method":"model/rerouted","params":{"threadId":"session","turnId":"provider-one","fromModel":"selected-model","toModel":"actual-model","reason":"test"}}"#)).records
        XCTAssertEqual(actual.first?.value["eventTurnId"].string, "app-one")
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"provider-one","status":"completed"}}}"#))
        _ = try rpc.user("two", attachments: [], id: "app-two")
        let late = try rpc.receive(json(#"{"method":"model/rerouted","params":{"threadId":"session","turnId":"provider-one","fromModel":"x","toModel":"late-old-model","reason":"test"}}"#)).records
        XCTAssertEqual(late.first?.value["eventTurnId"].string, "app-one")
        let events = [HootChatEvent(conversationID: "c", turnID: "app-one", sequence: 1, provider: .codex, record: actual[0]),
                      HootChatEvent(conversationID: "c", turnID: "app-two", sequence: 2, provider: .codex, record: .text(.user, "two")),
                      HootChatEvent(conversationID: "c", turnID: "app-one", sequence: 3, provider: .codex, record: late[0])]
        XCTAssertEqual(BackendHootChatStore.appliedModelReceipt(events: events, provider: .codex, sessionID: "session", turn: "app-one")["model"].string, "late-old-model")
        XCTAssertTrue(BackendHootChatStore.appliedModelReceipt(events: events, provider: .codex, sessionID: "session", turn: "app-two").isNullish)
        XCTAssertTrue(BackendHootChatStore.appliedModelReceipt(events: events, provider: .codex, sessionID: "other", turn: "app-one").isNullish)
    }

    func testClaudeHookProgressAndLateResponseKeepOriginalTurnAndRawPayload() throws {
        var decoder = HootChatDecoder(provider: .claude)
        decoder.beginTurn(id: "first")
        _ = try decoder.decode(json(#"{"type":"system","subtype":"hook_started","session_id":"s","hook_id":"h","hook_name":"Check","hook_event":"PostToolUse"}"#))
        let progress = try decoder.decode(json(#"{"type":"system","subtype":"hook_progress","session_id":"s","hook_id":"h","output":"working"}"#))
        XCTAssertEqual(progress.first?.value["hook"]["output"].string, "working")
        decoder.beginTurn(id: "second")
        let completed = try decoder.decode(json(#"{"type":"system","subtype":"hook_response","session_id":"s","hook_id":"h","outcome":"success","stdout":"exact stdout","stderr":"","exit_code":0,"trusted":false,"stop_reason":"reported reason"}"#))
        XCTAssertEqual(completed.first?.value["eventTurnId"].string, "first")
        XCTAssertEqual(completed.first?.value["hook"]["stdout"].string, "exact stdout")
        XCTAssertEqual(completed.first?.value["hook"]["trusted"].bool, false)
        XCTAssertEqual(completed.first?.value["hook"]["stop_reason"].string, "reported reason")
        XCTAssertFalse(completed.contains { $0.kind == .completed || $0.kind == .interrupted })
    }

    func testCodexHooksBeforeAcknowledgementAndAfterCompletionRemainScoped() throws {
        var rpc = try ready()
        _ = try rpc.user("one", attachments: [], id: "app-one")
        let early = try rpc.receive(json(#"{"method":"hook/started","params":{"threadId":"session","turnId":"provider-one","run":{"id":"h","status":"running","eventName":"postToolUse","entries":[]}}}"#))
        XCTAssertTrue(early.records.isEmpty)
        let acknowledged = try rpc.receive(json(#"{"id":"app-one","result":{"turn":{"id":"provider-one"}}}"#))
        XCTAssertEqual(acknowledged.records.first?.value["eventTurnId"].string, "app-one")
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"provider-one","status":"completed"}}}"#))
        _ = try rpc.user("two", attachments: [], id: "app-two")
        let late = try rpc.receive(json(#"{"method":"hook/completed","params":{"threadId":"session","turnId":"provider-one","run":{"id":"h","status":"stopped","eventName":"postToolUse","entries":[{"kind":"warning","text":"Check source"},{"kind":"stop","text":"A real stop reason"}]}}}"#)).records
        XCTAssertEqual(late.first?.value["eventTurnId"].string, "app-one")
        XCTAssertEqual(late.first?.value["hook"]["stopReason"].string, "A real stop reason")
        XCTAssertEqual(late.first?.value["warnings"].elements?.first?.string, "Check source")
        XCTAssertTrue(try rpc.receive(json(#"{"method":"hook/completed","params":{"threadId":"foreign","turnId":"provider-one","run":{"id":"h","status":"completed"}}}"#)).records.isEmpty)
        XCTAssertTrue(try rpc.receive(json(#"{"method":"warning","params":{"threadId":"foreign","message":"private"}}"#)).records.isEmpty)
        XCTAssertEqual(try rpc.receive(json(#"{"method":"configWarning","params":{"summary":"Real configuration warning","details":"source detail"}}"#)).records.first?.value["providerWarning"]["details"].string, "source detail")
    }

    func testMissingFilePatchAndOutputEventsReachExistingDiffShape() throws {
        var rpc = try ready()
        _ = try rpc.user("change", attachments: [], id: "app")
        _ = try rpc.receive(json(#"{"id":"app","result":{"turn":{"id":"p"}}}"#))
        let patch = try rpc.receive(json(#"{"method":"item/fileChange/patchUpdated","params":{"threadId":"session","turnId":"p","itemId":"edit","changes":[{"path":"file.swift","kind":{"type":"update"},"diff":"@@ -1 +1 @@\n-old\n+new\n"}]}}"#)).records
        XCTAssertEqual(patch.first?.value["input"]["changes"].elements?.first?["path"].string, "file.swift")
        let output = try rpc.receive(json(#"{"method":"item/fileChange/outputDelta","params":{"threadId":"session","turnId":"p","itemId":"edit","delta":"Applied edit"}}"#)).records
        XCTAssertEqual(output.first?.messageID, "edit")
        XCTAssertEqual(output.first?.value["partial"].bool, true)
        let rows = HootChatProjection.rows((patch + output).enumerated().map { .init(conversationID: "c", turnID: "app", sequence: $0.offset + 1, provider: .codex, record: $0.element) })
        XCTAssertEqual(BackendChatDiffs.cards(rows).first?.known, true)
        let aggregate = try rpc.receive(json(#"{"method":"turn/diff/updated","params":{"threadId":"session","turnId":"p","diff":"diff --git a/file.swift b/file.swift\n--- a/file.swift\n+++ b/file.swift\n@@ -1 +1 @@\n-old\n+new\n"}}"#)).records
        XCTAssertEqual(aggregate.first?.value["input"]["changes"].elements?.count, 1)
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/diff/updated","params":{"threadId":"foreign","turnId":"p","diff":"private"}}"#)).records.isEmpty)
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"session","turn":{"id":"p","status":"completed"}}}"#))
        let late = try rpc.receive(json(#"{"method":"turn/diff/updated","params":{"threadId":"session","turnId":"p","diff":"late"}}"#)).records
        XCTAssertEqual(late.first?.value["eventTurnId"].string, "app")
        XCTAssertTrue(try rpc.receive(json(#"{"method":"turn/diff/updated","params":{"threadId":"session","turnId":"unknown-turn","diff":"unowned"}}"#)).records.isEmpty)
    }

    func testUnifiedAndACPChangesKeepPathsAndUnknownBeforeVersions() throws {
        let patch = #"""
diff --git "a/caf\303\251.swift" "b/caf\303\251.swift"
--- "a/caf\303\251.swift"
+++ "b/caf\303\251.swift"
@@ -1 +1 @@
-old
+new
diff --git a/gone b/gone
--- a/gone
+++ /dev/null
@@ -1 +0,0 @@
-gone
"""#
        XCTAssertEqual(HootChatProviderRecords.unifiedChanges(patch).compactMap { $0["path"].string }, ["café.swift", "gone"])
        var rpc = try ready(.gemini)
        _ = try rpc.user("change", attachments: [], id: "app")
        let changed = try rpc.receive(json(#"{"method":"session/update","params":{"sessionId":"session","update":{"sessionUpdate":"tool_call","toolCallId":"edit","title":"Edit file","content":[{"type":"diff","path":"f","oldText":"old\n","newText":"new\n"}]}}}"#)).records
        XCTAssertEqual(changed.first?.value["name"].string, "fileChange")
        XCTAssertTrue(changed.first?.value["input"]["changes"].elements?.first?["diff"].string?.contains("-old\n+new") == true)
        let unknown = HootChatProviderRecords.acpChanges(try json(#"[{"type":"diff","path":"f","oldText":null,"newText":"contents"}]"#))
        XCTAssertTrue(unknown.first?["diff"].isNullish == true)
        XCTAssertEqual(unknown.first?["newText"].string, "contents")
    }

    func testStoreExposesAndRestoresOnlyActualModelReceiptForItsExactTurnAndSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-applied-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = #"""
import json,sys
def out(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 if r.get('type')=='control_request':
  out({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'model':'selected-model'}}})
  out({'type':'system','subtype':'init','session_id':'session','model':'selected-model'})
 elif r.get('type')=='user':
  text=json.dumps(r)
  if 'no-model' not in text:
   out({'type':'assistant','session_id':'session','parent_tool_use_id':'child','message':{'id':'child','model':'child-model','content':[]}})
   out({'type':'assistant','session_id':'foreign' if 'foreign' in text else 'session','message':{'id':'answer','model':'actual-model','content':[{'type':'text','text':'reply'}]}})
  out({'type':'result','session_id':'session','subtype':'success','modelUsage':{'wrong-model':{'contextWindow':200000}}})
"""#
        let file = directory.appendingPathComponent("chat.json")
        let launch = BackendHootChatLaunch(command: "/usr/bin/python3", arguments: ["-u", "-c", script], cwd: directory.path,
            environment: [:], setup: .init(cwd: directory.path, session: .object([.init("model", .string("saved-model"))])))
        let store = try BackendHootChatStore(file: file, provider: .claude)
        do {
            try await store.attach(launch); try await store.initialize()
            let initial = await store.snapshot()
            XCTAssertTrue(initial["appliedModel"].isNullish)
            _ = try await store.say("actual")
            try await idle(store)
            let actual = await store.snapshot()
            XCTAssertEqual(actual["appliedModel"].string, "actual-model")
            XCTAssertEqual(actual["appliedModelReceipt"]["providerMessageId"].string, "answer")
            XCTAssertEqual(actual["appliedModelReceipt"]["providerSessionId"].string, "session")
            await store.stop()
        } catch { await store.stop(); throw error }
        let restored = try BackendHootChatStore(file: file, provider: .claude)
        let saved = await restored.snapshot()
        XCTAssertEqual(saved["appliedModel"].string, "actual-model")
        do {
            try await restored.attach(launch); try await restored.initialize()
            _ = try await restored.say("no-model")
            try await idle(restored)
            let unknown = await restored.snapshot()
            XCTAssertTrue(unknown["appliedModel"].isNullish, "Selected models and modelUsage are not turn receipts")
            _ = try await restored.say("foreign")
            try await idle(restored)
            let foreign = await restored.snapshot()
            XCTAssertTrue(foreign["appliedModel"].isNullish, "Another session's model must not become this turn's receipt")
            await restored.stop()
        } catch { await restored.stop(); throw error }
    }

    private func idle(_ store: BackendHootChatStore) async throws {
        for _ in 0..<200 {
            if await store.isBusy == false { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeRPCError(code: "test-timeout", message: "The model-receipt fixture did not finish its turn.")
    }
}

private extension HootChatRecord {
    subscript(_ key: String) -> NativeRPCValue { value[key] }
}
