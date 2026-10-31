import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// U23: Claude's model list comes from Terminal Deck's own account store only. Claude Code's own sign-in is never
/// read out of the Keychain to borrow it.
final class HootModelSourceTests: XCTestCase {
    func testClaudeListComesOnlyFromTheAppsOwnStore() async throws {
        defer { BackendAccountModelList.install { .failure("no account store in tests") } }
        BackendAccountModelList.install { .system }
        guard case .failure = await BackendHootModelSource.fetchClaude() else { return XCTFail("this Mac's own Claude Code sign-in gave a list") }
        let body = Data(#"{"data":[{"id":"claude-test-1","display_name":"Claude Test 1","created_at":"2026-01-01T00:00:00Z"}]}"#.utf8)
        BackendAccountModelList.install { .body(body) }
        guard case .success(let rows) = await BackendHootModelSource.fetchClaude() else { return XCTFail("the store's list was not used") }
        XCTAssertEqual(rows.map(\.model.id), ["claude-test-1"])
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckBackend/BackendHootModelSource.swift"), encoding: .utf8)
        for borrowed in ["/usr/bin/security", "dump-keychain", "find-generic-password", "Claude Code-credentials"] {
            XCTAssertFalse(source.contains(borrowed), "the model list reads Claude Code's own sign-in: \(borrowed)")
        }
    }
}
