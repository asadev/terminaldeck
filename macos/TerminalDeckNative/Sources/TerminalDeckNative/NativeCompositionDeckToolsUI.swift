import AppKit
import Darwin
import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// `ui.list` / `ui.do` over the main window's own dispatcher (INT-A, 7 Oct 2026).
///
/// ui-tools.ts runs `UI_LIST_CALL` / `uiDoCall(...)` in the app's own window
/// (sessions-lane.ts:144 `evaluateIn`), where `driving/ui-bridge.ts` answers
/// through App.tsx's `run` — the one dispatcher every chord, menu item and
/// palette row shares, the same `run` `AppCommandRunner`'s `menu-command`
/// reaches. Here the call goes into the main page's own world with the request
/// passed as a JavaScript VALUE (`callAsyncJavaScript` arguments): nothing the
/// caller sends is ever spliced into script text.
///
/// The listing adds what a person can also run from the native menu bar
/// (`AppCommandCatalog`): page commands the palette did not list, and the
/// menu-only actions (zoom, Report an Issue) as `menu.<title>` ids, which run
/// through `AppCommandRunner.perform` exactly as their menu items do.
/// Nil means no window: the engine page is not up, or the main window is not open.
@MainActor
enum NativeCompositionDeckToolsUI {
    static let listBody = "return " + BackendDeckToolsAppUI.listCall + ";"
    static let doBody = "return globalThis.\(BackendDeckToolsAppUI.global)?.do(request) ?? null;"

    /// The `BackendDeckToolsAppUIService` the deck tools are built with.
    nonisolated static func service() -> BackendCompositionDeckToolsAppUI {
        BackendCompositionDeckToolsAppUI(list: { try await NativeCompositionDeckToolsUI.list() },
                                         perform: { kind, target in try await NativeCompositionDeckToolsUI.perform(kind: kind, target: target) })
    }

    /// `BackendCompositionFiles.Dependencies.showProject` — sessions-lane.ts:219
    /// `showInWindow`: `uiDoCall({ kind: 'project', target })`, true only on `{ ok: true }`.
    nonisolated static func showProject() -> @Sendable (String) async throws -> Bool {
        { path in try await NativeCompositionDeckToolsUI.call(kind: "project", target: path)?["ok"].bool == true }
    }

    /// The main page, only while it is up and its window is open.
    static func mainPage() -> WKWebView? {
        let model = AppModel.shared
        guard model.canRun else { return nil }
        let view = model.web.webView
        guard let window = view.window, window.isVisible || window.isMiniaturized else { return nil }
        return view
    }

    /// ui-bridge.ts `list()`, plus the menu bar's commands the palette does not list.
    static func list() async throws -> NativeRPCValue? {
        guard let page = mainPage() else { return nil }
        let raw = try await page.callAsyncJavaScript(listBody, arguments: [:], in: nil, contentWorld: .page)
        let listing = try NativeRPCValue.fromFoundation(raw)
        // null: the window has not finished starting (ui-bridge.ts list → null).
        guard listing.fields != nil else { return nil }
        var commands = listing["commands"].elements ?? []
        var listed = Set(commands.compactMap { $0["id"].string })
        for command in [AppCommandCatalog.about] + AppCommandCatalog.all {
            let id: String
            if case .page(let pageID) = command.action { id = pageID } else { id = nativeID(command) }
            guard listed.insert(id).inserted else { continue }
            commands.append(.object([.init("id", .string(id)), .init("title", .string(command.title)), .init("group", .string("Menu"))]))
        }
        return BackendUIGMemoryDiscovery.uiListing(listing.setting("commands", .array(commands)))
    }

    /// ui-bridge.ts `do({ kind, target })`; a menu-only action runs as its menu item does.
    static func perform(kind: String, target: String) async throws -> NativeRPCValue? {
        guard kind != "run" || UIGMemoryVisibility.showsCommand(target) else {
            throw NativeRPCError(code: "unavailable", message: UIGMemoryVisibility.unavailableTitle)
        }
        if kind == "run", let command = nativeCommand(target) {
            guard mainPage() != nil else { return nil }
            AppCommandRunner.perform(command, model: AppModel.shared)
            return .object([.init("ok", .bool(true)), .init("did", .string("ran \(target)"))])
        }
        return try await call(kind: kind, target: target)
    }

