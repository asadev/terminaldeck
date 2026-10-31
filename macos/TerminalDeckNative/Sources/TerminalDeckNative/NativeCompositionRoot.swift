import AppKit
import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// App-owned composition: the one native backend graph. Every area is installed
/// before the graph is sealed and the app's pages are served.
@MainActor
final class NativeCompositionRoot {
    static let shared = NativeCompositionRoot(runtime: .application)
    /// The graph's own notes go to the app's engine.log (an `open`-launched app's
    /// stderr, where NSLog also writes, is not kept anywhere).
    nonisolated static func note(_ text: String) {
        Task { @MainActor in shared.runtime.report(text) }
    }
    private(set) var backend: BackendCompositionRoot?
    private var browser: NativeCompositionBrowser?
    private var remoteBrowserControl: BackendRemoteServeBrowserControl?
    private var hoot: BackendHootJoinAssembly.Assembled?
    private var hootMigration: RNMHootDataMigration.Launch?
    private let hootTranscriptOwnerID = "native-composition:hoot-transcripts"
    private var starting = false
    private var startupFailure: NativeRPCError?
    /// Why the first start of this run failed (shown again if a retry fails only because of leftovers).
    private var firstStartFailure: Error?
    private var assemblies: [@MainActor (BackendCompositionRoot) async throws -> Void] = []
    private var production: NativeCompositionProduction?
    /// The sessions area, for keeping sessions running with no window (NativeSVResident).
    var sessionsArea: BackendCompositionSessions? { guard let production else { return nil }; return production.sessions }
    /// Defaults are the app owners; fixtures supply an isolated Store and inert UI callbacks.
    @MainActor struct Runtime {
        var state = NativeStateService.shared
        var environment = ProcessInfo.processInfo.environment
        var home = NSHomeDirectory()
        var fullGraph = true
        var settingsBrowser: (any BackendAppSettingsBrowserData)? = NativeBrowserDataClear()
        var connect: @MainActor (BackendCompositionRoot) async throws -> Void = { try await EngineBridge.shared.configure(native: $0) }
        var disconnect: @MainActor () async -> Void = { await EngineBridge.shared.disconnectNative() }
        var appearanceReady: @MainActor () async -> Void = {}
        var window: @MainActor @Sendable () -> NSWindow? = { nil }
        var showProject: @Sendable (String) async throws -> Bool = { _ in false }
        var whereWindow: @Sendable () async throws -> NativeRPCValue = { .null }
        var stopHoot: @MainActor () async -> Void = { await NativeCompositionHootUI.shared.stop() }
        var removeTranscripts: @MainActor (String) -> Void = { NativeTranscriptBackend.shared.removeHomeScope(ownerID: $0) }
        var report: @Sendable (String) -> Void = { NSLog("[native graph] %@", $0) }
    }
    private let runtime: Runtime
    init(runtime: Runtime = Runtime()) { self.runtime = runtime }

    static func pinned(_ configuration: EngineConfiguration) -> EngineConfiguration {
        var arguments = CommandLine.arguments
        if ProcessInfo.processInfo.environment[EngineConfiguration.dataEnvironmentKey]?.hasPrefix("/") == true {
            arguments.append("--user-data-dir=" + configuration.engineDataDirectory.path)
        }
        guard let root = BackendS3FillUserData.pin(current: configuration.engineDataDirectory, arguments: arguments) else { return configuration }
        return EngineConfiguration(source: configuration.source, dataRoot: root)
    }

    /// Fixtures contribute isolated owners before startup; production uses the complete graph.
    func contribute(_ assemble: @escaping @MainActor (BackendCompositionRoot) async throws -> Void) throws {
        guard backend == nil, !starting else {
            throw NativeRPCError(code: "composition-sealed", message: "Native areas must be assembled before startup.")
        }
        assemblies.append(assemble)
    }

