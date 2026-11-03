import Foundation
import AppKit
import Darwin
import TerminalDeckBackend
import TerminalDeckPeer
import TerminalDeckNativeCore

#if TD_HOST_ACCOUNT_BRIDGE
private typealias NativeHOSTRemoteProfileReader = any BackendHOSTProfileViewReading
#else
private typealias NativeHOSTRemoteProfileReader = BackendAccountProfileStore
#endif

extension NativeCompositionProduction {
    func installRemoteMachinesAndServers() async throws {
        let sessions = try wired(self.sessions, "sessions"), clients = try wired(self.clients, "clients"),
            usage = try wired(self.usage, "usage"), authority = try wired(self.authority, "authority")
        let trust = BackendRemoteTrustStore(directory: root.dataRoot.appendingPathComponent("remote"))
        try await trust.open()
        let windows = BackendRemoteServeWindowGrants(directory: root.dataRoot.appendingPathComponent("remote"),
            kindOf: { await trust.kindOf($0) }, report: report)
        await windows.open()
        let endpoint = try BackendRemoteHost(trust: trust, manager: sessions.manager, state: root.state,
            home: configuration.homeDirectory.path, hostName: Host.current().localizedName ?? "Mac",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            privateRoots: [root.dataRoot.path], operations: .init(create: { [sessions, joins, root, authority] request, _ in
                // A phone's New session choices (iOS batch 1), as this Mac's own dialog takes them; none: as before.
                let input = try await NativePhoneStart.input(request, chat: request.choices.chat == false ? false : nil, invoke: { channel, arguments in
                    try await root.registry.invoke(channel, context: authority.localContext(), arguments: arguments)
                }, specs: try? BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership))
                let boundary = try await joins.phoneStartBoundary(deviceID: request.deviceID, folder: request.cwd)
                let meta = try await BackendAGSLaunchScope.$deviceStart.withValue(request.deviceID) {
                    try await sessions.lifecycle.create(input, context: .init(deviceBoundary: boundary, rememberTab: true))
                }
                if boundary == nil { NativePhoneStart.rememberFolder(request.cwd) }
                return meta
            }, close: { [sessions] id in try await sessions.lifecycle.close(sessionID: id); return true },
                rename: { [sessions, root] id, title in
                    // A name typed on the phone reaches this Mac's windows and the island too, not only the phone's list.
                    guard try await sessions.lifecycle.rename(sessionID: id, title: title) else { return false }
                    let resolved = sessions.manager.list().first(where: { $0.id == id })?.title ?? title
                    try? await root.registry.publish("session:renamed", arguments: [.string(id), .string(resolved)])
                    return true
                }),
            ptySource: sessions.manager)
        // stream step 2 (dc2) and m5-direct-only (§11 link only): every paired device that asks gets one WebRTC link per
        // connection — the terminal, every message and the screen's video, same network → internet peer-to-peer →
        // Cloudflare TURN; the relay is only the meeting point. This Mac as a guest of another computer answers the same way.
        await endpoint.setLinkEngine(TerminalDeckPeerEngine())
        BackendRemoteGuest.answerer = TerminalDeckPeerAnswerer()
        // 1 Nov (item 58): a session's lastActivityAt is when something really happened inside it
        // (`BackendSessionActivity`): an AI's own hook steps, kept in the ledger across app restarts.
        sessions.manager.onActivity { [ledger = sessions.ledger] id, at in Task { try? await ledger.noteActivity(id, at: at) } }
        // Item 74: the same hook steps move the session's transcript; the phones following it get its context reading.
        let contextPush = BackendRemoteServeUsagePush()
        _ = await sessions.hookCoordinator.observeAccepted { [manager = sessions.manager] event in
            guard let id = event.sessionID, BackendSessionActivity.hookCounts(event.event) else { return }
            manager.noteActivity(id, at: event.receivedAt.timeIntervalSince1970 * 1000)
            Task { await contextPush.transcriptChanged(id) }
        }
        // 2 Nov (item 65): a session whose work came before its time was kept reads it from its own transcript, once.
        // Every Claude home the app gives its sessions, a scratch copy's <data>/agent-homes/claude too (F2).
        let claudeHomes = BackendSessionActivity.claudeHomes(home: configuration.homeDirectory, dataRoot: root.dataRoot,
            sessionEnvironment: configuration.inheritedEnvironment)
        await endpoint.setRecordedActivity { saved in BackendSessionActivity.transcriptActivity(saved: saved, configDirectories: claudeHomes) }
        joins.bindRemote(trust: trust, host: endpoint, windows: windows)
        remoteTrust = trust; remoteEndpoint = endpoint; windowGrants = windows
        root.events.bind(remote: endpoint) // 2 Nov: phones list the status the app accepted (a hooked AI's turn)
        let hostAdapter = BackendRemoteServeRegistrationHostAdapter(endpoint: endpoint)
        let asks = BackendRemoteServeWindowAsks()
        await asks.serve(BackendRemoteServeWindowWireAdapter(ask: { device, message in
            try await hostAdapter.askWindows(deviceID: device, message: message)
        }, reaches: { await hostAdapter.reachesWindows($0) }))
        let nativeGitHub = clients.githubAuth.map { BackendRemoteServeNativeGitHub(authenticator: $0) }
        let github = nativeGitHub.map { BackendRemoteServeGitHub(authenticator: $0) }
        let credentials = BackendRemoteServeCredentials(directory: root.dataRoot.appendingPathComponent("remote"),
            hostCredential: { await nativeGitHub?.gitCredential() })
        #if TD_HOST_ACCOUNT_BRIDGE
        // Incoming remote owner/core scope must be retained by its actual gate;
        // no nativeApp context is invented for a device or keyed caller here.
        let accounts = BackendRemoteServeAccountService(profiles: { [sessions] in
            let original = try BackendHOSTProfileScope.requireCurrent()
            return try await BackendHOSTProfileScope.withContext(original) { try await sessions.profiles.list(provider: nil) }
        }, attribution: { [sessions] id in
            guard sessions.manager.list().contains(where: { $0.id == id }) else { return nil }
            // 31 Oct (Asad: "accounts switching is also not working in phones"): the chip's own read, so an in-place
            // switch shows the chosen account at once on the phone as on this Mac (the bare attribution kept the old
            // one until the agent's next request, and the phone's Switch waited on it forever).
            if let original = try? BackendHOSTProfileScope.requireCurrent(),
               let chip = try? await sessions.sessionRPC.invoke("session:account", args: [.string(id)], context: original) {
                return BackendAccountSessionReading.decode(chip)
            }
            return await sessions.lifecycle.sessionAccount(sessionID: id)
        }, probe: { [sessions] profile in
            let original = try BackendHOSTProfileScope.requireCurrent()
            let value = try await sessions.signIn.invoke("profiles:signin", args: [.string(profile.id)], context: original)
            guard let state = value["state"].string.flatMap(BackendRemoteServeAccountSignIn.State.init(rawValue:)),
                  let detail = value["detail"].string else { throw BackendHOSTFailure.unavailable }
            return .init(state: state, account: value["account"].string, plan: value["plan"].string, detail: detail)
        }, switchAccount: { [sessions] id, account in
            let original = try BackendHOSTProfileScope.requireCurrent()
            let value = try await sessions.sessionRPC.invoke("session:switch-account", args: [.string(id), .string(account)], context: original)
            return .init(ok: true, message: "", session: value["id"].string)
        }, owner: { try authority.localContext() })   // a Full-control phone's Switch runs as this Mac's own (27 Oct, D3)
        #else
        let signIn = BackendRemoteServeAccountSignInAdapter(service: sessions.signIn)
        let accounts = BackendRemoteServeAccountService(profiles: sessions.profiles, lifecycle: sessions.lifecycle,
            signIn: signIn, switcher: sessions.switches, owner: { try authority.localContext() })
        #endif
        let browser = try NativeCompositionRoot.shared.remoteBrowserFeature(machineID: "", isMine: { id in
            guard await trust.isApproved(id) else { return false }; return await trust.kindOf(id) == .mine
        }, sessions: { [sessions] _ in sessions.manager.list().map { .init(id: $0.id, title: $0.title, ended: $0.exitCode != nil) } },
            write: { [sessions] id, text, _ in try await sessions.lifecycle.write(sessionID: id, data: text) },
            startPage: { [root] _ in   // SETTINGS-TRUTH row 64: the one start page key (browser.startUrl)
                let start = await root.settings.value("browser.startUrl").string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return start.isEmpty ? "about:blank" : start })
        let enrollment = BackendRemoteServeEnrollment(trust: trust,
            verifier: BackendRemoteServeSSHVerifier(transport: BackendNodelessSSHAuthTransport()), environment: configuration.inheritedEnvironment)
        remoteHost = try await root.remoteHostService(endpoint: endpoint,
            relayURL: BackendRelayAddress.resolve(),
            webRoot: Bundle.main.resourceURL?.appendingPathComponent("web/pwa"),
            hostName: Host.current().localizedName ?? "Mac", preview: Bundle.main.object(forInfoDictionaryKey: "TDNativeStandalone") as? Bool != true
                || configuration.dataDirectory.standardizedFileURL != BackendCompositionSuppliers.primaryDataDirectory(home: configuration.homeDirectory)
                || BackendDevCopy.isDevCopy(dataDirectory: configuration.dataDirectory),
            mcp: { [relay] head, body in await relay.answer(head, body: body) },
            localPort: UInt16(configuration.inheritedEnvironment["TD_WEB_PORT"] ?? "") ?? 8444, afterEndpointStart: { [weak self] in try await self?.startRemoteRegistration() })
        if let host = remoteHost { await relay.useLink { await host.status().relay } }
        let usageServe = BackendRemoteServeUsageService(usage: usage.usage, owner: { try authority.localContext() }, push: contextPush,
            hoot: { [weak self] in await MainActor.run { self?.hoot?.usage } })
        self.contextPush = contextPush
        await contextPush.bind(read: { id, caller in try await usageServe.pushedContext(sessionID: id, caller: caller) },
                               send: { connection, message in try await endpoint.sendToConnection(connection, message: message) })
        remoteRegistration = try await root.installRemoteServe(dependencies: .init(host: hostAdapter, trust: trust,
            lifecycle: sessions.lifecycle, accounts: accounts, usage: usageServe,
            credentials: credentials, windowGrants: windows, windowAsks: asks,
            offeredFolders: { [state, sessions, joins] _ in BackendRemoteServeSessionPolicy.offeredFolders(state.listProjects().compactMap { $0["path"].string }, sessions: sessions.manager.list(), hidden: { joins.hidden.contains($0) }) },
            observeAccountDeletion: { [configuration, sessions, authority] callback in
                try await NativeCompositionAccountDeletion.observe(directory: configuration.dataDirectory, list: {
                    #if TD_HOST_ACCOUNT_BRIDGE
                    // L8 (10 Oct): a file event carries no request, so every re-read refused ("profile-read
                    // context has not been fully connected") and deletions were never noticed. Read as the
                    // app owner, as startup and the task transcript locator do.
                    return try await BackendHOSTProfileScope.withContext(try authority.localContext()) { try await sessions.profiles.list(provider: nil).map(\.id) }
                    #else
                    return try await sessions.profiles.list(provider: nil).map(\.id)
                    #endif
                }, callback: callback)
            }, forgetAdditionalDeviceState: { [usage, weak self] id in
                await usage.disconnect(ownerID: id); await asks.gone(id)
                await self?.releaseServerControlOwner(id)
                let browser = try await NativeCompositionRoot.shared.browserForComposition()
                await browser.disconnect(.init(caller: .pairedDevice, ownerID: id))
            },
            spawn: { [sessions, joins, root, authority] request, guest in
                // #27: a phone's New session choices (login, agent, model, effort; Terminal) reach its terminal as they
                // reach its chats. This path dropped them, so a login picked on the phone was not the one that ran.
                let input = try await NativePhoneStart.input(request, chat: request.choices.chat == false ? false : nil, invoke: { channel, arguments in
                    try await root.registry.invoke(channel, context: authority.localContext(), arguments: arguments)
                }, specs: try? BackendTaskPersistence(directory: root.dataRoot.appendingPathComponent("remote/task-briefs"), ownership: root.state.ownership))
                // A phone's terminal: at Full control no folder sandbox, as for its chats (27 Oct, Decker D2).
                let boundary = try await joins.phoneStartBoundary(deviceID: request.deviceID, folder: request.cwd)
                // #27: the person's own device at Full gets this Mac's own git, SSH and GitHub logins (see forStart).
                let git = BackendRemoteServeGitGuest.forStart(guest, sandboxed: boundary != nil)
                let meta = try await BackendAGSLaunchScope.$deviceStart.withValue(request.deviceID) {
                    try await sessions.lifecycle.create(input, context: .init(deviceBoundary: boundary,
                        rememberTab: true, environmentOverrides: git.set, removeEnvironment: Set(git.remove)))
                }
                if boundary == nil { NativePhoneStart.rememberFolder(request.cwd) }   // walk g: the Mac's last folder too
                return meta
            }, github: github,
            observeGitHub: { [clients] callback in await clients.githubChanges.observe(callback) },
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
    private let list: @Sendable () async throws -> [String]
    private let callback: @Sendable (String) async -> Void
    private var source: DispatchSourceFileSystemObject?
    private var reading: Task<Void, Never>?
    private var stopped = false
    private init(list: @escaping @Sendable () async throws -> [String], callback: @escaping @Sendable (String) async -> Void) { self.list = list; self.callback = callback }
    static func observe(directory: URL, list: @escaping @Sendable () async throws -> [String],
                        callback: @escaping @Sendable (String) async -> Void) async throws -> NativeRPCSubscription {
        let watch = NativeCompositionAccountDeletion(list: list, callback: callback)
        watch.known = Set(try await list())
        let descriptor = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeRPCError(code: "watch-failed", message: "The account directory could not be observed.") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak watch] in Task { @MainActor in watch?.changed() } }
        source.setCancelHandler { Darwin.close(descriptor) }
        watch.source = source; source.resume()
        return NativeRPCSubscription { await watch.stop() }
    }
    private var again = false
    /// L8 (10 Oct): the data folder changes many times a second while sessions run. Events that arrive
    /// during a read fold into ONE more read, instead of queueing a read per event (that flooded the
    /// session host's account service until it refused every other account read).
    private func changed() {
        guard reading == nil else { again = true; return }
        reading = Task { [weak self] in
            while true {
                guard let self, !self.stopped else { return }
                self.again = false
                do {
                    let ids = Set(try await self.list())
                    let removed = self.known.subtracting(ids); self.known = ids
                    for id in removed { await self.callback(id) }
                } catch { NSLog("[native account deletion] %@", error.localizedDescription) }
                if !self.again { self.reading = nil; return }
            }
        }
    }
    private func stop() async { stopped = true; source?.cancel(); source = nil; await reading?.value; reading = nil }
}
