import Foundation
import TerminalDeckNativeCore

/// The integration owner implements this on the authoritative remote host.
/// install must atomically add this owner's features/suppliers/hooks, reject
/// duplicate ownership of the remote-serve area (even for different owner IDs),
/// and return a lease that removes ONLY this installation.
/// The present BackendRemoteHost cannot supply this through its private fields.
public protocol BackendRemoteServeRegistrationHost: Sendable {
    var endpoint: BackendRemoteHost { get }
    func install(ownerID: String, features: [BackendRemoteHostFeature],
                 suppliers: BackendRemoteServeRegistration.Suppliers,
                 hooks: BackendRemoteServeRegistration.Hooks) async throws -> NativeRPCSubscription
    func connectedDeviceIDs() async -> Set<String>
    /// Full source-shaped rows, including other owners' optional fields.
    func connectionRows() async -> [NativeRPCValue]
    func dropDevice(_ deviceID: String) async
    func foldersChanged(_ deviceID: String) async
    func askWindows(deviceID: String, message: BackendRemoteServerMessage) async throws -> Int
    func reachesWindows(_ deviceID: String) async -> Bool
    /// Recheck approval, mine kind and claimed capability for EACH live peer.
    func pushToOwnDevices(_ message: BackendRemoteServerMessage, claiming capability: String) async throws
}

/// One composition-root call registers the completed remote-serve area.
/// No listener, host, Tailscale command, credential read or store load starts
/// during registration. Call the returned start() during explicit startup,
/// after the shared trust owner is open and before accepting remote peers.
/// This area owns no MCP tool names: browser/usage tools keep their own owners
/// on composition.mcp; machine/panel/upload/tunnel/Hoot routes are not installed.
public enum BackendRemoteServeRegistration {
    public static let ownerID = "native-composition:remote-serve"
    public static let invokeChannels = BackendRemoteServeAccountChannels.channels.union(["remote:windows", "remote:windows:set"])
    public static let eventChannels: Set<String> = ["remote:connections"]
    public typealias Spawn = @Sendable (BackendRemoteCreateRequest, BackendRemoteServeGitGuest.Environment) async throws -> BackendSessionMeta
    public typealias ObserveGitHub = @Sendable (@escaping @Sendable () async -> Void) async throws -> NativeRPCSubscription
    public typealias ObserveAccountDeletion = @Sendable (@escaping @Sendable (String) async -> Void) async throws -> NativeRPCSubscription

