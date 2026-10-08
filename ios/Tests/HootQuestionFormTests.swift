import XCTest
@testable import TerminalDeck

@MainActor final class HootQuestionFormTests: XCTestCase {
    private let args: [String: Any] = ["subtype": "mcpServer/elicitation/request", "input": ["mode": "form", "requestedSchema": [
        "type": "object", "required": ["name", "count", "agree"], "properties": [
            "name": ["type": "string", "minLength": 2], "count": ["type": "integer", "minimum": 1], "agree": ["type": "boolean"]]]]]
    private func question(id: String = "broker", expiry: Double = Date().timeIntervalSince1970 * 1000 + 60_000, mine: Bool = true) -> CopilotQuestion {
        WireCodec.copilotQuestion(["id": id, "tool": "hoot.cli", "summary": "Details", "tier": "alter", "args": args, "mine": mine, "expiresAt": expiry])!
    }
    private final class Wire: CopilotWire {
        var sent: [ClientMessage] = []
        func send(_ message: ClientMessage) -> Bool { sent.append(message); return true }
    }
    private func link(_ wire: Wire) -> CopilotLink {
        let link = CopilotLink(wire: wire)
        link.welcomed(capabilities: ["copilot"], connection: .init(stated: true, linked: true, open: true, grant: .init(read: true, act: true, alter: true)))
        wire.sent = []
        return link
    }

    func testRequiredValuesAreRealJSONTypesAndRoundTripOnWire() throws {
        let form = HootQuestionForm.decode(tool: "hoot.cli", arguments: args)
        XCTAssertThrowsError(try form.answers([:]))
        XCTAssertThrowsError(try form.answers(["name": "N", "count": "1.5", "agree": "true"]))
        let answers = try XCTUnwrap(form.answers(["name": "Asad", "count": "2", "agree": "false"]))
        XCTAssertTrue(form.validate(answers))
        let encoded = WireCodec.encode(.copilotAnswer(id: "broker", approved: true, answers: answers))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        let object = try XCTUnwrap(frame["answers"] as? [String: Any])
        XCTAssertEqual(frame["id"] as? String, "broker")
        XCTAssertEqual(object["name"] as? String, "Asad")
        XCTAssertEqual(object["count"] as? Int, 2)
        XCTAssertEqual(object["agree"] as? Bool, false)
        XCTAssertFalse(WireCodec.encode(.copilotAnswer(id: "broker", approved: false, answers: answers)).contains("\"answers\""))
    }

    func testUserInputQuestionUsesAnswerArrayAndUnsupportedSchemaFailsClosed() throws {
        let form = HootQuestionForm.decode(tool: "hoot.cli", arguments: ["subtype": "item/tool/requestUserInput", "input": ["questions": [["id": "color", "header": "Color", "options": [["label": "Blue"], ["label": "Red"]]]]]])
        let answers = try XCTUnwrap(form.answers(["color": "Blue"]))
        XCTAssertEqual((answers.object["color"] as? [String: Any])?["answers"] as? [String], ["Blue"])
        XCTAssertThrowsError(try form.answers(["color": "Invisible"]))
        let unsupported = HootQuestionForm.decode(tool: "hoot.cli", arguments: ["subtype": "mcpServer/elicitation/request", "input": ["requestedSchema": ["type": "object", "properties": ["nested": ["type": "object"]]]]])
        XCTAssertNotNil(unsupported.unsupported)
        XCTAssertFalse(unsupported.validate(nil))
        XCTAssertThrowsError(try HootAnswers(["name": String(repeating: "x", count: 16 * 1024)]))
    }

    func testReconnectHydratesBrokerMetadataAndCannotAnswerEventIDOrTwice() throws {
        let wire = Wire(), link = link(wire)
        let row = question()
        link.apply(pending: [row])
        XCTAssertEqual(link.asked.first?.form.fields.count, 3)
        XCTAssertFalse(link.answer("cli-event-id", approved: true))
        XCTAssertFalse(link.answer("broker", approved: true))
        let answers = try XCTUnwrap(row.consent?.form.answers(["name": "Asad", "count": "2", "agree": "true"]))
        XCTAssertTrue(link.answer("broker", approved: true, answers: answers))
        XCTAssertFalse(link.answer("broker", approved: true, answers: answers))
        XCTAssertEqual(wire.sent.count, 1)
        link.connectionLost()
        XCTAssertTrue(link.asked.isEmpty)
    }

    func testExpiredSettledForeignAndRevokedQuestionsCannotBeAllowed() throws {
        let wire = Wire(), link = link(wire)
        link.apply(pending: [question(expiry: 1)])
        XCTAssertFalse(link.answer("broker", approved: false))
        link.apply(pending: [question(mine: false)])
        XCTAssertTrue(link.asked.isEmpty)
        link.apply(pending: [question()])
        link.apply(settled: .init(id: "broker", granted: false, by: "window", reason: nil))
        XCTAssertFalse(link.answer("broker", approved: false))
        link.apply(pending: [question(id: "new")])
        link.setPhoneAccess(negotiated: true, level: .look)
        XCTAssertFalse(link.answer("new", approved: false))
        XCTAssertTrue(wire.sent.isEmpty)
    }
}
