import AppKit
import ImageIO
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Created explicitly by app composition after it supplies its live tab owner.
/// Init does not resolve singletons, read saved data or launch any services.
@MainActor
final class NativeSafariRuntime: NSObject, BackendBrowserRuntime, WKScriptMessageHandler {
    let tabs: NativeBrowserTabs
    let map: BackendBrowserBindings
    let dataRoot: URL
    let userScreenshotDirectory: URL
    let publish: @MainActor (String, NativeRPCValue) -> Void
    private let browserData: @MainActor (String, [String: Any]) async throws -> Any
    private let authorizePopup: @MainActor (String, URL?, Bool) throws -> Void
    var ownTabID: String?
    private var eventNumber = 0
    private var installed: [String: ObjectIdentifier] = [:]
    private var controllers: [ObjectIdentifier: NativeSafariWeakController] = [:]
    private struct Frame { let info: WKFrameInfo; let webView: ObjectIdentifier; let document: String; let url: String }
    private var frames: [String: [String: Frame]] = [:]
    private var savedScreenshots: Set<String> = []
    private var popupOpeners: [String: String] = [:]
    private var transientPopups: Set<String> = []
    private let handlerName = "tdNativeSafariFrame"
    /// S4: the in-page picker (hover, click capture, Esc) in its own content world. One per runtime.
    private var inspectingTabs: Set<String> = []
    private lazy var guest: BackendS4BrowserGuestBridge = makeGuest()
    init(tabs: NativeBrowserTabs, bindings: BackendBrowserBindings, dataRoot: URL, screenshotDirectory: URL,
         browserData: @escaping @MainActor (String, [String: Any]) async throws -> Any,
         authorizePopup: @escaping @MainActor (String, URL?, Bool) throws -> Void,
         publish: @escaping @MainActor (String, NativeRPCValue) -> Void) {
        self.tabs = tabs; map = bindings; self.dataRoot = dataRoot.standardizedFileURL
        userScreenshotDirectory = screenshotDirectory.standardizedFileURL; self.publish = publish
        self.browserData = browserData
        self.authorizePopup = authorizePopup
        super.init()
    }
    /// Call for each existing/created/replaced WKWebView before its first load.
    /// Reusing a profile creates no new store: the existing tabs owner wins.
    func attachPage(_ id: String) throws {
        let tab = try requireTab(id); tab.ensurePage()
        guard let view = tab.webView else { throw refusal("This tab has no WebKit page.") }
        let identity = ObjectIdentifier(view)
        guard installed[id] != identity else { return }
        installed[id] = identity; frames[id] = [:]
        prepareConfiguration(view.configuration)
        // Existing documents register their top frame now; existing child frames
        // register on next navigation. No guessed cross-origin frame handles.
        view.evaluateJavaScript(Self.frameRegistration, in: nil, in: .defaultClient, completionHandler: nil)
        note(tab)
    }
    /// Must be called before constructing a normal, restored or popup page.
    /// Popup configurations can share their opener's user-content controller.
    func prepareConfiguration(_ configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        let key = ObjectIdentifier(controller)
        guard controllers[key]?.value !== controller else { return }
        controllers[key] = NativeSafariWeakController(controller)
        controller.add(NativeSafariWeakFrameHandler(self), contentWorld: .defaultClient, name: handlerName)
        controller.addUserScript(WKUserScript(source: Self.frameRegistration, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: .defaultClient))
        guest.install(into: configuration)
    }
    /// Call from WKUIDelegate using its real supplied configuration and action.
    /// Returning the actual child WKWebView retains window.opener/postMessage;
    /// opening a second independent tab at the URL would break OAuth completion.
    func adoptPopup(configuration: WKWebViewConfiguration, openerID: String, requestedURL: URL?, transientSignIn: Bool) throws -> WKWebView {
        let opener = try requireTab(openerID), openerView = try requireView(openerID)
        guard configuration.websiteDataStore === openerView.configuration.websiteDataStore else { throw refusal("The popup did not retain its opener's exact website store.") }
        if let requestedURL { _ = try BrowserStepRules.openableURL(requestedURL.absoluteString) }
        try authorizePopup(openerID, requestedURL, transientSignIn)
        prepareConfiguration(configuration)
        guard let view = tabs.adoptWindowRequest(configuration: configuration, from: opener),
              let child = tabs.tabs.first(where: { $0.webView === view }) else { throw refusal("The popup did not create a live browser tab.") }
        popupOpeners[child.id] = openerID
        if transientSignIn { transientPopups.insert(child.id) }
        do {
            try attachPage(child.id)
            if !transientSignIn, let session = map.owner(of: openerID) { _ = try map.attach(child.id, to: session) }
            return view
        } catch { closeTab(child.id); throw error }
    }
    func isTransientPopup(_ id: String) -> Bool { transientPopups.contains(id) }
    func detachedPage(_ id: String) {
        for child in popupOpeners.filter({ $0.value == id }).map(\.key) { closeTab(child) }
        popupOpeners[id] = nil; transientPopups.remove(id); inspectingTabs.remove(id)
        installed[id] = nil; frames[id] = nil; map.closed(id)
    }
    func shutdown() {
        for holder in controllers.values {
            holder.value?.removeScriptMessageHandler(forName: handlerName, contentWorld: .defaultClient)
            holder.value?.removeAllScriptMessageHandlers(from: BackendS4BrowserGuestBridge.world)
        }
        inspectingTabs.removeAll()
        controllers.removeAll(); installed.removeAll(); frames.removeAll(); popupOpeners.removeAll(); transientPopups.removeAll(); ownTabID = nil
    }
    func navigationStarted(_ id: String) {
        frames[id] = [:]
        // The new document's picker starts off; the tab says so instead of claiming a picker that is gone.
        if inspectingTabs.remove(id) != nil, let state = try? pageState(id) { publish("browser:state", state) }
    }
    func note(_ tab: NativeBrowserTab) {
        guard handoverPrompt(tab.id) == nil else { return }
        map.observe(.init(tabID: tab.id, viewID: tab.id, url: pageURL(tab.id), title: tab.title,
                          visible: tab.webView?.window != nil, width: Double(tab.webView?.bounds.width ?? 0)))
        if let state = try? pageState(tab.id) { publish("browser:state", state) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == handlerName, let view = message.webView,
              let tab = tabs.tabs.first(where: { $0.webView === view }), installed[tab.id] == ObjectIdentifier(view),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "frame", let document = body["document"] as? String, document.count <= 80,
           let url = body["url"] as? String, BackendBrowserOrigin.exact(url) != nil {
            if message.frameInfo.isMainFrame {
                // A new top document invalidates every handle from the old page.
                let old = frames[tab.id]?.values.first { $0.info.isMainFrame }?.document
                if let old, old != document { frames[tab.id] = [:] }
            }
            let id = message.frameInfo.isMainFrame ? "main" : document
            frames[tab.id, default: [:]][id] = Frame(info: message.frameInfo, webView: ObjectIdentifier(view), document: document, url: url)
        }
        // Element picks arrive only through the S4 guest bridge (its own world, TS browser-tab.ts checks).
    }
    func bindings() async -> BrowserBindings { BrowserBindings() }
    func tabExists(_ id: String) -> Bool { tabs.tab(id) != nil }
    func createTab(url: URL, isolated: Bool) -> String {
        createProfileTab(url: url, isolated: isolated, profileID: tabs.activeProfileID)
    }
    func createProfileTab(url: URL, isolated: Bool, profileID: String) -> String {
        let configuration = tabs.makeConfiguration(profile: profileID, isolated: isolated)
        prepareConfiguration(configuration)
        let tab = tabs.create(url: url, isolated: isolated, profile: profileID, show: false, configuration: configuration)
        do { try attachPage(tab.id) } catch { publish("browser:error", .string(error.localizedDescription)) }
        return tab.id
    }
    func attach(_ id: String, to session: BrowserDriverSession) async -> String? { try? map.attach(id, to: session).name }
    func load(_ id: String, url: URL) { navigationStarted(id); tabs.tab(id)?.load(url) }
    func isIsolated(_ id: String) -> Bool { tabs.tab(id)?.isolated ?? false }
    func setIsolated(_ id: String, _ isolated: Bool) {
        guard let tab = tabs.tab(id) else { return }
        tab.switchStore(profile: tab.profile, isolated: isolated)
        do { try attachPage(id) } catch { publish("browser:error", .string(error.localizedDescription)) }
    }
    func settle(_ id: String, timeoutMs: Int) async -> Bool {
        guard let tab = tabs.tab(id) else { return false }; tab.ensurePage()
        let deadline = now() + Double(max(0, timeoutMs))
        do {
            try await Task.sleep(for: .milliseconds(120))
            while tab.isLoading {
                try Task.checkCancellation(); guard now() < deadline else { return false }
                try await Task.sleep(for: .milliseconds(80))
            }
            return !Task.isCancelled && tabs.tab(id) != nil
        } catch { return false }
    }
    func pageURL(_ id: String) -> String { (tabs.tab(id)?.webView?.url ?? tabs.tab(id)?.url)?.absoluteString ?? "" }
    func title(_ id: String) -> String { tabs.tab(id)?.title ?? "" }
    func displayTitle(_ id: String) -> String { tabs.tab(id)?.displayTitle ?? "" }
    func evaluate(_ id: String, _ script: String) async throws -> Any? {
        try Task.checkCancellation()
        guard BrowserDriverScripts.name(of: script) != nil else { throw refusal("The browser driver only runs its own bounded scripts.") }
        let view = try requireView(id)
        let value = try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        try Task.checkCancellation(); return value
    }
    func reveal(_ id: String) async -> Bool { await tabs.reveal(id) }
    private func screen(_ id: String) -> (WKWebView, NSWindow)? {
        guard !Task.isCancelled, let view = tabs.tab(id)?.webView, let window = view.window,
              tabs.tab(id)?.handoverPrompt == nil else { return nil }
        return (view, window)
    }
    func click(_ id: String, cssRect: CGRect) -> Bool {
        guard let (view, window) = screen(id) else { return false }
        let point = BrowserInputGeometry.viewPoint(cssRect: cssRect, pageZoom: view.pageZoom,
            magnification: view.magnification, viewHeight: view.bounds.height, flipped: view.isFlipped)
        let location = view.convert(point, to: nil)
        for kind in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            eventNumber += 1
            guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: kind == .mouseMoved ? 0 : 1, pressure: kind == .leftMouseDown ? 1 : 0) else { return false }
            switch kind { case .mouseMoved: view.mouseMoved(with: event); case .leftMouseDown: view.mouseDown(with: event); default: view.mouseUp(with: event) }
        }
        return true
    }
    func focusForTyping(_ id: String) -> Bool { guard let (view, window) = screen(id) else { return false }; return window.makeFirstResponder(view) }
    func type(_ id: String, plan: BrowserTypingPlan) -> Bool {
        guard let (view, window) = screen(id) else { return false }
        switch plan {
        case .clear: sendKey(BrowserKeySpec.pressable["Backspace"]!, view, window)
        case .keys(let letters): for letter in letters { sendKey(.init(keyCode: 0, characters: letter), view, window) }
        case .insert(let text): view.insertText(text)
        }
        return true
    }
    func press(_ id: String, key: BrowserKeySpec) -> Bool {
        guard let (view, window) = screen(id), window.makeFirstResponder(view) else { return false }
        sendKey(key, view, window); return true
    }
    private func sendKey(_ key: BrowserKeySpec, _ view: WKWebView, _ window: NSWindow) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.keyCode) else { continue }
            if kind == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }
    func pageState(_ id: String) throws -> NativeRPCValue {
        let tab = try requireTab(id)
        return .object([.init("id", .string(id)), .init("url", .string(pageURL(id))), .init("title", .string(tab.title)),
            .init("loading", .bool(tab.isLoading)), .init("canGoBack", .bool(tab.canGoBack)), .init("canGoForward", .bool(tab.canGoForward)),
            .init("zoom", .number(tab.webView.map { Double($0.pageZoom) } ?? tab.zoom)), .init("error", tab.failure.map { .string($0.message) } ?? .null),
            .init("profileId", .string(tab.profile)), .init("isolated", .bool(tab.isolated)), .init("recording", .bool(tab.recording)),
            .init("popup", .bool(popupOpeners[id] != nil)), .init("transientSignIn", .bool(transientPopups.contains(id))),
            .init("inspecting", .bool(inspectingTabs.contains(id)))])
    }
    func pageCommand(_ id: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        try Task.checkCancellation(); let tab = try requireTab(id)
        if operation == "close" { closeTab(id); return .null }
        let view = try requireView(id)
        switch operation {
        case "state": return try pageState(id)
        case "navigate": load(id, url: try BrowserStepRules.openableURL(try arguments["url"].requireString("url", nonempty: true)))
        case "back": navigationStarted(id); tab.goBack()
        case "forward": navigationStarted(id); tab.goForward()
        case "reload": navigationStarted(id); tab.reload()
        case "stop": tab.stop()
        case "show": guard await reveal(id) else { throw refusal("This page could not be brought on screen.") }
        case "zoom":
            if arguments["factor"].isNullish { return .number(view.pageZoom) }
            guard let factor = arguments["factor"].number, (0.25...3).contains(factor) else { throw refusal("Zoom must be between 0.25 and 3.") }
            view.pageZoom = factor
        case "find":
            let config = WKFindConfiguration(); config.backwards = arguments["backwards"].bool ?? (arguments["forward"].bool == false)
            config.caseSensitive = arguments["matchCase"].bool ?? false; config.wraps = true
            let text = try arguments["text"].requireString("text")
            if text.isEmpty { tab.clearFind(); return .object([.init("matchFound", .bool(false))]) }
            let found = await withCheckedContinuation { continuation in view.find(text, configuration: config) { continuation.resume(returning: $0.matchFound) } }
            return .object([.init("matchFound", .bool(found))])
        case "findstop": tab.clearFind()
        case "print": guard view.window != nil else { throw refusal("Bring this page on screen to print it.") }; tab.printPage()
        case "devtools": throw refusal("WebKit has no public API to open Web Inspector. Use Safari's Develop menu or the page's Inspect Element menu.")
        case "useragent": view.customUserAgent = arguments["userAgent"].string ?? arguments["ua"].string; view.reload()
        case "inspect":
            let on = (arguments["on"].bool ?? arguments["enabled"].bool ?? false) && tab.handoverPrompt == nil
            if on { inspectingTabs.insert(id) } else { inspectingTabs.remove(id) }
            await guest.setInspecting(view, on)
            publish("browser:state", try pageState(id))
        case "record": if tab.recording != (arguments["on"].bool ?? true) { tab.toggleRecording() }
        case "recordclear": tab.clearRecording()
        case "resume": tab.endHandover(arguments["carryOn"].bool == true ? "resumed" : "stopped"); map.changed?(); return .null
        case "recording": return .object([.init("recording", .bool(tab.recording)), .init("steps", .array(tab.steps.map { step in
            .object([.init("kind", .string(step.kind.rawValue)), .init("selector", .string(step.selector)), .init("label", .string(step.label)),
                .init("tag", .string(step.tag)), .init("value", .string(step.redacted ? "" : step.value)), .init("redacted", .bool(step.redacted)),
                .init("key", .string(step.key)), .init("checked", .bool(step.checked)), .init("url", .string(step.url)), .init("at", .number(step.at))])
        }))])
        case "scroll":
            let x = arguments["x"].number ?? 0, y = arguments["y"].number ?? 0
            guard abs(x) <= 100_000, abs(y) <= 100_000 else { throw refusal("Scroll distance is too large.") }
            _ = try await view.callAsyncJavaScript("window.scrollBy(x,y); return {x:window.scrollX,y:window.scrollY};", arguments: ["x": x, "y": y], in: nil, contentWorld: .defaultClient)
        case "extract": return try await NativeSafariRecipeScripts.run(view, recipe: arguments["recipe"], limit: min(2_000, max(1, Int(arguments["limit"].number ?? 200))))
        case "pick":
            guard let x = arguments["x"].number, let y = arguments["y"].number, x.isFinite, y.isFinite else {
                throw refusal("Picking needs a finite document CSS point.")
            }
            guard handoverPrompt(id) == nil else { throw refusal("The person has this page right now.") }
            let epoch = tab.documentEpoch
            let picked = try await NativeCompositionBrowserPicking.run(view, x: x, y: y, up: arguments["up"].number ?? 0)
            try Task.checkCancellation()
            guard tabs.tab(id)?.webView === view, tab.documentEpoch == epoch, handoverPrompt(id) == nil else {
                throw refusal("This picking document or its current baton changed.")
            }
            let selector = BrowserLine.sanitize(picked["selector"].string ?? "", max: 400)
            let tag = BrowserLine.sanitize(picked["tag"].string ?? "", max: 40)
            let label = BrowserLine.sanitize(picked["label"].string ?? "", max: 150)
            let url = pageURL(id)
            return picked.setting("attributes", .object([])).setting("url", .string(url))
                .setting("context", .string(BrowserLine.sanitize("Browser element on \(url): \(selector) (\(tag)) \(label)", max: 1_200)))
                .setting("pageImage", .string(""))
        case "screenshot-marked":
            let raw: Data?
            if case .bytes(let data) = arguments["png"] { raw = data }
            else if let encoded = arguments["png"].string, encoded.hasPrefix("data:image/png;base64,") { raw = Data(base64Encoded: String(encoded.dropFirst(22))) }
            else { raw = nil }
            guard let raw, raw.count <= 32 * 1024 * 1024, raw.starts(with: [137,80,78,71,13,10,26,10]),
                  let source = CGImageSourceCreateWithData(raw as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) == 1,
                  let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = metadata[kCGImagePropertyPixelWidth] as? Int, let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 64 * 1024 * 1024 else {
                throw refusal("The drawing is not a bounded PNG image. Nothing was saved.")
            }
            let file = try savePNG(raw, folder: userScreenshotDirectory, prefix: "marked")
            return .object([.init("path", .string(file.path)), .init("width", .number(Double(width))), .init("height", .number(Double(height))), .init("url", .string(pageURL(id)))])
        case "evaluate":
            let script = try arguments["script"].requireString("script", nonempty: true)
            guard script.utf8.count <= 65_536 else { throw refusal("The app tool's script exceeds 64 KiB.") }
            return try NativeRPCValue.fromFoundation(await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient))
        case "screenshot", "snapshot":
            let shot = try await screenshot(id)
            return .object([.init("path", .string(shot.path)), .init("width", .number(Double(shot.width))), .init("height", .number(Double(shot.height))), .init("masked", .number(Double(shot.masked)))])
        case "user-screenshot":
            let shot = try await privacySnapshotPNG(id)
            let file = try savePNG(shot.bytes, folder: userScreenshotDirectory, prefix: "page")
            // A full capture already succeeded. Source captureBrowserView keeps
            // that receipt even when its independent thumbnail encode fails.
            let preview = try? resizedPNG(shot.bytes, maximumWidth: 1_200)
            return .object([.init("path", .string(file.path)), .init("width", .number(Double(shot.width))), .init("height", .number(Double(shot.height))),
                .init("preview", .string(preview.map { "data:image/png;base64," + $0.bytes.base64EncodedString() } ?? ""))])
        case "frame":
            let shot = try await privacySnapshotPNG(id), small = try resizedPNG(shot.bytes, maximumWidth: 2_000)
            return .object([.init("image", .string("data:image/png;base64," + small.bytes.base64EncodedString())),
                .init("width", .number(Double(small.width))), .init("height", .number(Double(small.height))), .init("url", .string(pageURL(id)))])
        default: throw refusal("Safari does not implement page action '\(operation)'.")
        }
        note(tab); return try pageState(id)
    }
    func frameCommand(_ id: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let view = try requireView(id); try Task.checkCancellation()
        if operation == "frames" {
            return .array((frames[id] ?? [:]).sorted { $0.key < $1.key }.map { key, frame in
                .object([.init("id", .string(key)), .init("url", .string(frame.url)), .init("main", .bool(frame.info.isMainFrame)), .init("document", .string(frame.document))])
            })
        }
        let name = arguments["frameId"].string ?? "main"
        guard let frame = frames[id]?[name], frame.webView == ObjectIdentifier(view) else {
            throw refusal("That frame has no live WebKit handle. Reload the page, list its frames, and use the returned id.")
        }
        let current = try await view.callAsyncJavaScript("return {url:String(location.href),document:window.__tdNativeDocument};", arguments: [:], in: frame.info, contentWorld: .defaultClient) as? [String: Any]
        guard current?["document"] as? String == frame.document else { throw refusal("That frame navigated. List frames again.") }
        if operation == "state" { return try NativeRPCValue.fromFoundation(current) }
        guard let authorizedOrigin = arguments["authorizedOrigin"].string,
              BackendBrowserOrigin.exact(current?["url"] as? String ?? "") == authorizedOrigin else {
            throw refusal("That frame's origin changed while approval was pending. Try again after listing frames.")
        }
        if let requested = arguments["waitFor"].string ?? (operation == "wait" ? arguments["selector"].string : nil) {
            let selector = BrowserElementRef.selector(for: requested)
            guard selector.count <= 400 else { throw refusal("That selector exceeds 400 characters.") }
            let timeout = min(30_000, max(500, arguments["timeoutMs"].number ?? 10_000)), deadline = now() + timeout
            while true {
                try Task.checkCancellation()
                guard handoverPrompt(id) == nil else { throw refusal("The person has this page.") }
                let probeScript = BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": selector])
                let raw = try await view.evaluateJavaScript(probeScript, in: frame.info, contentWorld: .defaultClient) as? [String: Any]
                guard BackendBrowserOrigin.exact(raw?["url"] as? String ?? "") == authorizedOrigin else { throw refusal("The frame moved to another site while waiting.") }
                if raw?["invalid"] as? Bool == true { throw refusal("That is not a valid CSS selector.") }
                if raw?["found"] as? Bool == true, raw?["visible"] as? Bool == true { break }
                guard now() < deadline else { throw refusal("The requested frame element did not appear before the timeout.") }
                try await Task.sleep(for: .milliseconds(80))
            }
            if operation == "wait" { return .object([.init("found", .bool(true)), .init("frameId", .string(name))]) }
        }
        let script: String
        switch operation {
        case "read":
            let selected = arguments["selector"].string.map { BrowserElementRef.selector(for: $0) }
            let limit = min(40_000, max(200, arguments["textChars"].number ?? 4_000))
            script = BrowserDriverScripts.with(selected == nil ? BrowserDriverScripts.outline : BrowserDriverScripts.text,
                args: ["selector": selected ?? "", "limit": selected == nil ? 60 : Int(limit), "textLimit": Int(limit)])
        case "scroll":
            let x = arguments["x"].number ?? 0, y = arguments["y"].number ?? 0
            guard abs(x) <= 100_000, abs(y) <= 100_000 else { throw refusal("Scroll distance is too large.") }
            return try NativeRPCValue.fromFoundation(await view.callAsyncJavaScript("window.scrollBy(x,y); return {x:window.scrollX,y:window.scrollY};", arguments: ["x": x, "y": y], in: frame.info, contentWorld: .defaultClient))
        case "evaluate": script = try arguments["script"].requireString("script", nonempty: true)
        case "step":
            // The frame driver uses the same actionability/secret rules. WebKit
            // exposes no cross-origin native coordinate transform, so its input
            // is explicitly the driver's DOM fallback, never labelled trusted.
            let host = NativeSafariFrameHost(runtime: self, tabID: id, frame: frame.info, url: current?["url"] as? String ?? frame.url)
            guard let command = BrowserDriverCommand.decode([["id": UUID().uuidString, "verb": "browser_step", "args": arguments.foundation ?? [:]]]) else { throw refusal("Invalid frame step.") }
            let result = try NativeRPCValue.fromFoundation(await BrowserDriverEngine(host: host).answer(command))
            if let error = result["error"].string { throw refusal(error) }
            return result["value"].setting("inputMode", .string("dom-events"))
        default: throw refusal("That frame operation is unavailable.")
        }
        guard script.utf8.count <= 131_072 else { throw refusal("The frame script is too large.") }
        return try NativeRPCValue.fromFoundation(await view.evaluateJavaScript(script, in: frame.info, contentWorld: .defaultClient))
    }
    func dataCommand(_ operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard let args = arguments.foundation as? [String: Any] else { throw refusal("Browser data arguments must be an object.") }
        return try NativeRPCValue.fromFoundation(await browserData(operation, args))
    }
    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) {
        let shot = try await privacySnapshotPNG(id)
        let file = try savePNG(shot.bytes, folder: RNMHootPaths(dataRoot: dataRoot).screenshots, prefix: "page")
        return (file.path, shot.width, shot.height, shot.masked)
    }
    func privacySnapshotPNG(_ id: String) async throws -> (bytes: Data, width: Int, height: Int, masked: Int) {
        let view = try requireView(id); guard handoverPrompt(id) == nil else { throw refusal("The person has this page.") }
        guard view.bounds.width > 0, view.bounds.height > 0 else { throw refusal("This page has no drawable size.") }
        // Mask all child-frame rectangles because WebKit cannot enumerate the
        // secrets in unregistered cross-origin frames. A probe failure refuses
        // the entire capture; it never writes an unredacted fallback picture.
        let raw = try await view.evaluateJavaScript(Self.secretRectangles, in: nil, contentWorld: .defaultClient)
        guard let fields = raw as? [String: Any], let values = fields["rects"] as? [[String: Any]] else { throw refusal("The page's privacy masks could not be read.") }
        let url = view.url
        let image = try await view.takeSnapshot(configuration: nil)
        try Task.checkCancellation()
        let after = try await view.evaluateJavaScript(Self.secretRectangles, in: nil, contentWorld: .defaultClient) as? [String: Any]
        guard let afterRects = after?["rects"] as? [[String: Any]],
              try JSONSerialization.data(withJSONObject: values, options: .sortedKeys) == JSONSerialization.data(withJSONObject: afterRects, options: .sortedKeys) else {
            throw refusal("A protected field moved during capture. No image was saved; try after the page settles.")
        }
        guard handoverPrompt(id) == nil, view.url == url,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw refusal("The page changed during capture; no image was saved.") }
        let rects = values.map { CGRect(x: ($0["x"] as? NSNumber)?.doubleValue ?? 0, y: ($0["y"] as? NSNumber)?.doubleValue ?? 0,
                                       width: ($0["width"] as? NSNumber)?.doubleValue ?? 0, height: ($0["height"] as? NSNumber)?.doubleValue ?? 0) }
        let scale = Double(cg.width) / max(1, view.bounds.width) * view.pageZoom * view.magnification
        let png = try NativeBrowserShotMask.maskedPNG(cg, rects: rects, scale: scale)
        return (png, cg.width, cg.height, rects.count)
    }
    private func resizedPNG(_ png: Data, maximumWidth: Int) throws -> (bytes: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw refusal("The captured image could not be decoded.") }
        let width = min(maximumWidth, original.width), height = max(1, Int(Double(original.height) * Double(width) / Double(original.width)))
        if width == original.width { return (png, width, height) }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw refusal("The captured preview could not be resized.") }
        context.interpolationQuality = .high; context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(), let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw refusal("The captured preview could not be encoded.") }
        return (bytes, width, height)
    }
    func revealScreenshot(_ path: String) throws {
        guard savedScreenshots.contains(path), FileManager.default.fileExists(atPath: path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else {
            throw refusal("This run did not save that screenshot. Open older images from the explicitly selected screenshot folder.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    private func savePNG(_ png: Data, folder: URL, prefix: String) throws -> URL {
        var ancestor = folder
        while ancestor.path != "/" {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else { throw refusal("The screenshot destination contains a symbolic link.") }
            ancestor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(prefix)-\(UUID().uuidString).png")
        try png.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        savedScreenshots.insert(file.path); return file
    }
    func handoverPrompt(_ id: String) -> String? {
        var current: String? = id; var seen: Set<String> = []
        while let tab = current, seen.insert(tab).inserted {
            if let prompt = tabs.tab(tab)?.handoverPrompt { return prompt }
            current = popupOpeners[tab]
        }
        return nil
    }
    func otherHandover(than id: String) -> String? { tabs.tabs.first { $0.id != id && $0.handoverPrompt != nil }?.displayTitle }
    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String {
        guard let tab = tabs.tab(id) else { return "drive-ended" }
        if tab.handoverPrompt == nil { tab.beginHandover(prompt) }
        map.changed?()
        _ = await reveal(id)
        let answer = NativeSafariHandoverOutcome()
        tab.handoverWaiter?("still-waiting")
        tab.handoverWaiter = { [weak self] in answer.value = $0; self?.map.changed?() }
        defer { tab.handoverWaiter = nil }
        let deadline = now() + Double(windowMs)
        while answer.value == nil, tab.handoverPrompt != nil, tabs.tab(id) != nil {
            if Task.isCancelled { return "still-waiting" }
            if now() >= deadline { return "still-waiting" }
            try? await Task.sleep(for: .milliseconds(80))
        }
        let outcome = answer.value ?? (tabs.tab(id) == nil ? "drive-ended" : "stopped")
        if outcome == "stopped" || outcome == "drive-ended" { map.release(id) }
        return outcome
    }
    func closeTab(_ id: String) { detachedPage(id); tabs.close(id) }
    func unbind(_ id: String) { map.detach(id) }
    func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
    func pause(ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
    private func requireTab(_ id: String) throws -> NativeBrowserTab { guard let tab = tabs.tab(id) else { throw refusal("That page is no longer open.") }; return tab }
    fileprivate func requireView(_ id: String) throws -> WKWebView { let tab = try requireTab(id); tab.ensurePage(); guard let view = tab.webView else { throw refusal("That page has no live WebKit view.") }; return view }
    private func refusal(_ message: String) -> NativeRPCError { .init(code: "browser-refused", message: message) }
    // MARK: S4 guest picker

    private func makeGuest() -> BackendS4BrowserGuestBridge {
        var hooks = BackendS4BrowserGuestHooks()
        hooks.isInspecting = { [weak self] view in
            guard let self, let tab = self.tabs.tabs.first(where: { $0.webView === view }) else { return false }
            return self.inspectingTabs.contains(tab.id) && tab.handoverPrompt == nil
        }
        hooks.isIsolated = { [weak self] view in self?.tabs.tabs.first(where: { $0.webView === view })?.isolated ?? true }
        hooks.element = { [weak self] view, element in self?.inspected(view, element) }
        hooks.cancelled = { [weak self] view in
            guard let self, let tab = self.tabs.tabs.first(where: { $0.webView === view }),
                  self.inspectingTabs.remove(tab.id) != nil, let state = try? self.pageState(tab.id) else { return }
            self.publish("browser:state", state)
        }
        // Sign-in forms stay with the native password adapter and steps with the native recorder.
        return BackendS4BrowserGuestBridge(hooks: hooks)
    }
    /// TS browser-tab.ts GUEST_ELEMENT_CHANNEL: photograph first, then send capture + context + picture + box.
    private func inspected(_ view: WKWebView, _ element: BackendS4BrowserElement) {
        guard let tab = tabs.tabs.first(where: { $0.webView === view }), installed[tab.id] == ObjectIdentifier(view),
              tab.handoverPrompt == nil else { return }
        let id = tab.id
        Task { @MainActor [weak self] in
            let picture = await Self.freezeFrame(view)
            guard let self, self.tabs.tab(id)?.webView === view else { return }
            let c = element.capture
            var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("selector", .string(c.selector)), .init("tag", .string(c.tag)),
                .init("label", .string(c.label)), .init("labelSource", .string(c.labelSource)), .init("url", .string(c.url)),
                .init("attributes", .object(c.attributes.keys.sorted().map { .init($0, .string(c.attributes[$0] ?? "")) })),
                .init("context", .string(element.context)), .init("pageImage", .string(picture))]
            fields.append(.init("rect", element.rect.map { .object([.init("x", .number($0.x)), .init("y", .number($0.y)),
                .init("width", .number($0.width)), .init("height", .number($0.height))]) } ?? .null))
            self.publish("browser:element", .object(fields))
        }
    }
    /// TS freezeFrame: the visible page as a JPEG data URL, at most 1600 wide, quality 80; empty when it cannot.
    private static func freezeFrame(_ view: WKWebView) async -> String {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let image = try? await view.takeSnapshot(configuration: nil),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return "" }
        let width = min(cg.width, 1600), height = max(1, Int((Double(cg.height) * Double(width) / Double(cg.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return "" }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    private static let secretRectangles = #"""
    (function(){const rects=[]; function walk(root){for(const e of root.querySelectorAll('input,textarea,iframe,frame,*')){
    if(e.shadowRoot)walk(e.shadowRoot); const t=(e.getAttribute('type')||'').toLowerCase();
    if(e.matches('iframe,frame,form')||e.localName.includes('-')&&!e.shadowRoot||t==='password'||t==='file'||/(password|one-time-code|cc-number|cc-csc)/i.test(e.getAttribute('autocomplete')||'')){
    const r=e.getBoundingClientRect(); if(r.width&&r.height)rects.push({x:r.x,y:r.y,width:r.width,height:r.height});}}
    } walk(document); return {rects};})()
    """#
    private static let frameRegistration = #"""
    (function(){if(window.__tdNativeDocument){window.webkit.messageHandlers.tdNativeSafariFrame.postMessage({kind:'frame',document:window.__tdNativeDocument,url:String(location.href)});return;} const bytes=new Uint8Array(16);crypto.getRandomValues(bytes);window.__tdNativeDocument=Array.from(bytes,n=>n.toString(16).padStart(2,'0')).join('');
    function announce(){window.webkit.messageHandlers.tdNativeSafariFrame.postMessage({kind:'frame',document:window.__tdNativeDocument,url:String(location.href)});}
    announce(); addEventListener('pageshow',announce);})()
    """#
}

@MainActor private final class NativeSafariHandoverOutcome { var value: String? }
@MainActor private final class NativeSafariWeakController {
    weak var value: WKUserContentController?
    init(_ value: WKUserContentController) { self.value = value }
}

@MainActor
private final class NativeSafariWeakFrameHandler: NSObject, WKScriptMessageHandler {
    weak var target: NativeSafariRuntime?
    init(_ target: NativeSafariRuntime) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}

/// Frame commands deliberately have no trusted native-input claim.
@MainActor
private final class NativeSafariFrameHost: BrowserDriverHost {
    let runtime: NativeSafariRuntime; let id: String; let frame: WKFrameInfo; let url: String
    var ownTabID: String?
    init(runtime: NativeSafariRuntime, tabID: String, frame: WKFrameInfo, url: String) { self.runtime = runtime; id = tabID; self.frame = frame; self.url = url; ownTabID = tabID }
    func bindings() async -> BrowserBindings { BrowserBindings() }
    func tabExists(_ id: String) -> Bool { runtime.tabExists(id) }
    func createTab(url: URL, isolated: Bool) -> String { runtime.createTab(url: url, isolated: isolated) }
    func attach(_ id: String, to session: BrowserDriverSession) async -> String? { nil }
    func load(_ id: String, url: URL) { runtime.load(id, url: url) }
    func isIsolated(_ id: String) -> Bool { runtime.isIsolated(id) }
    func setIsolated(_ id: String, _ isolated: Bool) { runtime.setIsolated(id, isolated) }
    func settle(_ id: String, timeoutMs: Int) async -> Bool { await runtime.settle(id, timeoutMs: timeoutMs) }
    func pageURL(_ id: String) -> String { url }
    func title(_ id: String) -> String { runtime.title(id) }
    func displayTitle(_ id: String) -> String { runtime.displayTitle(id) }
    func evaluate(_ id: String, _ script: String) async throws -> Any? {
        try Task.checkCancellation(); let view = try runtime.requireView(id)
        let current = try await view.callAsyncJavaScript("return String(location.href);", arguments: [:], in: frame, contentWorld: .defaultClient) as? String
        guard BackendBrowserOrigin.exact(current ?? "") == BackendBrowserOrigin.exact(url), runtime.handoverPrompt(id) == nil else {
            throw NativeRPCError(code: "origin-changed", message: "The frame's origin changed or the person took over. Try again after listing frames.")
        }
        return try await view.evaluateJavaScript(script, in: frame, contentWorld: .defaultClient)
    }
    func reveal(_ id: String) async -> Bool { await runtime.reveal(id) }
    func click(_ id: String, cssRect: CGRect) -> Bool { false }
    func focusForTyping(_ id: String) -> Bool { false }
    func type(_ id: String, plan: BrowserTypingPlan) -> Bool { false }
    func press(_ id: String, key: BrowserKeySpec) -> Bool { false }
    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) { try await runtime.screenshot(id) }
    func handoverPrompt(_ id: String) -> String? { runtime.handoverPrompt(id) }
    func otherHandover(than id: String) -> String? { runtime.otherHandover(than: id) }
    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String { await runtime.handOver(id, prompt: prompt, windowMs: windowMs) }
    func closeTab(_ id: String) { runtime.closeTab(id) }
    func unbind(_ id: String) { runtime.unbind(id) }
    func now() -> Double { runtime.now() }
    func pause(ms: Int) async { await runtime.pause(ms: ms) }
}
