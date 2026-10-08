import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// The ONE session-tool lease facade: ordinary leases plus the "elsewhere"
    /// leases servers and deck-tools share (never a second endpoint owner).
    func deckToolLeases() -> BackendDeckToolsSessionsLeaseFacade {
        if let leaseFacade { return leaseFacade }
        let made = BackendDeckToolsSessionsLeaseFacade(local: sessions.sessionTools, endpoint: core.sessionEndpoint)
        leaseFacade = made; return made
    }

    /// Before the manifest is sealed: observers and engines whose owners are
    /// installed and whose Node counterparts are disabled by this same manifest.
    /// Order follows TS startup: lifecycle observers, metrics, tasks, routines, machines.
    /// index.ts:5010-5030 at start: the session `open` shim (open-shim.ts writeOpenShim) first on
    /// every session's PATH, then the app map (app-context.ts writeAppContext), which says whether
    /// `open <url>` opens in the app. Both are removed or rewritten at the next start.
    func installOpenShim() async {
        guard let sessions else { return }
        await sessions.launch.setVerbsRegistry(verbs)
        var installed: BackendMacAppHandoffShimInstalled?
        do {
            installed = try await openShim.write(dataRoot: root.dataRoot.path, configPath: sessions.hookServer.endpoint.configPath)
            sessions.manager.setOpenShim(directory: installed?.directory, browser: installed?.browser)
        } catch { report("The session `open` shim could not be written: " + error.localizedDescription) }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        let name = BackendCompositionBrowserChannels.thisMachineName()
        let paths = NativePlatformPaths.native(configuration: engineConfiguration, home: configuration.homeDirectory,
            downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0], appRoot: Bundle.main.bundleURL)
        do { _ = try await appContext.write(paths: paths, input: .init(version: version, machineName: name.isEmpty ? "A desktop" : name, opensInApp: installed != nil)) }
        catch { report("The app map for sessions could not be written: " + error.localizedDescription) }
    }

    func startAreas() async throws {
        try await files.startLifecycle(lifecycle: sessions.lifecycle, contextForSession: { [authority] _ in
            try authority!.localContext()
        })
        try await usage.startAfterOwnershipTransfer()
        if let taskRegistration { try await taskRegistration.start() }
        if let routinesOwner { try await routinesOwner.start() }
        if let machineOwner { try await machineOwner.start() }
    }

    /// After the bridge is configured and the manifest sealed: dial remote access
    /// if it was left on (TS server.ts autoStart: `remote.enabled` !== false).
    /// Saved tabs are restored when the page first connects (`pageReady`).
    func afterSeal() async {
        guard let remoteHost, state.settingsEnvelope()["values"]["remote.enabled"].bool != false else { return }
        do { _ = try await remoteHost.start() }
        catch { report("remote access did not come up at launch: " + error.localizedDescription) }
    }

    /// TS index.ts hydrateRenderer: the first page to connect restores the saved
    /// tabs (an event sent before the page listens is dropped, not queued); every
    /// later page load (a reload) is re-told every live session and the held rows.
    func pageReady() async {
        if !restoreStarted {
            restoreStarted = true
            do {
                let result = try await sessions.restoreSavedSessions()
                for decision in result.decisions where decision.outcome == .skip || decision.outcome == .failed {
                    report("restore held a " + decision.session.provider + " tab: " + decision.reason)
                }
                report("restore: \(result.started.count) started, \(result.decisions.count) planned")
            } catch { report("Saved sessions could not be restored: " + error.localizedDescription) }
        } else if let devices {
            await devices.pageGone()   // TS devices/ipc.ts: a full reload never asked for the old page's pictures
        }
        for meta in sessions.manager.list() {
            try? await root.registry.publish("session:created", arguments: [BackendCompositionSuppliers.sessionWire(meta)])
        }
        if let held = try? await root.state.heldSessions() {
            try? await root.registry.publish("sessions:held", arguments: [.array(held.map(\.wireValue))])
        }
    }

    /// Unretained services the backend's area shutdown does not own.
    func stop() async {
        linkTabWindow.stop()
        await releaseServerControlOwner(BackendCompositionRoot.appOwnerID)
        sessions?.manager.setOpenShim(directory: nil, browser: nil); try? await openShim.remove(dataRoot: root.dataRoot.path)
        let trace: @Sendable (String) -> Void = { NativeCompositionRoot.note("quit: " + $0) }
        if let remoteHost { await BackendCompositionRoot.traced("remote host", trace) { await remoteHost.stop() } }
        if let leaseFacade { await BackendCompositionRoot.traced("server leases", trace) { await leaseFacade.stop() } }
    }

    /// TS remote/server.ts: registration starts only after the host endpoint is up.
    func startRemoteRegistration() async throws {
        guard let remoteRegistration else { throw NativeRPCError(code: "composition-incomplete", message: "Remote serving is not registered.") }
        try await remoteRegistration.start()
    }
}
