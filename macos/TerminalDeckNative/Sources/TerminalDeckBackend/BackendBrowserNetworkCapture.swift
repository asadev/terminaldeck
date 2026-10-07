import Foundation
import TerminalDeckNativeCore

public struct BackendBrowserCaptureTarget: Sendable {
    public let tabID: String
    public let profileID: String
    public let pageURL: URL
    public let title: String
    public init(tabID: String, profileID: String, pageURL: URL, title: String) {
        self.tabID = tabID; self.profileID = profileID; self.pageURL = pageURL; self.title = title
    }
}

public struct BackendBrowserCaptureFinish: Sendable {
    public let pageURL: String
    public let title: String
    public let tabClosed: Bool
    public init(pageURL: String, title: String, tabClosed: Bool) { self.pageURL = pageURL; self.title = title; self.tabClosed = tabClosed }
}

public struct BackendBrowserNetworkObservation: Sendable {
    /// Stop delivery and drain all previously accepted callbacks before return.
    public let stop: @Sendable () async throws -> BackendBrowserCaptureFinish
    public let diagnostics: @Sendable () async -> NativeRPCValue
    /// Revoke observation and drain delivery WITHOUT reading final page data.
    public let retire: @Sendable () async throws -> BackendBrowserCaptureFinish
    public init(stop: @escaping @Sendable () async throws -> BackendBrowserCaptureFinish,
                retire: @escaping @Sendable () async throws -> BackendBrowserCaptureFinish,
                diagnostics: @escaping @Sendable () async -> NativeRPCValue) {
        self.stop = stop; self.retire = retire; self.diagnostics = diagnostics
    }
}

public struct BackendBrowserNetworkHooks: Sendable {
    /// Resolve the source's window/session binding; arbitrary tool tab IDs do
    /// not bypass that binding. Profile grants are checked on every resolution.
    public let target: @Sendable (BackendBrowserScrapingCaller, NativeRPCValue) async throws -> BackendBrowserCaptureTarget
    public let observe: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget,
        @escaping @Sendable (BackendBrowserNetworkResponse) async -> Void) async throws -> BackendBrowserNetworkObservation
    public let authorize: BackendBrowserScrapingAuthorize
    public init(target: @escaping @Sendable (BackendBrowserScrapingCaller, NativeRPCValue) async throws -> BackendBrowserCaptureTarget,
                observe: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget,
                    @escaping @Sendable (BackendBrowserNetworkResponse) async -> Void) async throws -> BackendBrowserNetworkObservation,
                authorize: @escaping BackendBrowserScrapingAuthorize) {
        self.target = target; self.observe = observe; self.authorize = authorize
    }
}