    func start(configuration: EngineConfiguration) async throws {
        guard !starting else { throw NativeRPCError(code: "composition-starting", message: "The native backend is already starting.") }
        if let startupFailure { throw startupFailure }
        guard case .nativeOnly = configuration.source else {
            throw NativeRPCError(code: "composition-mode", message: "The native backend runs only in the Node-free standalone app.")
        }
        if let backend {
            guard backend.dataRoot == configuration.engineDataDirectory.standardizedFileURL else {
                throw NativeRPCError(code: "composition-root-conflict", message: "The native backend already owns another data folder.")
            }
            return
        }
        starting = true; defer { starting = false }
        try await runtime.state.start(
            stateFile: configuration.engineDataDirectory.appendingPathComponent("state.json"),
            ownership: .exclusive, failurePolicy: .sourceCompatible)
        let state = try await runtime.state.authoritativeStore()
        // Check the source through the same settings actor the graph will own,
        // before moving folders or entering its backup-before-write path.
        let settings = BackendAppSettingsStore(userData: configuration.engineDataDirectory, writable: true)
        do {
            try await settings.requireSupportedHootMigrationSource()
            hootMigration = try RNMHootDataMigration(dataRoot: configuration.engineDataDirectory)
                .prepareForLaunch(report: { runtime.report("Hoot data migration: " + $0.event) })
        } catch {
            hootMigration = nil
            await runtime.state.stop()
            throw error
        }
        let graph: BackendCompositionRoot
        do {
            graph = try BackendCompositionRoot(dataRoot: configuration.engineDataDirectory, state: state,
                environment: BackendScratchAgentHomes.environment(runtime.environment, home: URL(fileURLWithPath: runtime.home)), home: runtime.home, settingsStore: settings)
        } catch {
            hootMigration = nil
            await runtime.state.stop()
            throw error
        }
        do {
            try await graph.installFoundations()
            let projection = try await graph.installSettings(environment: NativeCompositionSettings.environment(
                backend: graph, configuration: configuration, browser: runtime.settingsBrowser))
            for assemble in assemblies { try await assemble(graph) }
            if runtime.fullGraph {
                let assembled = try NativeCompositionProduction(root: graph, state: projection, engineConfiguration: configuration,
                    window: runtime.window, showProject: runtime.showProject, whereWindow: runtime.whereWindow,
                    report: runtime.report)
                production = assembled
                try await assembled.assemble()
            }
            try Task.checkCancellation()
            // The app's pages and windows reach every area through this one graph.
            try await runtime.connect(graph)
            await runtime.appearanceReady()
            try Task.checkCancellation()
            await graph.seal()
            Self.checkUsedChannels(await graph.manifest(), report: runtime.report)
            // Debugging aid for coverage checks on scratch data: the sealed route manifest.
            if ProcessInfo.processInfo.environment[NativeLaunchSwitches.dumpRoutes] == "1" {
                try? (await graph.manifest()).encodedJSON(pretty: true).write(to: graph.dataRoot.appendingPathComponent("native-routes.json"))
                let tools = try await graph.mcp.catalogue()
                try? NativeRPCValue.array(tools.map { .string($0.id) }).encodedJSON(pretty: true)
                    .write(to: graph.dataRoot.appendingPathComponent("native-tools.json"))
            }
            backend = graph; firstStartFailure = nil
            if let production { await production.afterSeal() }
        } catch {
            var failure = error
            // L8 (11 Oct): a retry used to trip over what the failed attempt had left open (the remote trust
            // lease) and reported THAT ("Another native remote host owns this trust directory") instead of
            // the reason the app could not start. If a retry still fails that way, keep saying the first reason.
            if (failure as? NativeRPCError)?.code == "trust-owner", let first = firstStartFailure { failure = first }
            else { firstStartFailure = failure }
            runtime.report("Native startup failed: " + failure.localizedDescription)
            // Everything this attempt opened is closed again, so the next start is a true retry.
            await production?.releaseAfterFailedStart()
            await production?.stop(); production = nil
            let report = runtime.report
            do { try await graph.shutdown(trace: { report("startup cleanup: " + $0) }) }
            catch {
                // A failed drain still owns processes/account leases. Keep its
                // Store open and refuse a second bootstrap until stop succeeds.
                backend = graph
                let blocked = NativeRPCError(code: "composition-stop-blocked",
                    message: "Native startup failed and its owners could not finish shutdown: " + error.localizedDescription)
                startupFailure = blocked
                await runtime.disconnect()
                throw blocked
            }
            await runtime.stopHoot(); hoot = nil; production = nil
            runtime.removeTranscripts(hootTranscriptOwnerID)
            remoteBrowserControl = nil; browser = nil
            await runtime.disconnect()
            hootMigration = nil
            await runtime.state.stop(); throw failure
        }
    }

