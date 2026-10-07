import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Installed only on an explicitly supplied browser WKWebView. Never touches
/// the shell page, a global browser, system Safari, cookies or private APIs.
/// Isolated-world resource timing is intentionally partial metadata, not CDP.
@MainActor
final class NativeSafariCaptureBridge: NSObject, WKScriptMessageHandler {
    typealias FrameAuthorize = @Sendable (BackendBrowserScrapingCaller, String, URL, URL) async throws -> Void
    /// Runtime must verify the human/agent baton and mask password/token fields
    /// and entire unreadable child frames. A raw WK snapshot is never a fallback.
    typealias SafeSnapshot = @Sendable (BackendBrowserScrapingCaller, String, String) async throws -> Data
    private weak var webView: WKWebView?
    let tabID: String
    let profileID: String
    private let world: WKContentWorld
    private let handlerName: String
    private let authorize: FrameAuthorize
    private let safeSnapshot: SafeSnapshot
    private var installed = false
    private var listening = false
    private var stopping = false
    private var caller: BackendBrowserScrapingCaller?
    private var sink: (@Sendable (BackendBrowserNetworkResponse) async -> Void)?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var frames: [String: WKFrameInfo] = [:]
    private var received = 0
    private var dropped = 0
    private var excluded = 0
    init(webView: WKWebView, tabID: String, profileID: String, authorize: @escaping FrameAuthorize,
         safeSnapshot: @escaping SafeSnapshot) {
        self.webView = webView; self.tabID = tabID; self.profileID = profileID; self.authorize = authorize; self.safeSnapshot = safeSnapshot
        handlerName = "td_native_resource_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        world = .world(name: "td.native.resource-observer." + tabID)
        super.init()
        // Deliberately inert; attach/start is an explicit authorized operation.
    }
    func start(caller: BackendBrowserScrapingCaller, target: BackendBrowserCaptureTarget,
               sink: @escaping @Sendable (BackendBrowserNetworkResponse) async -> Void) async throws -> BackendBrowserNetworkObservation {
        try Task.checkCancellation()
        guard target.tabID == tabID, target.profileID == profileID, let view = webView else {
            throw NativeRPCError(code: "capture-target", message: "The capture target is not this live WebKit profile/tab.")
        }
        guard !listening, !stopping else { throw NativeRPCError(code: "capture-active", message: "This WebKit observer is already active.") }
        try await authorize(caller, profileID, target.pageURL, target.pageURL)
        let controller = view.configuration.userContentController
        controller.add(self, contentWorld: world, name: handlerName)
        self.caller = caller; self.sink = sink; listening = true; received = 0; dropped = 0; excluded = 0
        if !installed {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
            installed = true
        }
        do {
            _ = try await evaluate(script, frame: nil)
            // Existing known subframes can be restarted without crossing their
            // origin. Unknown already-loaded subframes remain an explicit gap.
            for frame in frames.values {
                let origin = try Self.origin(frame.securityOrigin)
                try await authorize(caller, profileID, origin, origin)
                _ = try? await evaluate(script, frame: frame)
            }
            try Task.checkCancellation()
        } catch {
            listening = false; self.caller = nil; self.sink = nil
            controller.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
            throw error
        }
        return BackendBrowserNetworkObservation(stop: { [weak self] in
            guard let self else { throw NativeRPCError(code: "capture-tab-closed", message: "This capture tab was closed.") }
            return try await self.stop()
        }, retire: { [weak self] in
            guard let self else { throw NativeRPCError(code: "capture-observer-lost", message: "The capture observer was released before its delivery drain could be confirmed.") }
            return try await self.stop(includeMetadata: false)
        }, diagnostics: { [weak self] in await self?.diagnostics() ?? .null })
    }
    private func diagnostics() -> NativeRPCValue {
        .object([.init("received", .number(Double(received))), .init("dropped", .number(Double(dropped))), .init("excludedByGrants", .number(Double(excluded))),
            .init("frameCoverage", .string("current main frame, previously observed live frames and future frame loads")),
            .init("visibility", .string("resource timing metadata only; service workers, failed/unfinished requests and response bodies may be absent")),
            .init("allTraffic", .bool(false))])
    }
    func stop(includeMetadata: Bool = true) async throws -> BackendBrowserCaptureFinish {
        guard let view = webView else {
            // Drain even if the native page closed; the stored target is still
            // a profile identity, but no final URL can be asserted.
            stopping = true; listening = false
            let tasks = Array(pending.values); for task in tasks { await task.value }
            stopping = false; sink = nil; caller = nil
            return .init(pageURL: "", title: "", tabClosed: true)
        }
        stopping = true
        // Disconnect JS first, accept its last callbacks, then remove the
        // handler and await each delivery. This makes stop a real drain barrier.
        _ = try? await evaluate("window[\(quoted(handlerName))]?.stop?.()", frame: nil)
        for frame in frames.values { _ = try? await evaluate("window[\(quoted(handlerName))]?.stop?.()", frame: frame) }
        listening = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        let tasks = Array(pending.values); for task in tasks { await task.value }
        let finalCaller = caller
        stopping = false; sink = nil; caller = nil
        guard includeMetadata, let finalCaller, let url = view.url else { return .init(pageURL: "", title: "", tabClosed: false) }
        do { try await authorize(finalCaller, profileID, url, url) }
        catch { return .init(pageURL: "", title: "", tabClosed: false) }
        return .init(pageURL: url.absoluteString, title: view.title ?? "", tabClosed: false)
    }
    /// Called by the runtime's real navigation delegate after finish/failure.
    /// This object never steals or replaces that delegate.
    func recordBlock(caller: BackendBrowserScrapingCaller, store: BackendBrowserScrapingStore,
                     requestedURL: URL, httpStatus: Int?, failure: NativeRPCValue = .null) async throws -> NativeRPCValue? {
        guard let view = webView, let pageURL = view.url else { throw NativeRPCError(code: "capture-tab-closed", message: "The block page is no longer available.") }
        guard try await store.blockCapture(profileID) else { return nil }
        try await authorize(caller, profileID, pageURL, pageURL)
        let raw = try await evaluate("(() => { const t = document.body?.innerText || ''; return {title: document.title.slice(0,512), text:t.slice(0,16384), textLength:t.length} })()", frame: nil)
        var evidence = raw.setting("requestedUrl", .string(requestedURL.absoluteString)).setting("finalUrl", .string(pageURL.absoluteString))
        evidence = evidence.setting("httpStatus", .number(Double(httpStatus ?? 0))).setting("httpStatusMeasured", .bool(httpStatus != nil))
            .setting("failed", failure).setting("statusText", .string(""))
        guard BackendBrowserScrapingStore.blockVerdict(evidence) != nil else { return nil }
        // Consent may have changed during DOM evaluation.
        try await authorize(caller, profileID, pageURL, pageURL)
        var png: Data?, note = ""
        do {
            png = try await safeSnapshot(caller, tabID, profileID)
            if png?.isEmpty != false { png = nil; note = "The privacy-safe runtime snapshot produced no PNG bytes." }
        } catch { note = error.localizedDescription }
        try await authorize(caller, profileID, pageURL, pageURL)
        return try await store.recordBlock(profile: profileID, evidence: evidence, png: png, note: note)
    }
    func detach() async {
        if listening { _ = try? await stop(includeMetadata: false) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        // Do not removeAllUserScripts: those belong to the DOM/runtime lanes.
        // The one installed script becomes inert when its handler is absent.
        webView = nil; frames.removeAll()
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard listening, message.name == handlerName, let caller, let sink,
              let body = message.body as? [String: Any], let documentID = body["documentID"] as? String,
              documentID.count <= 100, let rows = body["entries"] as? [[String: Any]], rows.count <= 200,
              let frameOrigin = try? Self.origin(message.frameInfo.securityOrigin) else { return }
        if frames.count < 128 { frames[documentID] = message.frameInfo }
        if let lost = body["dropped"] as? Int, lost > 0 { dropped += min(lost, 100_000) }
        for row in rows {
            guard pending.count < 256 else { dropped += 1; continue }
            guard let text = row["url"] as? String, text.utf8.count <= 16_384, let url = URL(string: text),
                  ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil else { continue }
            let initiator = row["initiator"] as? String ?? "other"
            let kind = ["img": "image", "css": "stylesheet", "link": "stylesheet", "script": "script", "xmlhttprequest": "xhr", "fetch": "fetch", "video": "media", "audio": "media"][initiator] ?? "other"
            let status = (row["status"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let bytes = (row["bytes"] as? Int).flatMap { $0 > 0 ? $0 : nil }
            let response = BackendBrowserNetworkResponse(url: url, kind: kind, status: status, bytes: bytes,
                bodyFailure: "An isolated WebKit resource timing observer cannot read HTTP response bodies.", source: "webkit-resource-timing")
            let id = UUID(); received += 1
            let task = Task { [weak self] in
                do {
                    guard let self else { return }
                    try Task.checkCancellation()
                    try await self.authorize(caller, self.profileID, frameOrigin, url)
                    await sink(response)
                } catch { self?.excluded += 1 }
                self?.pending[id] = nil
            }
            pending[id] = task
        }
    }
    private static func origin(_ origin: WKSecurityOrigin) throws -> URL {
        var components = URLComponents(); components.scheme = origin.protocol; components.host = origin.host
        if origin.port > 0 { components.port = origin.port }
        guard ["http", "https"].contains(components.scheme ?? ""), let url = components.url else {
            throw NativeRPCError(code: "capture-origin", message: "Only an exact HTTP(S) frame origin may report capture metadata.")
        }
        return url
    }
    private func evaluate(_ script: String, frame: WKFrameInfo?) async throws -> NativeRPCValue {
        guard let view = webView else { throw NativeRPCError(code: "capture-tab-closed", message: "The capture tab closed.") }
        return try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: frame, in: world) { result in
                switch result {
                case .success(let value):
                    do { continuation.resume(returning: try NativeRPCValue.fromFoundation(value)) }
                    catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func quoted(_ string: String) -> String { NativeRPCValue.string(string).compact }
    private var script: String {
        """
        (() => {
          const key = \(quoted(handlerName));
          if (!window.webkit?.messageHandlers?.[key]) return null;
          window[key]?.stop?.();
          const documentID = Date.now().toString(36) + Math.random().toString(36).slice(2);
          let active = true, lost = 0, scheduled = false, pending = [];
          const send = () => {
            scheduled = false;
            if (!active) return;
            const entries = pending.splice(0, 200), dropped = lost; lost = 0;
            try { window.webkit.messageHandlers[key].postMessage({documentID, entries, dropped}); }
            catch (_) { active = false; observer?.disconnect(); pending = []; }
            if (pending.length && active) { scheduled = true; queueMicrotask(send); }
          };
          const collect = list => {
            for (const item of list) {
              if (pending.length >= 5000) { lost++; continue; }
              pending.push({url: item.name, initiator: item.initiatorType || 'other',
                bytes: item.decodedBodySize > 0 ? item.decodedBodySize : null,
                status: item.responseStatus > 0 ? item.responseStatus : null});
            }
            if (!scheduled) { scheduled = true; queueMicrotask(send); }
          };
          let observer;
          const stop = () => { if (!active) return; do { send(); } while (pending.length && active); active = false; observer?.disconnect(); pending = []; };
          window[key] = {stop};
          if (typeof PerformanceObserver !== 'function') { stop(); throw new Error('Resource timing observer is unavailable'); }
          observer = new PerformanceObserver(list => collect(list.getEntries()));
          observer.observe({type:'resource', buffered:false});
          send();
          return {metadataOnly:true};
        })()
        """
    }
}