    static func call(kind: String, target: String) async throws -> NativeRPCValue? {
        guard kind != "run" || UIGMemoryVisibility.showsCommand(target) else {
            throw NativeRPCError(code: "unavailable", message: UIGMemoryVisibility.unavailableTitle)
        }
        guard let page = mainPage() else { return nil }
        let raw = try await page.callAsyncJavaScript(doBody, arguments: ["request": ["kind": kind, "target": target]],
                                                     in: nil, contentWorld: .page)
        let answer = try NativeRPCValue.fromFoundation(raw)
        return answer.fields == nil ? nil : answer
    }

    /// "Zoom In" → `menu.zoom-in`: the id a menu-only action is listed and run by.
    nonisolated static func nativeID(_ command: AppMenuCommand) -> String {
        "menu." + command.title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    nonisolated static func nativeCommand(_ id: String) -> AppMenuCommand? {
        AppCommandCatalog.all.first { command in
            if case .page = command.action { return false }
            return nativeID(command) == id
        }
    }
}

/// diagnostics.ts over the native app's real owners: the one app log, the
/// provider/login-PATH owner, the session hooks, the Store, and measured
/// process/platform facts — for `app.diagnostics`/`app.log` and `debug:*`.
@MainActor
enum NativeCompositionDiagnostics {
    struct Services: Sendable {
        /// diagnostics.ts's call ring. Not instrumented until the shared native
        /// invoke path times calls through `timed` and `activate(...: true)` runs.
        let metrics: BackendMacAppSetupIPCMetrics
        /// setup.ts detection (also what `prereq:check`/`setup:status` read).
        let detection: BackendMacAppSetupNativeDetection
        let source: BackendMacAppSetupNativeDiagnosticSource
        /// redact.ts defaults: this user's home and name, plus the env's secrets at collect time.
        let redaction: BackendSharedRedactOptions
    }

    nonisolated static let pushChannel = "debug:ipc-call"

    static func make(backend: BackendCompositionRoot, sessions: BackendCompositionSessions, log: BackendOSAppLog,
                     executor: BackendDevProcessExecutor, configuration: EngineConfiguration,
                     environment: [String: String], home: String) -> Services {
        let redaction = BackendSharedRedactOptions(home: home, username: NSUserName())
        let metrics = BackendMacAppSetupIPCMetrics(now: { Date().timeIntervalSince1970 * 1000 },
            monotonic: { ProcessInfo.processInfo.systemUptime * 1000 }, redaction: redaction,
            // diagnostics.ts timed(): `logger.error('ipc', `${channel} failed`, message)`.
            logFailure: { channel, message in _ = await log.write(level: "error", scope: "ipc", message: "\(channel) failed", data: .string(message)) })
        let copilot = BackendCopilotServiceDetector(environment: environment, home: home)
        let probe = BackendAppSessionToolProbe(environment: environment, home: home)
        let server = sessions.hookServer
        let detection = BackendMacAppSetupNativeDetection(providers: backend.providers, executor: executor, hooks: sessions.hookInstallation,
            environment: environment, home: home,
            copilot: { path in await copilot.detect(path: path).wireValue },
            lookupProbe: { name, path in await probe.probe(name, path: path).wireValue },
            // Only the socket path crosses to Setup output; never the per-run token.
            endpoint: {
                let status = server.status()
                return status["running"].bool == true ? .object([.init("socketPath", status["socketPath"])]) : nil
            })
        // diagnostics.ts aboutInfo(): this build's version/arch/packaged; a bundled
        // Node engine reports its own version, every other runtime is "n/a".
        let bundle = Bundle.main
        var runtimeVersions: [String: String] = [:]
        let about = BackendMacAppSetupDiagnostics.aboutInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            arch: NativeCompositionSettings.architecture, packaged: bundle.bundleURL.pathExtension == "app",
            runtimeVersions: runtimeVersions)
        let launchedAt = NSRunningApplication.current.launchDate ?? Date()
        // diagnostics.ts paths: userData, logs, state, temp, home, appPath, exe.
        let paths = NativeRPCValue.object([
            .init("userData", .string(backend.dataRoot.path)), .init("logs", .string(log.directory.path)),
            .init("state", .string(backend.dataRoot.appendingPathComponent("state.json").path)),
            .init("temp", .string(NSTemporaryDirectory())), .init("home", .string(home)),
            .init("appPath", .string(bundle.bundlePath)), .init("exe", .string(bundle.executablePath ?? "")),
        ])
        let source = BackendMacAppSetupNativeDiagnosticSource(providers: backend.providers, log: log, state: backend.state,
            detection: detection, environment: environment, about: { about },
            runtime: { NativeCompositionDiagnostics.runtime(launchedAt: launchedAt) }, paths: { paths })
        return Services(metrics: metrics, detection: detection, source: source, redaction: redaction)
    }

