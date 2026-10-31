import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/usage-ipc.test.ts:900 and :943 against the real BackendUsageService over the real
/// account runtime (BackendF4Runtime), its real BackendUsageProbe with `ask` recorded (TS fakeProbe),
/// sessions supplied through the service's `sessionLookup` (TS `wire((id) => session(...))`), and a
/// stand-in login shell + `claude` in the temporary folder. No real agent, shell or Keychain.
final class BackendFoundationTestsF4UsageIPC: XCTestCase, @unchecked Sendable {
    private struct Providers: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec { throw BackendSessionFailure.providerMismatch }
    }
    private struct Unconfined: BackendConfinementLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch,
                     context: BackendLaunchContext) async throws -> BackendConfinedLaunch { BackendConfinedLaunch(command: command, args: args) }
    }
    private struct NoInstructions: BackendInstructionLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
    }
    private struct NoProjectTools: BackendProjectMCPSource {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
    }

    private struct Wired { let service: BackendUsageService; let calls: BackendF4Box<Int>; let work: BackendAccountProfile; let screens: BackendF4Box<[String: String]> }

    /// TS usage-ipc.test.ts `wire(session, { accounts, probe })` with `fakeProbe(answer)`.
    private func wire(_ r: BackendF4Runtime, answer: NativeRPCValue?, name: String = "Work", provider: String = "claude") async throws -> Wired {
        let data = r.configuration.dataDirectory, profiles = await r.profiles
        // TS createProfile('Work', { provider: 'claude' }); its login is kept, so the probe can be served.
        let apiDirectory = BackendAPIAccountRecord.isAPIAccountID(name) ? r.configuration.accountLoginsRoot.appendingPathComponent("api-usage-fixture").path : nil
        let work = try await r.create(name, provider: provider, configDir: apiDirectory)
        if provider == "claude" { await r.put(work.id, BackendF4ClaudeLogin("WORK")) }
        let bin = r.root.appendingPathComponent("bin"), shell = r.root.appendingPathComponent("login-shell")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '\\000%s\\000' '\(bin.path):/usr/bin:/bin'\n".write(to: shell, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho '2.1.0 (Claude Code)'\n".write(to: bin.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        for file in [shell, bin.appendingPathComponent("claude")] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        let providers = try BackendNativeProviders(store: r.state, dataRoot: data, inheritedEnvironment: ["SHELL": shell.path], home: r.configuration.homeDirectory.path, runner: BackendCommandRunner())
        let calls = BackendF4Box(0)
        let probe = BackendUsageProbe(accounts: r.adapter, providers: providers, ask: { _, _, _, _, _ in
            calls.update { $0 += 1 }
            return (usage: answer, error: nil)
        })
        // The service's own session/lifecycle owners, inert: sessions come from `sessionLookup`.
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { _ in }
        let ledger = try await BackendNativeLedger.activate(store: NativeStateStore())
        let launcher = BackendSessionLauncher(manager: manager, dependencies: try BackendSessionLaunchDependencies(providers: Providers(), accounts: r.adapter,
            confinement: Unconfined(), instructions: NoInstructions(), ledger: ledger))
        let endpoint = BackendTestMCPEndpoint(readiness: .ready, description: { nil }, catalogue: { [] },
            register: { _, _ in throw BackendAccountFailure("No session tools in this test.") }, bind: { _, _, _ in }, revoke: { _ in })
        let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: Providers(), sessionTools: try BackendSessionToolLeases(endpoint: endpoint, userData: data),
            projectTools: try BackendProjectToolComposition(source: NoProjectTools(), userData: data, inheritedEnvironment: [:]),
            reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
        let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: r.adapter,
            attribution: BackendAccountAttribution(configuration: r.configuration, profiles: profiles), ledger: ledger, store: r.state,
            cleanup: BackendSessionLifecycleCleanup(readiness: .ready, release: { _ in }), emit: { _ in })
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: [r.root], writeRoots: [r.root]) }
        let projects = try BackendProjectService(store: r.state, files: BackendFilesystemService(authority: authority), home: r.root.path, appDataRoot: data, liveSessions: { [] })
        let cost = BackendCostService(projects: projects, scopeProvider: { _, _ in throw BackendAccountFailure("No cost scope in this test.") }, push: { _, _, _ in })
        let screens = BackendF4Box<[String: String]>([:])
        let root = r.root.path
        // TS `session({ id, profileId: profile.id })`: a Claude session established on Work.
        let lookup: BackendUsageService.SessionLookup = { id in
            let raw = NativeRPCValue.object([.init("id", .string(id)), .init("cwd", .string(root)), .init("title", .string(id)), .init("provider", .string(work.provider)),
                .init("exitCode", .null), .init("createdAt", .number(1_000)), .init("resumed", .bool(false)), .init("profileId", .string(work.id))])
            guard let meta = try? JSONDecoder().decode(BackendSessionMeta.self, from: raw.encodedJSON()) else { return nil }
            let reading = BackendAccountSessionReading(provider: work.provider, configDir: work.configDir, profileId: work.id, profileName: work.name, source: "profile", email: nil, reason: nil)
            return (meta: meta, observedProvider: work.provider, account: reading, screen: screens.value[id])
        }
        let service = BackendUsageService(accounts: r.adapter, lifecycle: lifecycle, store: r.state, cost: cost, providers: providers,
            modelLabel: { $0 }, push: { _, _, _ in }, probe: { account, cancellation in await probe.run(account: account, cancellation: cancellation) }, sessionLookup: lookup)
        return Wired(service: service, calls: calls, work: work, screens: screens)
    }
    private func withRuntime(_ body: (BackendF4Runtime) async throws -> Void) async throws {
        let root = try BackendF4Runtime.makeRoot().resolvingSymlinksInPath()
        let r = try await BackendF4Runtime.wire(root: root)
        do { try await body(r) } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }

    /// Real cache formats, deliberately containing subscription windows under both account kinds.
    private func writeSubscriptionCache(_ profile: BackendAccountProfile) throws {
        let home = URL(fileURLWithPath: profile.configDir)
        if profile.provider == "claude" {
            let raw: NativeRPCValue = .object([.init("cachedUsageUtilization", .object([
                .init("fetchedAtMs", .number(BackendUsageIO.now())),
                .init("utilization", .object([.init("five_hour", .object([.init("utilization", .number(42))]))]))
            ]))])
            try raw.encodedJSON().write(to: home.appendingPathComponent(".claude.json"))
        } else if profile.provider == "codex" {
            let folder = home.appendingPathComponent("archived_sessions")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let raw: NativeRPCValue = .object([.init("payload", .object([.init("rate_limits", .object([
                .init("primary", .object([.init("used_percent", .number(42)), .init("window_minutes", .number(300))]))
            ]))]))])
            try raw.encodedJSON().write(to: folder.appendingPathComponent("fixture.jsonl"))
        }
    }

    func testAPIAccountsNeverSeedSubscriptionLimitsOrProbeEvenWhenForced() async throws {
        for provider in ["claude", "codex", "gemini"] { try await withRuntime { r in
            let name = "api-key-" + String(repeating: "a", count: 24)
            let w = try await wire(r, answer: .object([.init("rate_limits_available", .bool(true))]), name: name, provider: provider)
            XCTAssertTrue(BackendAPIAccountRecord.isAPIAccountID(w.work.id))
            try writeSubscriptionCache(w.work)
            w.screens.value["api"] = "Current session\n42% used\nResets in 3 hours\n"
            let watched = try await w.service.watch(sessionID: "api", ownerID: "owner")
            XCTAssertEqual(watched["readings"].elements?.count, 0)
            XCTAssertTrue(watched["reason"].string?.contains("API billing") == true)
            XCTAssertTrue(watched["reason"].string?.contains("balance are not reported") == true)
            for force in [false, true] {
                let outcome = try await w.service.refresh(sessionID: "api", force: force)
                XCTAssertEqual(outcome.kind, "no-limits")
                XCTAssertFalse(outcome.spawned)
                XCTAssertTrue(outcome.readings.isEmpty)
                XCTAssertEqual(outcome.detail, watched["reason"].string)
            }
            XCTAssertEqual(w.calls.value, 0)
            let all = try await w.service.read(sessionID: nil)
            XCTAssertTrue(all.readings.isEmpty)
            let memory = await r.state.getAccountLimit(w.work.configDir)
            XCTAssertNil(memory["answer"].string)
            await w.service.stop()
        } }
    }

    func testSubscriptionAccountsStillSeedTheSameCLICaches() async throws {
        for provider in ["claude", "codex"] { try await withRuntime { r in
            let w = try await wire(r, answer: nil, provider: provider)
            try writeSubscriptionCache(w.work)
            let report = try await w.service.read(sessionID: "subscription")
            XCTAssertEqual(report.readings.count, 1)
            XCTAssertEqual(report.readings.first?.used, .percent(42))
            let all = try await w.service.read(sessionID: nil)
            XCTAssertEqual(all.readings.count, 1)
            await w.service.stop()
        } }
    }

    // usage-ipc.test.ts:900
    func testRemembersALoginWithNoSubscriptionLimitsAndAPressReachesPastIt() async throws { try await withRuntime { r in
        let usage = NativeRPCValue.object([.init("subscription_type", .string("max")), .init("rate_limits_available", .bool(false))])
        let w = try await wire(r, answer: usage)
        _ = try await w.service.watch(sessionID: "none-1", ownerID: "owner-1")
        let first = try await w.service.refresh(sessionID: "none-1", force: false)
        XCTAssertEqual(first.kind, "no-limits")
        let held = await r.state.getAccountLimit(w.work.configDir)
        XCTAssertEqual(held["answer"].string, "no-limits")
        // A second session on the same login, which has never asked anything.
        _ = try await w.service.watch(sessionID: "none-2", ownerID: "owner-2")
        let second = try await w.service.refresh(sessionID: "none-2", force: false)
        XCTAssertEqual(second.kind, "settled"); XCTAssertFalse(second.spawned)
        XCTAssertEqual(w.calls.value, 1)
        // And the one thing that overrides it, which is a person pressing.
        let pressed = try await w.service.refresh(sessionID: "none-2", force: true)
        XCTAssertEqual(pressed.kind, "no-limits")
        XCTAssertEqual(w.calls.value, 2)
        await w.service.stop()
    } }

    // usage-ipc.test.ts:943. TS feeds the banner to the session's plan tracker (notePlanOutput); natively the
    // service reads the same line off the session's screen, so the banner is what the session's screen shows.
    func testTakesTheCLIsOwnBannerAsTheAnswerBeforeStartingAnything() async throws { try await withRuntime { r in
        let w = try await wire(r, answer: .object([.init("subscription_type", .string("max")), .init("rate_limits_available", .bool(true))]))
        _ = try await w.service.watch(sessionID: "banner-1", ownerID: "owner-1")
        w.screens.value["banner-1"] = "Claude Code v2.1.224 · Opus 5 with xhigh effort · Claude API\r\n"
        let result = try await w.service.refresh(sessionID: "banner-1", force: false)
        XCTAssertEqual(result.kind, "no-limits"); XCTAssertFalse(result.spawned)
        XCTAssertEqual(w.calls.value, 0)
        let held = await r.state.getAccountLimit(w.work.configDir)
        XCTAssertEqual(held["billing"].string, "api")
        await w.service.stop()
    } }

    // 18 Oct (#651): a removed session's watch ends with it, even when its unwatch never arrived.
    func testRemovedSessionIsNoLongerWatched() async throws { try await withRuntime { r in
        let w = try await wire(r, answer: nil)
        _ = try await w.service.watch(sessionID: "gone", ownerID: "owner")
        let before = await w.service.isWatched("gone"); XCTAssertTrue(before)
        await w.service.forgetWatches("gone")
        let after = await w.service.isWatched("gone"); XCTAssertFalse(after)
        await w.service.stop()
    } }
}
