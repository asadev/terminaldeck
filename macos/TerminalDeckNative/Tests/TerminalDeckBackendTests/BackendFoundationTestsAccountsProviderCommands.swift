import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Reuse the existing profiles-signin fake executor/dependencies. The fake
/// handles every command, including Gemini's presence check; no child runs.
final class BackendFoundationTestsAccountsProviderCommands: XCTestCase, @unchecked Sendable {
    // provider-accounts.test.ts:138 — prove real sign-out command selection.
    func testClaudeAndCodexRunTheirOwnLogoutCommands() async throws {
        for (provider, expected) in [("claude", ["auth", "logout"]), ("codex", ["logout"])] {
            let profile = BackendAppAccountTestPortProfile(provider)
            let signedOut = provider == "codex" ? "Not logged in" : #"{"loggedIn":false,"authMethod":"none"}"#
            let executor = BackendAppSessionTestPortExecutor([.init(exitCode: 0), .init(stdout: signedOut, exitCode: 0)])
            let service = BackendAppAccountTestPortService(try .init(profile: profile), executor: executor)
            _ = await service.signOut(profile.id)
            let calls = await executor.calls
            XCTAssertEqual(calls.first?.command, provider); XCTAssertEqual(calls.first?.arguments, expected)
        }
    }
    // provider-accounts.test.ts:165 — no CLI status question for Gemini/shell.
    func testGeminiAndShellHaveNoCLIStatusProbe() async throws {
        for provider in ["gemini", "shell"] {
            let profile = BackendAppAccountTestPortProfile(), executor = BackendAppSessionTestPortExecutor([.init(exitCode: 44)])
            let service = BackendAppAccountTestPortService(try .init(profile: profile), executor: executor)
            let report = await service.read(profile, provider: provider, refresh: true), calls = await executor.calls
            XCTAssertEqual(report.command, ""); XCTAssertFalse(calls.contains { $0.command == provider })
        }
    }
}
