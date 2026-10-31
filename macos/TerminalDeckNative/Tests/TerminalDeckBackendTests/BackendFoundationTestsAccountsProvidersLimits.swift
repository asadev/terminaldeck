import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsAccountsProvidersLimits: XCTestCase, @unchecked Sendable {
    private func profile(_ provider: String, directory: String, system: Bool = false) -> BackendAccountProfile {
        .init(id: "work", name: "Work", provider: provider, configDir: directory, system: system, color: "--accent", createdAt: 1, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    /// Compare the account-variable contribution; PATH belongs to the probe
    /// transport rather than accountEnv/sessionEnv in the source.
    private func contribution(_ profile: BackendAccountProfile, provider: String) -> [String: String] {
        var env = BackendAppAccountSignInParsing.accountEnvironment(profile, provider: provider, inherited: [:], path: "/usr/bin:/bin", vaultVariables: [])
        XCTAssertEqual(env.removeValue(forKey: "PATH"), "/usr/bin:/bin")
        return env
    }
    // provider-accounts.test.ts:35
    func testClaudeAndCodexAreMultipleLoginsWithOwnVariables() {
        XCTAssertEqual(CodingAICatalog.claude.logins, .multiple); XCTAssertEqual(CodingAICatalog.codex.logins, .multiple)
        XCTAssertEqual(BackendAccountProfile.configEnvironment("claude"), "CLAUDE_CONFIG_DIR"); XCTAssertEqual(BackendAccountProfile.configEnvironment("codex"), "CODEX_HOME")
    }
    // provider-accounts.test.ts:42
    func testGeminiVariableDoesNotMoveItsLogin() {
        XCTAssertEqual(BackendAccountProfile.configEnvironment("gemini"), "GEMINI_CLI_HOME"); XCTAssertFalse(CodingAICatalog.gemini.canHaveAccounts)
        XCTAssertEqual(CodingAICatalog.gemini.logins, .single)
    }
    // provider-accounts.test.ts:64
    func testShellHasNoLoginOrConfigVariable() { XCTAssertFalse(CodingAICatalog.shell.canHaveAccounts); XCTAssertEqual(CodingAICatalog.shell.logins, .none); XCTAssertNil(BackendAccountProfile.configEnvironment("shell")) }
    // provider-accounts.test.ts:69
    func testMultipleLoginProvidersKeepCatalogueOrder() { XCTAssertEqual(CodingAICatalog.all.filter(\.canHaveAccounts).map(\.id), ["claude", "codex"]) }
    // provider-accounts.test.ts:73
    func testEveryProviderHasAccountDeclaration() { XCTAssertEqual(CodingAICatalog.all.map(\.id), ["claude", "codex", "gemini", "shell"]); for provider in ["claude", "codex", "gemini", "shell"] { XCTAssertEqual(CodingAICatalog.agent(provider)?.id, provider) } }
    // provider-accounts.test.ts:79
    func testUnsupportedReasonsSayActualAgentProblem() { let gemini = BackendAppAccountSignInParsing.unsupportedReason("gemini"), shell = BackendAppAccountSignInParsing.unsupportedReason("shell"); XCTAssertTrue(gemini.contains("keychain")); XCTAssertTrue(shell.contains("no account")); XCTAssertNotEqual(gemini, shell) }
    // provider-accounts.test.ts:93 and profiles.test.ts:230,266
    func testEachProviderExportsItsOwnAccountVariable() {
        XCTAssertEqual(contribution(profile("claude", directory: "/deck/profiles/work"), provider: "claude"), ["CLAUDE_CONFIG_DIR": "/deck/profiles/work"])
        XCTAssertEqual(contribution(profile("codex", directory: "/deck/profiles/work-codex"), provider: "codex"), ["CODEX_HOME": "/deck/profiles/work-codex"])
    }
    // provider-accounts.test.ts:100 and profiles.test.ts:243,266
    func testWrongAgentGetsNoAccountVariable() { XCTAssertEqual(contribution(profile("codex", directory: "/deck/profiles/work-codex"), provider: "claude"), [:]); XCTAssertEqual(contribution(profile("claude", directory: "/deck/profiles/work"), provider: "codex"), [:]) }
    // provider-accounts.test.ts:112 and profiles.test.ts:243,281
    func testUnverifiedLoginVariableIsNotExported() { for provider in ["gemini", "shell"] { XCTAssertEqual(contribution(profile(provider, directory: "/deck/profiles/" + provider), provider: provider), [:]) }; XCTAssertEqual(contribution(profile("claude", directory: "/deck/profiles/g"), provider: "gemini"), [:]) }
    // provider-accounts.test.ts:117 (empty directory; nil-account seam separately logged).
    func testEmptyAccountDirectoryExportsNothing() { XCTAssertEqual(contribution(profile("claude", directory: ""), provider: "claude"), [:]) }
    // profiles.test.ts:235,491
    func testSystemInstallExportsNoOverride() { for provider in ["claude", "codex", "gemini"] { XCTAssertEqual(contribution(profile(provider, directory: "/fixture/home/." + provider, system: true), provider: provider), [:]) } }
    // profiles.test.ts:259
    func testSupportedProfileIsolationIsExactlyClaudeAndCodex() { for (provider, supports) in [("claude", true), ("codex", true), ("gemini", false), ("shell", false)] { XCTAssertEqual(CodingAICatalog.agent(provider)?.canHaveAccounts, supports) } }
    // provider-accounts.test.ts:145
    func testAgentsWithoutLogoutHaveNoSignOut() { XCTAssertFalse(CodingAICatalog.hasSignOut("gemini")); XCTAssertFalse(CodingAICatalog.hasSignOut("shell")); XCTAssertTrue(CodingAICatalog.hasSignOut("claude")) }
    // provider-accounts.test.ts:179 (shell must also match the provider table).
    func testAccountAndCatalogueProviderLabelsAgree() { for provider in ["claude", "codex", "gemini", "shell"] { XCTAssertEqual(BackendAccountProfile.providerLabel(provider), CodingAICatalog.label(provider), provider) } }
    // vault-profiles.test.ts:399. Both fake probe transports stay local.
    func testProbeStripsEveryInheritedVaultCredentialVariable() {
        let keys: Set<String> = ["TERMINALDECK_ACCOUNT_VAULT", "TERMINALDECK_ACCOUNT_TICKET", "TERMINALDECK_ACCOUNT_HOME"]
        let inherited = ["TERMINALDECK_ACCOUNT_VAULT": "/somewhere/else.sock", "TERMINALDECK_ACCOUNT_TICKET": String(repeating: "f", count: 48), "TERMINALDECK_ACCOUNT_HOME": "/foreign", "PATH": "/old"]
        let env = BackendAppAccountSignInParsing.accountEnvironment(profile("claude", directory: "/fixture/home/.claude", system: true), provider: "claude", inherited: inherited, path: "/usr/bin", vaultVariables: keys)
        XCTAssertEqual(env, ["PATH": "/usr/bin"])
    }

    // account-limits.ts delegates to store.ts; these are all seven direct
    // account-limit store cases, with synthetic time and temporary state files.
    // store.test.ts:254
    func testUnknownLimitAccountIsNull() async { let store = NativeStateStore(); let value = await store.getAccountLimit("/never/seen"); XCTAssertEqual(value, .null); await store.close() }
    // store.test.ts:265
    func testAccountLimitsMergeSeparatelyLearnedFacts() async throws {
        let store = NativeStateStore(clock: { 1_000 }); _ = try await store.setAccountLimit("/one", patch: BackendFoundationTestsAccountsObject([("billing", .string("api"))])); _ = try await store.setAccountLimit("/one", patch: BackendFoundationTestsAccountsObject([("answer", .string("no-limits"))]))
        let value = await store.getAccountLimit("/one"); XCTAssertEqual(value["billing"], .string("api")); XCTAssertEqual(value["answer"], .string("no-limits")); XCTAssertEqual(value["at"], .number(1_000)); await store.close()
    }
    // store.test.ts:276
    func testAccountLimitImmediatelyPersists() async throws { try await BackendFoundationTestsAccountsWithFixture { f in _ = try await f.state.setAccountLimit("/one", patch: BackendFoundationTestsAccountsObject([("answer", .string("no-limits"))])); let disk = try NativeRPCValue.parseJSON(Data(contentsOf: f.configuration.dataDirectory.appendingPathComponent("state.json"))); XCTAssertEqual(disk["accountLimits"]["/one"]["answer"], .string("no-limits")) } }
    // store.test.ts:282
    func testForgetAccountLimitRemovesMemoryAndDisk() async throws { try await BackendFoundationTestsAccountsWithFixture { f in _ = try await f.state.setAccountLimit("/one", patch: BackendFoundationTestsAccountsObject([("billing", .string("api")), ("answer", .string("no-limits"))])); try await f.state.forgetAccountLimit("/one"); let value = await f.state.getAccountLimit("/one"), disk = try NativeRPCValue.parseJSON(Data(contentsOf: f.configuration.dataDirectory.appendingPathComponent("state.json"))); XCTAssertEqual(value, .null); XCTAssertFalse(disk["accountLimits"].has("/one")) } }
    // store.test.ts:291
    func testAccountLimitsNeverCrossAccountBoundary() async throws { let store = NativeStateStore(); _ = try await store.setAccountLimit("/a", patch: BackendFoundationTestsAccountsObject([("answer", .string("no-limits"))])); _ = try await store.setAccountLimit("/b", patch: BackendFoundationTestsAccountsObject([("billing", .string("subscription"))])); let a = await store.getAccountLimit("/a"), b = await store.getAccountLimit("/b"); XCTAssertEqual(a["answer"], .string("no-limits")); XCTAssertEqual(b["answer"], .missing); await store.close() }
    // store.test.ts:298
    func testLegacyStateKnowsNothingAboutLimits() async { let store = NativeStateStore(initialState: BackendFoundationTestsAccountsObject([("version", .number(1)), ("projects", .array([]))])); let value = await store.getAccountLimit("/one"); XCTAssertEqual(value, .null); await store.close() }
    // store.test.ts:307
    func testHandEditedAccountLimitArrayKnowsNothing() async { let store = NativeStateStore(initialState: BackendFoundationTestsAccountsObject([("version", .number(1)), ("projects", .array([])), ("accountLimits", .array([.string("not"), .string("a"), .string("map")]))])); let value = await store.getAccountLimit("/one"); XCTAssertEqual(value, .null); await store.close() }
}
