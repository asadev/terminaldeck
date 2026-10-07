import Foundation
import TerminalDeckNativeCore

/// The machines / servers / remote / devices / workers deck-tools families over
/// the one deck-tools gate (INT-B, 7 Oct). machine-area.ts, device-tools.ts and
/// worker-tools.ts as index.ts composes them; `browser.lift_request` is the
/// sessions lane's single definition, passed in and never built here.
public enum BackendCompositionDeckToolsMachines {
    public typealias RPC = @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext

    /// callers.ts Caller as machine-area/device/worker tools read it, from the
    /// credential-resolved core call only (never arguments, never `attended`
    /// guessed). `rpc` is that same call's authority ticket.
    public static func context(_ core: BackendDeckCoreSecurityCallContext, rpc: NativeRPCContext) -> BackendDeckToolsMachinesContext {
        let kind: BackendDeckToolsMachinesContext.Kind
        switch core.caller.kind {
        case .local: kind = .local
        case .key: kind = .key
        case .session: kind = .session
        case .remote: kind = .remote
        }
        return .init(kind: kind, attended: core.attended, sessionID: core.caller.sessionID, machineID: core.caller.machineID ?? "",
                     keyID: core.caller.keyID, deviceID: core.caller.deviceID, folders: core.caller.folders, rpc: rpc,
                     startedByCopilot: { core.startedByCopilot($0) }, noteStarted: { core.noteStarted($0) })
    }

    /// The machines environment over the deck-tools gate. deck-core has already
    /// checked grant, base tier, budget and consent; `execute` enters the same
    /// running call once at the policy's effective tier/sentence/owner question,
    /// runs, and hands only `output.summary` to that call's one log row.
    ///
    /// `rpc` must answer the authority ticket for the call (`gate.authority.rpc`).
    /// Pass the browser's MCP context mapper (NativeCompositionBrowserAuthority.rpc,
    /// i.e. installBrowser's `dependencies.mcpContext`): it returns the same ticket
    /// and also registers it, without which Safari's worker pool refuses the caller.
    public static func environment(scope: BackendCompositionDeckToolsScope, rpc: @escaping RPC) -> BackendDeckToolsMachinesEnvironmentAdapter {
        let gate = scope.gate
        return BackendDeckToolsMachinesEnvironmentAdapter(resolve: { native in
            let core = try await scope.resolve(native)
            return Self.context(core, rpc: try await rpc(native))
        }, execute: { context, policy, operation in
            // The context's rpc is this call's ticket; the authority maps it back
            // to the credential-resolved native call (never a new identity).
            let native = try await gate.authority.nativeCaller(context.rpc)
            try await gate.authorize(native, policy.tier, policy.sentence, policy.ownerMustAnswer)
            if native.cancellation.isCancelled { throw CancellationError() }
            let output = try await operation()
            await gate.noteResult(native, output.summary)
            return .value(output.value)
        }, failed: { call, _, _, loggedArguments, error in
            // The core row records the failure itself; it gets the source's
            // logged (redacted) arguments, never the raw ones.
            await gate.noteResult(call, loggedArguments)
            return BackendDeckToolsMachinesFactory.failureReply(error)
        })
    }

    /// Every id in `BackendDeckToolsMachinesCatalogue.rows()` exactly once, in
    /// machine-area order (machines, servers, remote), then devices, then the two
    /// worker tools followed by the supplied `browser.lift_request`.
    ///
    /// `machines` are the six machines.* definitions the machine registration
    /// already guards (BackendMachineMCP.contribution); they are passed through,
    /// never rebuilt. Nothing built here reaches a machines:* channel or the
    /// machine watch, so neither a watch nor the local-pairing gate is taken.
    public static func definitions(scope: BackendCompositionDeckToolsScope, rpc: @escaping RPC,
                                   registry: NativeChannelRegistry,
                                   dataRoot: URL, home: URL,
                                   machines: [BackendDeckToolsDefinition],
                                   serverShells: any BackendDeckToolsMachinesServerShells,
                                   devices: any BackendDeckToolsMachinesDeviceService,
                                   workers: BackendBrowserWorkers,
                                   workerMetadata: any BackendDeckToolsMachinesWorkerMetadata,
                                   liftRequest: [BackendDeckToolsDefinition]) async throws -> [BackendDeckToolsDefinition] {
        guard machines.map(\.spec.id).sorted() == BackendDeckToolsMachinesArea.ids.sorted() else {
            throw BackendDeckToolsSupport.unavailable("the six machines.* definitions from the machine registration")
        }
        let environment = Self.environment(scope: scope, rpc: rpc)
        let channels = BackendCompositionDeckToolsMachineChannels(registry: registry)
        let servers = BackendDeckToolsMachinesServers(channels: channels, shells: serverShells, dataRoot: dataRoot, home: home)
        let remote = BackendDeckToolsMachinesRemote(channels: channels)
        var definitions = machines
        definitions += try await servers.definitions(environment: environment)
        definitions += try await remote.definitions(environment: environment)
        definitions += try BackendDeckToolsMachinesDevices(service: devices).definitions(environment: environment)
        definitions += try BackendDeckToolsMachinesWorkers(pool: BackendDeckToolsMachinesSafariPool(workers: workers), metadata: workerMetadata)
            .definitions(environment: environment, liftRequest: liftRequest)
        let expected = try BackendDeckToolsMachinesCatalogue.rows().compactMap { $0["id"].string } + ["browser.lift_request"]
        let built = definitions.map(\.spec.id)
        guard built.count == expected.count, Set(built) == Set(expected), Set(built).count == built.count else {
            throw BackendDeckToolsSupport.unavailable("every machines, servers, remote, devices and workers tool exactly once")
        }
        return definitions
    }
}

