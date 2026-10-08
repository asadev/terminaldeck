import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("APE timer recovery: disk absence never proves the systemd cache stopped")
struct BackendAppsRecoveryTimerTests {
    @Test func captureReadsActiveEnabledCacheEvenWhenFileIsAbsent() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true)
        let baseline = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope))
        #expect(baseline.enabled && baseline.active)
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test func originallyAbsentTimerRequiresStopDisableReloadAndFreshNotFoundProof() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true)
        #expect(try await BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        let state = await fake.snapshot()
        #expect(state.mutations == ["stop", "disable", "daemon-reload"])
        #expect(!state.enabled && !state.active && !state.loaded)
        #expect(state.showCalls >= 4)
    }

    @Test func absentInactiveCacheStillDoesNotTakeFileMissingEarlySuccess() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: false, enabled: false, active: false)
        #expect(try await BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations == ["stop", "disable", "daemon-reload"])
    }

    @Test(arguments: ["stop", "disable", "daemon-reload"])
    func acceptedNoOpDoesNotClearCachedTimerRecovery(action: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true, noOps: [action])
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        let state = await fake.snapshot()
        #expect(state.mutations.contains(action))
    }

    @Test func presentOwnedUnitRestoresDisabledInactiveState() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: true, active: true)
        #expect(try await BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        let state = await fake.snapshot()
        #expect(state.mutations == ["daemon-reload", "disable", "stop"])
        #expect(state.loaded && !state.enabled && !state.active)
    }

    @Test func presentOwnedUnitRestoresEnabledActiveState() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: false, active: false)
        #expect(try await BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: true, active: true, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations == ["daemon-reload", "enable", "start"])
    }

    @Test(arguments: ["enable", "start"])
    func acceptedNoOpCannotProvePresentUnitWasRestored(action: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: false, active: false, noOps: [action])
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: true, active: true, command: fake.command(scope)))
    }

    @Test func acceptedNoOpReloadCannotProvePresentBeforeImageReachedPID1() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: true, active: true, noOps: ["daemon-reload"], needsReload: true)
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: true, active: true, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations == ["daemon-reload"])
    }

    @Test(arguments: ["/usr/lib/systemd/system/foreign.timer", "/run/systemd/transient/td-test-other.timer"])
    func foreignCachedFragmentRefusesAllMutations(fragment: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true, fragment: fragment)
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope)) }
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test(arguments: ["file-symlink", "parent-symlink", "missing-marker"])
    func unsafeUnitFileRefusesSnapshotAndRecovery(reason: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: true, active: true, diskFailure: reason)
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope)) }
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        #expect((await fake.snapshot()).showCalls == 0)
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test(arguments: ["enabled-runtime", "masked", "static", "indirect", "alias", "generated", "transient", "unexpected"])
    func unsupportedEnablementNeverBecomesDisabledSnapshot(status: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: false, active: false, unitFileState: status)
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope)) }
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test(arguments: ["activating", "deactivating", "failed", "reloading", "unexpected"])
    func transientOrUnknownActivityRefusesRecovery(status: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: true, active: true, activeState: status)
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope)) }
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test func namedPropertyOrderDoesNotChangeActualSnapshot() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: true, active: false)
        let state = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope))
        #expect(state.enabled && !state.active)
    }

    @Test(arguments: ["missing-property", "duplicate-property", "truncated-output", "unknown-load"])
    func malformedShowCannotProveRecovery(kind: String) async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true, showFailure: kind)
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: Self.unit(scope), command: fake.command(scope)) }
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test func failedScopedStopRetainsUnverifiedCachedTimer() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true, errors: ["stop"])
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: false, active: false, command: fake.command(scope)))
        let state = await fake.snapshot()
        #expect(state.active && state.enabled && state.loaded)
        #expect(state.mutations == ["stop"])
    }

    @Test func positiveStateCannotBeRestoredWithoutItsOwnedUnitFile() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: false, loaded: true, enabled: true, active: true)
        #expect(try await !BackendAppsRecoveryTimer.restore(scope: scope, unit: Self.unit(scope), enabled: true, active: true, command: fake.command(scope)))
        #expect((await fake.snapshot()).mutations.isEmpty)
    }

    @Test func foreignUnitNameNeverReachesCommandCallback() async throws {
        let scope = try await Self.scope(), fake = BackendAppsRecoveryTimerFixture(present: true, loaded: true, enabled: true, active: true)
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: "foreign.timer", command: fake.command(scope)) }
        await #expect(throws: NativeRPCError.self) { _ = try await BackendAppsRecoveryTimer.restore(scope: scope, unit: "foreign.timer", enabled: false, active: false, command: fake.command(scope)) }
        #expect((await fake.snapshot()).commands.isEmpty)
    }

    private static func unit(_ scope: BackendAppsRecoveryScope) -> String { scope.resourcePrefix + "-" + scope.appID + "-backup.timer" }
    private static func scope() async throws -> BackendAppsRecoveryScope {
        let context = NativeRPCContext(caller: .page, ownerID: "td-test-timer-owner")
        let refused: BackendAppsRuntime.Execute = { _, _, _, _, _ in throw NativeRPCError(code: "access-denied", message: "No real command is available in this scope fixture.") }
        let http: BackendAppsRuntime.HTTP = { _, _, _, _ in throw NativeRPCError(code: "access-denied", message: "No real API is available in this scope fixture.") }
        let kernel = BackendAppsRecovery(capture: { scope, supplied in
            guard supplied?.requestID == context.requestID, supplied?.ownerID == context.ownerID,
                  scope.serverID == "td-test-server", scope.appID == "td-test-app", scope.resourcePrefix == "td-test" else { throw NativeRPCError(code: "access-denied", message: "The synthetic scope receipt does not match.") }
            return BackendAppsRecoveryTransport(execute: refused, docker: http, caddy: http,
                authorizeRegistration: { supplied in
                    guard supplied?.requestID == context.requestID, supplied?.ownerID == context.ownerID else { throw NativeRPCError(code: "access-denied", message: "The synthetic scope receipt ended.") }
                }, validateBinding: {}, close: {})
        }, audit: { _ in }, monotonic: { 100 })
        let runtime = BackendAppsRuntime(execute: refused, privateNetwork: "td-test-apps", resourcePrefix: "td-test", stateRoot: "/var/lib/td-test-apps", recovery: kernel)
        let transaction = try await NativeCompositionCallContext.$rpc.withValue(context) {
            try await kernel.begin(runtime: runtime, serverID: "td-test-server", appID: "td-test-app")
        }
        await kernel.finish(transaction)
        return transaction.scope
    }
}