    /// A channel a screen calls with no native handler used to fail only in the person's
    /// hand ("No native handler registered"). Name each one at launch instead, against the
    /// list generated from the screens' call sites (Scripts/used-channels.py).
    static func checkUsedChannels(_ manifest: NativeRPCValue, report: (String) -> Void = note) {
        let invokes = Set(manifest["invoke"].elements?.compactMap(\.string) ?? [])
        let sends = Set(manifest["send"].elements?.compactMap(\.string) ?? [])
        let missingInvokes = EngineBridgeUsedChannels.invokes.filter { !invokes.contains($0.channel) }
        let missingSends = EngineBridgeUsedChannels.sends.filter { !sends.contains($0.channel) }
        for use in missingInvokes { report("missing native handler for '\(use.channel)', used by \(use.files)") }
        for use in missingSends { report("missing native send handler for '\(use.channel)', used by \(use.files)") }
        report("channel check: \(EngineBridgeUsedChannels.invokes.count + EngineBridgeUsedChannels.sends.count) used channels, \(missingInvokes.count + missingSends.count) without a native handler")
    }

    /// The main page finished loading (first load or a reload): the full graph
    /// restores/re-announces sessions now that the page can hear them.
    func mainPageReady() async { await production?.pageReady() }

    /// Only an actual successful owner read can acknowledge moved archives.
    /// The migration itself, writes, scaffolds and stat results are not reads.
    func confirmHootRead(_ folders: Set<RNMHootPaths.Folder>) throws {
        guard let launch = hootMigration else {
            throw NativeRPCError(code: "hoot-migration", message: "Hoot's migration was not prepared for this launch.")
        }
        hootMigration = try RNMHootDataMigration(paths: launch.paths).confirmRead(folders, on: launch)
    }

    /// Called during assembly before launch, after the concrete browser/session
    /// caller graph and writer ownership are supplied. Never called just because
    /// a handoff file exists.
    func installBrowser(in backend: BackendCompositionRoot, dependencies: NativeCompositionBrowserDependencies,
                        screenshotDirectory: URL, downloadsDirectory: URL,
                        excludedMCPToolIDs: Set<String> = []) async throws {
        guard browser == nil else {
            throw NativeRPCError(code: "composition-state", message: "The native browser needs the retained app backend.")
        }
        try await backend.requireAssemblyOpen()
        let graph = try NativeCompositionBrowser(registry: backend.registry, mcp: backend.mcp,
            dataRoot: backend.dataRoot, screenshotDirectory: screenshotDirectory,
            downloadsDirectory: downloadsDirectory, tabs: NativeBrowserTabs.shared, dependencies: dependencies,
            excludedMCPToolIDs: excludedMCPToolIDs)
        try await graph.start()
        do {
            try await backend.retain(.init(name: "browser", domains: ["browser"], ownerID: NativeCompositionBrowser.ownerID,
                invokes: Set(graph.invokeChannels), sends: Set(graph.sendChannels), events: Set(graph.eventChannels),
                stop: { try await graph.stop() }))
            browser = graph
        } catch { try? await graph.stop(); throw error }
    }
    func browserForComposition() throws -> NativeCompositionBrowser {
        guard let browser, browser.started else { throw NativeRPCError(code: "composition-incomplete", message: "The actual Safari owner is not installed.") }
        return browser
    }

