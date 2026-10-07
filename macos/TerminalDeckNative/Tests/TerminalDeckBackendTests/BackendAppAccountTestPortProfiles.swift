import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppAccountTestPortProfiles: XCTestCase, @unchecked Sendable {
    typealias P = BackendAppAccountSignInParsing
    private func report(_ provider: String, _ probe: BackendAppSessionCommandResult) -> BackendAppAccountSignInReport {
        P.report(profileID: "work", provider: provider, command: provider == "codex" ? "codex login status" : "claude auth status --json", probe: probe, now: 1)
    }
    private func report(_ probe: BackendAppSessionCommandResult) -> BackendAppAccountSignInReport { report("claude", probe) }
    func testSignedInAuthKeepsExactAddressAndPlan() { XCTAssertEqual(P.claude(BackendAppAccountTestPortSignedIn), .init(loggedIn: true, account: "someone@example.com", plan: "max")) }
    func testSignedOutAuthKeepsNoneMethod() { XCTAssertEqual(P.claude(BackendAppAccountTestPortSignedOut), .init(loggedIn: false, account: nil, plan: "none")) }
    func testAuthNoticeBeforeJSONObject() { XCTAssertEqual(P.claude("A new version of Claude Code is available.\n" + BackendAppAccountTestPortSignedIn + "\n")?.loggedIn, true) }
    func testAuthOrganizationFallback() { XCTAssertEqual(P.claude(#"{"loggedIn":true,"orgName":"Acme","authMethod":"apiKey"}"#), .init(loggedIn: true, account: "Acme", plan: "apiKey")) }
    func testAuthRefusesEveryUnrecognizedFixture() { for raw in ["Not logged in · Please run /login", "zsh: command not found: claude", "{\"loggedIn\":", "{\"ok\":true}", ""] { XCTAssertNil(P.claude(raw), raw) } }
    func testDescriptionAccountAndPlanExact() { XCTAssertEqual(P.describe(.init(loggedIn: true, account: "a@b.com", plan: "max")), "Signed in as a@b.com · max") }
    func testDescriptionSaysOnlyKnownFacts() { XCTAssertEqual(P.describe(.init(loggedIn: true, account: nil, plan: nil)), "Signed in.") }
    func testDescriptionSignedOutNamesSession() { XCTAssertTrue(P.describe(.init(loggedIn: false, account: nil, plan: nil)).contains("session")) }
    func testReportSignedInOnlyFromCLIAnswer() { let r = report(.init(stdout: BackendAppAccountTestPortSignedIn, exitCode: 0)); XCTAssertEqual(r.state, "signed-in"); XCTAssertEqual(r.account, "someone@example.com") }
    func testReportSignedOutFromCLIAnswer() { let r = report(.init(stdout: BackendAppAccountTestPortSignedOut, exitCode: 0)); XCTAssertEqual(r.state, "signed-out"); XCTAssertNil(r.account) }
    func testReportFailureIsUnknownWithCommandAndShellWords() { let r = report(.init(stderr: "zsh: command not found: claude", exitCode: 127)); XCTAssertEqual(r.state, "unknown"); XCTAssertTrue(r.detail.contains("command not found")); XCTAssertTrue(r.detail.contains("claude auth status --json")) }
    func testReportTimeoutSaysTenSeconds() { let r = report(.init(killed: true)); XCTAssertEqual(r.state, "unknown"); XCTAssertTrue(r.detail.contains("10")) }
    func testReportSilentFailureDoesNotInventWords() { XCTAssertTrue(report(.init(exitCode: 1)).detail.contains("answered nothing")) }
    func testReportCarriesCommandActuallyRun() { XCTAssertEqual(report(.init(stdout: BackendAppAccountTestPortSignedIn, exitCode: 0)).command, "claude auth status --json") }
    func testReadRunsExactClaudeArgsUnderAccountDirectory() async throws {
        let profile = BackendAppAccountTestPortProfile(), e = BackendAppSessionTestPortExecutor([.init(stdout: BackendAppAccountTestPortSignedIn, exitCode: 0)])
        let service = BackendAppAccountTestPortService(try .init(profile: profile), executor: e)
        let r = await service.read(profile, refresh: true), calls = await e.calls
        XCTAssertEqual(r.state, "signed-in"); XCTAssertEqual(calls[0].environment["CLAUDE_CONFIG_DIR"], profile.configDir); XCTAssertEqual(calls[0].arguments, ["auth", "status", "--json"])
    }
    func testReadSystemInstallDoesNotExportConfigDirectory() async throws {
        let profile = BackendAppAccountTestPortProfile(system: true), e = BackendAppSessionTestPortExecutor([.init(stdout: BackendAppAccountTestPortSignedIn, exitCode: 0)])
        let service = BackendAppAccountTestPortService(try .init(profile: profile), executor: e)
        _ = await service.read(profile, refresh: true); let calls = await e.calls; XCTAssertNil(calls[0].environment["CLAUDE_CONFIG_DIR"])
    }
    func testReadCacheReusesAnswerAndRefreshOverridesIt() async throws {
        let profile = BackendAppAccountTestPortProfile(), e = BackendAppSessionTestPortExecutor([.init(stdout: BackendAppAccountTestPortSignedIn, exitCode: 0), .init(stdout: BackendAppAccountTestPortSignedIn, exitCode: 0)])
        let service = BackendAppAccountTestPortService(try .init(profile: profile), executor: e)
        _ = await service.read(profile); _ = await service.read(profile); let before = await e.calls; XCTAssertEqual(before.count, 1)
        _ = await service.read(profile, refresh: true); let after = await e.calls; XCTAssertEqual(after.count, 2)
    }
    func testReadGeminiNeverSpawnsItsCLI() async throws {
        let profile = BackendAppAccountTestPortProfile(), e = BackendAppSessionTestPortExecutor([.init(exitCode: 44)])
        let service = BackendAppAccountTestPortService(try .init(profile: profile), executor: e)
        let r = await service.read(profile, provider: "gemini", refresh: true), calls = await e.calls
        XCTAssertTrue(["signed-in", "signed-out"].contains(r.state)); XCTAssertNotEqual(r.state, "unsupported"); XCTAssertEqual(r.command, ""); XCTAssertFalse(calls.contains { $0.command == "gemini" || $0.command == "claude" })
    }
    func testReadBrokenBinaryNeverSpawnsOrPastesStackTrace() async throws {
        let profile = BackendAppAccountTestPortProfile("codex"), e = BackendAppSessionTestPortExecutor([])
        let service = BackendAppAccountTestPortService(try .init(profile: profile, broken: true), executor: e)
        let r = await service.read(profile, refresh: true), calls = await e.calls
        XCTAssertEqual(r.state, "unknown"); XCTAssertTrue(calls.isEmpty); XCTAssertTrue(r.detail.contains("will not start")); XCTAssertTrue(r.detail.contains("npm install -g @openai/codex")); XCTAssertFalse(r.detail.contains("ENOENT"))
    }
    func testReadNeverRejectsFailedSpawnEvidence() async throws {
        let profile = BackendAppAccountTestPortProfile(), e = BackendAppSessionTestPortExecutor([.init(stderr: "EACCES", exitCode: 13)])
        let r = await BackendAppAccountTestPortService(try .init(profile: profile), executor: e).read(profile, refresh: true); XCTAssertEqual(r.state, "unknown")
    }
    func testUnsupportedShellHasNoAccount() { XCTAssertTrue(P.unsupportedReason("shell").contains("no account")) }
    func testUnsupportedCodexExplainsLoginRisk() { XCTAssertTrue(P.unsupportedReason("codex").contains("login")) }
    func testCodexObservedAnswersExact() { XCTAssertEqual(P.codex("Not logged in\n"), .init(loggedIn: false, account: nil, plan: nil)); XCTAssertEqual(P.codex("Logged in using ChatGPT\n"), .init(loggedIn: true, account: nil, plan: "ChatGPT")) }
    func testCodexOtherBinaryPhrasings() { XCTAssertEqual(P.codex("Logged in using an API key - work")?.plan, "an API key - work"); XCTAssertEqual(P.codex("Logged in using personal access token")?.plan, "personal access token"); XCTAssertEqual(P.codex("Logged in using Amazon Bedrock API key")?.loggedIn, true) }
    func testCodexDoesNotNameEmailItDidNotPrint() { XCTAssertNil(P.codex("Logged in using ChatGPT")?.account) }
    func testCodexIgnoresNoticeAboveItsAnswer() { XCTAssertEqual(P.codex("\n  A new version is available.\n\nLogged in using ChatGPT\n")?.plan, "ChatGPT") }
    func testCodexUnrecognizedAnswersRemainNil() { for said in ["", "command not found: codex", "Connexion établie", "{\"loggedIn\":true}"] { XCTAssertNil(P.codex(said)) } }
    func testCodexReportUsesOwnParserAndExactDescription() { let r = report("codex", .init(stdout: "Logged in using ChatGPT\n", exitCode: 0)); XCTAssertEqual(r.state, "signed-in"); XCTAssertEqual(r.plan, "ChatGPT"); XCTAssertEqual(r.detail, "Signed in using ChatGPT") }
    func testSignedOutReportNamesEachAgentsLoginCommand() { XCTAssertTrue(report("codex", .init(stdout: "Not logged in", exitCode: 0)).detail.contains("codex login")); XCTAssertTrue(report(.init(stdout: BackendAppAccountTestPortSignedOut, exitCode: 0)).detail.contains("claude auth login")) }
    func testUnreadableCodexProbeIsUnknownWithActualStderr() { let r = report("codex", .init(stderr: "command not found: codex", exitCode: 127)); XCTAssertEqual(r.state, "unknown"); XCTAssertTrue(r.detail.contains("command not found: codex")) }
    func testCodexQuestionAndEnvironmentComeFromProfile() async throws {
        let profile = BackendAppAccountTestPortProfile("codex"), e = BackendAppSessionTestPortExecutor([.init(stdout: "Logged in using ChatGPT\n", exitCode: 0)])
        let r = await BackendAppAccountTestPortService(try .init(profile: profile), executor: e).read(profile, refresh: true), calls = await e.calls
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls[0].arguments, ["login", "status"]); XCTAssertEqual(calls[0].environment["CODEX_HOME"], profile.configDir); XCTAssertNil(calls[0].environment["CLAUDE_CONFIG_DIR"]); XCTAssertEqual(r.provider, "codex"); XCTAssertEqual(r.state, "signed-in"); XCTAssertEqual(r.command, "codex login status")
    }
    func testSystemInstallExportsNoAgentOverride() async throws { try await testReadSystemInstallDoesNotExportConfigDirectory() }
    func testLogoutRunsOwnCommandThenConfirmsSignedOut() async throws {
        let profile = BackendAppAccountTestPortProfile("codex"), e = BackendAppSessionTestPortExecutor([.init(stdout: "Successfully logged out", exitCode: 0), .init(stdout: "Not logged in", exitCode: 0)])
        let r = await BackendAppAccountTestPortService(try .init(profile: profile), executor: e).signOut(profile.id), calls = await e.calls
        XCTAssertEqual(calls[0].arguments, ["logout"]); XCTAssertTrue(calls.contains { $0.arguments == ["login", "status"] }); XCTAssertEqual(r["ok"].bool, true); XCTAssertTrue(r["message"].string?.contains("signed out") == true); XCTAssertEqual(r["session"], .null)
    }
    func testLogoutDoesNotBelieveExitStatusIfLoginRemains() async throws {
        let profile = BackendAppAccountTestPortProfile("codex"), e = BackendAppSessionTestPortExecutor([.init(stdout: "Successfully logged out", exitCode: 0), .init(stdout: "Logged in using ChatGPT", exitCode: 0)])
        let r = await BackendAppAccountTestPortService(try .init(profile: profile), executor: e).signOut(profile.id)
        XCTAssertEqual(r["ok"].bool, false); XCTAssertTrue(r["message"].string?.contains("still signed in") == true)
    }
    func testLogoutDeletedAccountHasExactNoSuchLoginResult() async throws {
        let e = BackendAppSessionTestPortExecutor([]), service = BackendAppAccountTestPortService(try .init(profile: BackendAppAccountTestPortProfile()), executor: e)
        let r = await service.signOut("gone-in-between")
        XCTAssertEqual(r["ok"].bool, false); XCTAssertTrue(r["message"].string?.lowercased().contains("no such login") == true); XCTAssertEqual(r["session"], .null)
    }
}
