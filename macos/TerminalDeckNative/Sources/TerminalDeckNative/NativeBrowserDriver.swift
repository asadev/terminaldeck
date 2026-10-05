import AppKit
import WebKit
import TerminalDeckNativeCore

/// Agents driving the native browser: the engine's six browser tools, answered
/// here against real WKWebView tabs.
///
/// The contract (`BrowserDriverContract.swift` in Core, `native-browser.ts` in
/// the engine): the engine pushes `native-browser:command` `{id, verb, args,
/// session}`; this answers with `native-browser:result` `[id, {value, summary}]`
/// or `[id, {error}]`. The engine keeps everything in front of a call — who may
/// drive, the person's confirmation for the first change on a public website.
///
/// Seeing: `browser_screenshot` (secret fields painted out). Reading:
/// `browser_read` (the page's words and every element with a selector and a
/// stable ref). Acting: `browser_step` — real mouse and key events sent into the
/// web view when the tab is on screen (the tab is brought forward first, as the
/// Electron driver does), scripted input only when it cannot be. Plus open,
/// close, and handover (the person takes the page; the agent waits).
///
/// It also answers what the web app's browser used to: agent-opened links
/// (`link:open-tab`), and the engine's show/close requests for a window; and it
/// tells the engine about every tab (`browser:window-opened` / `-closed`) so a
/// session's windows can be attached and listed by name (B1, B2).
@MainActor
final class NativeBrowserDriver: BrowserDriverHost {
    static let shared = NativeBrowserDriver()

    /// Hoot's (or an owner AI app's) own tab.
    var ownTabID: String?
    private var subscriptions: [EngineSubscription] = []
    private var eventNumber = 0
    private lazy var engine = BrowserDriverEngine(host: self)

    private var store: NativeBrowserTabs { NativeBrowserTabs.shared }
    private var bridge: EngineBridge { EngineBridge.shared }

