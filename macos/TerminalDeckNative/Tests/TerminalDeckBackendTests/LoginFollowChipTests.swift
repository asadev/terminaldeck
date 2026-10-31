import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("A Claude session follows its chip")
struct LoginFollowChipTests {
    private func remembered(_ email: String, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let value = NativeRPCValue.object([.init("oauthAccount", .object([.init("emailAddress", .string(email))]))])
        try value.encodedJSON().write(to: folder.appendingPathComponent(".claude.json"))
    }
    private func launch(_ runtime: BackendF4Runtime) async throws -> BackendAccountLaunch {
        try await runtime.adapter.resolve(BackendCreateSessionInput(cwd: runtime.root.path, cols: 80, rows: 24, provider: "claude"),
            provider: BackendProviderSpec(id: "claude", command: "/bin/true", args: [], resumeArgs: []),
            loginPath: "/usr/bin:/bin", context: BackendLaunchContext(isAppComposed: true))
    }
    @Test func signedOutDefaultStartsOnMatchingSavedLoginAndNamesIt() async throws {
        let runtime = try await BackendF4Runtime.wire()
        do {
            let saved = try await runtime.create("Work")
            try remembered("work@example.com", folder: URL(fileURLWithPath: saved.configDir))
            try FileManager.default.createDirectory(atPath: runtime.configuration.systemDirectory("claude"), withIntermediateDirectories: true)
            try remembered("work@example.com", folder: runtime.configuration.homeDirectory)
            _ = await runtime.put(saved.id, #"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":4102444800000,"subscriptionType":"max"}}"#)
            await runtime.adapter.setSignInCheck { profile, _ in profile.system ? "signed-out" : "signed-in" }
            let account = try await launch(runtime)
            #expect(account.profile?.id == saved.id)
            #expect(account.environment["CLAUDE_CONFIG_DIR"] == saved.configDir)
            let served = await runtime.find(account.environment[runtime.ticketKey] ?? "", configDir: saved.configDir)
            var servedCode: Int32?
            if case .exit(let reply) = served { servedCode = reply.code }
            #expect(servedCode == 0, "the selected saved login is served to this launch")
            let chip = AccountChipRules.chipIdentity(knownEmail: "work@example.com", current: (saved.id, saved.name, false),
                live: CodingAISignIn(state: .signedIn, account: "work@example.com"))
            #expect(chip.label == "work@example.com" && chip.verified)
            await runtime.adapter.abandon(account)
            _ = await runtime.dispose(removeRoot: true)
        } catch { _ = await runtime.dispose(removeRoot: true); throw error }
    }
    @Test func noMatchingLoginRefusesWithSignInAndNeverUsesAnotherEmail() async throws {
        let runtime = try await BackendF4Runtime.wire()
        do {
            let saved = try await runtime.create("other@example.com")
            try remembered("work@example.com", folder: runtime.configuration.homeDirectory)
            await runtime.adapter.setSignInCheck { profile, _ in profile.system ? "signed-out" : "signed-in" }
            do { _ = try await launch(runtime); Issue.record("A different email must never be chosen") }
            catch { #expect(error.localizedDescription.contains(BackendAccountLaunchAdapter.notSignedInMarker)); #expect(error.localizedDescription.contains("Sign in")) }
            #expect(saved.name == "other@example.com")
            _ = await runtime.dispose(removeRoot: true)
        } catch { _ = await runtime.dispose(removeRoot: true); throw error }
    }
    @Test func staleSavedEmailCannotPickADifferentSignedInEmail() async throws {
        let runtime = try await BackendF4Runtime.wire()
        do {
            let saved = try await runtime.create("Work")
            try remembered("work@example.com", folder: URL(fileURLWithPath: saved.configDir))
            try remembered("work@example.com", folder: runtime.configuration.homeDirectory)
            await runtime.adapter.setSignInCheck(identity: { _ in "other@example.com" }) { profile, _ in
                profile.system ? "signed-out" : "signed-in"
            }
            do { _ = try await launch(runtime); Issue.record("A stale saved email must not pick a different actual login") }
            catch { #expect(error.localizedDescription.contains(BackendAccountLaunchAdapter.notSignedInMarker)) }
            _ = await runtime.dispose(removeRoot: true)
        } catch { _ = await runtime.dispose(removeRoot: true); throw error }
    }
    @Test func signedInDefaultStaysDefault() async throws {
        let runtime = try await BackendF4Runtime.wire()
        do {
            _ = try await runtime.create("work@example.com")
            await runtime.adapter.setSignInCheck { _, _ in "signed-in" }
            let account = try await launch(runtime)
            #expect(account.profile?.id == "system")
            await runtime.adapter.abandon(account)
            _ = await runtime.dispose(removeRoot: true)
        } catch { _ = await runtime.dispose(removeRoot: true); throw error }
    }
    @Test func duplicateMatchingLoginsAskUnlessAnExistingChoiceNamesOne() throws {
        let first = LoginAgainTests.kept
        var second = first; second.id = "kept-2"
        let matches = BackendDefaultClaudeLogin.candidates(remembered: "work@example.com", signedIn: [first, second],
            emails: [first.id: "work@example.com", second.id: "work@example.com"])
        #expect(matches.count == 2)
        do { _ = try BackendDefaultClaudeLogin.choose(matches, preferred: []); Issue.record("Switch must ask") }
        catch { #expect(error.localizedDescription == BackendDefaultClaudeLogin.chooseMarker) }
        #expect(try BackendDefaultClaudeLogin.choose(matches, preferred: [second.id])?.id == second.id)
    }
    @Test func actualLaunchAsksForDuplicateMatchingSavedLogins() async throws {
        let runtime = try await BackendF4Runtime.wire()
        do {
            for name in ["Work", "Personal"] {
                let saved = try await runtime.create(name)
                try remembered("work@example.com", folder: URL(fileURLWithPath: saved.configDir))
            }
            try remembered("work@example.com", folder: runtime.configuration.homeDirectory)
            await runtime.adapter.setSignInCheck { profile, _ in profile.system ? "signed-out" : "signed-in" }
            do { _ = try await launch(runtime); Issue.record("Switch must ask before a process starts") }
            catch { #expect(error.localizedDescription == BackendDefaultClaudeLogin.chooseMarker) }
            let profiles = await runtime.profiles
            let saved = try #require(try await profiles.list(provider: "claude").first { !$0.system })
            try await profiles.markUsed(id: saved.id, projectPath: runtime.root.path)
            let picked = try await launch(runtime)
            #expect(picked.profile?.id == saved.id, "the project's last-used account breaks the tie")
            await runtime.adapter.abandon(picked)
            _ = await runtime.dispose(removeRoot: true)
        } catch { _ = await runtime.dispose(removeRoot: true); throw error }
    }
    @Test func onlySavedLoginIsUsedOnlyWhenDefaultRemembersNoEmail() throws {
        let saved = LoginAgainTests.kept
        #expect(BackendDefaultClaudeLogin.candidates(remembered: nil, signedIn: [saved], emails: [:]) == [saved])
        #expect(BackendDefaultClaudeLogin.candidates(remembered: "someone@example.com", signedIn: [saved], emails: [saved.id: "work@example.com"]).isEmpty)
    }
    @Test func freshSignInAndOtherCredentialsKeepDefault() async throws {
        let root = try BackendF4Runtime.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try BackendF4Runtime.configuration(root)
        var configured = LoginAgainTests.system; configured.configDir = config.systemDirectory("claude")
        let system = configured
        let unchanged = try await BackendDefaultClaudeLogin.resolve(system, saved: [LoginAgainTests.kept], preferred: [], configuration: config,
            check: { _, fresh in fresh ? "signed-in" : "signed-out" })
        #expect(unchanged.id == "system")
        let withKey = try await BackendDefaultClaudeLogin.$environmentOverrides.withValue(["ANTHROPIC_API_KEY": "fixture"]) {
            try await BackendDefaultClaudeLogin.resolve(system, saved: [LoginAgainTests.kept], preferred: [], configuration: config, check: { _, _ in "signed-out" })
        }
        #expect(withKey.id == "system")
    }
    @Test func uncheckedDefaultNeverShowsItsRememberedEmail() {
        #expect(AccountChipRules.chipIdentity(knownEmail: "old@example.com", current: ("work", "Work", false),
            live: CodingAISignIn(state: .signedIn, account: "current@example.com")).label == "current@example.com")
        #expect(AccountChipRules.chipIdentity(knownEmail: "work@example.com", current: ("system", "Default", true), live: nil).label == "Checking…")
    }
}
