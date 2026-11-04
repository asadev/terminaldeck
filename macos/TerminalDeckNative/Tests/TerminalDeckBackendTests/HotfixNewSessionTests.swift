import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private enum HotfixProfileRead {
    @TaskLocal static var approved = false
}
private actor HotfixProviders: BackendProviderLaunchResolver {
    nonisolated let readiness: BackendLaunchReadiness = .ready
    var command = "/usr/bin/true"
    func change() { command = "/bin/echo" }
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        .init(id: input.provider ?? "claude", command: command, args: [], resumeArgs: [])
    }
}
private struct HotfixProbe: BackendAppSessionCommandExecuting {
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        let text = arguments == ["mcp", "list", "--json"] ? "[]" : "--json --model --effort --permission-mode --mcp-config --strict-mcp-config --settings --config --sandbox --ask-for-approval"
        return .init(stdout: text, exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { XCTFail("No real CLI in this fixture") }
}
private actor HotfixLeases {
    var reserved = 0, abandoned = 0, written = 0
    func lease(_ root: URL) -> BackendAGSLaunchFileLease {
        reserved += 1
        return .init(id: UUID(), directory: root.appendingPathComponent("lease-\(reserved)"),
            write: { _ in await self.write() }, bind: { _ in }, abandon: { await self.abandon() })
    }
    func write() { written += 1 }
    func abandon() { abandoned += 1 }
}

final class HotfixNewSessionTests: XCTestCase, @unchecked Sendable {
    private func binding(_ fixture: BackendFoundationTestsAccountsFixture, providers: HotfixProviders = HotfixProviders(), leases: HotfixLeases = HotfixLeases()) -> BackendAGSLaunchBinding {
        let facts = BackendAGSSelectedAccountFacts(providers: providers, profiles: fixture.profiles,
            configuration: fixture.configuration, projectRoot: { $0 }, command: HotfixProbe())
        return .init(facts: facts, reserve: { await leases.lease(fixture.root) }, authorize: { _, _ in })
    }
    private func account(_ profile: BackendAccountProfile) -> BackendAccountLaunch {
        let key = BackendAccountProfile.configEnvironment(profile.provider)!
        return .init(profile: profile.identity, environment: [key: profile.configDir], path: "/usr/bin:/bin")
    }

    func testEveryDefaultClaudeLoginSurvivesRestartAndTheUnscopedReservation() async throws {
        // Each round is a new account reader / preparation owner, as after replacing a keeper.
        for _ in 0..<2 {
            try await BackendFoundationTestsAccountsWithFixture { fixture in
                for number in 1...3 {
                    let saved = try await fixture.create("existing-\(number)")
                    await fixture.profiles.setDefaultLoginResolver { system, _, _ in
                        HotfixProfileRead.approved ? saved : system
                    }
                    let input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude")
                    let binding = self.binding(fixture)
                    let prepared = try await HotfixProfileRead.$approved.withValue(true) {
                        try await binding.prepare(input, settings: .init(provider: "claude"), context: .init(), nativeServerNames: [])
                    }
                    let unpinned = try await fixture.profiles.resolve(sessionProfileID: input.profileId, projectPath: input.cwd, provider: "claude")
                    XCTAssertEqual(unpinned.id, "system")
                    let provider = BackendProviderSpec(id: "claude", command: "/usr/bin/true", args: [], resumeArgs: [])
                    XCTAssertThrowsError(try BackendAGSLaunchBinding.requireAccount(prepared, actual: self.account(unpinned), provider: provider))
                    XCTAssertEqual(prepared.input.profileId, saved.id)
                    _ = try await binding.stage(prepared, generatedServers: .object([]), context: .init(), originalInput: input)
                    let final = try await fixture.profiles.resolve(sessionProfileID: prepared.input.profileId, projectPath: input.cwd, provider: "claude")
                    XCTAssertEqual(final.id, saved.id)
                    XCTAssertNoThrow(try BackendAGSLaunchBinding.requireAccount(prepared, actual: self.account(final), provider: provider))
                }
            }
        }
    }

