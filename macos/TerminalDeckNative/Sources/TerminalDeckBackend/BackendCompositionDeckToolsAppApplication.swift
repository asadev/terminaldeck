import Foundation
import TerminalDeckNativeCore

/// `app.*` / `updates.*` over the native app owners (INT-A, 7 Oct 2026).
///
/// agents-area-live.ts:229-246 wires each dep to the function its channel
/// calls; the native equivalents are the same owners those channels use here:
/// settings-extra.ts (`settings:about/paths/open-path/clear-browser-data`) →
/// `BackendAppSettingsChannels` over the app's `BackendAppSettingsEnvironment`;
/// app-log-ipc.ts (`log:*`) → `BackendOSAppLog`; diagnostics.ts (`debug:*`) →
/// `BackendMacAppSetupDiagnostics` + `BackendMacAppSetupIPCMetrics`; the update
/// controller → the app target's `NativeAppUpdater`, through closures.
///
/// The app-tools factory (`BackendDeckToolsAppApplication.definitions`) has
/// already entered the running call through the gate with the source tier and
/// sentence before any of these runs; nothing here takes a caller identity.
public struct BackendCompositionDeckToolsAppApplication: BackendDeckToolsAppApplicationService, Sendable {
    /// shell.openPath for the log folder: "" on success, otherwise the problem
    /// (the same closure `NativeCompositionOS` gives `BackendOSAppLog`).
    public typealias OpenFolder = @Sendable (_ path: String) async throws -> String
    private let environment: BackendAppSettingsEnvironment
    private let log: BackendOSAppLog
    private let source: any BackendMacAppSetupDiagnosticSource
    private let metrics: BackendMacAppSetupIPCMetrics
    private let registry: NativeChannelRegistry
    private let redaction: BackendSharedRedactOptions
    private let openFolder: OpenFolder
    private let updater: BackendCompositionDeckToolsAppUpdates?

    /// - environment: the one `NativeCompositionSettings.environment(...)` the settings channels use.
    /// - diagnostics/metrics: the same source and timing observer the `debug:*` channels use.
    /// - updater: nil only for a build that genuinely has no update controller (TS `updates()` null).
    public init(environment: BackendAppSettingsEnvironment, log: BackendOSAppLog,
                diagnostics: any BackendMacAppSetupDiagnosticSource, metrics: BackendMacAppSetupIPCMetrics,
                registry: NativeChannelRegistry, redaction: BackendSharedRedactOptions,
                openFolder: @escaping OpenFolder, updater: BackendCompositionDeckToolsAppUpdates?) {
        self.environment = environment; self.log = log; self.source = diagnostics; self.metrics = metrics
        self.registry = registry; self.redaction = redaction; self.openFolder = openFolder; self.updater = updater
    }

    /// settings-extra.ts aboutInfo — `settings:about`'s own body.
    public func about() async throws -> NativeRPCValue { try await environment.about() }
    /// `brand:get`: `{ name: BRAND.name, tagline: BRAND.tagline }`.
    public func brand() async throws -> NativeRPCValue {
        BackendDeckToolsSupport.object([("name", .string(BackendSharedBrand.name)), ("tagline", .string(BackendSharedBrand.tagline))])
    }
    /// settings-extra.ts configPaths — `settings:paths`.
    public func paths() async throws -> [NativeRPCValue] { BackendAppSettingsChannels.paths(environment).elements ?? [] }
    /// app-log-ipc.ts logStatus — already redacted by the log owner.
    public func logStatus() async throws -> NativeRPCValue { await log.status() }
    /// settings-extra.ts openConfigPath — `settings:open-path`'s own body (reveal a file, open a folder).
    public func openPath(_ key: String) async throws -> NativeRPCValue {
        await BackendAppSettingsChannels.openPath(.string(key), environment: environment)
    }
    /// app-log-ipc.ts openLogFolder: make the folder, then shell.openPath; "" on success.
    public func openLogFolder() async throws -> String {
        // "openPath will report it" — a failed mkdir is not this step's answer.
        try? FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return try await openFolder(log.directory.path)
    }
    /// diagnostics.ts collectDiagnostics({ ipcMain, includeClis, logLines }) and
    /// formatDiagnostics for text — the `debug:diagnostics(-text)` bodies. Redacted by the collector.
    public func diagnostics(includeClis: Bool, logLines: Int, text: Bool) async throws -> NativeRPCValue {
        let invokes = await registry.channels(), sends = await registry.sends(), instrumented = await metrics.isInstrumented()
        let ipc = BackendMacAppSetupDiagnostics.ipcInfo(invoke: invokes, send: sends, instrumented: instrumented)
        let bundle = try await BackendMacAppSetupDiagnostics.collect(source: source, ipc: ipc, includeClis: includeClis, logLines: logLines,
            redaction: redaction, now: Date().timeIntervalSince1970 * 1000)
        return text ? .string(BackendMacAppSetupDiagnostics.format(bundle)) : bundle
    }
    /// app-log-ipc.ts recentLog — `{ file, lines }`, redacted on the way out.
    public func recentLog(_ lines: Int) async throws -> NativeRPCValue { try await log.recent(lines) }
    /// diagnostics.ts recentIpcCalls — `debug:ipc-log`.
    public func recentCalls(_ limit: Int) async throws -> [NativeRPCValue] { await metrics.recent(Double(limit)) }
    /// `log:clear`: `appLog().clear()`.
    public func clearLog() async throws { try await log.clear() }
    /// `debug:ipc-clear`: clearIpcCalls().
    public func clearCalls() async throws { await metrics.clear() }
    /// settings-extra.ts clearBrowsingData — `settings:clear-browser-data`: `{ cleared, message }`.
    public func clearBrowserData() async throws -> NativeRPCValue { await BackendAppSettingsChannels.clearBrowserData(environment) }
    public func updates() async throws -> (any BackendDeckToolsAppUpdateService)? { updater }
}