    public struct Dependencies: Sendable {
        public let host: any BackendRemoteServeRegistrationHost
        public let trust: BackendRemoteTrustStore
        public let lifecycle: BackendSessionLifecycleCoordinator
        public let accounts: BackendRemoteServeAccountService
        public let usage: BackendRemoteServeUsageService
        public let credentials: BackendRemoteServeCredentials
        public let windowGrants: BackendRemoteServeWindowGrants
        public let windowAsks: BackendRemoteServeWindowAsks
        public let github: BackendRemoteServeGitHub?
        public let enrollment: BackendRemoteServeEnrollment?
        public let browser: BackendRemoteHostFeature?
        public let hostLifecycle: (any BackendRemoteServeHostLifecycle)?
        public let hidden: BackendRemoteServeSessionHidden
        public let offeredFolders: @Sendable (String) async throws -> [String]
        public let spawn: Spawn?
        public let observeGitHub: ObserveGitHub?
        public let observeAccountDeletion: ObserveAccountDeletion
        /// Clear kinds and other domains' state without the obsolete trust
        /// window writer. Domain grants/window grants/credential keys are
        /// already forgotten here. Never call old aggregate forgetGrants.
        public let forgetAdditionalDeviceState: @Sendable (String) async throws -> Void
        public let report: @Sendable (String) -> Void
        public init(host: any BackendRemoteServeRegistrationHost, trust: BackendRemoteTrustStore,
                    lifecycle: BackendSessionLifecycleCoordinator, accounts: BackendRemoteServeAccountService,
                    usage: BackendRemoteServeUsageService, credentials: BackendRemoteServeCredentials,
                    windowGrants: BackendRemoteServeWindowGrants, windowAsks: BackendRemoteServeWindowAsks,
                    offeredFolders: @escaping @Sendable (String) async throws -> [String],
                    observeAccountDeletion: @escaping ObserveAccountDeletion,
                    forgetAdditionalDeviceState: @escaping @Sendable (String) async throws -> Void,
                    spawn: Spawn? = nil, github: BackendRemoteServeGitHub? = nil,
                    observeGitHub: ObserveGitHub? = nil, enrollment: BackendRemoteServeEnrollment? = nil,
                    browser: BackendRemoteHostFeature? = nil, hostLifecycle: (any BackendRemoteServeHostLifecycle)? = nil,
                    hidden: BackendRemoteServeSessionHidden = .shared,
                    report: @escaping @Sendable (String) -> Void = { _ in }) {
            self.host = host; self.trust = trust; self.lifecycle = lifecycle; self.accounts = accounts
            self.usage = usage; self.credentials = credentials; self.windowGrants = windowGrants; self.windowAsks = windowAsks
            self.offeredFolders = offeredFolders; self.observeAccountDeletion = observeAccountDeletion
            self.forgetAdditionalDeviceState = forgetAdditionalDeviceState; self.spawn = spawn
            self.github = github; self.observeGitHub = observeGitHub
            // ssh-verify.ts parity without ssh2: unless a caller supplies its own,
            // SSH-login enrollment uses the native handshake-only loopback check.
            self.enrollment = enrollment ?? BackendRemoteServeEnrollment(trust: trust,
                verifier: BackendRemoteServeSSHVerifier(transport: BackendNodelessSSHAuthTransport()),
                environment: ProcessInfo.processInfo.environment)
            self.browser = browser; self.hostLifecycle = hostLifecycle; self.hidden = hidden; self.report = report
        }
    }

    /// These are real host suppliers, not IPC/MCP aliases. The host installer
    /// applies the source's create/hidden/account/window rules on every call.
    public struct Suppliers: Sendable {
        public let requireReady: @Sendable () async throws -> Void
        public let create: BackendRemoteServeSessionCreate?
        public let enrollment: BackendRemoteServeEnrollment?
        public let drivesWindows: @Sendable (String) async throws -> Bool
        public let sessionVisible: @Sendable (String, String) async -> Bool
        public let isHidden: @Sendable (String) -> Bool
        public let accountShared: @Sendable (String, String) async -> Bool
        public let anyAccount: @Sendable (String) async -> Bool
        /// Legacy credential frames are consumed without advertising credential.
        /// Do not use legacyFeature(): its credential.legacy label is not in
        /// the current host's accepted capability set.
        public let legacyCredential: @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> Void
        public let missingFeature: @Sendable (String) throws -> BackendRemoteServerMessage?
        public let guestRefusal: @Sendable (String) throws -> BackendRemoteServerMessage?
    }
    public struct Hooks: Sendable {
        public let connectionsChanged: @Sendable () async -> Void
        public let rosterChanged: @Sendable () async -> Void
        public let lastDeviceDisconnected: @Sendable (String) async -> Void
        public let windowHolds: @Sendable (BackendRemoteClientMessage, String) async -> Void
    }
    public struct Installed: Sendable {
        private let runtime: Runtime
        fileprivate init(runtime: Runtime) { self.runtime = runtime }
        public func start() async throws { try await runtime.start() }
        public func stop() async { await runtime.stop() }
        /// TS remote:device:revoke → device-roster.ts revoke: revoke → drop → forget → announce,
        /// false for a no-op (the one cascade the wire and the desktop's Remove share).
        public func revoke(_ deviceID: String) async throws -> Bool { try await runtime.revokeDevice(deviceID) }
        /// Re-announce the device list to the owner's own devices (TS approve's push).
        public func rosterChanged() async { await runtime.rosterChanged() }
    }

