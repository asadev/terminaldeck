import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderPolicyTests: XCTestCase, @unchecked Sendable {
    private actor Wire {
        var calls: [(String, NativeRPCValue)] = []
        let replies: [NativeRPCValue]
        init(_ replies: [NativeRPCValue] = []) { self.replies = replies }
        func request(_ method: String, _ params: NativeRPCValue) -> NativeRPCValue {
            let index = calls.count; calls.append((method, params))
            return replies.isEmpty ? .object([]) : replies[min(index, replies.count - 1)]
        }
        func recorded() -> [(String, NativeRPCValue)] { calls }
    }
    private func json(_ value: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(value.utf8)) }
    private func invoke(_ operation: String, _ arguments: NativeRPCValue = .object([]), provider: HootChatProvider = .codex,
                        conversation: String? = "own-thread", receipt: NativeRPCValue = .null, busy: Bool = false, wire: Wire) async throws -> NativeRPCValue {
        try await BackendChatProviderPolicy.invoke(operation: operation, arguments: arguments, provider: provider,
            conversation: conversation, cwd: "/scratch", receipt: receipt, busy: busy,
            request: { method, params in await wire.request(method, params) })
    }
    func testMatchedSessionReceiptKeepsOnlyAuthoritativeBoundaryFields() throws {
        let response = try json(#"{"thread":{"id":"own-thread"},"approvalPolicy":"on-request","approvalsReviewer":"user","sandbox":{"type":"workspaceWrite","networkAccess":false,"writableRoots":["/scratch"],"credentials":"hidden"},"runtimeWorkspaceRoots":["/scratch"],"activePermissionProfile":{"id":":workspace","extends":"base","secret":"hidden"},"cwd":"/scratch","config":{"approval_policy":"never"},"workspaceTrust":{"status":"trusted"}}"#)
        let receipt = try XCTUnwrap(BackendChatProviderPolicy.resolvedSession(response, provider: .codex, conversation: "own-thread", source: "thread/start", at: 123))
        XCTAssertEqual(receipt["approval"].string, "on-request")
        XCTAssertEqual(receipt["sandbox"]["type"].string, "workspaceWrite")
        XCTAssertEqual(receipt["network"]["enabled"].bool, false)
        XCTAssertEqual(receipt["activePermissionProfile"]["id"].string, ":workspace")
        XCTAssertEqual(receipt["reportedAt"].number, 123)
        XCTAssertTrue(receipt["workspaceTrust"].isNullish)
        XCTAssertFalse(String(decoding: try receipt.encodedJSON(), as: UTF8.self).contains("hidden"))
    }
    func testAbsentNetworkAndTrustRemainUnknownForEverySandboxType() throws {
        for type in ["dangerFullAccess", "readOnly", "workspaceWrite", "externalSandbox"] {
            let receipt = try XCTUnwrap(BackendChatProviderPolicy.resolvedSession(try json("{\"thread\":{\"id\":\"own-thread\"},\"sandbox\":{\"type\":\"\(type)\"}}"), provider: .codex, conversation: "own-thread", source: "thread/resume"))
            XCTAssertTrue(receipt["network"].isNullish)
            XCTAssertTrue(receipt["workspaceTrust"].isNullish)
            XCTAssertTrue(receipt["approval"].isNullish)
            XCTAssertTrue(receipt["sandbox"]["networkAccess"].isNullish)
        }
    }
    func testForeignThreadAndRequestedConfigCannotCreateAnEffectiveReceipt() throws {
        let response = try json(#"{"thread":{"id":"foreign"},"sandbox":{"type":"dangerFullAccess"},"approvalPolicy":"never"}"#)
        XCTAssertNil(BackendChatProviderPolicy.resolvedSession(response, provider: .codex, conversation: "own-thread", source: "thread/start"))
        XCTAssertNil(BackendChatProviderPolicy.resolvedSession(response, provider: .codex, conversation: "foreign", source: "config/read"))
        XCTAssertNil(BackendChatProviderPolicy.resolvedSession(response, provider: .gemini, conversation: "foreign", source: "thread/start"))
    }
    func testClaudeReceiptsNeedActualScopedModeAndDoNotInventSandbox() throws {
        let row = try json(#"{"type":"system","subtype":"init","session_id":"own-thread","permissionMode":"acceptEdits","sandbox":{"type":"dangerFullAccess"}}"#)
        let receipt = try XCTUnwrap(BackendChatProviderPolicy.resolvedClaude(row, conversation: "own-thread", at: 456))
        XCTAssertEqual(receipt["approval"].string, "acceptEdits")
        XCTAssertEqual(receipt["source"].string, "system/init")
        XCTAssertTrue(receipt["sandbox"].isNullish)
        XCTAssertTrue(receipt["network"].isNullish)
        XCTAssertNil(BackendChatProviderPolicy.resolvedClaude(row, conversation: "foreign"))
        XCTAssertNil(BackendChatProviderPolicy.resolvedClaudeMode(.object([]), conversation: "own-thread"))
    }
    func testReadUsesOnlyReceiptForCurrentProviderConversationWithoutRPC() async throws {
        let wire = Wire()
        let receipt = try XCTUnwrap(BackendChatProviderPolicy.resolvedSession(try json(#"{"thread":{"id":"own-thread"},"approvalPolicy":"never"}"#), provider: .codex, conversation: "own-thread", source: "thread/start"))
        let current = try await invoke("policy/read", receipt: receipt, wire: wire)
        XCTAssertEqual(current["effectivePolicy"]["approval"].string, "never")
        XCTAssertEqual(current["appPermissionChoiceSeparate"].bool, true)
        let foreign = try await invoke("policy/read", conversation: "foreign", receipt: receipt, wire: wire)
        XCTAssertTrue(foreign["effectivePolicy"].isNullish)
        let calls = await wire.recorded(); XCTAssertTrue(calls.isEmpty)
    }
    func testIdleCodexChangeUsesSameThreadResumeAndActualResolvedPolicy() async throws {
        let wire = Wire([try json(#"{"goal":null}"#), try json(#"{"thread":{"id":"own-thread"},"approvalPolicy":"on-request","sandbox":{"type":"readOnly","networkAccess":false}}"#)])
        let result = try await invoke("policy/change", try json(#"{"sandbox":"read-only","approvalPolicy":"on-request"}"#), wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["thread/goal/get", "thread/resume"])
        XCTAssertEqual(calls[1].1["threadId"].string, "own-thread")
        XCTAssertEqual(calls[1].1["sandbox"].string, "read-only")
        XCTAssertEqual(calls[1].1["excludeTurns"].bool, true)
        XCTAssertTrue(calls[1].1["config"].isNullish)
        XCTAssertTrue(calls[1].1["input"].isNullish)
        XCTAssertEqual(result["effectivePolicy"]["approval"].string, "on-request")
        XCTAssertEqual(result["changeConfirmed"].bool, true)
        XCTAssertEqual(result["changeScope"].string, "provider-current-session")
    }
    func testActiveGoalBlocksPolicyResumeWithoutStartingOrPausingWork() async throws {
        let wire = Wire([try json(#"{"goal":{"status":"active"}}"#)])
        let result = try await invoke("policy/change", try json(#"{"sandbox":"read-only"}"#), wire: wire)
        XCTAssertEqual(result["availability"].string, "unavailable")
        let calls = await wire.recorded(); XCTAssertEqual(calls.map(\.0), ["thread/goal/get"])
    }
    func testBusyOrUnsupportedBoundaryChangesCannotSendRPC() async throws {
        let wire = Wire()
        do {
            _ = try await invoke("policy/change", try json(#"{"sandbox":"read-only"}"#), busy: true, wire: wire)
            XCTFail("Busy policy change accepted")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "busy") }
        let blocked = try await invoke("policy/change", try json(#"{"workspaceTrust":"trusted","config":{"approval_policy":"never"}}"#), wire: wire)
        XCTAssertEqual(blocked["availability"].string, "unavailable")
        let calls = await wire.recorded(); XCTAssertTrue(calls.isEmpty)
    }
    func testMissingOrDifferentReturnedSettingsNeverConfirmRequestedChoice() async throws {
        for response in [#"{"thread":{"id":"own-thread"}}"#, #"{"thread":{"id":"own-thread"},"approvalPolicy":"untrusted"}"#] {
            let wire = Wire([try json(#"{"goal":null}"#), try json(response)])
            let result = try await invoke("policy/change", try json(#"{"approvalPolicy":"never"}"#), wire: wire)
            XCTAssertEqual(result["changeConfirmed"].bool, false)
            XCTAssertNotEqual(result["effectivePolicy"]["approval"].string, "never")
        }
    }
    func testClaudeEmptyAcknowledgementStaysUnconfirmed() async throws {
        let wire = Wire()
        let result = try await invoke("policy/change", try json(#"{"mode":"acceptEdits"}"#), provider: .claude, wire: wire)
        let calls = await wire.recorded()
        XCTAssertEqual(calls.map(\.0), ["set_permission_mode"])
        XCTAssertEqual(calls[0].1["mode"].string, "acceptEdits")
        XCTAssertEqual(result["changeConfirmed"].bool, false)
        XCTAssertTrue(result["effectivePolicy"].isNullish)
    }
    func testForeignChangeResponseIsRejected() async throws {
        let wire = Wire([try json(#"{"goal":null}"#), try json(#"{"thread":{"id":"foreign"},"approvalPolicy":"never"}"#)])
        do { _ = try await invoke("policy/change", try json(#"{"approvalPolicy":"never"}"#), wire: wire); XCTFail("Foreign policy response accepted") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "provider-policy-unconfirmed") }
    }
}