/// The machine/server/remote channel slice over the actual registered handlers.
/// Same allowed set, local-pairing gate and Swift→source projections as
/// `BackendDeckToolsMachinesRegistry` (Contracts.swift), with one difference that
/// matters to the authority: every round trip carries the call's OWN ticket
/// context, never a re-minted request ID, because `authorizeMutation` /
/// `authorizeMetadata` find the caller by that ticket. The registry refuses two
/// in-flight invokes with one request ID, so one call's round trips take turns
/// (a tool's parallel reads, such as remote.status, simply run in order).
public struct BackendCompositionDeckToolsMachineChannels: BackendDeckToolsMachinesChannels, Sendable {
    private let registry: NativeChannelRegistry
    private let localPairingAvailable: @Sendable () async -> Bool
    private let turns = BackendCompositionDeckToolsCallTurns()
    public init(registry: NativeChannelRegistry, localPairingAvailable: @escaping @Sendable () async -> Bool = { false }) {
        self.registry = registry; self.localPairingAvailable = localPairingAvailable
    }
    public func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        guard BackendDeckToolsMachinesRegistry.allowed.contains(channel) else { throw BackendDeckToolsSupport.unavailable(channel) }
        if ["machines:code", "machines:code:cancel"].contains(channel), !(await localPairingAvailable()) {
            throw BackendDeckToolsSupport.unavailable("the native local machine pairing host")
        }
        guard await registry.has(channel) else { throw BackendDeckToolsSupport.unavailable(channel) }
        let rpc = context.rpc
        await turns.enter(rpc.requestID)
        do {
            let answer = try await project(channel, try await registry.invoke(channel, context: rpc, arguments: arguments), rpc: rpc)
            await turns.leave(rpc.requestID); return answer
        } catch { await turns.leave(rpc.requestID); throw error }
    }
    private func project(_ channel: String, _ answer: NativeRPCValue, rpc: NativeRPCContext) async throws -> NativeRPCValue {
        if ["machines:connect", "machines:disconnect", "machines:rename", "machines:forget", "machines:drive-windows"].contains(channel), answer.fields == nil {
            return try await registry.invoke("machines:list", context: rpc, arguments: [])
        }
        if channel == "machines:pair", answer["offer"].isNullish, !answer["machine"].isNullish {
            return answer.setting("offer", answer["machine"])
        }
        return answer
    }
}