/// A semantic Swift PID 1 cache. Disk presence is independent of loaded and
/// active state; no real filesystem, shell, systemd or process is invoked.
private actor BackendAppsRecoveryTimerFixture {
    struct Snapshot: Sendable {
        let commands: [String], mutations: [String]
        let loaded: Bool, enabled: Bool, active: Bool
        let showCalls: Int
    }
    private let present: Bool, noOps: Set<String>, errors: Set<String>
    private let fragment: String?, unitFileState: String?, activeState: String?, diskFailure: String?, showFailure: String?
    private var loaded: Bool, enabled: Bool, active: Bool
    private var needsReload: Bool
    private var commands: [String] = [], mutations: [String] = []
    private var showCalls = 0
    init(present: Bool, loaded: Bool, enabled: Bool, active: Bool, noOps: Set<String> = [], errors: Set<String> = [],
         fragment: String? = nil, unitFileState: String? = nil, activeState: String? = nil, diskFailure: String? = nil, showFailure: String? = nil, needsReload: Bool = false) {
        self.present = present; self.loaded = loaded; self.enabled = enabled; self.active = active
        self.noOps = noOps; self.errors = errors; self.fragment = fragment; self.unitFileState = unitFileState
        self.activeState = activeState; self.diskFailure = diskFailure; self.showFailure = showFailure
        self.needsReload = needsReload || (!present && loaded)
    }
    nonisolated func command(_ scope: BackendAppsRecoveryScope) -> BackendAppsRecoveryTimer.Command {
        { script in await self.run(script, scope: scope) }
    }
    func snapshot() -> Snapshot { .init(commands: commands, mutations: mutations, loaded: loaded, enabled: enabled, active: active, showCalls: showCalls) }
    private func run(_ script: String, scope: BackendAppsRecoveryScope) -> BackendServersRunResult {
        commands.append(script)
        let unit = scope.resourcePrefix + "-" + scope.appID + "-backup.timer"
        let path = "/etc/systemd/system/" + unit
        if script.contains("td_timer_file=") {
            guard script.contains(path), script.contains("# Terminal Deck managed backup for " + scope.appID), diskFailure == nil else { return .init(code: 45, stdout: "") }
            return .init(code: 0, stdout: present ? "present\n" : "absent\n")
        }
        if script.hasPrefix("systemctl show ") {
            showCalls += 1
            guard script.contains("--all"), script.contains(BackendAppsRuntime.quote(unit)) else { return .init(code: 45, stdout: "") }
            let load = showFailure == "unknown-load" ? "error" : (loaded ? "loaded" : "not-found")
            let actualFragment = fragment ?? (loaded ? path : "")
            let install = unitFileState ?? (enabled ? "enabled" : (loaded ? "disabled" : ""))
            let activity = activeState ?? (active ? "active" : "inactive")
            var lines = ["ActiveState=" + activity, "UnitFileState=" + install, "FragmentPath=" + actualFragment, "LoadState=" + load, "NeedDaemonReload=" + (needsReload ? "yes" : "no")]
            if showFailure == "missing-property" { lines.removeFirst() }
            if showFailure == "duplicate-property" { lines.append("LoadState=" + load) }
            return .init(code: 0, stdout: lines.joined(separator: "\n") + "\n", truncated: showFailure == "truncated-output")
        }
        let verb: String
        if script == "systemctl daemon-reload" { verb = "daemon-reload" }
        else {
            guard let found = ["stop", "disable", "enable", "start"].first(where: { script == "systemctl " + $0 + " -- " + BackendAppsRuntime.quote(unit) }) else { return .init(code: 45, stdout: "") }
            verb = found
        }
        mutations.append(verb)
        if errors.contains(verb) { return .init(code: 1, stdout: "") }
        if !noOps.contains(verb) {
            switch verb {
            case "stop": active = false
            case "disable": enabled = false
            case "enable": enabled = true
            case "start": active = true
            case "daemon-reload": loaded = present; needsReload = false
            default: break
            }
        }
        return .init(code: 0, stdout: "")
    }
}
