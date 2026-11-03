import AppKit
import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor @Observable
final class NativeCompositionINT2HOSTCore {
    static var current: NativeCompositionINT2HOSTCore?
    var notice: NativeHOSTNotice.State = .checking
    private(set) var mayRestore = true
    private(set) var preservingHosted = false
    private var connected = false
    private var client: BackendHOSTClient?
    private var bridge: BackendHOSTManagerBridge?
    private let sessions: BackendCompositionSessions
    private let dataRoot: URL
    private let home: URL
    private var updateDeferred = false
    private var lifecycleObserver: UUID?
    private var dispatchInstalled = false
    private var generation: UInt64 = 0
    init(sessions: BackendCompositionSessions, dataRoot: URL, home: URL) {
        self.sessions = sessions; self.dataRoot = dataRoot; self.home = home
        Self.current = self
    }
    #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
    /// L8: the managed helper was replaced after a crash; the status file follows it.
    func refreshStatus() { record() }
    func noteManagedDetachment() { preservingHosted = true; connected = false; generation &+= 1; record() }
    func usePreconnected(client: BackendHOSTClient, bridge: BackendHOSTManagerBridge) async {
        self.client = client; self.bridge = bridge; connected = client.isConnected
        dispatchInstalled = true // Managed launcher already has its actual resolved dispatch.
        mayRestore = connected; updateDeferred = true // Existing core process remains unchanged.
        if lifecycleObserver == nil {
            lifecycleObserver = await sessions.lifecycle.observe { [weak self] _ in
                await MainActor.run { self?.refreshNotice() }
            }
        }
        refreshNotice(); record()
    }
    #endif
    func start() async {
#if TD_HOST_INTEGRATED
        guard ProcessInfo.processInfo.environment[NativeLaunchSwitches.hostDisabled] != "1" else {
            notice = .fallback(reason: "Session survival was disabled for this launch."); record(); return
        }
        guard sessions.manager.localSessionCount() == 0 else {
            notice = .fallback(reason: "Close the in-app sessions first, then restart the session keeper.")
            record(); return
        }
        if connected, client?.isConnected == true { return }
        generation &+= 1; let attempt = generation
        if client != nil || bridge != nil { sessions.manager.detachHOSTFrontend(); client = nil; bridge = nil }
        notice = .checking
        var candidate: BackendHOSTClient?
        do {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalDeckSessionHostHelper")
            let marketing = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.20.2") + "-host2"
            // One folder per helper build (QUIT); the 77 MB hash runs off the main thread.
            let version = try await Task.detached(priority: .userInitiated) { try BackendHOSTLaunchAgent.buildVersion(marketing: marketing, helper: helper) }.value
            let plan = try BackendHOSTLaunchAgent(paths: BackendHOSTPaths(dataDirectory: dataRoot), version: version,
                launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents"))
            let result = try await plan.connectOrStart(sourceHelper: helper)
            let deferred: Bool
            switch result {
            case .attached(let value, let older): candidate = value; deferred = older
            case .started(let value): candidate = value; deferred = false
            }
            let active = candidate!
            updateDeferred = deferred
            let made = BackendHOSTManagerBridge(client: active,
                write: { try active.write($0, bytes: $1, expectedCreatedAt: $2) },
                drain: { try await active.drain(timeoutMilliseconds: $0) },
                setWatched: { try active.setWatched($0) }, stampIndependent: { $0.ownerIndependent = true })
            let barrier = BackendHOSTReadyBarrier()
            try sessions.manager.installHOSTFrontend(made, ready: { barrier.finish(nil) }, disconnected: { [weak self] in
                barrier.finish(BackendHOSTFailure.unavailable)
                Task { @MainActor in if self?.generation == attempt { self?.disconnected() } }
            })
            made.onHostLost(NativeHOSTLost.announce)
            bridge = made; client = active
            try await barrier.wait(timeout: 60)
            await sessions.restore.setHostedClaims { [manager = sessions.manager] in manager.list().filter { manager.isHostedSession($0.id) } }
            // Adopt the original immutable input/scope into the sole app ledger.
            for meta in active.cachedSessions() {
                guard let snapshot = try active.snapshot(meta.id), let input = snapshot.input, let scope = snapshot.scope else {
                    throw BackendHOSTFailure.invalid("A kept session is missing its original launch facts.")
                }
                try await sessions.ledger.started(snapshot.session, input: input,
                    context: BackendLaunchContext(deviceBoundary: scope.deviceBoundary, appFenceID: scope.appFenceID,
                        rememberTab: scope.rememberTab, isAppComposed: scope.isAppComposed, requiresInAppOwner: true))
            }
            if !dispatchInstalled {
                let originalAccounts: BackendAccountLaunchAdapter?
                #if TD_HOST_ACCOUNT_BRIDGE
                originalAccounts = sessions.accounts as? BackendAccountLaunchAdapter
                #else
                originalAccounts = sessions.accounts
                #endif
                try await sessions.launcher.setHostedDispatch { [weak self, accounts = originalAccounts] input, spawn, account, context in
                    guard let accounts, !context.requiresInAppOwner, !context.isAppComposed,
                          context.deviceBoundary == nil, context.appFenceID == nil,
                          input.taskID == nil, input.agentSettings == nil,
                          input.originRoutineId == nil, input.originRunId == nil,
                          input.origin == nil || input.origin == .app,
                          await accounts.hostIndependent(account) else {
                        await self?.noteFallback(); return nil
                    }
                    guard let self else { throw BackendHOSTFailure.unavailable }
                    return try await self.create(input, spawn: spawn, context: context)
                }
                dispatchInstalled = true
            }
            connected = true; mayRestore = true
            if lifecycleObserver == nil {
                lifecycleObserver = await sessions.lifecycle.observe { [weak self] _ in
                    await MainActor.run { self?.refreshNotice() }
                }
            }
            notice = .running
            NativeCompositionRoot.note("HOST core attached, protocol2; independent sessions survive quit/update")
            // The line is back after a loss (the notice's Restart, or the next session asking for it):
            // every page that failed meanwhile reads again by itself (DeckReconnect).
            if wasLost { wasLost = false; DeckReconnect.shared.back("the session host is running again") }
        } catch {
            if candidate != nil { mayRestore = false }
            if let failure = error as? BackendHOSTFailure {
                switch failure { case .occupiedHost, .incompatible, .authentication: mayRestore = false; default: break }
            }
            connected = false
            notice = .fallback(reason: mayRestore ? "The existing in-app session owner is active." : "Kept sessions are unavailable; saved-session restore is paused to avoid duplicates.")
            NativeCompositionRoot.note("HOST core fallback: " + error.localizedDescription)
        }
#else
        notice = .inApp // a build without the session host runs every session in the app, by design
#endif
        record()
    }
#if TD_HOST_INTEGRATED
    private func create(_ input: BackendCreateSessionInput, spawn: BackendSpawnSpec, context: BackendLaunchContext) async throws -> BackendSessionMeta? {
        if !connected || client?.isConnected != true { await start() }
        guard connected else {
            // No create was sent. Only a proven empty/prelaunch fallback may
            // use the original owner; unseen/uncertain kept sessions stay held.
            if mayRestore { noteFallback(); return nil }
            throw BackendHOSTFailure.unavailable
        }
        let made = try sessions.manager.createHOST(input, spawn: spawn, context: context, machineID: "", independent: true)
        refreshNotice(); record()
        return made
    }
    var canKeepWithoutApp: Bool {
        #if TD_HOST_ACCOUNT_BRIDGE
        if NativeCompositionINT2HOSTManaged.current != nil { return false }
        #endif
        return connected && client?.isConnected == true && sessions.manager.localSessionCount() == 0
    }
    func keepAndDetach(stoppingLocalForUpdate: Bool = false) -> Bool {
        #if TD_HOST_ACCOUNT_BRIDGE
        if NativeCompositionINT2HOSTManaged.current != nil { return false }
        #endif
        guard connected, client?.isConnected == true, stoppingLocalForUpdate || sessions.manager.localSessionCount() == 0 else { return false }
        generation &+= 1
        preservingHosted = sessions.manager.hostedSessionCount() > 0
        sessions.manager.detachHOSTFrontend(); connected = false; record()
        return true
    }
    func prepareShutdown() {
        if !NativeSVResident.shared.explicitStop { _ = keepAndDetach(stoppingLocalForUpdate: true) }
    }
#else
    var canKeepWithoutApp: Bool { false }
    func keepAndDetach(stoppingLocalForUpdate: Bool = false) -> Bool { false } // same shape as the host build (NativeSVResident calls it)
    func prepareShutdown() {}
#endif
    /// A session that runs in the app by design (not host-eligible yet): never a warning. A host that really
    /// failed keeps its own failure notice (it is not overwritten here).
    private func noteFallback() { guard connected else { return }; notice = .inApp; record() }
    private func refreshNotice() {
#if TD_HOST_INTEGRATED
        guard connected else { return }
        if sessions.manager.localSessionCount() > 0 { noteFallback() }
        else { notice = .running }
#endif
    }
    private var wasLost = false
    private func disconnected() { wasLost = true; connected = false; mayRestore = false; notice = .fallback(reason: "Kept sessions are disconnected. Restore is paused."); record() }
    func retry() async throws -> NativeHOSTNotice.State { await start(); return notice }
    private func record() {
        #if TD_HOST_INTEGRATED
        let compiled = true
#else
        let compiled = false
#endif
        var value: [String: Any] = ["compiled": compiled, "connected": connected, "restoreAllowed": mayRestore,
            "helperBundlePath": "Contents/MacOS/TerminalDeckSessionHostHelper", "protocolVersion": BackendHOSTProtocol.version]
        #if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
        value["accountBridgeCompiled"] = true
        if let managed = NativeCompositionINT2HOSTManaged.current, let agents = managed.managedClient {
            value["managedConnected"] = agents.isConnected
            value["managedHostPID"] = agents.hello.hostPID
            value["managedHostVersion"] = agents.hello.hostVersion
            value["managedNamespace"] = "agents"
        } else { value["managedConnected"] = false }
        #endif
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: dataRoot.appendingPathComponent("host-core-status.json"), options: .atomic)
        }
    }
}

/// HOSTLOST (9 Oct): a session host died or was replaced (Asad's agents host, SIGPIPE, 19:28): its
/// sessions are shown as ended with "Restart and resume" instead of a frozen screen; their saved tabs
/// stay on record so the restore at the next launch resumes them.
enum NativeHOSTLost {
    static let announce: @Sendable ([String]) -> Void = { ids in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NativeCompositionRoot.note("session host lost: \(ids.count) session(s) ended with it; restart resumes them")
                NotificationCenter.default.post(name: .tdSessionHostLost, object: nil, userInfo: ["ids": ids])
            }
        }
    }
}