    func start() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            bridge.on("native-browser:command") { [weak self] args in
                guard let command = BrowserDriverCommand.decode(args) else { return }
                Task { await self?.answer(command) }
            },
            bridge.on("link:open-tab") { [weak self] args in self?.openLinkTab(args.first) },
            bridge.on("browser:drive-show") { [weak self] args in self?.showRequest(args.first) },
            bridge.on("browser:drive-close") { [weak self] args in self?.closeRequest(args.first) },
        ]
    }

    // MARK: Telling the engine about tabs

    func announce(_ tab: NativeBrowserTab) {
        guard bridge.isReady else { return }
        bridge.send("browser:window-opened", [[
            "tabId": tab.id,
            "url": tab.url?.absoluteString ?? "",
            "title": tab.title,
            "visible": store.selectedID == tab.id,
        ] as [String: Any]])
    }

    func announceClosed(_ id: String) {
        if id == ownTabID { ownTabID = nil }
        guard bridge.isReady else { return }
        bridge.send("browser:window-closed", [id])
    }

    // MARK: Requests from the engine that are not tool calls

    /// A link that should open as a browser tab (`window.open` from the app, a
    /// target=_blank link, a link from a session). Answered when asked to be.
    private func openLinkTab(_ raw: Any?) {
        guard let request = raw as? [String: Any], let text = request["url"] as? String else { return }
        let requestId = request["requestId"] as? String
        guard let url = try? BrowserStepRules.openableURL(text) else {
            if let requestId {
                bridge.send("link:opened", [["requestId": requestId,
                                             "refused": "That link is not a web page, so no tab was opened for it."]])
            }
            return
        }
        let tab = store.create(url: url, show: true)
        if let requestId { bridge.send("link:opened", [["requestId": requestId, "tabId": tab.id]]) }
    }

    private func showRequest(_ raw: Any?) {
        guard let request = raw as? [String: Any], let id = request["id"] as? String,
              let tabId = request["tabId"] as? String, store.tab(tabId) != nil else { return }
        Task {
            let shown = await store.reveal(tabId)
            bridge.send("browser:drive-shown", [id, shown])
        }
    }

    private func closeRequest(_ raw: Any?) {
        guard let request = raw as? [String: Any], let id = request["id"] as? String,
              let tabId = request["tabId"] as? String, store.tab(tabId) != nil else { return }
        store.close(tabId)
        bridge.send("browser:drive-closed", [id, true])
    }

    // MARK: Tool calls

    private func answer(_ command: BrowserDriverCommand) async {
        let result = await engine.answer(command)
        _ = try? await bridge.invoke("native-browser:result", [command.id, result])
    }

    // MARK: BrowserDriverHost — the real tabs

    func bindings() async -> BrowserBindings {
        guard bridge.isReady, let value = try? await bridge.invoke("browser:bindings") else { return BrowserBindings() }
        return BrowserBindings.read(value)
    }

    func tabExists(_ id: String) -> Bool { store.tab(id) != nil }

    func createTab(url: URL, isolated: Bool) -> String {
        store.create(url: url, isolated: isolated, show: false).id
    }

    /// Attach a tab to a session in the engine's map, and learn its name there.
    func attach(_ id: String, to session: BrowserDriverSession) async -> String? {
        guard bridge.isReady, let tab = store.tab(id) else { return nil }
        announce(tab)
        bridge.send("browser:bind", [["tabId": id, "sessionId": session.sessionId, "machineId": session.machineId]])
        for _ in 0..<20 {
            if let window = await bindings().of(session).first(where: { $0.tabID == id }) { return window.name }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    func load(_ id: String, url: URL) { store.tab(id)?.load(url) }
    func isIsolated(_ id: String) -> Bool { store.tab(id)?.isolated ?? false }

    func setIsolated(_ id: String, _ isolated: Bool) {
        guard let tab = store.tab(id) else { return }
        tab.switchStore(profile: tab.profile, isolated: isolated)
    }

    func settle(_ id: String, timeoutMs: Int) async -> Bool {
        guard let tab = store.tab(id) else { return false }
        tab.ensurePage()
        return await tab.settle(timeout: .milliseconds(timeoutMs))
    }

    func pageURL(_ id: String) -> String {
        guard let tab = store.tab(id) else { return "" }
        return (tab.webView?.url ?? tab.url)?.absoluteString ?? ""
    }

    func title(_ id: String) -> String { store.tab(id)?.title ?? "" }
    func displayTitle(_ id: String) -> String { store.tab(id)?.displayTitle ?? "" }

    func evaluate(_ id: String, _ script: String) async throws -> Any? {
        guard let tab = store.tab(id) else { throw BrowserDriverRefusal("that page is not open any more") }
        tab.ensurePage()
        return try await tab.evaluate(script)
    }

    func reveal(_ id: String) async -> Bool { await store.reveal(id) }

    // Real input: mouse and key events sent into the web view itself.

    private func onScreen(_ id: String) -> (WKWebView, NSWindow)? {
        guard let webView = store.tab(id)?.webView, let window = webView.window else { return nil }
        return (webView, window)
    }

    func click(_ id: String, cssRect: CGRect) -> Bool {
        guard let (webView, window) = onScreen(id) else { return false }
        let point = BrowserInputGeometry.viewPoint(cssRect: cssRect, pageZoom: webView.pageZoom,
                                                   magnification: webView.magnification,
                                                   viewHeight: webView.bounds.height, flipped: webView.isFlipped)
        let location = webView.convert(point, to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = mouseEvent(type, at: location, in: window) else { return false }
            switch type {
            case .mouseMoved: webView.mouseMoved(with: event)
            case .leftMouseDown: webView.mouseDown(with: event)
            default: webView.mouseUp(with: event)
            }
        }
        return true
    }

    func focusForTyping(_ id: String) -> Bool {
        guard let (webView, window) = onScreen(id) else { return false }
        return window.makeFirstResponder(webView)
    }

    func type(_ id: String, plan: BrowserTypingPlan) -> Bool {
        guard let (webView, window) = onScreen(id) else { return false }
        switch plan {
        case .clear:
            key(BrowserKeySpec.pressable["Backspace"]!, into: webView, window: window)
        case .keys(let characters):
            for character in characters {
                key(BrowserKeySpec(keyCode: 0, characters: character), into: webView, window: window)
            }
        case .insert(let text):
            webView.insertText(text)
        }
        return true
    }

    func press(_ id: String, key spec: BrowserKeySpec) -> Bool {
        guard let (webView, window) = onScreen(id) else { return false }
        window.makeFirstResponder(webView)
        key(spec, into: webView, window: window)
        return true
    }

    private func key(_ spec: BrowserKeySpec, into webView: WKWebView, window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: spec.characters, charactersIgnoringModifiers: spec.characters,
                                               isARepeat: false, keyCode: spec.keyCode) else { continue }
            if type == .keyDown { webView.keyDown(with: event) } else { webView.keyUp(with: event) }
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint, in window: NSWindow) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                                  clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)
    }

    // Seeing

    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) {
        guard let tab = store.tab(id), let shot = await tab.snapshot() else {
            throw BrowserDriverRefusal("The page has to be on screen to capture it.")
        }
        // Every password, one-time-code and file field is painted out first.
        var rects: [CGRect] = []
        if let raw = try? await tab.evaluate(BrowserDriverScripts.secretRects) as? [String: Any] {
            rects = ((raw["rects"] as? [Any]) ?? []).map(BrowserDriverEngine.rect)
        }
        let scale = tab.webView.map { Double(shot.width) / max(1, $0.bounds.width) * $0.pageZoom * $0.magnification } ?? 1
        let png = try Self.maskedPNG(shot.cgImage, rects: rects, scale: scale)
        // Where the Electron driver writes them: <engine data>/copilot/screenshots.
        let folder = AppModel.shared.engine.configuration.engineDataDirectory
            .appendingPathComponent("copilot", isDirectory: true)
            .appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("page-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        try png.write(to: file, options: .atomic)
        return (file.path, shot.width, shot.height, rects.count)
    }

    static func maskedPNG(_ image: CGImage, rects: [CGRect], scale: Double) throws -> Data {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BrowserDriverRefusal("the picture could not be made")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        for rect in rects {
            // CSS rects run top-down; the bitmap runs bottom-up.
            context.fill(CGRect(x: rect.minX * scale, y: Double(height) - rect.maxY * scale,
                                width: rect.width * scale, height: rect.height * scale).insetBy(dx: -2, dy: -2))
        }
        guard let masked = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: masked).representation(using: .png, properties: [:]) else {
            throw BrowserDriverRefusal("the picture could not be made")
        }
        return png
    }

    // Handing the page to the person

    func handoverPrompt(_ id: String) -> String? { store.tab(id)?.handoverPrompt }

    func otherHandover(than id: String) -> String? {
        store.tabs.first { $0.handoverPrompt != nil && $0.id != id }?.displayTitle
    }

    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String {
        guard let tab = store.tab(id) else { return "drive-ended" }
        if tab.handoverPrompt == nil { tab.beginHandover(prompt) }
        _ = await store.reveal(id)
        // One answer per call: an earlier call still waiting is told to ask again.
        tab.handoverWaiter?("still-waiting")
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            tab.handoverWaiter = { once.finish($0) }
            Task {
                try? await Task.sleep(for: .milliseconds(windowMs))
                once.finish("still-waiting")
            }
        }
    }

    /// Resumes a continuation exactly once.
    @MainActor private final class Once {
        private var continuation: CheckedContinuation<String, Never>?
        init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
        func finish(_ value: String) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    func closeTab(_ id: String) { store.close(id) }
    func unbind(_ id: String) { bridge.send("browser:unbind", [id]) }

    func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    func pause(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
}
