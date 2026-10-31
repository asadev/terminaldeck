import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// F4-profiles: real ports of profiles.test.ts and provider-accounts.test.ts
/// cases that were UNPORTED placeholders. Pure helpers, or the real store over
/// a temporary folder; nothing here reads a live environment or keychain.
final class BackendFoundationTestsF4Profiles: XCTestCase, @unchecked Sendable {
    /// profiles.test.ts `INHERITED` — a string only; nothing is created there.
    private let inherited = "/tmp/terminaldeck-inherited-install"
    private func configuration() throws -> BackendAccountConfiguration {
        try BackendAccountConfiguration(dataDirectory: URL(fileURLWithPath: "/fixture/data"), homeDirectory: URL(fileURLWithPath: "/fixture/home"),
            appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/fixture/never-run-helper"), inheritedEnvironment: [:])
    }
    private func profile(_ id: String, provider: String = "claude", directory: String) -> BackendAccountProfile {
        .init(id: id, name: id, provider: provider, configDir: directory, system: false, color: BackendAccountProfile.colors[0], createdAt: 1, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    /// agent-catalog.ts `configEnv`, verbatim.
    private let catalogueConfigEnv: [String: String?] = ["claude": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME", "gemini": "GEMINI_CLI_HOME", "shell": nil]

    // profiles.test.ts:291 — points at the profile config dir, not the default install.
    func testTranscriptDirPointsAtTheProfileConfigDir() {
        let p = profile("work", directory: "/fixture/data/profiles/work")
        XCTAssertEqual(BackendAccountProfile.profileTranscriptDir(p, cwd: "/Users/asad/Projects/terminaldeck"),
                       "/fixture/data/profiles/work/projects/-Users-asad-Projects-terminaldeck")
    }

    // profiles.test.ts:315 — never slugs to an empty directory name.
    func testNeverSlugsToAnEmptyDirectoryName() async throws {
        XCTAssertEqual(BackendAccountProfile.slugifyProfileID("!!!"), "profile")
        XCTAssertEqual(BackendAccountProfile.slugifyProfileID(""), "profile")
        // The same helper allocates create's id, so "!!!" gets its own folder
        // rather than the profiles root a delete would then be handed.
        try await BackendFoundationTestsAccountsWithFixture { f in
            let p = try await f.create("!!!")
            XCTAssertEqual(p.id, "profile"); XCTAssertEqual(p.configDir, f.configuration.profilesRoot.appendingPathComponent("profile").path)
        }
    }

    // profiles.test.ts:888 — names the agent, the variable and the directory.
    func testInheritedInstallNamesAgentVariableAndDirectory() {
        XCTAssertEqual(BackendAccountProfile.inheritedSystemInstalls(environment: ["CLAUDE_CONFIG_DIR": inherited]),
                       [BackendAccountInheritedInstall(provider: "claude", env: "CLAUDE_CONFIG_DIR", dir: inherited)])
    }

    // profiles.test.ts:893 — empty on the ordinary machine, and a blank variable is unset.
    func testInheritedInstallsAreEmptyOrdinarilyAndIgnoreBlankVariable() throws {
        XCTAssertEqual(BackendAccountProfile.inheritedSystemInstalls(environment: [:]), [])
        XCTAssertEqual(BackendAccountProfile.inheritedSystemInstalls(environment: ["CLAUDE_CONFIG_DIR": "   "]), [])
        XCTAssertEqual(try configuration().systemDirectory("claude", environment: ["CLAUDE_CONFIG_DIR": "   "]), "/fixture/home/.claude")
    }

    // profiles.test.ts:901 — every agent whose store was redirected, not just Claude's.
    func testEveryRedirectedAgentIsReported() {
        let both = BackendAccountProfile.inheritedSystemInstalls(environment: ["CLAUDE_CONFIG_DIR": inherited, "CODEX_HOME": "/tmp/cx"])
        XCTAssertEqual(both.map(\.provider).sorted(), ["claude", "codex"])
    }

    // provider-accounts.test.ts:117 — nothing when there is no account, or no directory.
    func testNoAccountOrNoDirectoryExportsNothing() {
        XCTAssertEqual(BackendAccountStrategies.accountEnv(provider: "claude", account: nil), [:])
        XCTAssertEqual(BackendAccountStrategies.accountEnv(provider: "claude", account: (provider: "claude", configDir: "")), [:])
    }

    // provider-accounts.test.ts:124 — the sign-in command is the agent's own.
    func testSignInCommandIsTheAgentsOwn() {
        XCTAssertEqual(BackendAccountStrategies.signInCommandLine("claude", bin: "claude"), "claude auth login")
        XCTAssertEqual(BackendAccountStrategies.signInCommandLine("codex", bin: "codex"), "codex login")
    }

    // provider-accounts.test.ts:131 — absent for an agent with no account of its own.
    func testNoSignInCommandForAnAgentWithoutAccounts() {
        XCTAssertNil(BackendAccountStrategies.signInCommandLine("gemini", bin: "gemini"))
        XCTAssertNil(BackendAccountStrategies.signInCommandLine("shell", bin: "/bin/zsh"))
    }

    // provider-accounts.test.ts:145 — absent where the row shows a reason instead.
    func testNoSignOutCommandWhereTheRowShowsAReason() {
        XCTAssertNil(BackendAccountStrategies.signOutCommandLine("gemini", bin: "gemini"))
        XCTAssertNil(BackendAccountStrategies.signOutCommandLine("shell", bin: "/bin/zsh"))
        XCTAssertFalse(BackendAccountStrategies.hasSignOut("gemini"))
        XCTAssertTrue(BackendAccountStrategies.hasSignOut("claude"))
    }

    // provider-accounts.test.ts:227 — both tables built from the same catalogue.
    func testBothTablesAreBuiltFromTheSameCatalogue() throws {
        XCTAssertEqual(BackendAccountStrategies.all.map(\.provider), CodingAICatalog.all.map(\.id))
        for entry in CodingAICatalog.all {
            let strategy = try XCTUnwrap(BackendAccountStrategies.strategy(entry.id))
            XCTAssertEqual(strategy.label, entry.label)
            XCTAssertEqual(strategy.configEnv, catalogueConfigEnv[entry.id] ?? nil, entry.id)
            XCTAssertEqual(BackendAccountStrategies.supportsAccounts(entry.id), entry.logins == .multiple, entry.id)
            XCTAssertEqual(entry.canHaveAccounts, entry.logins == .multiple, entry.id)
            XCTAssertEqual(BackendAccountStrategies.hasSignOut(entry.id), entry.hasSignOut, entry.id)
            XCTAssertEqual(BackendAccountProfile.providerLabel(entry.id), entry.label)
        }
        // The account-providers rows the screens read come from that one declaration.
        let rows = BackendAccountRPC.accountProvidersView()["providers"].elements ?? []
        XCTAssertEqual(rows.map { $0["id"].string }, ["claude", "codex", "gemini"])
        for row in rows {
            let id = try XCTUnwrap(row["id"].string), agent = try XCTUnwrap(CodingAICatalog.agent(id))
            XCTAssertEqual(row["label"], .string(agent.label)); XCTAssertEqual(row["supported"], .bool(agent.canHaveAccounts))
            XCTAssertEqual(row["canSignIn"], .bool(agent.hasAnyLogin))
            XCTAssertEqual(row["configEnv"], (catalogueConfigEnv[id] ?? nil).map(NativeRPCValue.string) ?? .null)
            XCTAssertEqual(row["reason"], agent.canHaveAccounts ? .null : .string(try XCTUnwrap(agent.loginsNote)))
        }
    }

    // provider-accounts.test.ts:236 — the picker keeps no second list to drift.
    func testRendererKeepsNoSecondListToDrift() throws {
        let package = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Both native ports of ProviderPicker.tsx read the catalogue.
        for name in ["CodingAIAgents.swift", "NewSessionRules.swift"] {
            let source = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNativeCore/" + name), encoding: .utf8)
            XCTAssertNil(source.range(of: #"canHaveAccounts:\s*(true|false)\s*,"#, options: .regularExpression), name)
            XCTAssertTrue(source.contains("CodingAICatalog"), name)
        }
        for agent in CodingAICatalog.all { XCTAssertEqual(agent.canHaveAccounts, agent.logins == .multiple, agent.id) }
    }
}