/// updates/updater.ts UpdateController (state / check / download / installNow)
/// over the app target's `NativeAppUpdater`. Each closure answers the updater's
/// own state afterwards (`rawState`), as `update:get/check/download/install` do.
public struct BackendCompositionDeckToolsAppUpdates: BackendDeckToolsAppUpdateService, Sendable {
    public typealias Step = @Sendable () async throws -> NativeRPCValue
    private let current: Step
    private let checking: @Sendable (_ automatic: Bool) async throws -> NativeRPCValue
    private let downloading: Step
    private let installing: Step
    public init(state: @escaping Step, check: @escaping @Sendable (_ automatic: Bool) async throws -> NativeRPCValue,
                download: @escaping Step, installNow: @escaping Step) {
        current = state; checking = check; downloading = download; installing = installNow
    }
    public func state() async throws -> NativeRPCValue { try await current() }
    public func check(automatic: Bool) async throws -> NativeRPCValue { try await checking(automatic) }
    public func download() async throws -> NativeRPCValue { try await downloading() }
    public func installNow() async throws -> NativeRPCValue { try await installing() }
}

/// `settings.reset` over the one settings writer (`BackendCompositionRoot.settings`,
/// settings-store.ts) and the Store's preferences, as live-surface.ts:214-274
/// reads, snapshots, writes and pushes them for the deck.
public struct BackendCompositionDeckToolsAppSettings: BackendDeckToolsAppSettingsService, Sendable {
    /// live-surface.ts `tellWindow(channel, payload)`: true only when a window was
    /// actually told. Optional in TS too: absent answers false ("not applied").
    public typealias TellWindow = @Sendable (_ channel: String, _ payload: NativeRPCValue) async -> Bool
    private let settings: BackendAppSettingsStore
    private let store: NativeStateStore
    private let tellWindow: TellWindow?

    public init(settings: BackendAppSettingsStore, store: NativeStateStore, tellWindow: TellWindow?) {
        self.settings = settings; self.store = store; self.tellWindow = tellWindow
    }
    /// A TellWindow over the registry the app window subscribes to: publish, then
    /// say whether a window is there to have received it.
    public static func registryWindow(_ registry: NativeChannelRegistry, windowOpen: @escaping @Sendable () async -> Bool) -> TellWindow {
        { channel, payload in
            do { try await registry.publish(channel, arguments: [payload]) } catch { return false }
            return await windowOpen()
        }
    }

    /// live-surface.ts readSettings: `{ settings: values, preferences }`.
    public func readSettings() async throws -> NativeRPCValue {
        let values = await settings.get()["values"], preferences = await store.getPreferences()
        return BackendDeckToolsSupport.object([("settings", values), ("preferences", preferences)])
    }
    /// live-surface.ts:231 writeSettingsSnapshot(preferences, `${BRAND.assistant} settings.write`).path.
    public func snapshotSettings() async throws -> String {
        let preferences = await store.getPreferences()
        let written = try await settings.snapshot(preferences: preferences, reason: BackendSharedBrand.assistant + " settings.write")
        guard let path = written["path"].string else { throw NativeRPCError(code: "internal", message: "The settings snapshot did not report where it was written.") }
        return path
    }
    /// live-surface.ts:233 patchStoredSettings(patch).values. A protected key is
    /// refused here too (catalogue.ts:1201), so no caller of this writer can reach one.
    public func writeSettings(_ patch: NativeRPCValue) async throws -> NativeRPCValue {
        guard let fields = patch.fields else { throw BackendDeckToolsArgs.bad("patch must be an object") }
        let blocked = fields.map(\.key).filter(BackendDeckToolsAppApplication.isProtected)
        guard blocked.isEmpty else {
            throw NativeRPCError(code: "not-permitted", message: "these settings cannot be changed through \(BackendSharedBrand.assistant): \(blocked.joined(separator: ", ")). Ask the person to change them in Settings if they want them changed.")
        }
        return try await settings.patch(patch)["values"]
    }
    /// live-surface.ts:270 applyToWindow('settings', values) → tellWindow(SETTINGS_CHANGED_CHANNEL, …).
    /// The native window's `settings:changed` listeners read the store's envelope
    /// (what `BackendAppSettingsChannels` publishes after `settings:set`), so the
    /// same `{ version, values }` shape is sent rather than bare values.
    public func applyToWindow(_ settings: NativeRPCValue) async throws -> Bool {
        guard let tellWindow else { return false }
        let envelope = NativeRPCValue.object([.init("version", .number(Double(BackendAppSettingsStore.version))), .init("values", settings)])
        return await tellWindow("settings:changed", envelope)
    }
}
