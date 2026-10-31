import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class APIAccountDraftTests: XCTestCase {
    func testSecureFieldNeverEntersRPCMetadata() {
        let draft = NativeAPIAccountDraft(provider: "claude", name: "check API", key: "fixture-private-credential")
        XCTAssertFalse(draft.metadata.compact.contains("fixture-private-credential"))
        XCTAssertNil(draft.metadata["key"].string)
        XCTAssertEqual(draft.metadata["kind"].string, "anthropic")
    }
    func testAccountsParseTheirTypeWithoutExposingAKey() throws {
        let account = try XCTUnwrap(CodingAIAccountsParse.account(CodingAIJSON([
            "id": "api-key-" + String(repeating: "a", count: 24), "name": "check API", "provider": "codex", "authentication": "api-key",
            "apiKind": "compatible", "apiBaseURL": "https://models.example.invalid/v1", "apiModel": "vendor/model", "apiConfigured": true])))
        XCTAssertTrue(account.isAPIKey); XCTAssertEqual(account.apiModel, "vendor/model")
        XCTAssertEqual(NativeAPIAccounts.status(account), "Not checked")
    }
    func testMCPKeyEntryRequestHasARealDestinationAndRejectsIgnoredActions() throws {
        XCTAssertTrue(try NativeAPIAccountToolIntent.secureEntry(action: "add", credential: "request-on-mac"))
        XCTAssertTrue(try NativeAPIAccountToolIntent.secureEntry(action: "update", credential: "request-on-mac"))
        XCTAssertFalse(try NativeAPIAccountToolIntent.secureEntry(action: "add", credential: "invalid-check"))
        XCTAssertFalse(try NativeAPIAccountToolIntent.secureEntry(action: "list", credential: nil))
        for action in ["list", "check", "remove"] {
            XCTAssertThrowsError(try NativeAPIAccountToolIntent.secureEntry(action: action, credential: "request-on-mac"))
        }
        XCTAssertThrowsError(try NativeAPIAccountToolIntent.secureEntry(action: "update", credential: "invalid-check"))
    }
}
