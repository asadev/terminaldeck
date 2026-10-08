import XCTest
@testable import TerminalDeck

@MainActor
final class IOSAlignmentTests: XCTestCase {
    private func event(_ sequence: Int, _ kind: String, id: String = "m", value: [String: Any] = [:]) -> [String: Any] {
        ["version": 1, "id": "c:\(sequence)", "sequence": sequence, "conversationId": "c",
         "turnId": "turn", "provider": "claude", "kind": kind, "messageId": id,
         "value": value, "at": 1000]
    }

    private func batch(_ rows: [[String: Any]], reset: Bool = false) -> HootEventBatch {
        HootEventBatch.decode(["conversationId": "c", "reset": reset, "events": rows])!
    }

    func testDeltasFinalMessageAndReplayDoNotDuplicateText() {
        let stream = HootEventStream()
        stream.apply(batch([event(1, "textDelta", value: ["text": "Good "]), event(2, "textDelta", value: ["text": "morning"])], reset: true))
        XCTAssertEqual(stream.items.first?.text, "Good morning")
        stream.apply(batch([event(2, "textDelta", value: ["text": "morning"]), event(3, "message", value: ["text": "Good morning."]), event(4, "completed", id: "")]))
        XCTAssertEqual(stream.items.count, 1)
        XCTAssertEqual(stream.items.first?.text, "Good morning.")
        XCTAssertFalse(stream.isStreaming)
        stream.apply(batch([event(3, "message", value: ["text": "Good morning."]), event(4, "completed", id: "")], reset: true))
        XCTAssertEqual(stream.items.count, 1)
    }

    func testMissingDeltaRequestsReplayAndDoesNotInventTheSentence() {
        let stream = HootEventStream()
        stream.apply(batch([event(1, "textDelta", value: ["text": "I can "])], reset: true))
        stream.apply(batch([event(3, "textDelta", value: ["text": "do that"])]))
        XCTAssertTrue(stream.needsReplay)
        XCTAssertEqual(stream.items.first?.text, "I can ")
        stream.apply(batch([event(4, "message", value: ["text": "I can safely do that."])], reset: true))
        XCTAssertFalse(stream.needsReplay)
        XCTAssertEqual(stream.items.first?.text, "I can safely do that.")
    }

    func testToolsMergeResultsAndPreserveArguments() {
        let stream = HootEventStream()
        stream.apply(batch([event(1, "toolCall", id: "tool", value: ["name": "tasks_list", "input": ["project": "/work"]]),
                            event(2, "toolResult", id: "tool", value: ["output": "3 tasks"])], reset: true))
        XCTAssertEqual(stream.items.count, 1)
        XCTAssertEqual(stream.items.first?.name, "tasks_list")
        XCTAssertEqual(stream.items.first?.text, "3 tasks")
        XCTAssertTrue(stream.items.first?.input?.contains("/work") == true)
        stream.apply(batch([event(3, "toolResult", id: "tool", value: ["output": "Permission refused", "isError": true])]))
        XCTAssertTrue(stream.items.first?.failed == true)
    }

    func testApprovalResolvedRemovesOnlyItsMatchingRequest() {
        let stream = HootEventStream()
        stream.apply(batch([event(1, "approval", id: "r1", value: ["requestId": "r1"]),
                            event(2, "approval", id: "r2", value: ["requestId": "r2"]),
                            event(3, "approvalResolved", id: "r1", value: ["allowed": false])], reset: true))
        XCTAssertEqual(stream.items.map(\.id), ["r2"])
        XCTAssertFalse(stream.isStreaming)
    }

    func testMalformedAndCrossConversationBatchesAreRejectedWhole() {
        XCTAssertNil(HootEventBatch.decode(["conversationId": "other", "reset": true, "events": [event(1, "message")]]))
        XCTAssertNil(HootEventBatch.decode(["conversationId": "c", "reset": true, "events": [event(1, "unknown")]]))
        XCTAssertNil(HootEventBatch.decode(["conversationId": "c", "reset": 1, "events": []]))
        var malformed = event(1, "textDelta")
        malformed["sequence"] = true
        XCTAssertNil(HootEvent.decode(malformed))
        malformed = event(1, "message", value: ["text": String(repeating: "x", count: 65537)])
        XCTAssertNil(HootEvent.decode(malformed))
    }

    func testOldAndNewHootNamesDecodeIdentically() {
        let frame = #"{"t":"copilot.chat","run":"r","messages":[{"id":"m","role":"agent","text":"Hello","at":1}],"reset":true}"#
        XCTAssertEqual(WireCodec.decode(frame), WireCodec.decode(frame.replacingOccurrences(of: "copilot.chat", with: "hoot.chat")))
        let question = #"{"t":"copilot.ask","question":{"id":"q","tool":"tasks_add","summary":"Add task","args":{"title":"Test"},"origin":"device:d","requestedAt":1,"expiresAt":10000}}"#
        XCTAssertEqual(WireCodec.decode(question), WireCodec.decode(question.replacingOccurrences(of: "copilot.ask", with: "hoot.ask")))
    }

