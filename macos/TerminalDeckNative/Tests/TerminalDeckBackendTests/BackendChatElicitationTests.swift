import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatElicitationTests: XCTestCase, @unchecked Sendable {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func request(_ input: NativeRPCValue) -> NativeRPCValue {
        .object([.init("subtype", .string("mcpServer/elicitation/request")), .init("input", input)])
    }
    private func rejects(_ request: NativeRPCValue, _ answers: NativeRPCValue, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await BackendChatElicitation.validate(request, answers: answers)
            XCTFail("An invalid answer must leave the form unanswered.", file: file, line: line)
        } catch { }
    }

    func testRequiredTypedAnswersRejectMalformedValuesAndSchemaConstraints() async throws {
        let form = request(try json(#"{"mode":"form","requestedSchema":{"type":"object","required":["name","age","active","color"],"properties":{"name":{"type":"string","minLength":2},"age":{"type":"integer","minimum":0,"maximum":120},"active":{"type":"boolean"},"color":{"type":"string","enum":["blue","green"]}},"additionalProperties":false}}"#))
        let valid = try json(#"{"name":"Asad","age":0,"active":false,"color":"blue"}"#)
        try await BackendChatElicitation.validate(form, answers: valid)
        for answer in [
            #"{"age":0,"active":false,"color":"blue"}"#,
            #"{"name":"A","age":0,"active":false,"color":"blue"}"#,
            #"{"name":"Asad","age":"0","active":false,"color":"blue"}"#,
            #"{"name":"Asad","age":1.5,"active":false,"color":"blue"}"#,
            #"{"name":"Asad","age":-1,"active":false,"color":"blue"}"#,
            #"{"name":"Asad","age":121,"active":false,"color":"blue"}"#,
            #"{"name":"Asad","age":0,"active":"false","color":"blue"}"#,
            #"{"name":"Asad","age":0,"active":false,"color":"red"}"#,
            #"{"name":"Asad","age":0,"active":false,"color":"blue","extra":true}"#
        ] { await rejects(form, try json(answer)) }
        await rejects(form, .string("unstructured"))
        XCTAssertThrowsError(try BackendChatElicitation.answers(form, text: ["age": "not a number"], selected: .object([])))
    }

    func testOmittedModePreservesFalseZeroAndLeavesOptionalFieldsAbsent() async throws {
        let form = request(try json(#"{"requestedSchema":{"type":"object","required":["enabled","count"],"properties":{"enabled":{"type":"boolean","default":false},"count":{"type":"integer","default":0},"note":{"type":"string"}}}}"#))
        XCTAssertTrue(BackendChatElicitation.usesFields(form))
        let defaults = BackendChatElicitation.defaults(form)
        XCTAssertEqual(defaults["enabled"].bool, false)
        XCTAssertEqual(defaults["count"].number, 0)
        let answers = try BackendChatElicitation.answers(form, text: ["count": "0", "note": ""], selected: defaults)
        XCTAssertEqual(answers["enabled"].bool, false)
        XCTAssertEqual(answers["count"].number, 0)
        XCTAssertFalse(answers.has("note"))
        try await BackendChatElicitation.validate(form, answers: answers)
    }

    func testNestedSchemaUsesJSONFallbackAndStillValidatesIt() async throws {
        let form = request(try json(#"{"mode":"form","requestedSchema":{"type":"object","required":["settings"],"properties":{"settings":{"type":"object","required":["limit"],"properties":{"limit":{"type":"integer","minimum":1}},"additionalProperties":false}}}}"#))
        XCTAssertFalse(BackendChatElicitation.usesFields(form))
        try await BackendChatElicitation.validate(form, answers: json(#"{"settings":{"limit":3}}"#))
        await rejects(form, try json(#"{"settings":{"limit":0}}"#))
        await rejects(form, try json(#"{"settings":"three"}"#))
    }

    func testTitledSingleAndMultipleChoicesKeepWireValues() async throws {
        let form = request(try json(#"{"requestedSchema":{"type":"object","properties":{"region":{"type":"string","oneOf":[{"const":"ae","title":"United Arab Emirates"}]},"scopes":{"type":"array","items":{"anyOf":[{"const":"read","title":"Read calendar"},{"const":"write","title":"Edit calendar"}]},"minItems":1,"uniqueItems":true}},"required":["region","scopes"]}}"#))
        XCTAssertTrue(BackendChatElicitation.usesFields(form))
        let fields = BackendChatElicitation.fields(form)
        XCTAssertEqual(fields[0].choiceTitle(0), "United Arab Emirates")
        XCTAssertEqual(fields[1].choiceTitle(1), "Edit calendar")
        let values = try BackendChatElicitation.answers(form, text: [:], selected: json(#"{"region":"ae","scopes":["read"]}"#))
        try await BackendChatElicitation.validate(form, answers: values)
        await rejects(form, try json(#"{"region":"ae","scopes":[]}"#))
        await rejects(form, try json(#"{"region":"ae","scopes":["read","read"]}"#))
    }

    func testAuthenticationLinksRequireWebURLWithoutEmbeddedCredentials() async throws {
        let safe = request(try json(#"{"mode":"url","url":"https://auth.example.test/connect?state=fixture","elicitationId":"auth-fixture"}"#))
        XCTAssertEqual(BackendChatElicitation.authURL(safe)?.host, "auth.example.test")
        try await BackendChatElicitation.validate(safe, answers: .object([]))
        for url in ["javascript:alert(1)", "file:///tmp/auth", "/relative/auth", "https://user:fixture@example.test/auth", "https:///", ""] {
            let unsafe = request(.object([.init("mode", .string("url")), .init("url", .string(url))]))
            XCTAssertNil(BackendChatElicitation.authURL(unsafe))
            await rejects(unsafe, .object([]))
        }
        let unknown = request(try json(#"{"mode":"future-mode","requestedSchema":{"type":"object"}}"#))
        await rejects(unknown, .object([]))
    }

    func testPermissionBypassNeverAnswersFormOrAuthenticationRequest() throws {
        let form = request(try json(#"{"mode":"form","requestedSchema":{"type":"object","properties":{"confirmed":{"type":"boolean"}}}}"#))
        let auth = request(try json(#"{"mode":"url","url":"https://auth.example.test/connect"}"#))
        for mode in BackendHootChatStore.bypassModes.union(BackendHootChatStore.editModes) {
            for request in [form, auth] {
                XCTAssertFalse(BackendHootChatStore.autoAllows(mode: mode, provider: .codex, request: request))
            }
        }
    }
}