    public static func register(in composition: BackendCompositionRoot, dependencies d: Dependencies) async throws -> Installed {
        let registry = composition.registry
        guard !(await composition.domains()).contains("remote-serve") else {
            throw NativeRPCError(code: "duplicate-handler", message: "The remote-serve area already has a native owner.")
        }
        for channel in invokeChannels {
            guard !(await registry.has(channel)) else {
                throw NativeRPCError(code: "duplicate-handler", message: "A handler is already registered for '\(channel)'")
            }
        }
        if d.github != nil && d.observeGitHub == nil {
            throw NativeRPCError(code: "unavailable", message: "The host GitHub change source is unavailable.")
        }
        if let browser = d.browser {
            let expectedTags = await BackendRemoteServeBrowserControl.requestTags
            guard browser.capability == "browser.control", browser.messageTypes == expectedTags else {
                throw NativeRPCError.malformed("Supply the complete remote Safari browser-control feature.")
            }
        }
        // This reuses its existing owner and no-ops if already installed; it
        // does not register tailnet twice or start Tailscale.
        try await composition.installFoundations()
        // A failed concurrent attempt must never remove another lease's routes.
        let owner = ownerID + ":" + UUID().uuidString.lowercased()
        let runtime = Runtime(dependencies: d, registry: registry, ownerID: owner)
        let gate = BackendRemoteServeSessionGate(trust: d.trust, manager: d.lifecycle.manager, hidden: d.hidden)
        let roster = BackendRemoteServeRoster(trust: d.trust,
            connected: { await d.host.connectedDeviceIDs() }, drop: { await d.host.dropDevice($0) },
            forget: { try await runtime.forgetDevice($0) }, announce: { await runtime.rosterChanged() })
        await runtime.retainRoster(roster)
        var features = [await roster.feature(), d.windowAsks.feature(), d.usage.feature(gate: gate)]
        if let account = d.accounts.accountFeature(trust: d.trust, gate: gate) { features.append(account) }
        if let logins = d.accounts.loginFeature() { features.append(logins) }
        if let github = d.github { features.append(await github.feature()) }
        if let browser = d.browser { features.append(browser) }
        if let lifecycle = d.hostLifecycle { features.append(BackendRemoteServeLifecycle.feature(lifecycle)) }
        // Registration is inert; an early packet cannot reach unopened stores.
        features = features.map { feature in
            .init(capability: feature.capability, messageTypes: feature.messageTypes, policy: feature.policy, sessionField: feature.sessionField) { message, context in
                try await runtime.requireStarted()
                return try await feature.handle(message, context)
            }
        }
        let creator = d.spawn.map { spawn in
            BackendRemoteServeSessionCreate(folders: { device in
                let offered = try await d.offeredFolders(device)
                let sessions = d.lifecycle.manager.list()
                return BackendRemoteServeSessionPolicy.offeredFolders(offered, sessions: sessions, hidden: { d.hidden.contains($0) })
            }, unrestricted: { await d.trust.kindOf($0) == .mine }, spawn: { request in
                try await runtime.requireStarted()
                let grant = try await d.credentials.openGuestSession(deviceID: request.deviceID)
                do {
                    let meta = try await spawn(request, grant.environment)
                    await d.credentials.started(key: grant.key, sessionID: meta.id); return meta
                } catch { await d.credentials.close(key: grant.key); throw error }
            }, noteStarted: { device, session in
                _ = try await d.trust.remoteServeIncludeStartedSession(device, sessionID: session)
            }, report: d.report)
        }
        let suppliers = Suppliers(requireReady: { try await runtime.requireStarted() }, create: creator, enrollment: d.enrollment,
            drivesWindows: { try await runtime.requireStarted(); return try await d.windowGrants.drives($0) },
            sessionVisible: { await gate.visible(deviceID: $0, sessionID: $1) }, isHidden: { d.hidden.contains($0) },
            accountShared: { await d.trust.accountAllowed($0, account: $1) }, anyAccount: { await d.trust.hasAnyAccount($0) },
            legacyCredential: { message, context in
                try await runtime.requireStarted(); await d.credentials.handle(deviceID: context.deviceID, message: message)
            }, missingFeature: { try BackendRemoteServeHostRefusals.missing($0) }, guestRefusal: { try BackendRemoteServeHostRefusals.guest($0) })
        let hooks = Hooks(connectionsChanged: { await runtime.connectionsChanged() }, rosterChanged: { await runtime.rosterChanged() },
            lastDeviceDisconnected: { await d.windowAsks.gone($0); await d.credentials.connectionClosed($0) },
            windowHolds: { await d.windowAsks.receivedHolds($0, deviceID: $1) })
        do {
            let channels = BackendRemoteServeAccountChannels(trust: d.trust, lifecycle: d.lifecycle, hidden: d.hidden,
                foldersChanged: { await d.host.foldersChanged($0) }, sessionsChanged: { await d.host.endpoint.sessionsChanged() })
            for channel in BackendRemoteServeAccountChannels.channels.sorted() {
                try await registry.register(channel, ownerID: owner, policy: BackendCompositionRoot.requireLocalUI) { _, args in
                    try await runtime.requireStarted(); return try await channels.invoke(channel, arguments: args)
                }
            }
            for channel in ["remote:windows", "remote:windows:set"] {
                try await registry.register(channel, ownerID: owner, policy: BackendCompositionRoot.requireLocalUI) { context, args in
                    try await runtime.requireStarted()
                    if channel == "remote:windows:set" {
                        _ = try await d.windowGrants.set(context.argument(0, in: args), drives: context.argument(1, in: args))
                        await d.host.endpoint.refreshGrants()
                    }
                    let devices = await d.trust.listDevices()
                    var result: [NativeRPCValue] = []
                    for entry in devices.enumerated().sorted(by: { a, b in a.element.addedAt == b.element.addedAt ? a.offset < b.offset : a.element.addedAt > b.element.addedAt }) {
                        if try await d.windowGrants.drives(entry.element.id) { result.append(.string(entry.element.id)) }
                    }
                    return .array(result)
                }
            }
            let lease = try await d.host.install(ownerID: owner, features: features, suppliers: suppliers, hooks: hooks)
            await runtime.retain(lease)
            let fanout = BackendRemoteServeSessionFanout(lifecycle: d.lifecycle, host: d.host.endpoint, trust: d.trust, report: d.report)
            let lifecycleObserver = await d.lifecycle.observe { event in
                guard await runtime.started() else { return }
                switch event { case .exit(let id, _), .removed(let id, _): await d.credentials.sessionEnded(id); default: break }
                await fanout.note(event)
            }
            await runtime.retain(NativeRPCSubscription { await d.lifecycle.removeObserver(lifecycleObserver) })
            await runtime.retain(try await d.observeAccountDeletion { id in
                await runtime.accountDeleted(id)
            })
            if let github = d.github, let observe = d.observeGitHub {
                let listener = await github.onChanged { await runtime.githubChanged() }
                await runtime.retain(NativeRPCSubscription { await github.unsubscribe(listener) })
                await runtime.retain(try await observe { await github.emitChanged() })
            }
            await runtime.ownConsumers()
            await d.credentials.serve(ownDevice: { device in
                guard await d.trust.isApproved(device) else { return false }; return await d.trust.kindOf(device) == .mine
            })
            await d.windowAsks.serve(BackendRemoteServeWindowWireAdapter(
                ask: { try await d.host.askWindows(deviceID: $0, message: $1) }, reaches: { await d.host.reachesWindows($0) }))
            try await composition.retain(.init(name: "remote-serve", domains: ["remote-serve"], ownerID: owner,
                invokes: invokeChannels, events: eventChannels, stop: { await runtime.stop() }))
            return Installed(runtime: runtime)
        } catch { await runtime.stop(); throw error }
    }