    /// diagnostics.ts registerDiagnosticsIpc: debug:about, debug:diagnostics(-text),
    /// debug:ipc-log, debug:ipc-clear, debug:subscribe, debug:unsubscribe, pushing
    /// `debug:ipc-call` to the subscribed window. The app's own window only.
    static func install(backend: BackendCompositionRoot, services: Services) async throws {
        try await backend.requireAssemblyOpen()
        let owner = "native-composition:diagnostics", registry = backend.registry, metrics = services.metrics
        do {
            try await BackendMacAppSetupDiagnosticsChannels.register(registry: registry, metrics: metrics, source: services.source,
                ownerID: owner, authorize: BackendCompositionRoot.requireLocalUI, redaction: services.redaction,
                now: { Date().timeIntervalSince1970 * 1000 },
                subscriber: { context in NativeCompositionDiagnosticsSubscriber(registry: registry, ownerID: context.ownerID) })
            try await backend.retain(.init(name: "diagnostics", domains: ["diagnostics"], ownerID: owner,
                invokes: BackendMacAppSetupDiagnostics.channels, events: [pushChannel],
                stop: { await metrics.unsubscribe(BackendCompositionRoot.appOwnerID) }))
        } catch { await registry.removeOwner(owner); throw error }
    }

    /// diagnostics.ts timed(): one record per call, never changing its outcome.
    /// For the shared native invoke path (EngineBridge's native route).
    nonisolated static func timed(_ metrics: BackendMacAppSetupIPCMetrics, channel: String, kind: String = "invoke",
                                  _ body: () async throws -> NativeRPCValue) async throws -> NativeRPCValue {
        let started = await metrics.started(channel)
        do {
            let value = try await body()
            await metrics.finish(channel, kind: kind, started: started)
            return value
        } catch {
            await metrics.finish(channel, kind: kind, started: started, error: error)
            throw error
        }
    }

    /// locale, uptimeSeconds and system os/release/arch/memory — measured, as diagnostics.ts reads them.
    nonisolated static func runtime(launchedAt: Date) -> NativeRPCValue {
        func mb(_ bytes: Double) -> NativeRPCValue { .number((bytes / (1024 * 1024)).rounded()) }
        let system = NativeRPCValue.object([
            .init("os", .string("Darwin")), .init("release", .string(kernelRelease())),
            .init("arch", .string(NativeCompositionSettings.architecture)),
            .init("memoryTotalMb", mb(Double(ProcessInfo.processInfo.physicalMemory))),
            .init("memoryFreeMb", mb(freeMemory())), .init("processRssMb", mb(residentBytes())),
        ])
        return .object([.init("locale", .string(Locale.preferredLanguages.first ?? "unknown")),
                        .init("uptimeSeconds", .number(max(0, Date().timeIntervalSince(launchedAt)).rounded())),
                        .init("system", system)])
    }
    /// os.release(): the kernel release.
    nonisolated static func kernelRelease() -> String {
        var size = 0
        guard sysctlbyname("kern.osrelease", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osrelease", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    /// os.freemem() on macOS (libuv): free pages × page size.
    nonisolated static func freeMemory() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(stats.free_count) * Double(sysconf(_SC_PAGESIZE))
    }
    /// process.memoryUsage().rss: this process's resident size.
    nonisolated static func residentBytes() -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Double(info.pti_resident_size)
    }
}

/// diagnostics.ts's subscriber: the window that asked, pushed on `debug:ipc-call`
/// with the registry's owner filter, so no other listener receives the records.
struct NativeCompositionDiagnosticsSubscriber: BackendMacAppSetupDiagnosticSubscriber {
    let registry: NativeChannelRegistry
    let ownerID: String
    func destroyed() async throws -> Bool { false }
    func send(_ record: NativeRPCValue) async throws {
        try await registry.publish(NativeCompositionDiagnostics.pushChannel, arguments: [record], ownerID: ownerID)
    }
    /// The app's own window lives as long as the registry; a closed registry
    /// fails `send`, and the metrics owner then drops this subscriber.
    func observeDestroyed(_ callback: @escaping @Sendable () async -> Void) async throws -> @Sendable () async throws -> Void { {} }
}
