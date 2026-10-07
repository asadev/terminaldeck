import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/host-core.kept-unavailable.test.ts and the delete cases of profiles.test.ts /
/// profiles.windows.test.ts, through the real launch path: BackendSessionLauncher + real PTY manager
/// (inert `sleep` children only) + the real account runtime (BackendF4Runtime). Temporary folders only.
final class BackendFoundationTestsF4HostCore: XCTestCase, @unchecked Sendable {
    private struct Providers: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        /// The stand-in agent: inert, or (`untilEOF`) one that ends when its terminal sends ^D.
        var script = "sleep 30"
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            guard let id = input.provider, ["shell", "claude"].contains(id) else { throw BackendSessionFailure.providerMismatch }
            return BackendProviderSpec(id: id, command: "/bin/sh", args: ["-c", script], resumeArgs: [])
        }
    }
    private struct Unconfined: BackendConfinementLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        /// The environment each launch was handed (the seat's ticket is in it), by working folder.
        var launched = BackendF4Box<[[String: String]]>([])
        func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch,
                     context: BackendLaunchContext) async throws -> BackendConfinedLaunch {
            launched.update { $0.append(account.environment) }
            return BackendConfinedLaunch(command: command, args: args, hostCwd: nil, deviceKey: nil, enforcedBoundary: false)
        }
    }
    private struct NoInstructions: BackendInstructionLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
    }
    /// TS `createHostCore(...)`: a launcher over the real account runtime.
    private func core(_ r: BackendF4Runtime, script: String = "sleep 30", confinement: Unconfined = Unconfined()) async throws -> (launcher: BackendSessionLauncher, manager: BackendPTYManager) {
        // As the lifecycle coordinator does: a process that exits is reported to the launch path.
        let exited = BackendF4Box<(@Sendable (String) -> Void)?>(nil)
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { event in if case .exit(let id, _) = event { exited.value?(id) } }
        let ledger = try await BackendNativeLedger.activate(store: NativeStateStore(), oldSessionOwnerDisabled: true)
        let dependencies = try BackendSessionLaunchDependencies(providers: Providers(script: script), accounts: r.adapter,
            confinement: confinement, instructions: NoInstructions(), ledger: ledger)
        let launcher = BackendSessionLauncher(manager: manager, dependencies: dependencies)
        exited.value = { id in Task { await launcher.processExited(id) } }
        return (launcher, manager)
    }
    /// TS `until(check, ms)`.
    private func until(_ milliseconds: Int = 8_000, _ check: () async -> Bool) async {
        let end = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while !(await check()), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }
    /// A process that cannot reach the vault: its file is another build's, so it will not unlock here.
    private func lockVault(_ r: BackendF4Runtime) async throws {
        let vault = await r.vault
        try Data("a vault from another build of the app".utf8).base64EncodedString().write(to: vault.file, atomically: true, encoding: .utf8)
        await vault.reload()
        let state = await vault.openState(); XCTAssertEqual(state, .locked)
    }
    private func withRuntime(_ body: (BackendF4Runtime) async throws -> Void) async throws {
        let r = try await BackendF4Runtime.wire()
        do { try await body(r) } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }
    private func input(_ r: BackendF4Runtime, _ provider: String, profile: String) -> BackendCreateSessionInput {
        var input = BackendCreateSessionInput(cwd: r.root.path, cols: 80, rows: 24, provider: provider); input.profileId = profile
        return input
    }

    // host-core.kept-unavailable.test.ts:42
    func testAKeptAccountInAProcessThatCannotReachTheVaultIsRefusedWithASentenceAndNoSessionIsStarted() async throws { try await withRuntime { r in
        let kept = try await r.create("kept@example.com")
        XCTAssertEqual(kept.loginStore, "app")
        try await lockVault(r)
        let (launcher, manager) = try await core(r)
        defer { manager.killAll() }
        let before = manager.list().count
        do { _ = try await launcher.create(input(r, "claude", profile: kept.id)); XCTFail("a kept account whose vault cannot open must not start") }
        catch { XCTAssertTrue(error.localizedDescription.contains(BackendSessionSwitchKeptLogin.unavailableSentence), error.localizedDescription) }
        XCTAssertEqual(manager.list().count, before)
    } }

    // host-core.kept-unavailable.test.ts:56. An account the app does not keep (made before the vault).
    func testEveryOtherAccountIsLeftExactlyAsItWas() async throws { try await withRuntime { r in
        let store = await r.profiles
        let plain = try await store.create(name: "plain@example.com", vaultManaged: false)
        XCTAssertNil(plain.loginStore)
        try await lockVault(r)
        let (launcher, manager) = try await core(r)
        defer { manager.killAll() }
        let meta = try await launcher.create(input(r, "shell", profile: plain.id))
        XCTAssertFalse(meta.id.isEmpty)
    } }

    /// A Mac account the app does not keep, made before the vault: TS profiles.test.ts `createProfile('Work')`.
    private func agentKept(_ r: BackendF4Runtime) async throws -> BackendAccountProfile {
        try await (await r.profiles).create(name: "Work", vaultManaged: false)
    }

    // profiles.test.ts:405. (O2 applied F4 → O2 deleteProfile.)
    func testReportsThatTheLoginSurvivesTheProfile() async throws { try await withRuntime { r in
        let created = try await agentKept(r)
        let result = try await r.adapter.deleteProfile(id: created.id, deleteFiles: true)
        XCTAssertTrue(result.credentialsRetained)
    } }

    // profiles.windows.test.ts:107. (O2 applied F4 → O2 deleteProfile.)
    func testKeepsTheLoginOnMacOSWhereItIsInTheKeychain() async throws { try await withRuntime { r in
        let profile = try await agentKept(r)
        let result = try await r.adapter.deleteProfile(id: profile.id, deleteFiles: true)
        XCTAssertEqual([result.removed, result.filesDeleted, result.credentialsRetained], [true, true, true]); XCTAssertNil(result.warning)
    } }

    // profiles.windows.test.ts:129. (O2 applied F4 → O2 deleteProfile.)
    func testStillKeepsTheLoginOnMacOSWhenACredentialsFileHappensToBeThere() async throws { try await withRuntime { r in
        let profile = try await agentKept(r)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: profile.configDir).appendingPathComponent(".credentials.json"))
        let result = try await r.adapter.deleteProfile(id: profile.id, deleteFiles: true)
        XCTAssertTrue(result.credentialsRetained)
    } }

    // host-core.switch-in-place.test.ts:220
    func testASessionWhoseProcessHasEndedLosesItsSeatAndIsSwitchedByARestartInstead() async throws { try await withRuntime { r in
        let home = try await r.create("gone-home@example.com")
        let (launcher, manager) = try await core(r, script: "cat >/dev/null")
        defer { manager.killAll() }
        let meta = try await launcher.create(input(r, "claude", profile: home.id))
        let tickets = await r.broker.tickets
        XCTAssertNotNil(tickets.sessionSeat(meta.id))
        try manager.write(meta.id, data: "\u{4}")
        await until { manager.list().first { $0.id == meta.id }?.exitCode != nil }
        await until { tickets.sessionSeat(meta.id) == nil }
        XCTAssertNil(tickets.sessionSeat(meta.id))
    } }

    // host-core.switch-in-place.test.ts:149 — the seat and process half: through the real launch path,
    // the broker's seat and BackendAccountSwitchInPlace (TS switchInPlace over liveInPlace deps).
    // The agent's own lookups are answered through the broker as the shim delivers them. The switch
    // verbs' ledger/row half stays with the switch coordinator (NIGHT-REQUESTS "F4 → P1").
    func testHandsTheSameProcessTheOtherAccountsLoginSameSessionSamePIDNothingRestarted() async throws { try await withRuntime { r in
        let home = try await r.create("home@example.com"), work = try await r.create("work@example.com")
        await r.put(home.id, BackendF4ClaudeLogin("HOME")); await r.put(work.id, BackendF4ClaudeLogin("WORK"))
        let confinement = Unconfined()
        let (launcher, manager) = try await core(r, confinement: confinement)
        defer { manager.killAll() }
        let meta = try await launcher.create(input(r, "claude", profile: home.id))
        XCTAssertEqual(meta.profileId, home.id)
        let pidBefore = manager.pidOf(meta.id)
        XCTAssertNotNil(pidBefore)
        let ticket = try XCTUnwrap(confinement.launched.value.last?[r.ticketKey])
        // The agent asks under its own folder's hash, before and after: only the seat changes.
        func ask() async -> String? {
            if case .exit(let answer) = await r.find(ticket, configDir: home.configDir), answer.code == 0 {
                return BackendF4TokenOf(answer.stdout)
            }
            return nil
        }
        let first = await ask(); XCTAssertEqual(first, "sk-ant-oat01-HOME")
        let deps = await r.broker.switchInPlaceDependencies()
        let switched = await BackendAccountSwitchInPlace.switchInPlace(sessionID: meta.id, account: .init(id: work.id, name: work.name, configDir: work.configDir), dependencies: deps)
        XCTAssertTrue(switched.ok, "\(switched)")
        let after = await ask(); XCTAssertEqual(after, "sk-ant-oat01-WORK")
        XCTAssertEqual(manager.pidOf(meta.id), pidBefore)
        XCTAssertEqual(manager.list().filter { $0.exitCode == nil }.map(\.id), [meta.id])
        let back = await BackendAccountSwitchInPlace.switchInPlace(sessionID: meta.id, account: .init(id: home.id, name: home.name, configDir: home.configDir), dependencies: deps)
        XCTAssertTrue(back.ok)
        let again = await ask(); XCTAssertEqual(again, "sk-ant-oat01-HOME")
        XCTAssertEqual(manager.pidOf(meta.id), pidBefore)
    } }
}

/// The access token in a Claude login, as the TS test's fake agent prints it.
func BackendF4TokenOf(_ login: String) -> String? {
    (try? NativeRPCValue.parseJSON(Data(login.utf8)))?["claudeAiOauth"]["accessToken"].string
}