    fileprivate actor Runtime {
        let d: Dependencies, registry: NativeChannelRegistry
        let ownerID: String
        var subscriptions: [NativeRPCSubscription] = [], roster: BackendRemoteServeRoster?
        var active = false, starting = false, stopped = false, ownsConsumers = false
        var pendingDeletedAccounts = Set<String>()
        init(dependencies: Dependencies, registry: NativeChannelRegistry, ownerID: String) {
            d = dependencies; self.registry = registry; self.ownerID = ownerID
        }
        func retain(_ token: NativeRPCSubscription) { subscriptions.append(token) }
        func retainRoster(_ value: BackendRemoteServeRoster) { roster = value }
        func revokeDevice(_ id: String) async throws -> Bool {
            guard let roster else { throw NativeRPCError(code: "unavailable", message: "The device roster is not installed.") }
            return try await roster.revoke(id)
        }
        func ownConsumers() { ownsConsumers = true }
        func started() -> Bool { active && !stopped }
        func requireStarted() throws { guard started() else { throw NativeRPCError(code: "unavailable", message: "The native remote-serve area is not started.") } }
        func start() async throws {
            guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The native remote-serve registration has stopped.") }
            if active { return }
            guard !starting else { throw NativeRPCError(code: "unavailable", message: "The native remote-serve area is still starting.") }
            starting = true; defer { starting = false }
            try await d.trust.remoteServeReloadDomainGrants(report: d.report)
            await d.windowGrants.open()
            guard !stopped else { await d.windowGrants.close(); throw NativeRPCError(code: "unavailable", message: "The native remote-serve registration stopped during startup.") }
            if await d.credentials.start() == nil { d.report("[credentials] the credential endpoint could not start; guest Git remains isolated without a helper link.") }
            guard !stopped else { await d.credentials.stop(); await d.windowGrants.close(); throw NativeRPCError(code: "unavailable", message: "The native remote-serve registration stopped during startup.") }
            // Deletions can arrive while stores/listener are opening. Prune
            // them before any feature/channel becomes usable.
            while !pendingDeletedAccounts.isEmpty {
                let pending = pendingDeletedAccounts
                for id in pending {
                    _ = try await d.trust.remoteServeDropAccount(id)
                    pendingDeletedAccounts.remove(id)
                }
                guard !stopped else { throw NativeRPCError(code: "unavailable", message: "The native remote-serve registration stopped during startup.") }
            }
            active = true
        }
        func connectionsChanged() async {
            guard started() else { return }
            do { try await registry.publish("remote:connections", arguments: [.array(await d.host.connectionRows())]) }
            catch { d.report("[remote] could not publish connections: " + error.localizedDescription) }
        }
        func rosterChanged() async {
            guard started(), let roster else { return }; await connectionsChanged()
            do { try await d.host.pushToOwnDevices(try await roster.changedMessage(), claiming: "devices") }
            catch { d.report("[remote] could not publish device roster: " + error.localizedDescription) }
        }
        func githubChanged() async {
            guard started(), let github = d.github else { return }
            do { try await d.host.pushToOwnDevices(try await github.changedMessage(), claiming: "github") }
            catch { d.report("[remote] could not publish host GitHub state: " + error.localizedDescription) }
        }
        func forgetDevice(_ id: String) async throws {
            await d.credentials.forget(id)
            _ = try await d.trust.remoteServeForgetFolderGrants(id)
            _ = try await d.trust.remoteServeForgetAccountGrants(id)
            _ = try await d.trust.remoteServeForgetSessionGrants(id)
            _ = try await d.windowGrants.forget(id)
            try await d.forgetAdditionalDeviceState(id)
        }
        func accountDeleted(_ id: String) async {
            guard !stopped, !id.isEmpty else { return }
            guard active else { pendingDeletedAccounts.insert(id); return }
            do { _ = try await d.trust.remoteServeDropAccount(id) }
            catch { d.report("[remote] could not drop a deleted account's grants: " + error.localizedDescription) }
        }
        func stop() async {
            guard !stopped else { return }; stopped = true; active = false
            let installed = subscriptions; subscriptions = []
            for subscription in installed.reversed() { await subscription.cancelAndWait() }
            if ownsConsumers { await d.windowAsks.stop(); await d.credentials.stop(); await d.windowGrants.close() }
            roster = nil; pendingDeletedAccounts = []; await registry.removeOwner(ownerID)
        }
    }
}