actor BackendCompositionDeckToolsCallTurns {
    private var busy: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    func enter(_ id: UUID) async {
        if !busy.contains(id) { busy.insert(id); return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }
    /// The turn passes straight to the next waiter of the same call.
    func leave(_ id: UUID) {
        guard var queue = waiters[id], !queue.isEmpty else { busy.remove(id); waiters[id] = nil; return }
        let next = queue.removeFirst(); waiters[id] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

/// surface.ts `deviceFolders` (L669) / remote-start.ts: the folders one paired
/// device may start a session in — the SAME array its `welcome` carries and its
/// `create` is checked against (BackendRemoteHost.context: open projects plus
/// visible sessions' folders, minus hidden, through the trust store's reach).
/// An unapproved or unknown device has none.
public struct BackendCompositionDeckToolsDeviceFolders: BackendDeckToolsMachinesDeviceFolders, Sendable {
    private let trust: BackendRemoteTrustStore
    private let authority: BackendCompositionAuthority
    public init(trust: BackendRemoteTrustStore, authority: BackendCompositionAuthority) { self.trust = trust; self.authority = authority }
    public func deviceFolders(_ deviceID: String) async throws -> [String] {
        guard !deviceID.isEmpty, await trust.isApproved(deviceID) else { return [] }
        let hidden = authority.hidden, sessions = authority.prepared.manager.list()
        let raw = authority.state.listProjects().compactMap { $0["path"].string } + sessions.filter { !hidden.contains($0.id) }.map(\.cwd)
        let offered = BackendRemoteServeSessionPolicy.offeredFolders(raw, sessions: sessions, hidden: { hidden.contains($0) })
        return await trust.reach(deviceID, offered: offered, home: authority.configuration.homeDirectory.path).folders
    }
    /// The same answer as `BackendCompositionDeckToolsScope.deviceFolders`.
    public var scopeFolders: BackendCompositionDeckToolsScope.DeviceFolders { { try await self.deviceFolders($0) } }
}

/// browser-session-lift.ts `noteInjection` / `injectionsFor` (L668-683): the hosts
/// each worker profile was signed into this run, newest first. A host and a
/// time only; never a cookie name or value. Recorded only when something landed
/// (L759: set > 0 || queued > 0). Process-lifetime, like the source map.
public actor BackendCompositionDeckToolsWorkerSignIns {
    private var injected: [String: [String: Double]] = [:]
    private let now: @Sendable () -> Double
    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }
    public func note(_ report: BackendBrowserSessionLiftReport) {
        guard report.cookiesSet > 0 || report.storageSet > 0 || report.storageQueued > 0,
              let host = URL(string: report.target.origin)?.host, !host.isEmpty else { return }
        injected[report.target.endpoint.profileID, default: [:]][host] = now()
    }
    public func hosts(_ profileID: String) -> [String] {
        (injected[profileID] ?? [:]).sorted { $0.value > $1.value }.map(\.key)
    }
    public func forgetAll() { injected.removeAll() }
    /// Wraps the Safari lift hooks so every real injection is noted, with no
    /// second transfer path: everything else passes through untouched.
    public nonisolated func recording(_ hooks: BackendBrowserSessionLiftHooks) -> BackendBrowserSessionLiftHooks {
        BackendBrowserSessionLiftHooks(source: hooks.source, targets: hooks.targets, approve: hooks.approve, capture: hooks.capture,
            inject: { [self] id, target, permit in
                let report = try await hooks.inject(id, target, permit)
                await self.note(report); return report
            }, reapprove: hooks.reapprove, forget: hooks.forget, revoke: hooks.revoke,
            revokeHolder: hooks.revokeHolder, pending: hooks.pending)
    }
}

/// worker-tools.ts `windowsByWorker` (L184-197) and `injectionsFor`: only the
/// calling session's own Safari windows (B1, B2…), first slot wins; Hoot and AI
/// apps have none. `browser` is the app target's Safari service
/// (`{ try await MainActor.run { try NativeCompositionRoot.shared.browserForComposition().service } }`).
public struct BackendCompositionDeckToolsWorkerMetadata: BackendDeckToolsMachinesWorkerMetadata, Sendable {
    public typealias Browser = @Sendable () async throws -> BackendBrowserService
    private let browser: Browser
    private let signIns: BackendCompositionDeckToolsWorkerSignIns
    public init(browser: @escaping Browser, signIns: BackendCompositionDeckToolsWorkerSignIns) { self.browser = browser; self.signIns = signIns }
    public func windowsByWorker(context: BackendDeckToolsMachinesContext) async throws -> [String: String] {
        guard context.kind == .session, let sessionID = context.sessionID else { return [:] }
        let service = try await browser(), machineID = context.machineID, ownerID = context.rpc.ownerID
        return await MainActor.run {
            let session = BrowserDriverSession(sessionId: sessionID, machineId: machineID)
            let principal = BackendBrowserPrincipal(ownerID: ownerID, sessionID: sessionID, machineID: machineID)
            var slots: [String: String] = [:]
            for window in service.bindings.bindings(for: principal).of(session) {
                // A window showing no page has no worker (source: viewId === null).
                guard let shown = service.bindings.window(window.tabID), !shown.viewID.isEmpty,
                      let profile = try? service.runtime.pageState(window.tabID)["profileId"].string, !profile.isEmpty else { continue }
                if slots[profile] == nil { slots[profile] = window.name }
            }
            return slots
        }
    }
    public func signedInHosts(profileID: String, context: BackendDeckToolsMachinesContext) async throws -> [String] {
        await signIns.hosts(profileID)
    }
}