/// WebKit's public surface is a partial metadata observer. Never advertise a
/// CDP debugger, intercepted/fulfilled request count or complete traffic log.
public actor BackendBrowserNetworkCapture {
    public enum CleanupReason: String, Sendable { case tabClosed, profileChanged, humanTakeover, grantsRevoked, callerDisconnected, appShutdown }
    private let store: BackendBrowserScrapingStore
    private let hooks: BackendBrowserNetworkHooks
    private struct Run: Sendable {
        let generation: UUID; let capture: UUID; let owner: String; let target: BackendBrowserCaptureTarget
        let observer: BackendBrowserNetworkObservation
        var failures: Int = 0; var stopping = false
    }
    private var runs: [String: Run] = [:]
    private var starting: Set<String> = []
    public init(store: BackendBrowserScrapingStore, hooks: BackendBrowserNetworkHooks) { self.store = store; self.hooks = hooks }
    public func invoke(_ args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        let action = try args["action"].requireString("network action", nonempty: true)
        guard ["start", "status", "stop"].contains(action) else { throw BackendBrowserScrapingError.invalid("Network action is start, status or stop.") }
        let target = try await hooks.target(caller, args)
        try await hooks.authorize(caller, "browser.network." + action, target.profileID, target.pageURL, args)
        if action == "start" { return try await start(target, args: args, caller: caller) }
        guard let run = runs[target.tabID] else {
            if action == "stop" { throw NativeRPCError(code: "not-armed", message: "There is no capture armed on this bound tab.") }
            // browser-network-tool.ts status whenNone (empty-result.test.ts L516: a sentence over 40 characters).
            return .object([.init("armed", .bool(false)), .init("empty", .bool(true)), .init("emptyReason", .string("nothing is armed on this page. browser.network with action start arms it."))])
        }
        guard run.owner == caller.holder, run.target.profileID == target.profileID else {
            throw BackendBrowserScrapingError.denied("This capture is owned by another caller or profile.")
        }
        if action == "stop" { return try await stop(target.tabID, caller: caller) }
        return .object([.init("armed", .bool(true)), .init("suspended", .bool(run.stopping)), .init("rules", .object([])),
            .init("counts", .null), .init("captured", try await store.captureSnapshot(run.capture)),
            .init("observerFailures", .number(Double(run.failures))), .init("scope", .string("webkit-resource-timing")),
            .init("observer", await run.observer.diagnostics()),
            .init("requestInterception", .bool(false)), .init("allResponseBodies", .bool(false))])
    }
    private func start(_ target: BackendBrowserCaptureTarget, args: NativeRPCValue, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        try Task.checkCancellation()
        guard runs[target.tabID] == nil, !starting.contains(target.tabID) else { throw NativeRPCError(code: "already-armed", message: "This tab already has a capture or is arming one.") }
        starting.insert(target.tabID); defer { starting.remove(target.tabID) }
        let settings = try await store.config(target.profileID)
        let rules = args.has("rules") ? args["rules"] : settings["requests"]
        _ = try rules.requireObject("network rules")
        let knownKinds = Set(["image", "media", "font", "stylesheet", "script", "xhr", "fetch"])
        for field in rules.fields ?? [] where !knownKinds.contains(field.key) {
            throw BackendBrowserScrapingError.invalid("Unknown network resource kind: \(field.key).")
        }
        for field in rules.fields ?? [] where field.value.string != "allow" && !field.value.isNullish {
            throw BackendBrowserScrapingError.unsupported("WebKit cannot pause, fulfill or report counts for HTTP request rule '\(field.key)'. No interception was armed.")
        }
        let captureOn = args.has("capture") ? args["capture"].bool ?? true : settings["capture"]["on"].bool ?? true
        guard captureOn else { throw BackendBrowserScrapingError.invalid("capture:false with no supported interception rules would do nothing.") }
        let generation = UUID(), runID = args["runId"].string ?? generation.uuidString
        var limits = args["limits"]
        if limits["maxTotalBytes"].isNullish, let keep = settings["capture"]["keepMB"].number {
            limits = limits.setting("maxTotalBytes", .number(keep * 1_024 * 1_024))
        }
        let kinds = Set(args["limits"]["bodyKinds"].elements?.compactMap(\.string) ?? ["fetch", "xhr"])
        let capture = try await store.startCapture(profile: target.profileID, runID: runID, pageURL: target.pageURL.absoluteString,
            bounds: .init(limits: limits), bodyKinds: kinds, visibility: "webkit-resource-timing")
        do {
            let observer = try await hooks.observe(caller, target) { [weak self] response in
                await self?.received(response, target: target, generation: generation, capture: capture, caller: caller)
            }
            do { try Task.checkCancellation() }
            catch { _ = try? await observer.stop(); throw error }
            // The adapter may deliver callbacks before observe returns. They
            // write to the explicit capture handle, not an uninitialized run.
            runs[target.tabID] = Run(generation: generation, capture: capture, owner: caller.holder, target: target, observer: observer)
            return .object([.init("armed", .bool(true)), .init("runId", .string(runID)), .init("profileId", .string(target.profileID)),
                .init("captured", try await store.captureSnapshot(capture)), .init("rules", .object([])), .init("counts", .null),
                .init("scope", .string("webkit-resource-timing")), .init("allResponseBodies", .bool(false)),
                .init("requestInterception", .bool(false)), .init("incomplete", .bool(true)),
                .init("shortfall", .string("Metadata only. WebKit's public APIs cannot provide the complete network stream, service worker traffic or all response bodies.")),
                // browser-network-tool.ts: every start that returns armed something, so `empty` is
                // written out as false rather than left off (empty-result.test.ts L516).
                .init("empty", .bool(false)), .init("emptyReason", .string(""))])
        } catch {
            _ = try? await store.stopCapture(capture, pageURL: target.pageURL.absoluteString, title: target.title)
            throw error
        }
    }
    private func received(_ response: BackendBrowserNetworkResponse, target: BackendBrowserCaptureTarget, generation: UUID,
                          capture: UUID, caller: BackendBrowserScrapingCaller) async {
        if let run = runs[target.tabID], run.generation != generation { return }
        do {
            try Task.checkCancellation()
            try await hooks.authorize(caller, "browser.network.observe", target.profileID, response.url, .object([]))
            try await store.record(capture, response: response)
        } catch {
            await store.denyObservation(capture)
            if runs[target.tabID]?.generation == generation { runs[target.tabID]!.failures += 1 }
        }
    }
    private func stop(_ tabID: String, caller: BackendBrowserScrapingCaller) async throws -> NativeRPCValue {
        guard var run = runs[tabID], !run.stopping else { throw NativeRPCError(code: "capture-stopping", message: "This capture is already stopping.") }
        guard run.owner == caller.holder else { throw BackendBrowserScrapingError.denied("This caller does not own the capture.") }
        run.stopping = true; runs[tabID] = run
        do {
            let target = try await run.observer.stop()
            let summary = try await store.stopCapture(run.capture, pageURL: target.pageURL, title: target.title,
                termination: .object([.init("tabClosed", .bool(target.tabClosed)), .init("finalMetadataRead", .bool(!target.pageURL.isEmpty))]))
            runs[tabID] = nil
            return .object([.init("armed", .bool(false)), .init("capture", summary), .init("counts", .null),
                .init("observer", await run.observer.diagnostics()),
                .init("tabClosed", .bool(target.tabClosed)),
                .init("incomplete", summary["incomplete"]), .init("shortfall", summary["shortfall"]), .init("empty", summary["empty"]), .init("emptyReason", summary["emptyReason"])])
        } catch {
            if runs[tabID]?.generation == run.generation { runs[tabID]!.stopping = false }
            throw error
        }
    }
    public func disconnect(_ caller: BackendBrowserScrapingCaller) async {
        for (tabID, run) in runs where run.owner == caller.holder {
            _ = try? await cleanup(tabID: tabID, profileID: run.target.profileID, ownerHolder: caller.holder, reason: .callerDisconnected)
        }
    }
    /// Lifecycle-only retained-identity cleanup. Do not expose this API as an
    /// arbitrary tab-ID tool/channel or use it to acquire new page read access.
    public func cleanup(tabID: String, profileID: String, ownerHolder: String, reason: CleanupReason) async throws -> NativeRPCValue {
        guard var run = runs[tabID] else { throw NativeRPCError(code: "not-armed", message: "There is no retained capture to clean up on this tab.") }
        guard run.target.profileID == profileID, run.owner == ownerHolder else {
            throw BackendBrowserScrapingError.denied("Cleanup identity does not match the retained capture owner and profile.")
        }
        guard !run.stopping else { throw NativeRPCError(code: "capture-stopping", message: "Capture cleanup is already in progress.") }
        run.stopping = true; runs[tabID] = run
        var observerStopped = false
        do {
            let finish = try await run.observer.retire(); observerStopped = true
            let summary = try await store.stopCapture(run.capture, pageURL: "", title: "", termination: .object([
                .init("retiredBecause", .string(reason.rawValue)), .init("tabClosed", .bool(finish.tabClosed || reason == .tabClosed)),
                .init("revoked", .bool(reason == .grantsRevoked)), .init("finalMetadataRead", .bool(false))]))
            guard runs[tabID]?.generation == run.generation else { throw NativeRPCError(code: "capture-generation", message: "Capture ownership changed during cleanup.") }
            runs[tabID] = nil
            return .object([.init("armed", .bool(false)), .init("observerStopped", .bool(true)), .init("summaryWritten", .bool(true)),
                .init("capture", summary), .init("retiredBecause", .string(reason.rawValue)),
                .init("tabClosed", .bool(finish.tabClosed || reason == .tabClosed)), .init("finalMetadataRead", .bool(false)),
                .init("revoked", .bool(reason == .grantsRevoked)), .init("observer", await run.observer.diagnostics())])
        } catch {
            if runs[tabID]?.generation == run.generation { runs[tabID]!.stopping = false }
            throw NativeRPCError(code: "capture-cleanup-failed", message: error.localizedDescription,
                details: .object([.init("observerStopped", .bool(observerStopped)), .init("summaryWritten", .bool(false)),
                    .init("retainedForRetry", .bool(runs[tabID]?.generation == run.generation))]))
        }
    }
}
