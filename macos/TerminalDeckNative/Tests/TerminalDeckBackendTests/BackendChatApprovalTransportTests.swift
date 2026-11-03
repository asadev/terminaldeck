import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatApprovalTransportTests: XCTestCase, @unchecked Sendable {
    private func wait(_ check: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeRPCError(code: "test-timeout", message: "The offline approval fixture did not reach its expected state.")
    }

    func testClaudeRealPipesKeepOfferedSessionScopeAndDenialCommentThroughConsentBroker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-approval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        import json,sys
        turn=0
        def send(value):
            print(json.dumps(value),flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            with open('requests.jsonl','a') as log:
                log.write(json.dumps(request)+'\\n')
            if request.get('type')=='control_request' and request.get('request',{}).get('subtype')=='initialize':
                send({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}})
            elif request.get('type')=='user':
                turn+=1
                send({'type':'system','subtype':'init','session_id':'fixture-claude'})
                send({'type':'control_request','request_id':'approval-'+str(turn),'request':{
                    'subtype':'can_use_tool','tool_name':'Bash','tool_use_id':'fixture-tool-'+str(turn),
                    'input':{'command':'cat fixture.txt'},'decision_reason':'Review the fixture command',
                    'permission_suggestions':[{'type':'addRules','behavior':'allow','destination':'session',
                        'rules':[{'toolName':'Bash','ruleContent':'cat fixture.txt'}]}]}})
            elif request.get('type')=='control_response':
                send({'type':'result','subtype':'success','is_error':False})
        """
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in true })
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"), provider: .claude, consent: consent)
        do {
            await store.setPermissionPolicy("default")
            try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", script], cwd: root.path, environment: [:]))
            try await store.initialize()
            _ = try await store.say("Approve the fixture command for this session")
            try await wait { await store.snapshot()["pending"].elements?.first?["requestId"].string == "approval-1" }
            try await wait { await consent.list().count == 1 }
            let firstPending = await store.snapshot()["pending"].elements?.first
            let firstNonce = try XCTUnwrap(firstPending?["approvalNonce"].string)
            XCTAssertFalse(firstNonce.isEmpty)
            let offered = firstPending?["permissionSuggestions"]
            do {
                try await store.answer(id: "approval-1", allowed: true,
                    answers: .object([.init("updatedPermissions", .array([]))]))
                XCTFail("Caller-supplied permission updates reached the consent broker.")
            } catch { }
            let waiting = await store.snapshot()["pending"].elements?.first?["requestId"].string
            XCTAssertEqual(waiting, "approval-1")
            let waitingConsent = await consent.list()
            XCTAssertEqual(waitingConsent.count, 1)
            try await store.answer(id: "approval-1", allowed: true,
                answers: .object([.init("scope", .string("session")), .init("approvalNonce", .string(firstNonce))]))
            try await wait { await store.isBusy == false }
            let firstConsentSettled = await consent.list()
            XCTAssertTrue(firstConsentSettled.isEmpty)
            do { try await store.answer(id: "approval-1", allowed: true); XCTFail("A settled approval was answered twice.") } catch { }

            _ = try await store.say("Decline the next fixture command with a reason")
            try await wait { await store.snapshot()["pending"].elements?.first?["requestId"].string == "approval-2" }
            try await wait { await consent.list().count == 1 }
            let secondPending = await store.snapshot()["pending"].elements?.first
            let secondNonce = try XCTUnwrap(secondPending?["approvalNonce"].string)
            XCTAssertFalse(secondNonce.isEmpty)
            XCTAssertNotEqual(firstNonce, secondNonce, "Each pending operation needs its own lifetime binding.")
            try await store.answer(id: "approval-2", allowed: false,
                answers: .object([.init("comment", .string("Use the scratch copy instead.")), .init("approvalNonce", .string(secondNonce))]))
            try await wait { await store.isBusy == false }
            await store.stop()

            let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
            let responses = requests.filter { $0["type"].string == "control_response" }
            XCTAssertEqual(responses.count, 2, "Invalid and replayed decisions must not reach the CLI.")
            let allowed = try XCTUnwrap(responses.first { $0["response"]["request_id"].string == "approval-1" })["response"]["response"]
            XCTAssertEqual(allowed["behavior"].string, "allow")
            XCTAssertEqual(allowed["updatedInput"]["command"].string, "cat fixture.txt")
            XCTAssertEqual(allowed["updatedPermissions"], offered)
            let denied = try XCTUnwrap(responses.first { $0["response"]["request_id"].string == "approval-2" })["response"]["response"]
            XCTAssertEqual(denied["behavior"].string, "deny")
            XCTAssertEqual(denied["message"].string, "Use the scratch copy instead.")
            XCTAssertFalse(denied.has("updatedPermissions"))
            XCTAssertFalse(denied.has("updatedInput"))
        } catch {
            await store.stop()
            throw error
        }
    }
}
