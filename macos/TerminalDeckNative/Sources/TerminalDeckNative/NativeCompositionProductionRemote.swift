import Foundation
import AppKit
import Darwin
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installRemoteMachinesAndServers() async throws {
        let trust = BackendRemoteTrustStore(directory: root.dataRoot.appendingPathComponent("remote"))
        try await trust.open()
        let windows = BackendRemoteServeWindowGrants(directory: root.dataRoot.appendingPathComponent("remote"),
            kindOf: { await trust.kindOf($0) }, report: report)
        await windows.open()
        let endpoint = try BackendRemoteHost(trust: trust, manager: sessions.manager, state: root.state,
            home: configuration.homeDirectory.path, hostName: Host.current().localizedName ?? "Mac",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            privateRoots: [root.dataRoot.path], operations: .init(create: { [sessions, joins] request, _ in
                var input = BackendCreateSessionInput(cwd: request.cwd, provider: request.provider)
                input.cols = request.cols; input.rows = request.rows
                let boundary = try await joins.deviceBoundary(deviceID: request.deviceID, folder: request.cwd)
                return try await sessions!.lifecycle.create(input, context: .init(deviceBoundary: boundary, rememberTab: true))
            }, close: { [sessions] id in try await sessions!.lifecycle.close(sessionID: id); return true },
                rename: { [sessions] id, title in try await sessions!.lifecycle.rename(sessionID: id, title: title) }),
            ptySource: sessions.manager)
        joins.bindRemote(trust: trust, host: endpoint, windows: windows)
        remoteTrust = trust; remoteEndpoint = endpoint; windowGrants = windows
        let hostAdapter = BackendRemoteServeRegistrationHostAdapter(endpoint: endpoint)
        let asks = BackendRemoteServeWindowAsks()
        await asks.serve(BackendRemoteServeWindowWireAdapter(ask: { device, message in
            try await hostAdapter.askWindows(deviceID: device, message: message)
        }, reaches: { await hostAdapter.reachesWindows($0) }))
        let nativeGitHub = clients.githubAuth.map { BackendRemoteServeNativeGitHub(authenticator: $0) }
        let github = nativeGitHub.map { BackendRemoteServeGitHub(authenticator: $0) }
        let credentials = BackendRemoteServeCredentials(directory: root.dataRoot.appendingPathComponent("remote"),
            hostCredential: { await nativeGitHub?.gitCredential() })
        let signIn = BackendRemoteServeAccountSignInAdapter(service: sessions.signIn)
        let accounts = BackendRemoteServeAccountService(profiles: sessions.profiles, lifecycle: sessions.lifecycle,
            signIn: signIn, switcher: sessions.switches)
        let browser = try NativeCompositionRoot.shared.remoteBrowserFeature(machineID: "", isMine: { id in
            guard await trust.isApproved(id) else { return false }; return await trust.kindOf(id) == .mine
        }, sessions: { [sessions] _ in sessions!.manager.list().map { .init(id: $0.id, title: $0.title, ended: $0.exitCode != nil) } },
            write: { [sessions] id, text, _ in try await sessions!.lifecycle.write(sessionID: id, data: text) },
            startPage: { [root] _ in await root.settings.value("browser.startPage").string ?? "about:blank" })
        let enrollment = BackendRemoteServeEnrollment(trust: trust,
            verifier: BackendRemoteServeSSHVerifier(transport: BackendNodelessSSHAuthTransport()), environment: configuration.inheritedEnvironment)
        remoteHost = try await root.remoteHostService(endpoint: endpoint,
            relayURL: BackendRelayAddress.resolve(),
            webRoot: Bundle.main.resourceURL?.appendingPathComponent("web/pwa"),
            hostName: Host.current().localizedName ?? "Mac", preview: Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool != true,
            mcp: { [relay] head, body in await relay.answer(head, body: body) }, afterEndpointStart: { [weak self] in try await self?.startRemoteRegistration() })
        if let host = remoteHost { await relay.useLink { await host.status().relay } }
        remoteRegistration = try await root.installRemoteServe(dependencies: .init(host: hostAdapter, trust: trust,
            lifecycle: sessions.lifecycle, accounts: accounts, usage: BackendRemoteServeUsageService(usage: usage.usage),
            credentials: credentials, windowGrants: windows, windowAsks: asks,
            offeredFolders: { [state, sessions, joins] _ in BackendRemoteServeSessionPolicy.offeredFolders(state.listProjects().compactMap { $0["path"].string }, sessions: sessions!.manager.list(), hidden: { joins.hidden.contains($0) }) },
            observeAccountDeletion: { [configuration, sessions] callback in
                try await NativeCompositionAccountDeletion.observe(directory: configuration.dataDirectory, profiles: sessions!.profiles, callback: callback)
            }, forgetAdditionalDeviceState: { [usage] id in
                await usage!.disconnect(ownerID: id); await asks.gone(id)
                let browser = try await NativeCompositionRoot.shared.browserForComposition()
                await browser.disconnect(.init(caller: .pairedDevice, ownerID: id))
            },
            spawn: { [sessions, joins] request, guest in
                var input = BackendCreateSessionInput(cwd: request.cwd, provider: request.provider)
                input.cols = request.cols; input.rows = request.rows
                return try await sessions!.lifecycle.create(input, context: .init(
                    deviceBoundary: try await joins.deviceBoundary(deviceID: request.deviceID, folder: request.cwd),
                    rememberTab: true, environmentOverrides: guest.set, removeEnvironment: Set(guest.remove)))
            }, github: github,
            observeGitHub: { [clients] callback in await clients!.githubChanges.observe(callback) },
            enrollment: enrollment, browser: browser, hostLifecycle: nil, // TS: a desktop is its own screen; host.control is the headless host's
            hidden: joins.hidden, report: report))
        try await installRemoteSettings(endpoint: endpoint)
        try await prepareMachines(endpoint: endpoint, trust: trust)
        try await installServers()
    }
}

/// Observe actual profile-file directory changes, then read the SAME account
/// actor. Atomic rename writes are covered without a poll or another cache.
@MainActor
private final class NativeCompositionAccountDeletion {
    private var known: Set<String> = []
    private let profiles: BackendAccountProfileStore
    private let callback: @Sendable (String) async -> Void
    private var source: DispatchSourceFileSystemObject?
    private var reading: Task<Void, Never>?
    private var stopped = false
    private init(profiles: BackendAccountProfileStore, callback: @escaping @Sendable (String) async -> Void) { self.profiles = profiles; self.callback = callback }
    static func observe(directory: URL, profiles: BackendAccountProfileStore,
                        callback: @escaping @Sendable (String) async -> Void) async throws -> NativeRPCSubscription {
        let watch = NativeCompositionAccountDeletion(profiles: profiles, callback: callback)
        watch.known = Set(try await profiles.list(provider: nil).map(\.id))
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeRPCError(code: "watch-failed", message: "The account directory could not be observed.") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak watch] in Task { @MainActor in watch?.changed() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        watch.source = source; source.resume()
        return NativeRPCSubscription { await watch.stop() }
    }
    private func changed() {
        let previous = reading
        reading = Task { [weak self] in
            await previous?.value
            guard let self, !self.stopped else { return }
            do {
                let ids = Set(try await self.profiles.list(provider: nil).map(\.id))
                let removed = self.known.subtracting(ids); self.known = ids
                for id in removed { await self.callback(id) }
            } catch { NSLog("[native account deletion] %@", error.localizedDescription) }
        }
    }
    private func stop() async { stopped = true; source?.cancel(); source = nil; await reading?.value; reading = nil }
}
