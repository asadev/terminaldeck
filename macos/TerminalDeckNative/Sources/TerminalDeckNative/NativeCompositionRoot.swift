import AppKit
import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// App-owned composition, distinct from the Node child and helper. A completed
/// domain is installed before its route manifest is handed to the child.
@MainActor
final class NativeCompositionRoot {
    static let shared = NativeCompositionRoot()
    /// The graph's own notes go to the app's engine.log (an `open`-launched app's
    /// stderr, where NSLog also writes, is not kept anywhere).
    nonisolated static func note(_ text: String) {
        NSLog("[native graph] %@", text)
        Task { @MainActor in AppModel.shared.engine.log.note("graph: " + text) }
    }
    private(set) var backend: BackendCompositionRoot?
    private var browser: NativeCompositionBrowser?
    private var remoteBrowserControl: BackendRemoteServeBrowserControl?
    private var hoot: BackendHootJoinAssembly.Assembled?
    private let hootTranscriptOwnerID = "native-composition:hoot-transcripts"
    private var starting = false
    private var startupFailure: NativeRPCError?
    private var assemblies: [@MainActor (BackendCompositionRoot) async throws -> Void] = []
    private var hootAssembly: (@MainActor (BackendCompositionRoot) async throws -> (inputs: BackendHootJoinAssembly.Inputs, oldOwnerDisabled: Bool))?
    private var production: NativeCompositionProduction?
    /// The sessions area, for keeping sessions running with no window (NativeSVResident).
    var sessionsArea: BackendCompositionSessions? { guard let production else { return nil }; return production.sessions }
    private init() {}

    /// The full native graph is the app (NIGHT-PLAN D14): every backend owner is
    /// native. `TD_NATIVE_GRAPH=off` (or the bundle key `TDNativeGraph` = "off")
    /// remains only as a debugging off-switch.
    static var fullGraphSelected: Bool {
        if let asked = ProcessInfo.processInfo.environment["TD_NATIVE_GRAPH"] { return asked != "off" }
        return Bundle.main.object(forInfoDictionaryKey: "TDNativeGraph") as? String != "off"
    }
    static func pinned(_ configuration: EngineConfiguration) -> EngineConfiguration {
        var arguments = CommandLine.arguments
        if ProcessInfo.processInfo.environment[EngineConfiguration.dataEnvironmentKey]?.hasPrefix("/") == true {
            arguments.append("--user-data-dir=" + configuration.engineDataDirectory.path)
        }
        guard let root = BackendS3FillUserData.pin(current: configuration.engineDataDirectory, arguments: arguments) else { return configuration }
        return EngineConfiguration(source: configuration.source, dataRoot: root)
    }

    func contribute(_ assemble: @escaping @MainActor (BackendCompositionRoot) async throws -> Void) throws {
        guard backend == nil, !starting else {
            throw NativeRPCError(code: "composition-sealed", message: "Native areas must be assembled before the transitional engine launches.")
        }
        assemblies.append(assemble)
    }

    /// Hoot runs after the ordinary contributions have installed the one
    /// session and deck-core owners, before the bridge manifest is sealed.
    /// The transfer owner supplies real inputs and its Node relinquishment.
    func contributeHoot(_ prepare: @escaping @MainActor (BackendCompositionRoot) async throws -> (inputs: BackendHootJoinAssembly.Inputs, oldOwnerDisabled: Bool)) throws {
        guard backend == nil, !starting, hootAssembly == nil else {
            throw NativeRPCError(code: "composition-sealed", message: "Hoot's startup contribution must be supplied once before native assembly.")
        }
        hootAssembly = prepare
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
        try await NativeStateService.shared.start(
            stateFile: configuration.engineDataDirectory.appendingPathComponent("state.json"),
            ownership: .exclusive, failurePolicy: .sourceCompatible)
        let state = try await NativeStateService.shared.authoritativeStore()
        let graph = try BackendCompositionRoot(dataRoot: configuration.engineDataDirectory, state: state,
            environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        do {
            try await graph.installFoundations()
            let projection = try await graph.installSettings(environment: NativeCompositionSettings.environment(
                backend: graph, configuration: configuration), oldSettingsOwnerDisabled: true)
            for assemble in assemblies { try await assemble(graph) }
            if Self.fullGraphSelected {
                let assembled = try NativeCompositionProduction(root: graph, state: projection, engineConfiguration: configuration,
                    window: { NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) },
                    report: Self.note)
                production = assembled
                try await assembled.assemble()
            }
            if let hootAssembly {
                let prepared = try await hootAssembly(graph)
                try Task.checkCancellation()
                _ = try await installHoot(in: graph, inputs: prepared.inputs,
                    oldHootOwnerDisabled: prepared.oldOwnerDisabled)
            }
            try Task.checkCancellation()
            // The app's pages and windows reach every area through this one graph.
            try await EngineBridge.shared.configure(native: graph)
            try Task.checkCancellation()
            await graph.seal()
            // Debugging aid for coverage checks on scratch data: the sealed route manifest.
            if ProcessInfo.processInfo.environment["TD_NATIVE_DUMP_ROUTES"] == "1" {
                try? (await graph.manifest()).encodedJSON(pretty: true).write(to: graph.dataRoot.appendingPathComponent("native-routes.json"))
            }
            backend = graph
            if let production { await production.afterSeal() }
        } catch {
            let failure = error
            await production?.stop(); production = nil
            do { try await graph.shutdown() }
            catch {
                // A failed drain still owns processes/account leases. Keep its
                // Store open and refuse a second bootstrap until stop succeeds.
                backend = graph
                let blocked = NativeRPCError(code: "composition-stop-blocked",
                    message: "Native startup failed and its owners could not finish shutdown: " + error.localizedDescription)
                startupFailure = blocked
                await EngineBridge.shared.disconnectNative()
                throw blocked
            }
            await NativeCompositionHootUI.shared.stop(); hoot = nil; production = nil
            NativeTranscriptBackend.shared.removeHomeScope(ownerID: hootTranscriptOwnerID)
            remoteBrowserControl = nil; browser = nil
            await EngineBridge.shared.disconnectNative()
            await NativeStateService.shared.stop(); throw failure
        }
    }