    func testWelcomeAcceptsNewHootGrantAndCapabilities() {
        let frame = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"Phone","token":null,"sessions":[],"capabilities":["hoot","hoot.files"],"hoot":{"linked":true,"open":false,"grant":{"read":true,"act":false,"alter":false}}}"#
        guard case let .ok(.welcome(_, _, _, _, _, caps, _, _, _, connection, _, _), _) = WireCodec.decode(frame) else { return XCTFail("welcome missing") }
        XCTAssertTrue(caps.contains("copilot"))
        XCTAssertTrue(caps.contains("copilot.files"))
        XCTAssertTrue(connection.grant.canWatch)
        XCTAssertFalse(connection.grant.canDirect)
    }

    func testUnknownAccessRevokesRatherThanKeepingFullControl() {
        guard case .ok(.phoneAccess(nil), _) = WireCodec.decode(#"{"t":"device.access","level":"owner"}"#) else { return XCTFail("must revoke") }
        XCTAssertNil(PhoneAccessGrant.decode(["level": true]))
    }

    func testPanelMetadataClaimsSurviveHelloAndNegotiatedWelcome() throws {
        let json = WireCodec.encode(.hello(protocolVersion: 1, token: "d.token",
            device: .init(name: "Phone", platform: "ios"),
            capabilities: WireCapability.claimed))
        let hello = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let claims = try XCTUnwrap(hello["capabilities"] as? [String])
        for domain in ["artifacts", "store", "readiness", "mcp", "tasks", "goals", "memory"] {
            XCTAssertTrue(claims.contains("panels." + domain))
        }
        XCTAssertLessThanOrEqual(claims.count, 24)

        let welcome = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"Phone","token":null,"sessions":[],"capabilities":["panels","panels.tasks","panels.goals","panels.memory","device.access"]}"#
        guard case let .ok(.welcome(_, _, _, _, _, offered, _, _, _, _, _, _), _) = WireCodec.decode(welcome) else { return XCTFail("welcome missing") }
        XCTAssertTrue(offered.contains("panels.tasks"))
        XCTAssertTrue(offered.contains("panels.goals"))
        XCTAssertTrue(offered.contains("panels.memory"))
        let oldWelcome = #"{"t":"welcome","protocol":1,"deviceId":"d","deviceName":"Phone","token":null,"sessions":[],"capabilities":["panels"]}"#
        guard case let .ok(.welcome(_, _, _, _, _, oldOffered, _, _, _, _, _, _), _) = WireCodec.decode(oldWelcome) else { return XCTFail("old welcome missing") }
        XCTAssertFalse(oldOffered.contains("panels.tasks"))
    }

    func testLookWorkAndFullControlHaveSeparatePowers() {
        let look = PhoneAccessGrant(level: .look), work = PhoneAccessGrant(level: .work), full = PhoneAccessGrant(level: .full)
        XCTAssertTrue(look.allows(.panelRead(panel: "tasks", path: "/p", scope: nil, query: nil)))
        XCTAssertFalse(look.allows(.input(id: "s", data: "ls\n")))
        XCTAssertTrue(work.allows(.input(id: "s", data: "ls\n")))
        XCTAssertTrue(work.allows(.panelAct(panel: "tasks", action: "done", path: "/p", id: "t", fields: [:])))
        XCTAssertFalse(work.allows(.settingsApply(rid: "r", key: .defaultProvider, value: "codex")))
        XCTAssertFalse(work.allows(.copilotAnswer(id: "q", approved: true)))
        XCTAssertFalse(work.allows(.accountSwitch(rid: "r", id: "s", accountId: "a")))
        XCTAssertTrue(full.allows(.accountSwitch(rid: "r", id: "s", accountId: "a")))
        XCTAssertFalse(work.allows(.panelAct(panel: "settings", action: "save", path: "/p", id: nil, fields: [:])))
        XCTAssertTrue(full.allows(.panelAct(panel: "settings", action: "save", path: "/p", id: nil, fields: [:])))
    }

    func testProjectTaskFormsUseExistingPanelProtocol() {
        let frame = #"{"t":"panel.rows","panel":"tasks","path":"/p","actions":[{"id":"add","label":"Add task","fields":[{"id":"title","label":"Title","required":true}]}],"rows":[{"id":"t","title":"Fix login","actions":[{"id":"done","label":"Done"},{"id":"move","label":"Move to project","fields":[{"id":"project","label":"Project","choices":["/p","/q"]}]}]}]}"#
        guard case let .ok(.panelRows(data), _) = WireCodec.decode(frame) else { return XCTFail("tasks missing") }
        XCTAssertEqual(data.panel, .tasks)
        XCTAssertEqual(data.actions.first?.fields.first?.id, "title")
        XCTAssertEqual(data.rows.first?.actions.last?.fields.first?.choices, ["/p", "/q"])
        XCTAssertEqual(data.rows.first?.key, "t")
        XCTAssertEqual(WireCodec.panelRow(["title": "Task run", "sessionId": "s1"], index: 0)?.sessionId, "s1")
    }

    func testLiveGrantRevocationBlocksSessionActionsImmediately() async {
        let (model, transport) = IOSAlignmentPreview.fixture()
        model.start()
        guard let host = model.current else { return XCTFail("fixture host missing") }
        XCTAssertTrue(host.canCreateSessions)
        XCTAssertTrue(host.canActOnPanel(.tasks))
        transport.emit(.phoneAccess(.init(level: .look)))
        XCTAssertFalse(host.canCreateSessions)
        XCTAssertFalse(host.canActOnPanel(.tasks))
        XCTAssertTrue(host.canReadPanel(.tasks))
        let sent = transport.sent.count
        host.createSession(in: "/Projects/Phone")
        host.actOnPanel(.tasks, action: "done", path: "/Projects/Phone", id: "0")
        XCTAssertEqual(transport.sent.count, sent)
        XCTAssertFalse(host.copilot.grant.canDirect)
        XCTAssertFalse(host.copilot.grant.canAnswer)
        transport.emit(.phoneAccess(nil))
        XCTAssertFalse(host.canReadPanel(.tasks))
        transport.emit(.phoneAccess(.init(level: .full)))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(host.hootStream.items.contains { $0.kind == .message })
        host.stop()
        XCTAssertNil(host.phoneAccess)
        XCTAssertFalse(host.canCreateSessions)
        XCTAssertFalse(host.hootStream.isStreaming)
    }
}