    func testNormalClaudeAndCodexChoicesKeepTheirLoginAndStillRejectRedirects() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            for name in ["claude", "codex"] {
                let saved = try await fixture.create("existing-" + name, provider: name)
                var input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: name)
                input.profileId = saved.id
                let binding = self.binding(fixture)
                let prepared = try await binding.prepare(input, settings: .init(provider: name), context: .init(), nativeServerNames: [])
                _ = try await binding.stage(prepared, generatedServers: .object([]), context: .init(), originalInput: input)
                let provider = BackendProviderSpec(id: name, command: "/usr/bin/true", args: [], resumeArgs: [])
                XCTAssertEqual(prepared.input.profileId, saved.id)
                XCTAssertNoThrow(try BackendAGSLaunchBinding.requireAccount(prepared, actual: self.account(saved), provider: provider))
                let redirected = BackendAccountLaunch(profile: saved.identity,
                    environment: [BackendAccountProfile.configEnvironment(name)!: fixture.root.appendingPathComponent("other-home").path], path: "/usr/bin:/bin")
                XCTAssertThrowsError(try BackendAGSLaunchBinding.requireAccount(prepared, actual: redirected, provider: provider))
                let other = BackendAccountLaunch(profile: .init(id: "different-login", name: "Other"), environment: [:], path: "/usr/bin:/bin")
                XCTAssertThrowsError(try BackendAGSLaunchBinding.requireAccount(prepared, actual: other, provider: provider))
                await binding.abandon(prepared)
            }
        }
    }

    func testChangedCLIRepreparesOnceWithNewFilesAndReleasesTheOldLease() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let providers = HotfixProviders(), leases = HotfixLeases()
            let binding = self.binding(fixture, providers: providers, leases: leases)
            let input = BackendCreateSessionInput(cwd: fixture.configuration.homeDirectory.path, provider: "claude")
            let selected = try await BackendAGSLaunchBinding.retryingSelection {
                let prepared = try await binding.prepare(input, settings: .init(provider: "claude"), context: .init(), nativeServerNames: [])
                do {
                    _ = try await binding.stage(prepared, generatedServers: .object([]), context: .init(), originalInput: input)
                    await providers.change()
                    let actualProvider = try await providers.resolve(prepared.input, loginPath: "/usr/bin:/bin")
                    let profile = try await fixture.profiles.resolve(sessionProfileID: prepared.input.profileId, projectPath: input.cwd, provider: "claude")
                    try BackendAGSLaunchBinding.requireAccount(prepared, actual: self.account(profile), provider: actualProvider)
                    return actualProvider.command
                } catch { await binding.abandon(prepared); throw error }
            }
            XCTAssertEqual(selected, "/bin/echo")
            let reserved = await leases.reserved, abandoned = await leases.abandoned, written = await leases.written
            XCTAssertEqual(reserved, 2); XCTAssertEqual(abandoned, 1); XCTAssertEqual(written, 2)
        }
    }

    func testPersistentSelectionChangesStopAfterTwoAttemptsAndOtherErrorsNeverRetry() async throws {
        let attempts = HotfixLeases()
        do {
            let _: Bool = try await BackendAGSLaunchBinding.retryingSelection {
                await attempts.abandon()
                throw BackendAGSLaunchBinding.SelectionChanged()
            }
            XCTFail("A persistent mismatch must still refuse")
        } catch is BackendAGSLaunchBinding.SelectionChanged {} catch { throw error }
        let count = await attempts.abandoned; XCTAssertEqual(count, 2)
        do {
            let _: Bool = try await BackendAGSLaunchBinding.retryingSelection {
                await attempts.abandon()
                throw CancellationError()
            }
            XCTFail("Cancellation must not retry")
        } catch is CancellationError {} catch { throw error }
        let cancelledCount = await attempts.abandoned; XCTAssertEqual(cancelledCount, 3)
    }
}