    /// The main page finished loading (first load or a reload): the full graph
    /// restores/re-announces sessions now that the page can hear them.
    func mainPageReady() async { await production?.pageReady() }

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

    func installHoot(in backend: BackendCompositionRoot, inputs: BackendHootJoinAssembly.Inputs,
                     oldHootOwnerDisabled: Bool) async throws -> BackendHootJoinAssembly.Assembled {
        guard hoot == nil else { throw NativeRPCError(code: "composition-conflict", message: "The app already owns Hoot's native panels.") }
        try await backend.requireHootServices(sessions: inputs.sessions, deckCore: inputs.deckCore)
        guard oldHootOwnerDisabled else { throw NativeRPCError(code: "ownership-required", message: "Hoot's Node owner must relinquish its readers before native startup.") }
        let home = BackendCopilotSessionRuntime.homeScope(userData: backend.dataRoot.path, storageDir: inputs.storageRoot.path)
        let scope = try await inputs.transcriptScope()
        NativeTranscriptBackend.shared.installHomeScope(home, ownerID: hootTranscriptOwnerID, scope: scope)
        let joined = BackendHootJoinAssembly.Inputs(storageRoot: inputs.storageRoot, sessions: inputs.sessions,
            deckCore: inputs.deckCore, confinement: inputs.confinement, machineID: inputs.machineID,
            pickFolder: inputs.pickFolder, transcriptScope: {
                let scope = try await inputs.transcriptScope()
                return await NativeTranscriptBackend.shared.includingAssembledHomes(scope)
            }, reveal: inputs.reveal, window: inputs.window,
            transcriptHomeScopes: { await NativeTranscriptBackend.shared.configuredHomeScopes },
            stopPhoneRuns: inputs.stopPhoneRuns)
        do {
            let installed = try await BackendHootJoinAssembly.install(in: backend, inputs: joined,
                oldHootOwnerDisabled: oldHootOwnerDisabled) { authority in
                    NativeCompositionHootUI.shared.supply(registry: backend.registry, authority: authority)
                }
            NativeCompositionHootUI.shared.bind(installed)
            do { try await installed.registration.start(); hoot = installed; return installed }
            catch { try? await installed.registration.stop(); await NativeCompositionHootUI.shared.stop(); throw error }
        } catch {
            await NativeCompositionHootUI.shared.stop()
            NativeTranscriptBackend.shared.removeHomeScope(ownerID: hootTranscriptOwnerID)
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
        let trace: @Sendable (String) -> Void = { Self.note("quit: " + $0) }
        if let production { await BackendCompositionRoot.traced("production", trace) { await production.stop() } }
        production = nil
        if let backend { try await BackendCompositionRoot.traced("backend", trace) { try await backend.shutdown(trace: trace) } }
        backend = nil
        await BackendCompositionRoot.traced("hoot window", trace) { await NativeCompositionHootUI.shared.stop() }; hoot = nil
        NativeTranscriptBackend.shared.removeHomeScope(ownerID: hootTranscriptOwnerID)
        remoteBrowserControl = nil; browser = nil
        await BackendCompositionRoot.traced("app bridge", trace) { await EngineBridge.shared.disconnectNative() }
        await BackendCompositionRoot.traced("state service", trace) { await NativeStateService.shared.stop() }
        startupFailure = nil
    }
}
