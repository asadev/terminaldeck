import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatElicitationTransportTests: XCTestCase, @unchecked Sendable {
    private func wait(_ check: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeRPCError(code: "test-timeout", message: "Claude's fixture did not reach the expected elicitation state.")
    }

    func testClaudeRealPipesValidateFormsAndKeepAuthenticationOutOfPermissionBroker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-elicitation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = """
        import json,sys
        def send(value):
            print(json.dumps(value),flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            with open('requests.jsonl','a') as log:
                log.write(json.dumps(request)+'\\n')
            if request.get('type')=='control_request' and request.get('request',{}).get('subtype')=='initialize':
                send({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}})
            elif request.get('type')=='user':
                send({'type':'system','subtype':'init','session_id':'fixture-claude'})
                send({'type':'control_request','request_id':'form-fixture','request':{
                    'subtype':'elicitation','mcp_server_name':'fixture-server','message':'Review fixture settings',
                    'requested_schema':{'type':'object','required':['enabled','count'],'additionalProperties':False,
                        'properties':{'enabled':{'type':'boolean'},'count':{'type':'integer','minimum':0}}}}})
            elif request.get('type')=='control_response':
                request_id=request.get('response',{}).get('request_id')
                if request_id=='form-fixture':
                    send({'type':'control_request','request_id':'auth-fixture','request':{
                        'subtype':'elicitation','mcp_server_name':'fixture-server','message':'Connect fixture account',
                        'mode':'url','url':'https://auth.example.test/connect','elicitation_id':'fixture-auth'}})
                elif request_id=='auth-fixture':
                    send({'type':'result','subtype':'success','is_error':False})
        """
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in
            XCTFail("A structured elicitation must never become a Boolean permission prompt.")
            return false
        })
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"), provider: .claude, consent: consent)
        do {
            await store.setPermissionPolicy("bypassPermissions")
            try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", script], cwd: root.path, environment: [:]))
            try await store.initialize()
            _ = try await store.say("Run the offline elicitation fixture")
            try await wait { await store.snapshot()["pending"].elements?.first?["requestId"].string == "form-fixture" }
            let form = await store.snapshot()["pending"].elements?.first
            XCTAssertEqual(form?["subtype"].string, "elicitation")
            XCTAssertEqual(form?["input"]["serverName"].string, "fixture-server")
            do {
                try await store.answer(id: "form-fixture", allowed: true,
                    answers: .object([.init("enabled", .bool(false)), .init("count", .string("zero"))]))
                XCTFail("A malformed number reached Claude's pipe.")
            } catch { }
            let stillPending = await store.snapshot()["pending"].elements
            XCTAssertEqual(stillPending?.count, 1)
            XCTAssertEqual(stillPending?.first?["requestId"].string, "form-fixture")
            let noBrokerQuestions = await consent.list()
            XCTAssertTrue(noBrokerQuestions.isEmpty)

            try await store.answer(id: "form-fixture", allowed: true,
                answers: .object([.init("enabled", .bool(false)), .init("count", .number(0))]))
            try await wait { await store.snapshot()["pending"].elements?.first?["requestId"].string == "auth-fixture" }
            do { try await store.answer(id: "form-fixture", allowed: true); XCTFail("A settled form was answered twice.") } catch { }
            let authPending = await store.snapshot()["pending"].elements
            XCTAssertEqual(authPending?.count, 1, "Bypass mode must still wait for the person's authentication decision.")
            try await store.answer(id: "auth-fixture", allowed: true,
                answers: .object([.init("mustNotReachURLReply", .string("fixture"))]))
            try await wait { await store.isBusy == false }
            await store.stop()
        } catch {
            await store.stop()
            throw error
        }

        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        let responses = requests.filter { $0["type"].string == "control_response" }
        XCTAssertEqual(responses.count, 2, "Invalid and replayed answers must not write to the pipe.")
        let formReply = try XCTUnwrap(responses.first { $0["response"]["request_id"].string == "form-fixture" })["response"]["response"]
        XCTAssertEqual(formReply["action"].string, "accept")
        XCTAssertEqual(formReply["content"]["enabled"].bool, false)
        XCTAssertEqual(formReply["content"]["count"].number, 0)
        XCTAssertFalse(formReply.has("behavior"))
        XCTAssertFalse(formReply.has("updatedInput"))
        let authReply = try XCTUnwrap(responses.first { $0["response"]["request_id"].string == "auth-fixture" })["response"]["response"]
        XCTAssertEqual(authReply["action"].string, "accept")
        XCTAssertFalse(authReply.has("content"))
    }
}