    func installHoot(in backend: BackendCompositionRoot, inputs: BackendHootJoinAssembly.Inputs) async throws -> BackendHootJoinAssembly.Assembled {
        guard hoot == nil else { throw NativeRPCError(code: "composition-conflict", message: "The app already owns Hoot's native panels.") }
        try await backend.requireHootServices(sessions: inputs.sessions, deckCore: inputs.deckCore)
        let home = BackendCopilotSessionRuntime.homeScope(userData: backend.dataRoot.path, storageDir: inputs.storageRoot.path)
        let scope = try await inputs.transcriptScope()
        NativeTranscriptBackend.shared.installHomeScope(home, ownerID: hootTranscriptOwnerID, scope: scope)
        // HOOTFIX: one copy that carries every input (readyDefaults/ownerContext
        // were dropped by the old field-by-field copy -> "awaiting integration").
        let joined = inputs.replacingTranscripts(scope: {
                let scope = try await inputs.transcriptScope()
                return await NativeTranscriptBackend.shared.includingAssembledHomes(scope)
            }, homeScopes: { await NativeTranscriptBackend.shared.configuredHomeScopes })
        do {
            let installed = try await BackendHootJoinAssembly.install(in: backend, inputs: joined,
                screenMonitor: NativeHootScreens.monitor()) { authority in
                    NativeCompositionHootUI.shared.supply(registry: backend.registry, authority: authority)
                }
            NativeCompositionHootUI.shared.bind(installed)
            do { try await installed.registration.start(); hoot = installed; return installed }
            catch { try? await installed.registration.stop(); await runtime.stopHoot(); throw error }
        } catch {
            await runtime.stopHoot()
            runtime.removeTranscripts(hootTranscriptOwnerID)
            throw error
        }
    }

    /// Select the richer Safari policy once, over the same page/binding owner.
    /// All device/session/consent callbacks come from the authoritative graph.
    func remoteBrowserFeature(machineID: String, isMine: @escaping BackendRemoteServeBrowserSafari.Mine,
                              sessions: @escaping BackendRemoteServeBrowserSafari.Sessions,
                              write: @escaping BackendRemoteServeBrowserSafari.Write,
                              startPage: @escaping BackendRemoteServeBrowserSafari.StartPage) throws -> BackendRemoteHostFeature {
        guard let browser, browser.started, remoteBrowserControl == nil else {
            throw NativeRPCError(code: "composition-incomplete", message: "Remote browser control requires the retained Safari owner and one feature supplier.")
        }
        let safari = BackendRemoteServeBrowserSafari(service: browser.service, machineID: machineID,
            isMine: isMine, sessions: sessions, write: write, startPage: startPage,
            authorize: browser.dependencies.authorizeBrowser, documentPicker: browser)
        let control = BackendRemoteServeBrowserControl(operations: safari)
        remoteBrowserControl = control
        return control.feature()
    }

    /// Node drains first in AppModel. Domain observers/children stop next; the
    /// shared Store transport is closed last so Node's final ledger save works.
    func stop() async throws {
        guard !starting else { throw NativeRPCError(code: "composition-starting", message: "Native startup is still draining; its Store must stay open.") }
        // The production graph's unretained services (remote host, lease facade) stop first;
        // backend's area cleanup then owns every retained area, the browser drain included.
        let report = runtime.report
        let trace: @Sendable (String) -> Void = { report("quit: " + $0) }
        if let production { await BackendCompositionRoot.traced("production", trace) { await production.stop() } }
        production = nil
        if let backend { try await BackendCompositionRoot.traced("backend", trace) { try await backend.shutdown(trace: trace) } }
        backend = nil
        await BackendCompositionRoot.traced("hoot window", trace) { await runtime.stopHoot() }; hoot = nil
        runtime.removeTranscripts(hootTranscriptOwnerID)
        remoteBrowserControl = nil; browser = nil
        await BackendCompositionRoot.traced("app bridge", trace) { await runtime.disconnect() }
        await BackendCompositionRoot.traced("state service", trace) { await runtime.state.stop() }
        hootMigration = nil
        startupFailure = nil
    }
}
