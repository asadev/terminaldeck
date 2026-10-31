import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatApprovalTests: XCTestCase {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func request(_ method: String, input: NativeRPCValue = .object([]), extra: NativeRPCValue = .object([])) -> NativeRPCValue {
        .object([.init("subtype", .string(method)), .init("input", input)]).merging(extra)
    }
    private func scope(_ value: String) -> NativeRPCValue { .object([.init("scope", .string(value))]) }

    func testCodexCommandScopesRequireOfferedDecisionsAndPreserveExactPolicyAmendment() throws {
        let input = try json(#"{"command":"cat fixture.txt","availableDecisions":["accept","acceptForSession",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["cat","fixture.txt"]}},{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"fixture.example.test","action":"allow"}}},{"applyNetworkPolicyAmendment":{"network_policy_amendment":{"host":"blocked.example.test","action":"deny"}}},"decline"]}"#)
        let command = request("item/commandExecution/requestApproval", input: input)
        XCTAssertEqual(BackendChatApproval.scopes(command).map(\.id), ["once", "session", "decision:2", "decision:3"])
        for selected in ["once", "session", "decision:2", "decision:3"] {
            XCTAssertNoThrow(try BackendChatApproval.validate(command, allowed: true, answers: scope(selected)))
        }
        XCTAssertEqual(BackendChatApproval.codexDecision(command, allowed: true, scope: "once"), .string("accept"))
        XCTAssertEqual(BackendChatApproval.codexDecision(command, allowed: true, scope: "session"), .string("acceptForSession"))
        XCTAssertEqual(BackendChatApproval.codexDecision(command, allowed: true, scope: "decision:2"), input["availableDecisions"].elements![2])
        XCTAssertEqual(BackendChatApproval.codexDecision(command, allowed: true, scope: "decision:3"), input["availableDecisions"].elements![3])
        for selected in ["decision:4", "decision:5", "decision:-1", "decision:200", "always"] {
            XCTAssertThrowsError(try BackendChatApproval.validate(command, allowed: true, answers: scope(selected)))
        }
    }

    func testCodexMissingAndRestrictedOfferNeverInventSessionOrOnceApproval() throws {
        let legacy = request("item/commandExecution/requestApproval")
        XCTAssertEqual(BackendChatApproval.scopes(legacy).map(\.id), ["once"])
        XCTAssertThrowsError(try BackendChatApproval.validate(legacy, allowed: true, answers: scope("session")))
        let restricted = request("item/commandExecution/requestApproval", input: try json(#"{"availableDecisions":["acceptForSession","cancel"]}"#))
        XCTAssertEqual(BackendChatApproval.scopes(restricted).map(\.id), ["session"])
        XCTAssertThrowsError(try BackendChatApproval.validate(restricted, allowed: true, answers: scope("once")))
        XCTAssertEqual(BackendChatApproval.codexDecision(restricted, allowed: false, scope: "once"), .string("cancel"))
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "danger-full-access", provider: .codex, request: restricted))
        XCTAssertTrue(BackendChatApproval.requiresRememberedConsent(restricted, allowed: true, answers: scope("session")))
        XCTAssertFalse(BackendChatApproval.requiresRememberedConsent(legacy, allowed: true, answers: scope("once")))
        XCTAssertFalse(BackendChatApproval.requiresRememberedConsent(restricted, allowed: false, answers: scope("session")))
    }

    func testCodexPermissionAndFileScopesHaveNoUnsupportedComment() throws {
        for method in ["item/permissions/requestApproval", "item/fileChange/requestApproval"] {
            let approval = request(method)
            XCTAssertEqual(BackendChatApproval.scopes(approval).map(\.id), ["once", "session"])
            XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: scope("once")))
            XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: scope("session")))
            XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false,
                answers: .object([.init("comment", .string("Use the fixture instead."))])))
        }
    }

    func testGeminiUsesOfferedOpaqueOptionIDsAndProviderRememberLabel() throws {
        let approval = request("session/request_permission", input: try json(#"{"options":[{"optionId":"opaque/one:7","name":"Allow this operation","kind":"allow_once"},{"optionId":"remember-rule-9","name":"Remember the fixture rule","kind":"allow_always"},{"optionId":"deny-rule-3","name":"Never allow","kind":"reject_always"}]}"#))
        XCTAssertEqual(BackendChatApproval.scopes(approval).map(\.id), ["opaque/one:7", "remember-rule-9"])
        XCTAssertEqual(BackendChatApproval.scopes(approval).last?.title, "Remember the fixture rule")
        XCTAssertEqual(BackendChatApproval.defaultScope(approval), "opaque/one:7")
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: scope("remember-rule-9")))
        for fabricated in ["session", "always", "deny-rule-3"] {
            XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: scope(fabricated)))
        }
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false,
            answers: .object([.init("comment", .string("Unsupported ACP comment"))])))
    }

    func testGeminiRememberOptionNamedOnceStillRequiresExplicitRememberedConsent() throws {
        let approval = request("session/request_permission", input: try json(#"{"options":[{"optionId":"once","name":"Remember fixture rule","kind":"allow_always"}]}"#))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: .object([])),
            "An opaque remembered-option ID must never become the implicit one-use default.")
        let explicit = scope("once")
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: explicit))
        XCTAssertTrue(BackendChatApproval.requiresRememberedConsent(approval, allowed: true, answers: explicit))
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "bypassPermissions", provider: .gemini, request: approval))
    }

    func testGeminiDuplicateOptionIDsCannotHideRememberedPermissionAsOneUse() throws {
        let approval = request("session/request_permission", input: try json(#"{"options":[{"optionId":"same-id","name":"Allow once","kind":"allow_once"},{"optionId":"same-id","name":"Remember fixture rule","kind":"allow_always"}]}"#))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: .object([])))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: scope("same-id")))
        XCTAssertFalse(BackendHootChatStore.autoAllows(mode: "bypassPermissions", provider: .gemini, request: approval))
    }

    func testClaudeScopesUseOnlyExactOfferedOperationUpdates() throws {
        let offered = try json(#"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"cat fixture.txt"}],"behavior":"allow","destination":"session"},{"type":"addDirectories","directories":["/scratch/fixture"],"destination":"session"},{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"/scratch/fixture/**"}],"behavior":"allow","destination":"projectSettings"},{"type":"addRules","rules":[{"toolName":"Read","ruleContent":"/scratch/local/**"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/scratch/user-fixture"],"destination":"userSettings"},{"type":"setMode","mode":"bypassPermissions","destination":"session"},{"type":"addRules","rules":[{"toolName":"Write"}],"behavior":"deny","destination":"session"}]"#)
        let approval = request("can_use_tool", extra: .object([.init("permissionSuggestions", offered)]))
        XCTAssertEqual(BackendChatApproval.scopes(approval).map(\.id), ["once", "session", "suggestion:2", "suggestion:3", "suggestion:4"])
        XCTAssertEqual(BackendChatApproval.updates(approval, scope: "session"), Array((offered.elements ?? []).prefix(2)))
        XCTAssertEqual(BackendChatApproval.updates(approval, scope: "suggestion:2"), [offered.elements![2]])
        XCTAssertEqual(BackendChatApproval.updates(approval, scope: "once"), [])
        for selected in ["session", "suggestion:2", "suggestion:3", "suggestion:4"] {
            XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: scope(selected)))
        }
        for selected in ["suggestion:5", "suggestion:6", "suggestion:99"] {
            XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: scope(selected)))
        }
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true,
            answers: .object([.init("updatedPermissions", offered)])))
        let noOffer = request("can_use_tool")
        XCTAssertEqual(BackendChatApproval.scopes(noOffer).map(\.id), ["once"])
        XCTAssertThrowsError(try BackendChatApproval.validate(noOffer, allowed: true, answers: scope("session")))
    }

    func testMalformedClaudePermissionSuggestionsAreNeverOffered() throws {
        let approval = request("can_use_tool", extra: try json(#"{"permissionSuggestions":[{"type":"addRules","rules":[{}],"behavior":"allow","destination":"session"},{"type":"addDirectories","directories":[3],"destination":"projectSettings"},{"type":"addRules","rules":[{"toolName":""}],"behavior":"allow","destination":"userSettings"}]}"#))
        XCTAssertEqual(BackendChatApproval.scopes(approval).map(\.id), ["once"])
        XCTAssertTrue(BackendChatApproval.sessionUpdates(approval).isEmpty)
    }

    func testQuestionAnswersNamedScopeCannotBecomePermissionUpdates() throws {
        let question = try json(#"{"subtype":"can_use_tool","name":"AskUserQuestion","input":{"questions":[{"question":"scope","header":"Scope"}]},"permissionSuggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"cat fixture.txt"}],"behavior":"allow","destination":"session"}]}"#)
        let answers = try json(#"{"scope":"session"}"#)
        try BackendChatQuestions.validate(question, answers: answers)
        XCTAssertFalse(BackendChatApproval.isApproval(question))
        XCTAssertTrue(BackendChatApproval.sessionUpdates(question).isEmpty)
        XCTAssertTrue(BackendChatApproval.updates(question, scope: "session").isEmpty)
        XCTAssertTrue(BackendChatApproval.updates(question, scope: "suggestion:0").isEmpty)
    }

    func testClaudeDenialCommentIsBoundedAndCannotGrantPermissions() throws {
        let approval = request("can_use_tool")
        let comment = NativeRPCValue.object([.init("comment", .string("Use the fixture copy instead."))])
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: false, answers: comment))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: comment))
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: false,
            answers: .object([.init("comment", .string(String(repeating: "a", count: 4096)))])))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false,
            answers: .object([.init("comment", .string(String(repeating: "a", count: 4097)))])))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false,
            answers: .object([.init("comment", .string(String(repeating: "🦉", count: 1025)))])))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false, answers: scope("session")))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false, answers: .string("deny")))
    }

    func testBackendNonceBindsRememberedDecisionAndRejectsEveryProvidedStaleNonce() throws {
        let approval = request("item/commandExecution/requestApproval",
            input: try json(#"{"availableDecisions":["accept","acceptForSession","decline"]}"#),
            extra: .object([.init("approvalNonce", .string("current-operation-fixture"))]))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: scope("session")),
            "A remembered grant must identify the exact pending operation.")
        let stale = try json(#"{"scope":"session","approvalNonce":"previous-operation-fixture"}"#)
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true, answers: stale))
        let matching = try json(#"{"scope":"session","approvalNonce":"current-operation-fixture"}"#)
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: matching))
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: true, answers: scope("once")),
            "Existing one-use callers may omit the optional lifetime binding.")
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: true,
            answers: try json(#"{"scope":"once","approvalNonce":"previous-operation-fixture"}"#)))
        XCTAssertThrowsError(try BackendChatApproval.validate(approval, allowed: false,
            answers: try json(#"{"approvalNonce":"previous-operation-fixture"}"#)))
        XCTAssertNoThrow(try BackendChatApproval.validate(approval, allowed: false,
            answers: try json(#"{"approvalNonce":"current-operation-fixture"}"#)))
    }

    func testOperationDetailsExposeCommandWorkingDirectoryAndDiffWithoutChangingInput() throws {
        let original = try json(#"{"command":"cat fixture.txt","cwd":"/scratch/fixture","reason":"Read the fixture"}"#)
        let command = request("item/commandExecution/requestApproval", input: original)
        let details = BackendChatApproval.details(command)
        XCTAssertEqual(details["command"].string, "cat fixture.txt")
        XCTAssertEqual(details["cwd"].string, "/scratch/fixture")
        XCTAssertEqual(details["reason"].string, "Read the fixture")
        XCTAssertEqual(details["input"], original)
        XCTAssertEqual(command["input"], original)
        let fileInput = try json(#"{"threadId":"fixture-thread","reason":"Update the fixture"}"#)
        let file = request("item/fileChange/requestApproval", input: fileInput,
            extra: try json(#"{"operation":{"changes":[{"path":"/scratch/fixture.txt","diff":"@@ -1 +1 @@\n-old\n+new\n"}]}}"#))
        let fileDetails = BackendChatApproval.details(file)
        let diff = try XCTUnwrap(fileDetails["diffs"].elements?.first)
        XCTAssertEqual(diff["path"].string, "/scratch/fixture.txt")
        XCTAssertEqual(diff["plus"].number, 1)
        XCTAssertEqual(diff["minus"].number, 1)
        XCTAssertEqual(file["input"], fileInput)
    }
}
