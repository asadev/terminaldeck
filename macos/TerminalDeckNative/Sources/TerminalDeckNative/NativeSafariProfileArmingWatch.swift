import AppKit
import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The runtime supplies privacy-proved PNG pixels, using its real baton,
/// password/token scan and child-frame mask. No raw WK snapshot fallback exists.
struct NativeSafariProfileArmingWatchPixels: Sendable {
    let png: Data
    let privacy: BackendWebKitProfileArmingWatchFrame.Privacy
    let prompt: String
}

/// Public WebKit event adapter. It installs a private world only on the supplied
/// guest page, coalesces DOM invalidations with animation-frame events and owns
/// no display-link/timer/polling loop. This is not continuous video capture.
@MainActor
final class NativeSafariProfileArmingWatchBridge: NSObject, WKScriptMessageHandler {
    typealias SafePixels = @Sendable (BackendBrowserScrapingCaller, String, String, Bool) async throws -> NativeSafariProfileArmingWatchPixels
    private weak var webView: WKWebView?
    private let tabID: String
    private let profileID: String
    private let authorize: BackendBrowserScrapingAuthorize
    private let safePixels: SafePixels
    private let invalidated: @Sendable () async -> Void
    private let world: WKContentWorld
    private let handler = "td_watch_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var started = false
    private var installed = false
    private var pending: Task<Void, Never>?
    init(webView: WKWebView, tabID: String, profileID: String, authorize: @escaping BackendBrowserScrapingAuthorize,
         safePixels: @escaping SafePixels, invalidated: @escaping @Sendable () async -> Void) {
        self.webView = webView; self.tabID = tabID; self.profileID = profileID
        self.authorize = authorize; self.safePixels = safePixels; self.invalidated = invalidated
        world = .world(name: "td.native.watch." + tabID)
        super.init()
    }
    /// Start when the first permitted watcher attaches; stop at the last one.
    func start(caller: BackendBrowserScrapingCaller, target: BackendBrowserCaptureTarget) async throws {
        guard !started else { return }
        try await check(caller, target)
        guard let view = webView else { throw closed() }
        view.configuration.userContentController.add(self, contentWorld: world, name: handler)
        started = true
        if !installed {
            view.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
            installed = true
        }
        do { _ = try await evaluate(script); try await check(caller, target) }
        catch { await stop(); throw error }
    }
    func stop() async {
        started = false
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: handler, contentWorld: world)
        pending?.cancel(); pending = nil
        // The installed script sees no handler on subsequent documents and is
        // inert. removeAllUserScripts would destroy the other native lanes.
        // No evaluate call during teardown: an expired watch grant may not read
        // or execute on the page. The JS observer stops on its next event when
        // the absent handler rejects delivery, and never sends pixels itself.
    }
    func detach() async { await stop(); webView = nil }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard started, message.name == handler, message.frameInfo.isMainFrame, webView != nil else { return }
        if pending != nil { return }
        pending = Task { [weak self] in
            guard let self else { return }
            await invalidated(); pending = nil
        }
    }
    func snapshot(caller: BackendBrowserScrapingCaller, target: BackendBrowserCaptureTarget, ownDevice: Bool,
                  maxWidth: Int, quality: Int) async throws -> BackendWebKitProfileArmingWatchFrame {
        try await check(caller, target)
        let before = try await geometry()
        let pixels = try await safePixels(caller, tabID, profileID, ownDevice)
        try await check(caller, target)
        let after = try await geometry()
        guard before == after else { throw NativeRPCError(code: "watch-view-changed", message: "The page moved while its privacy-safe snapshot was being measured. Wait for the next page event.") }
        let width = max(1, Int(before["width"].number ?? 0)), height = max(1, Int(before["height"].number ?? 0))
        if pixels.privacy == .masked {
            return try .init(jpeg: Data(), width: width, height: height, viewportWidth: Double(width), viewportHeight: Double(height),
                pageScale: before["pageScale"].number ?? 1, scrollX: before["scrollX"].number ?? 0, scrollY: before["scrollY"].number ?? 0,
                privacy: .masked, prompt: pixels.prompt)
        }
        guard pixels.privacy != .owner || ownDevice, !pixels.png.isEmpty, pixels.png.count <= 64 * 1024 * 1024,
              let source = NSBitmapImageRep(data: pixels.png), source.pixelsWide > 0, source.pixelsHigh > 0,
              source.pixelsWide <= 16_384, source.pixelsHigh <= 16_384 else {
            throw NativeRPCError(code: "watch-privacy", message: "The runtime supplied no bounded privacy-proved image for this watcher.")
        }
        let ratio = min(1, Double(min(1920, max(64, maxWidth))) / Double(source.pixelsWide))
        var imageWidth = max(1, Int((Double(source.pixelsWide) * ratio).rounded()))
        var imageHeight = max(1, Int((Double(source.pixelsHigh) * ratio).rounded()))
        var requestedQuality = min(100, max(1, quality))
        // Bounded native compression is a frame-size adaptation, not a request
        // retry or poll. A large frame never enters the remote socket buffer.
        for _ in 0..<18 {
            try Task.checkCancellation()
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: imageWidth, pixelsHigh: imageHeight,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NativeRPCError(code: "watch-encode", message: "The native JPEG buffer could not be made.")
            }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            graphics.imageInterpolation = .high
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)).fill()
            let image = NSImage(size: NSSize(width: CGFloat(source.pixelsWide), height: CGFloat(source.pixelsHigh))); image.addRepresentation(source)
            image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight)), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: Double(requestedQuality) / 100]), jpeg.count <= 67 * 1024 {
                return try .init(jpeg: jpeg, width: imageWidth, height: imageHeight, viewportWidth: Double(width), viewportHeight: Double(height),
                    pageScale: before["pageScale"].number ?? 1, scrollX: before["scrollX"].number ?? 0, scrollY: before["scrollY"].number ?? 0,
                    privacy: pixels.privacy, prompt: pixels.prompt)
            }
            if requestedQuality > 1 { requestedQuality = max(1, requestedQuality - 10) }
            else { imageWidth = max(1, imageWidth / 2); imageHeight = max(1, imageHeight / 2) }
        }
        throw NativeRPCError(code: "watch-too-large", message: "The privacy-safe snapshot could not fit the browser frame byte limit.")
    }

    /// The explicit owner-device branch the agent snapshot API cannot provide.
    /// Use only behind the same real current watch grant provider. This does not
    /// weaken the agent's masked snapshot or permit a guest to take raw pixels.
    func ownerPixels(caller: BackendBrowserScrapingCaller, target: BackendBrowserCaptureTarget,
                     grant: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget) async throws -> BackendWebKitProfileArmingWatchGrant) async throws -> NativeSafariProfileArmingWatchPixels {
        try await check(caller, target)
        let before = try await grant(caller, target)
        guard before.ownDevice, before.baton != .human || before.humanHolder == caller.holder, let view = webView else {
            throw NativeRPCError(code: "watch-owner", message: "Only this permitted owner device or the actual human handover holder may receive owner pixels.")
        }
        let url = view.url
        let image = try await view.takeSnapshot(configuration: nil)
        try await check(caller, target)
        let after = try await grant(caller, target)
        guard after.ownDevice, after.baton == before.baton, after.humanHolder == before.humanHolder,
              webView === view, view.url == url, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cg.width > 0, cg.height > 0, cg.width <= 16_384, cg.height <= 16_384,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]), png.count <= 64 * 1024 * 1024 else {
            throw NativeRPCError(code: "watch-owner-changed", message: "The owner-device view or its grants changed during capture. No owner pixels were returned.")
        }
        return NativeSafariProfileArmingWatchPixels(png: png, privacy: .owner, prompt: "")
    }
    private func check(_ caller: BackendBrowserScrapingCaller, _ target: BackendBrowserCaptureTarget) async throws {
        guard target.tabID == tabID, target.profileID == profileID, let view = webView,
              BackendBrowserOrigin.exact(view.url?.absoluteString ?? "") == BackendBrowserOrigin.exact(target.pageURL.absoluteString),
              BackendBrowserOrigin.exact(target.pageURL.absoluteString) != nil else { throw closed() }
        try await authorize(caller, "browser.watch", profileID, target.pageURL, .object([.init("tabId", .string(tabID))]))
        try Task.checkCancellation()
    }
    private func geometry() async throws -> NativeRPCValue {
        let value = try await evaluate("({width:innerWidth,height:innerHeight,pageScale:visualViewport?.scale||1,scrollX:scrollX,scrollY:scrollY})")
        guard let w = value["width"].number, let h = value["height"].number, w > 0, h > 0, w <= 16_384, h <= 16_384 else {
            throw NativeRPCError(code: "watch-geometry", message: "The native page has no measurable bounded viewport.")
        }; return value
    }
    private func evaluate(_ source: String) async throws -> NativeRPCValue {
        guard let view = webView else { throw closed() }
        return try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    do { continuation.resume(returning: try NativeRPCValue.fromFoundation(value)) }
                    catch { continuation.resume(throwing: error) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
    private func closed() -> NativeRPCError { .init(code: "watch-tab", message: "This watcher no longer names the live HTTP(S) WebKit tab/profile/origin.") }
    private var script: String {
        """
        (() => {
          const key = \(NativeRPCValue.string(handler).compact);
          if (!window.webkit?.messageHandlers?.[key]) return null;
          window[key]?.stop?.();
          let active = true, frame = 0;
          const signal = () => {
            if (!active || frame) return;
            frame = requestAnimationFrame(() => {
              frame = 0;
              if (active) try { window.webkit.messageHandlers[key].postMessage({changed:true}); } catch (_) { stop(); }
            });
          };
          const observer = new MutationObserver(signal);
          observer.observe(document, {subtree:true,childList:true,attributes:true,characterData:true});
          const events = ['scroll','resize','input','change','focusin','focusout','load'];
          for (const name of events) window.addEventListener(name, signal, true);
          const stop = () => {
            active = false; if (frame) cancelAnimationFrame(frame); frame = 0; observer.disconnect();
            for (const name of events) window.removeEventListener(name, signal, true);
          };
          window[key] = {stop}; signal(); return {eventDriven:true,continuousVideo:false};
        })()
        """
    }
}
