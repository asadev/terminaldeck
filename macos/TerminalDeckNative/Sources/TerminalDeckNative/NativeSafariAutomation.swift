import AppKit
import CoreGraphics
import ImageIO
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// A page an agent drives while nobody shows it lives in one of these: off
/// screen, never key, never in the person's way (WebKit renders it like any page).
typealias NativeBrowserParkingWindow = NativeBrowserCaptureWindow

/// Browser 27 (Asad, 4 Nov 2026): everything WebKit's public API lets the
/// in-app browser do that Playwright does — real input on pages nobody is
/// looking at, more element actions, files for upload, full-page/element/PDF
/// captures, waits, scripts, dialogs, console, network log/blocking/mocking,
/// emulation, storage and multi-page collection. The tool shapes and consent
/// tiers live in TerminalDeckBackend (BackendBrowserService / Factories).
extension NativeSafariRuntime {
    // MARK: Parking (a real viewport for pages nobody is looking at)

    func parkingSize(_ id: String) -> CGSize {
        guard let tab = tabs.tab(id) else { return CGSize(width: 1280, height: 800) }
        if let size = tab.automation.viewport { return size }
        if let frame = BRDeviceSize.frame(deviceID: tab.deviceID, customWidth: tab.customWidth, customHeight: tab.customHeight) {
            return tab.deviceLandscape ? CGSize(width: frame.height, height: frame.width) : CGSize(width: frame.width, height: frame.height)
        }
        return CGSize(width: 1280, height: 800)
    }

    /// Give a page that is in no window an off-screen one, so layout, hit tests,
    /// screenshots and real mouse input all work as on screen. The person's
    /// browser takes the page back the moment it shows that tab.
    func parkIfHidden(_ id: String) {
        guard let tab = tabs.tab(id), let view = tab.webView else { return }
        if let window = tab.automation.parkingWindow, view.window !== window { window.close(); tab.automation.parkingWindow = nil }
        guard view.window == nil else { return }
        let size = parkingSize(id)
        let window = NativeBrowserParkingWindow(contentRect: NSRect(x: -32_000, y: -32_000, width: size.width, height: size.height),
                                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        // Not throttled like a hidden page: timers, animation frames and loads run at full speed.
        view.configuration.preferences.inactiveSchedulingPolicy = .none
        window.orderBack(nil)
        tab.automation.parkingWindow = window
    }

    func unpark(_ id: String) {
        guard let tab = tabs.tab(id), let window = tab.automation.parkingWindow else { return }
        tab.automation.parkingWindow = nil
        if window.contentView != nil { window.contentView = nil }
        window.close()
    }

    func resizeParked(_ id: String) {
        guard let tab = tabs.tab(id), let window = tab.automation.parkingWindow, tab.webView?.window === window else { return }
        window.setContentSize(parkingSize(id))
    }

    // MARK: Page scripts with a deadline

    /// A page script never holds a tool (or the page's lock) forever: a document
    /// replaced mid-call, or stuck behind a dialog, answers with a refusal instead.
    func js(_ view: WKWebView, _ script: String, world: WKContentWorld, ms: Int = 15_000) async throws -> Any? {
        try await NativeBrowserRace.within(ms) { NativeBrowserUnchecked(try await view.evaluateJavaScript(script, in: nil, contentWorld: world)) }.value
    }

    func asyncJS(_ view: WKWebView, _ body: String, _ arguments: [String: Any], world: WKContentWorld, ms: Int = 15_000) async throws -> Any? {
        let args = NativeBrowserUnchecked(arguments)
        return try await NativeBrowserRace.within(ms) {
            NativeBrowserUnchecked(try await view.callAsyncJavaScript(body, arguments: args.value as? [String: Any] ?? [:], in: nil, contentWorld: world))
        }.value
    }

    // MARK: Real input beyond a click

    private func flags(_ modifiers: BrowserClickModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.shift { flags.insert(.shift) }
        if modifiers.control { flags.insert(.control) }
        if modifiers.alt { flags.insert(.option) }
        if modifiers.meta { flags.insert(.command) }
        return flags
    }

    private func mouse(_ id: String, cssRect: CGRect, clicks: [Int], flags: NSEvent.ModifierFlags) -> Bool {
        guard let (view, window) = screen(id) else { return false }
        let point = BrowserInputGeometry.viewPoint(cssRect: cssRect, pageZoom: view.pageZoom,
            magnification: view.magnification, viewHeight: view.bounds.height, flipped: view.isFlipped)
        let location = view.convert(point, to: nil)
        var kinds: [(NSEvent.EventType, Int)] = [(.mouseMoved, 0)]
        for count in clicks { kinds += [(.leftMouseDown, count), (.leftMouseUp, count)] }
        for (kind, count) in kinds {
            eventNumber += 1
            guard let event = NSEvent.mouseEvent(with: kind, location: location, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: count, pressure: kind == .leftMouseDown ? 1 : 0) else { return false }
            switch kind { case .mouseMoved: view.mouseMoved(with: event); case .leftMouseDown: view.mouseDown(with: event); default: view.mouseUp(with: event) }
        }
        return true
    }

    func click(_ id: String, cssRect: CGRect, modifiers: BrowserClickModifiers) -> Bool {
        modifiers.isEmpty ? click(id, cssRect: cssRect) : mouse(id, cssRect: cssRect, clicks: [1], flags: flags(modifiers))
    }

    func doubleClick(_ id: String, cssRect: CGRect) -> Bool { mouse(id, cssRect: cssRect, clicks: [1, 2], flags: []) }

    func hover(_ id: String, cssRect: CGRect) -> Bool { mouse(id, cssRect: cssRect, clicks: [], flags: []) }

    func press(_ id: String, chord: BrowserKeyChord) -> Bool {
        guard let (view, window) = screen(id), window.makeFirstResponder(view) else { return false }
        var modifierFlags = flags(BrowserClickModifiers(shift: chord.shift, control: chord.control, alt: chord.alt, meta: chord.meta))
        if chord.spec.characters.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true { modifierFlags.insert(.function) }
        let ignoring = chord.shift ? chord.spec.characters.lowercased() : chord.spec.characters
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chord.spec.characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: chord.spec.keyCode) else { continue }
            if kind == .keyDown {
                if chord.meta, view.performKeyEquivalent(with: event) { continue }
                view.keyDown(with: event)
            } else { view.keyUp(with: event) }
        }
        return true
    }

    // MARK: Files for the page (Playwright's setInputFiles and file chooser)

    func uploadDocument(_ id: String) -> String? {
        guard let tab = tabs.tab(id), let view = tab.webView else { return nil }
        return "\(ObjectIdentifier(view)):\(tab.documentEpoch.uuidString):\(view.url?.absoluteString ?? "")"
    }

    func upload(_ id: String, selector: String, files: [String], probe: [String: Any]) async throws -> [String: Any] {
        try await upload(id, selector: selector, files: files, probe: probe, authority: { true })
    }

    func upload(_ id: String, selector: String, files: [String], probe: [String: Any],
                authority: @escaping @MainActor () -> Bool) async throws -> [String: Any] {
        let cancellation = NativeBrowserUploadCancellation()
        return try await withTaskCancellationHandler {
            try await authorizedUpload(id, selector: selector, files: files, probe: probe, authority: authority, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.tabs.tab(id)?.automation.disarmUpload() }
        }
    }

    private func authorizedUpload(_ id: String, selector: String, files: [String], probe: [String: Any],
                                  authority: @escaping @MainActor () -> Bool, cancellation: NativeBrowserUploadCancellation) async throws -> [String: Any] {
        let tab = try requireTab(id), view = try requireView(id)
        let epoch = tab.documentEpoch, page = view.url?.absoluteString ?? ""
        guard let origin = BackendBrowserOrigin.exact(page), authority(), !cancellation.isCancelled, handoverPrompt(id) == nil else {
            throw BrowserDriverRefusal("The upload's document or permission changed.")
        }
        guard probe["inFrame"] as? Bool != true else { throw BrowserDriverRefusal("Uploading into another frame requires its own permission.") }
        let valid: @MainActor () -> Bool = { [weak self, weak tab, weak view] in
            guard let self, let tab, let view else { return false }
            return !cancellation.isCancelled && authority() && self.tabs.tab(id) === tab && tab.webView === view
                && tab.documentEpoch == epoch && view.url?.absoluteString == page && self.handoverPrompt(id) == nil
        }
        // This isolated-world token closes the WebKit queue race: a replacement
        // document cannot receive bytes even if it commits after the native check.
        let token = UUID().uuidString
        let binding = BrowserDriverScripts.with("(function(){var args = /*__DECK_ARGS__*/null || {}; window.__tdUploadDocument = args.token; return String(location.href);})()", args: ["token": token])
        let boundURL = try await js(view, binding, world: .defaultClient) as? String
        guard valid(), boundURL == page else { throw BrowserDriverRefusal("The upload document changed before the files were armed.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var urls: [URL] = [], total = 0
        for path in files {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if let why = BrowserUploadPolicy.refusal(path: path, resolved: resolved.path, home: home, protectedRoots: [dataRoot.path, dataRoot.resolvingSymlinksInPath().path]) {
                throw BrowserDriverRefusal(why)
            }
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { throw BrowserDriverRefusal("\(path) is not a file that exists on this Mac") }
            guard FileManager.default.isReadableFile(atPath: resolved.path) else { throw BrowserDriverRefusal("\(path) cannot be read") }
            let size = values?.fileSize ?? 0
            guard size <= BrowserUploadPolicy.maxFileBytes else { throw BrowserDriverRefusal("\(path) is larger than 50 MB; a step uploads files up to 50 MB") }
            total += size
            urls.append(resolved)
        }
        let names = urls.map(\.lastPathComponent)
        let isInput = (probe["tag"] as? String) == "input" && ((probe["type"] as? String) ?? "").lowercased() == "file"
        if probe["enabled"] as? Bool == false { throw BrowserDriverRefusal("that file field is disabled") }

        // 1. The page's own file chooser, answered with the files: what a person picking them does.
        tab.automation.armUpload(urls, origin: origin, authority: valid)
        defer { tab.automation.disarmUpload() }
        let opener = BrowserDriverScripts.with(BrowserDriverScripts.scriptedInput, args: ["action": "click", "selector": selector, "mainDocumentOnly": true])
        _ = try await js(view, Self.boundUploadScript(opener, token: token, page: page), world: .defaultClient)
        guard valid(), tab.automation.uploadArmed else { throw BrowserDriverRefusal("The upload was cancelled because the page or permission changed.") }
        if let given = await tab.automation.waitForUpload(timeout: .seconds(3)) {
            await pause(ms: 150)
            let check = try? await evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": selector]))
            var answer: [String: Any] = ["via": "file chooser", "count": given.count, "files": given.map(\.lastPathComponent)]
            if isInput, let have = (check as? [String: Any])?["files"] { answer["fieldHas"] = have }
            return answer
        }
        guard valid(), tab.automation.uploadArmed else { throw BrowserDriverRefusal("The upload was cancelled because the page or permission changed.") }
        // 2. No chooser opened (a drop zone, or a field the page keeps closed): hand the
        // files over in the page itself, as setInputFiles or a drop would.
        guard total <= BrowserUploadPolicy.maxScriptBytes else {
            throw BrowserDriverRefusal("the page did not open its file chooser, and \(total / 1_048_576) MB is more than the 25 MB a step can hand over directly. Point the upload at the page's file field or its upload button.")
        }
        var payload: [[String: Any]] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { throw BrowserDriverRefusal("\(url.path) could not be read") }
            let type = (UTTypeLookup.mime(for: url))
            let modified = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()).timeIntervalSince1970 * 1000
            payload.append(["name": url.lastPathComponent, "type": type, "data": data.base64EncodedString(), "lastModified": modified])
        }
        let script = BrowserDriverScripts.with(BrowserDriverScripts.files, args: ["selector": selector, "files": payload, "mode": isInput ? "input" : "drop", "mainDocumentOnly": true])
        guard valid(), tab.automation.uploadArmed else { throw BrowserDriverRefusal("The upload document or permission changed before delivery.") }
        let raw = (try await js(view, Self.boundUploadScript(script, token: token, page: page), world: .defaultClient)) as? [String: Any] ?? [:]
        guard raw["ok"] as? Bool == true else { throw BrowserDriverRefusal((raw["reason"] as? String) ?? "the page did not take the files") }
        var answer: [String: Any] = ["via": (raw["via"] as? String) == "drop" ? "drop" : "file field", "count": raw["count"] ?? names.count, "files": names]
        if let accepted = raw["accepted"] { answer["dropAccepted"] = accepted }
        return answer
    }

    static func boundUploadScript(_ script: String, token: String, page: String) -> String {
        let guardScript = BrowserDriverScripts.with("""
        var args = /*__DECK_ARGS__*/null || {};
        if (window !== window.top || window.__tdUploadDocument !== args.token || String(location.href) !== args.page)
            return {ok:false,reason:'The authorized upload document changed.'};
        """, args: ["token": token, "page": page])
        return "(function(){" + guardScript + "return (" + script + ");})()"
    }

    // MARK: Full page, one element, PDF

    func screenshot(_ id: String, options: BrowserScreenshotOptions) async throws -> (path: String, width: Int, height: Int, masked: Int) {
        if options.isPlain { return try await screenshot(id) }
        let view = try requireView(id)
        guard handoverPrompt(id) == nil else { throw refusal("The person has this page.") }
        parkIfHidden(id)
        let folder = RNMHootPaths(dataRoot: dataRoot).screenshots
        if let selector = options.selector {
            let shot = try await privacySnapshotPNG(id)
            let probe = (try await evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": selector]))) as? [String: Any] ?? [:]
            guard probe["found"] as? Bool == true else { throw BrowserDriverRefusal("nothing on the page matches that selector") }
            let rect = BrowserDriverEngine.rect(probe["rect"])
            let cssWidth = Double(view.bounds.width) / max(0.01, Double(view.pageZoom * view.magnification))
            let scale = Double(shot.width) / max(1, cssWidth)
            guard let source = CGImageSourceCreateWithData(shot.bytes as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw refusal("The picture could not be read back.") }
            let crop = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !crop.isNull, crop.width >= 1, crop.height >= 1, let part = image.cropping(to: crop),
                  let png = NSBitmapImageRep(cgImage: part).representation(using: .png, properties: [:]) else {
                throw BrowserDriverRefusal("that element is not inside the visible page; scroll it into view first")
            }
            let file = try savePNG(png, folder: folder, prefix: "element")
            return (file.path, part.width, part.height, shot.masked)
        }
        let guardState = (try await evaluate(id, BrowserDriverScripts.secretState)) as? [String: Any] ?? [:]
        if options.pdf {
            if ((guardState["filled"] as? NSNumber)?.intValue ?? 0) > 0 {
                throw BrowserDriverRefusal("a password, one-time-code or card field on this page holds a value, and a PDF would carry it. Use a screenshot (it paints those fields out), or save the PDF after the field is empty.")
            }
            let frames = (try? await js(view, Self.paymentFrames, world: .defaultClient)) as? Int ?? 0
            if frames > 0 { throw BrowserDriverRefusal("this page has a payment form from another site in it, which a PDF would carry unmasked. Use a screenshot instead.") }
            let data = try await view.pdf(configuration: WKPDFConfiguration())
            let size = Self.pdfSize(data)
            let file = try savePNG(data, folder: folder, prefix: "page", ext: "pdf")
            return (file.path, Int(size.width), Int(size.height), 0)
        }
        // Full page: WebKit draws the whole document as one PDF page; it becomes a PNG
        // here, with every password and card field (and unreadable frame) painted out.
        let raw = (try await js(view, Self.secretDocumentRectangles, world: .defaultClient)) as? [String: Any]
        guard let fields = raw, let values = fields["rects"] as? [[String: Any]] else { throw refusal("The page's privacy masks could not be read.") }
        let url = view.url
        let data = try await view.pdf(configuration: WKPDFConfiguration())
        guard handoverPrompt(id) == nil, view.url == url else { throw refusal("The page changed during capture; no image was saved.") }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
            throw refusal("WebKit did not draw the page.")
        }
        let box = page.getBoxRect(.mediaBox)
        let pixels = Double(box.width * box.height)
        let scale = min(2.0, 16_384 / Double(max(box.width, box.height)), (64_000_000 / max(1, pixels)).squareRoot())
        let width = max(1, Int(Double(box.width) * scale)), height = max(1, Int(Double(box.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw refusal("The full-page picture is too large to draw.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw refusal("The full-page picture could not be drawn.") }
        let documentWidth = (fields["width"] as? NSNumber)?.doubleValue ?? Double(box.width)
        let rectScale = Double(width) / max(1, documentWidth)
        let rects = values.map { CGRect(x: ($0["x"] as? NSNumber)?.doubleValue ?? 0, y: ($0["y"] as? NSNumber)?.doubleValue ?? 0,
                                        width: ($0["width"] as? NSNumber)?.doubleValue ?? 0, height: ($0["height"] as? NSNumber)?.doubleValue ?? 0) }
        let png = try NativeBrowserShotMask.maskedPNG(image, rects: rects, scale: rectScale)
        let file = try savePNG(png, folder: folder, prefix: "fullpage")
        return (file.path, width, height, rects.count)
    }

    static func pdfSize(_ data: Data) -> CGSize {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return .zero }
        return page.getBoxRect(.mediaBox).size
    }

    /// Cross-origin frames that look like a card form (they cannot be read, so they cannot be checked).
    static let paymentFrames = #"""
    (function(){var n=0,f=document.querySelectorAll('iframe,frame');for(var i=0;i<f.length;i++){var d=null;try{d=f[i].contentDocument}catch(e){}
    if(d)continue;var s=String(f[i].src||'')+' '+String(f[i].name||'')+' '+String(f[i].title||'');
    if(/(stripe|braintree|adyen|paypal|checkout|payment|card|klarna|square|worldpay|recurly|chargebee)/i.test(s))n++}return n})()
    """#

    /// The same masks as a visible screenshot (NativeSafariRuntime.secretRectangles), in
    /// document coordinates for a whole-page picture, plus the document's width.
    static let secretDocumentRectangles = #"""
    (function(){const rects=[];const sx=window.scrollX||0,sy=window.scrollY||0;
    function secret(e){const t=(e.getAttribute('type')||'').toLowerCase(); return e.matches('input,textarea')&&(t==='password'||
    /(password|one-time-code|cc-[a-z-]+)/i.test(e.getAttribute('autocomplete')||'')||/(card.?num|credit.?card|cc.?num|cvc|cvv|csc|one.?time.?code|password|passwd)/i.test((e.getAttribute('name')||'')+' '+e.id));}
    function walk(root,dx,dy){for(const e of root.querySelectorAll('*')){
    if(e.shadowRoot)walk(e.shadowRoot,dx,dy); const frame=e.matches('iframe,frame'); if(!frame&&!secret(e))continue;
    const b=e.getBoundingClientRect(); const r={x:b.x+dx,y:b.y+dy,width:b.width,height:b.height}; if(r.width<=0||r.height<=0)continue;
    let d=null; if(frame)try{d=e.contentDocument}catch(_){}
    if(!d){rects.push(r);continue;} const s=getComputedStyle(e);
    walk(d,r.x+e.clientLeft+parseFloat(s.paddingLeft||0),r.y+e.clientTop+parseFloat(s.paddingTop||0));}
    } walk(document,sx,sy); const se=document.scrollingElement||document.documentElement;
    return {rects, width: Math.max(se?se.scrollWidth:0, document.documentElement.clientWidth||0), height: se?se.scrollHeight:0};})()
    """#

    // MARK: browser_page: waits, scripts, dialogs, console, network, emulation, storage, collect

    func automationCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue? {
        if let why = BrowserAutomationPolicy.refusal(operation: operation, arguments: arguments,
                isolated: tab.isolated && !view.configuration.websiteDataStore.isPersistent) {
            throw refusal(why)
        }
        let automation = tab.automation
        switch operation {
        case "wait": return try await waitCommand(id, tab: tab, view: view, arguments: arguments)
        case "evaluate": return try await evaluateCommand(id, view: view, arguments: arguments)
        case "dialogs":
            if let raw = arguments["policy"].string {
                guard let policy = NativeBrowserAutomation.DialogPolicy(rawValue: raw) else { throw refusal("policy is ask, accept or dismiss.") }
                automation.dialogPolicy = policy
                automation.promptText = arguments["promptText"].string
                automation.dialogOnce = arguments["once"].bool ?? false
            }
            let rows: [NativeRPCValue] = automation.dialogs.suffix(20).map { record in
                .object([.init("kind", .string(record.kind)), .init("message", .string(record.message)), .init("site", .string(record.site)),
                         .init("answer", .string(record.answer)), .init("by", .string(record.by)), .init("at", .number(record.at.timeIntervalSince1970 * 1000))])
            }
            return .object([.init("policy", .string(automation.dialogPolicy.rawValue)), .init("once", .bool(automation.dialogOnce)),
                .init("promptText", automation.promptText.map { _ in .string("set") } ?? .null), .init("recent", .array(rows)),
                .init("url", .string(pageURL(id)))])
        case "console": return try await consoleCommand(id, tab: tab, view: view, arguments: arguments)
        case "requests": return try await requestsCommand(id, tab: tab, view: view, arguments: arguments)
        case "route": return try await routeCommand(id, tab: tab, view: view, arguments: arguments)
        case "emulate": return try await emulateCommand(id, tab: tab, view: view, arguments: arguments)
        case "permissions":
            if let raw = arguments["camera"].string {
                guard let policy = NativeBrowserAutomation.MediaPolicy(rawValue: raw) else { throw refusal("camera is ask, allow or deny.") }
                automation.camera = policy
            }
            if let raw = arguments["microphone"].string {
                guard let policy = NativeBrowserAutomation.MediaPolicy(rawValue: raw) else { throw refusal("microphone is ask, allow or deny.") }
                automation.microphone = policy
            }
            return .object([.init("camera", .string(automation.camera.rawValue)), .init("microphone", .string(automation.microphone.rawValue)),
                .init("note", .string("ask puts the question to the person on this tab. allow still needs the Mac's own permission for this app, which macOS asks the person once."))])
        case "storage": return try await storageCommand(id, view: view, arguments: arguments)
        case "collect": return try await collectCommand(id, tab: tab, view: view, arguments: arguments)
        default: return nil
        }
    }

    private func clampMs(_ value: Double?, fallback: Int, max upper: Int) -> Int { Int(min(Double(upper), max(0, value ?? Double(fallback)))) }

    private func waitCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let kind = arguments["for"].string ?? "load"
        let timeout = clampMs(arguments["timeoutMs"].number, fallback: 10_000, max: 60_000)
        let started = now()
        func left() -> Int { max(0, timeout - Int(now() - started)) }
        func answer(_ done: Bool, _ extra: [NativeRPCValue.Field] = []) -> NativeRPCValue {
            .object([.init("for", .string(kind)), .init("done", .bool(done)), .init("timedOut", .bool(!done)),
                     .init("waitedMs", .number(Double(Int(now() - started)))), .init("url", .string(pageURL(id)))] + extra)
        }
        switch kind {
        case "load":
            return answer(await tab.settle(timeout: .milliseconds(timeout)))
        case "url":
            let match = try BrowserURLMatch.matcher(try arguments["url"].requireString("url", nonempty: true))
            let done = await NativeBrowserSignalWait.until(timeout: .milliseconds(timeout)) { [weak tab] in match(tab?.url?.absoluteString ?? "") }
            if done { _ = await tab.settle(timeout: .milliseconds(left())) }
            return answer(done)
        case "selector", "text":
            var args: [String: Any] = ["kind": kind, "state": arguments["state"].string ?? "visible"]
            if kind == "selector" { args["selector"] = BrowserElementRef.selector(for: try arguments["selector"].requireString("selector", nonempty: true)) }
            else { args["text"] = try arguments["text"].requireString("text", nonempty: true) }
            while true {
                // A click that started a navigation: look at the page that loads, not the one going away.
                if tab.isLoading { _ = await tab.settle(timeout: .milliseconds(left())) }
                args["timeoutMs"] = left()
                let document = tab.documentEpoch
                do {
                    let raw = try await asyncJS(view, BrowserAsyncScripts.wait, ["args": args], world: .defaultClient, ms: left() + 1_000) as? [String: Any] ?? [:]
                    if raw["invalid"] as? Bool == true { throw refusal("that is not a selector this can read") }
                    if raw["done"] as? Bool != true, left() > 0, tab.documentEpoch != document || tab.isLoading { continue }
                    return answer(raw["done"] as? Bool == true, [.init("count", .number((raw["count"] as? NSNumber)?.doubleValue ?? 0))])
                } catch let refused as NativeRPCError where refused.code == "browser-refused" { throw refused }
                catch {
                    // The document was replaced mid-wait (or never answered): wait for the next one and look again.
                    guard left() > 0 else { return answer(false) }
                    _ = await tab.settle(timeout: .milliseconds(left()))
                    if tab.documentEpoch == document && !tab.isLoading { await pause(ms: 100) }
                }
            }
        case "function":
            let script = try arguments["script"].requireString("script", nonempty: true)
            guard script.utf8.count <= 65_536 else { throw refusal("The script is larger than 64 KB.") }
            try await refuseWhileSecretsFilled(id)
            let world: WKContentWorld = arguments["world"].string == "isolated" ? .defaultClient : .page
            let args: [String: Any] = ["timeoutMs": timeout, "arg": arguments["arg"].foundation ?? NSNull()]
            let raw: NativeRPCValue
            do { raw = try NativeRPCValue.fromFoundation(try await asyncJS(view, BrowserAsyncScripts.waitForFunction(script), ["args": args], world: world, ms: timeout + 2_000)) }
            catch { throw Self.scriptFailure(error) }
            let extra: [NativeRPCValue.Field] = raw["error"].string.map { [.init("lastError", .string(String($0.prefix(500))))] } ?? []
            return answer(raw["done"].bool == true, extra)
        case "networkidle":
            let quiet = clampMs(arguments["idleMs"].number, fallback: 500, max: 10_000)
            _ = await tab.settle(timeout: .milliseconds(timeout))
            while true {
                var idle = false
                if tab.automation.networkHookInstalled,
                   let state = try? await js(view, BrowserPageHooks.networkIdle, world: .page) as? [String: Any] {
                    idle = (state["inflight"] as? NSNumber)?.intValue == 0 && ((state["idleFor"] as? NSNumber)?.intValue ?? 0) >= quiet && state["ready"] as? String == "complete"
                } else if let state = try? await js(view, Self.resourceQuiet, world: .defaultClient) as? [String: Any] {
                    idle = ((state["idleFor"] as? NSNumber)?.intValue ?? 0) >= quiet && state["ready"] as? String == "complete"
                }
                if idle && !tab.isLoading { return answer(true, [.init("method", .string(tab.automation.networkHookInstalled ? "requests in flight" : "resource timing"))]) }
                if left() <= 0 { return answer(false) }
                await pause(ms: 100)
            }
        case "download":
            let known = Set(tabs.downloads.items.map(\.id))
            func finished(_ item: NativeBrowserDownloads.Item) -> Bool { item.state != .running }
            func recent(_ item: NativeBrowserDownloads.Item) -> Bool {
                guard let path = item.destination?.path, let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
                return Date().timeIntervalSince(date) < 30
            }
            let runningAtStart = Set(tabs.downloads.items.filter { $0.state == .running }.map(\.id))
            var found: NativeBrowserDownloads.Item?
            let done = await NativeBrowserSignalWait.until(timeout: .milliseconds(timeout)) { [weak self] in
                guard let self else { return true }
                found = self.tabs.downloads.items.first { item in
                    finished(item) && (!known.contains(item.id) || runningAtStart.contains(item.id) || recent(item))
                }
                return found != nil
            }
            guard done, let item = found else { return answer(false) }
            let state: String
            switch item.state { case .finished: state = "done"; case .cancelled: state = "cancelled"; case .failed(let why): state = "failed: " + why; case .running: state = "downloading" }
            return answer(true, [.init("name", .string(item.name)), .init("path", .string(item.destination?.path ?? "")),
                                 .init("source", .string(item.source?.absoluteString ?? "")), .init("bytes", .number(Double(item.received))),
                                 .init("state", .string(state))])
        case "time":
            await pause(ms: min(timeout, 30_000))
            return answer(true)
        default:
            throw refusal("for is load, networkidle, url, selector, text, function, download or time.")
        }
    }

    static let resourceQuiet = #"""
    (function(){var e=performance.getEntriesByType('resource'),last=0;for(var i=0;i<e.length;i++){last=Math.max(last,e[i].responseEnd||0)}
    var nav=performance.getEntriesByType('navigation')[0];if(nav)last=Math.max(last,nav.loadEventEnd||0);
    return {idleFor:Math.round(performance.now()-last),ready:document.readyState}})()
    """#

    func refuseWhileSecretsFilled(_ id: String) async throws {
        let state = (try await evaluate(id, BrowserDriverScripts.secretState)) as? [String: Any] ?? [:]
        if ((state["filled"] as? NSNumber)?.intValue ?? 0) > 0 {
            throw BrowserDriverRefusal("a password, one-time-code or card field on this page holds a value, so no script runs here (it could read it). Use browser.read and browser.step, or hand the page to the person.")
        }
    }

    private func evaluateCommand(_ id: String, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let script = try arguments["script"].requireString("script", nonempty: true)
        guard script.utf8.count <= 65_536 else { throw refusal("The script is larger than 64 KB.") }
        try await refuseWhileSecretsFilled(id)
        let world: WKContentWorld = arguments["world"].string == "isolated" ? .defaultClient : .page
        let timeout = clampMs(arguments["timeoutMs"].number, fallback: 30_000, max: 120_000)
        let arg = arguments["arg"].foundation ?? NSNull()
        func run(_ asBody: Bool) async throws -> NativeRPCValue {
            try await NativeBrowserRace.within(timeout) {
                try NativeRPCValue.fromFoundation(try await view.callAsyncJavaScript(BrowserAsyncScripts.evaluate(script, asBody: asBody),
                                                                                   arguments: ["arg": arg], in: nil, contentWorld: world))
            }
        }
        var raw: NativeRPCValue
        do { raw = try await run(false) }
        catch where Self.scriptMessage(error)?.contains("SyntaxError") == true {
            do { raw = try await run(true) } catch { throw Self.scriptFailure(error) }
        } catch { throw Self.scriptFailure(error) }
        let json = raw["json"].string ?? "null"
        let truncated = raw["truncated"].bool == true
        let value: NativeRPCValue = truncated ? .string(json) : ((try? NativeRPCValue.parseJSON(Data(json.utf8))) ?? .string(json))
        var fields: [NativeRPCValue.Field] = [.init("value", value), .init("world", .string(world == .page ? "page" : "isolated")), .init("url", .string(pageURL(id)))]
        if truncated { fields.append(.init("truncated", .bool(true))); fields.append(.init("chars", raw["chars"])) }
        return .object(fields)
    }

    static func scriptMessage(_ error: Error) -> String? {
        let ns = error as NSError
        return ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? (ns.domain == WKErrorDomain ? ns.localizedDescription : nil)
    }

    static func scriptFailure(_ error: Error) -> Error {
        if error is BrowserDriverRefusal || error is NativeRPCError { return error }
        if let message = scriptMessage(error) {
            let number = ((error as NSError).userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber)?.intValue ?? 0
            let line = number > 0 ? " (line \(number))" : ""
            return BrowserDriverRefusal("the script threw: \(message.prefix(800))\(line)")
        }
        return error
    }

    private func installUserScript(_ view: WKWebView, _ source: String) {
        view.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
    }

    private func consoleCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        var note = ""
        let present = (try? await js(view, BrowserPageHooks.with(BrowserPageHooks.readConsole, argument: 1e15), world: .page)) as? [String: Any] != nil
        if !present {
            if !tab.automation.consoleArmed {
                installUserScript(view, BrowserPageHooks.console(auto: false))
                tab.automation.consoleArmed = true
            }
            _ = try? await js(view, BrowserPageHooks.console(auto: false), world: .page)
            note = "Console capture is on for this tab from now. Reload the page (browser_page reload) to catch what it logs while it loads."
        }
        if arguments["clear"].bool == true { _ = try? await js(view, BrowserPageHooks.clearConsole, world: .page) }
        let since = arguments["since"].number ?? 0
        let raw = (try await js(view, BrowserPageHooks.with(BrowserPageHooks.readConsole, argument: since), world: .page)) as? [String: Any] ?? [:]
        let levels = Set((arguments["level"].string ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        let limit = Int(min(1_000, max(1, arguments["limit"].number ?? 200)))
        var entries = ((raw["entries"] as? [[String: Any]]) ?? []).filter { levels.isEmpty || levels.contains(($0["level"] as? String ?? "").lowercased()) }
        let total = entries.count
        if entries.count > limit { entries = Array(entries.suffix(limit)) }
        return .object([.init("entries", try NativeRPCValue.fromFoundation(entries)), .init("count", .number(Double(entries.count))),
            .init("total", .number(Double(total))), .init("dropped", .number((raw["dropped"] as? NSNumber)?.doubleValue ?? 0)),
            .init("last", .number((raw["last"] as? NSNumber)?.doubleValue ?? 0)), .init("note", .string(note)), .init("url", .string(pageURL(id)))])
    }

    /// The page-world network hook for this tab: installed for every later document
    /// of the tab, and in the current one now. Config changes reach both.
    private func applyNetwork(_ tab: NativeBrowserTab, _ view: WKWebView) async {
        let config = tab.automation.networkConfig
        if !tab.automation.networkHookInstalled {
            installUserScript(view, BrowserPageHooks.network(config: config))
            tab.automation.networkHookInstalled = true
        } else {
            installUserScript(view, BrowserPageHooks.configureNetwork(config))
        }
        _ = try? await js(view, BrowserPageHooks.network(config: config), world: .page)
    }

    private func requestsCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        var note = ""
        let wasInstalled = tab.automation.networkHookInstalled
        if let bodies = arguments["bodies"].bool { tab.automation.networkConfig["bodies"] = bodies }
        if !wasInstalled || arguments["bodies"].bool != nil { await applyNetwork(tab, view) }
        if !wasInstalled { note = "The request log is on for this tab from now. Reload the page (browser_page reload) to see the requests it makes while loading." }
        if arguments["clear"].bool == true { _ = try? await js(view, BrowserPageHooks.clearNetwork, world: .page) }
        let since = arguments["since"].number ?? 0
        let raw = (try await js(view, BrowserPageHooks.with(BrowserPageHooks.readNetwork, argument: since), world: .page)) as? [String: Any] ?? [:]
        let filter = arguments["url"].string?.lowercased()
        let method = arguments["method"].string?.uppercased()
        let limit = Int(min(500, max(1, arguments["limit"].number ?? 100)))
        var hidden = 0
        var entries: [[String: Any]] = ((raw["entries"] as? [[String: Any]]) ?? []).compactMap { entry in
            if let filter, !((entry["url"] as? String) ?? "").lowercased().contains(filter) { return nil }
            if let method, (entry["method"] as? String) != method { return nil }
            var row = entry
            for key in ["requestHeaders", "responseHeaders"] {
                let scrubbed = BrowserNetworkScrub.headers(entry[key]); row[key] = scrubbed.value; hidden += scrubbed.hidden
            }
            for key in ["requestBody", "responseBody"] {
                let scrubbed = BrowserNetworkScrub.body(entry[key] as? String); row[key] = scrubbed.value; hidden += scrubbed.hidden
            }
            return row
        }
        let total = entries.count
        if entries.count > limit { entries = Array(entries.suffix(limit)) }
        var resources = (raw["resources"] as? [[String: Any]]) ?? []
        if let filter { resources = resources.filter { (($0["url"] as? String) ?? "").lowercased().contains(filter) } }
        var fields: [NativeRPCValue.Field] = [.init("entries", try NativeRPCValue.fromFoundation(entries)), .init("count", .number(Double(entries.count))),
            .init("total", .number(Double(total))), .init("inflight", .number((raw["inflight"] as? NSNumber)?.doubleValue ?? 0)),
            .init("dropped", .number((raw["dropped"] as? NSNumber)?.doubleValue ?? 0)), .init("last", .number((raw["last"] as? NSNumber)?.doubleValue ?? 0)),
            .init("hiddenSecrets", .number(Double(hidden))), .init("bodies", .bool(tab.automation.networkConfig["bodies"] as? Bool == true)),
            .init("scope", .string("The page's own fetch and XMLHttpRequest calls with headers and bodies; images, scripts, styles and the page itself as timing rows only (WebKit gives a page no more).")),
            .init("note", .string(note)), .init("url", .string(pageURL(id)))]
        if arguments["resources"].bool == true { fields.append(.init("resources", try NativeRPCValue.fromFoundation(Array(resources.suffix(500))))) }
        else { fields.append(.init("resourceCount", .number(Double(resources.count)))) }
        if arguments["har"].bool == true {
            let har = BrowserHAR.make(pageURL: pageURL(id), title: tab.title, entries: entries, resources: resources)
            let data = try JSONSerialization.data(withJSONObject: har, options: [.prettyPrinted, .sortedKeys])
            let file = try savePNG(data, folder: RNMHootPaths(dataRoot: dataRoot).screenshots, prefix: "network", ext: "har")
            fields.append(.init("har", .string(file.path)))
        }
        return .object(fields)
    }

    private func routeCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let automation = tab.automation
        let controller = view.configuration.userContentController
        var hookChanged = false
        if arguments["clear"].bool == true {
            if let list = automation.blockList { controller.remove(list); automation.blockList = nil }
            if let list = automation.offlineList { controller.remove(list); automation.offlineList = nil }
            automation.blockPatterns = []; automation.extraHeaders = [:]
            automation.networkConfig["routes"] = []; automation.networkConfig["headers"] = [:]; automation.networkConfig["offline"] = false
            hookChanged = automation.networkHookInstalled
        }
        if let block = arguments["block"].elements {
            let patterns = block.compactMap(\.string)
            guard patterns.count == block.count, patterns.count <= 200 else { throw refusal("block is a list of up to 200 URL patterns.") }
            let types = arguments["types"].elements?.compactMap(\.string)
            if let list = automation.blockList { controller.remove(list); automation.blockList = nil }
            automation.blockPatterns = patterns
            if !patterns.isEmpty {
                let json = try BrowserContentRules.blockList(patterns, types: types)
                guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "td-b27-block-\(id)", encodedContentRuleList: json) else {
                    throw refusal("WebKit could not read those block patterns.")
                }
                controller.add(list); automation.blockList = list
            }
        }
        if let mocks = arguments["mock"].elements {
            guard mocks.count <= 100 else { throw refusal("mock takes up to 100 routes.") }
            var routes: [[String: Any]] = []
            for mock in mocks {
                let url = try mock["url"].requireString("mock url", nonempty: true)
                var route: [String: Any] = ["url": url, "action": mock["abort"].bool == true ? "abort" : "fulfill"]
                if let method = mock["method"].string { route["method"] = method }
                if let status = mock["status"].number { route["status"] = Int(status) }
                if let body = mock["body"].string { guard body.utf8.count <= 1_048_576 else { throw refusal("A mocked body is at most 1 MB.") }; route["body"] = body }
                else if !mock["json"].isNullish { route["body"] = mock["json"].compact; route["contentType"] = "application/json" }
                if let type = mock["contentType"].string { route["contentType"] = type }
                if let headers = mock["headers"].foundation as? [String: Any] { route["headers"] = headers.mapValues { String(describing: $0) } }
                routes.append(route)
            }
            automation.networkConfig["routes"] = routes; hookChanged = true
        }
        if let headers = arguments["headers"].fields {
            var extra: [String: String] = [:]
            for field in headers {
                guard let value = field.value.string else { throw refusal("Each header value is text.") }
                let name = field.key.lowercased()
                guard !["cookie", "host", "content-length", "origin", "referer"].contains(name) else { throw refusal("\(field.key) cannot be set from here.") }
                extra[field.key] = value
            }
            automation.extraHeaders = extra; automation.networkConfig["headers"] = extra; hookChanged = true
        }
        if let offline = arguments["offline"].bool {
            if let list = automation.offlineList { controller.remove(list); automation.offlineList = nil }
            if offline {
                guard let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "td-b27-offline", encodedContentRuleList: BrowserContentRules.offlineList) else {
                    throw refusal("WebKit could not turn on offline mode.")
                }
                controller.add(list); automation.offlineList = list
            }
            automation.networkConfig["offline"] = offline; hookChanged = true
        }
        if hookChanged { await applyNetwork(tab, view) }
        return .object([.init("block", .array(automation.blockPatterns.map(NativeRPCValue.string))),
            .init("mock", .number(Double((automation.networkConfig["routes"] as? [Any])?.count ?? 0))),
            .init("headers", .array(automation.extraHeaders.keys.sorted().map(NativeRPCValue.string))),
            .init("offline", .bool(automation.networkConfig["offline"] as? Bool == true)),
            .init("scope", .string("Blocking and offline stop every kind of load (WebKit content rules). Mocks answer the page's fetch and XMLHttpRequest calls. Extra headers go on navigations the tools start and on the page's same-origin fetch/XHR.")),
            .init("url", .string(pageURL(id)))])
    }

    private func emulateCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let automation = tab.automation
        var scriptChanged = false
        if arguments["reset"].bool == true {
            automation.viewport = nil; tab.deviceID = nil; view.appearance = nil
            if !automation.emulation.isEmpty { automation.emulation = [:]; scriptChanged = true }
        }
        if let device = arguments["device"].string {
            guard let preset = BrowserDevicePreset.byID(device) else {
                throw refusal("device is one of: \(BrowserDevicePreset.all.map(\.id).joined(separator: ", ")).")
            }
            tab.deviceID = preset.id; tab.deviceLandscape = arguments["landscape"].bool ?? false
            automation.viewport = tab.deviceLandscape ? CGSize(width: preset.height, height: preset.width) : CGSize(width: preset.width, height: preset.height)
        }
        if !arguments["viewport"].isNullish {
            guard let width = arguments["viewport"]["width"].number, let height = arguments["viewport"]["height"].number,
                  (Double(BRDeviceSize.minimum)...Double(BRDeviceSize.maximum)).contains(width),
                  (Double(BRDeviceSize.minimum)...Double(BRDeviceSize.maximum)).contains(height) else {
                throw refusal("viewport is {width, height}, each \(BRDeviceSize.minimum) to \(BRDeviceSize.maximum) pixels.")
            }
            tab.deviceID = BRDeviceSize.customID; tab.deviceLandscape = false
            tab.customWidth = String(Int(width)); tab.customHeight = String(Int(height))
            automation.viewport = CGSize(width: Int(width), height: Int(height))
        }
        resizeParked(id)
        if let scheme = arguments["colorScheme"].string {
            switch scheme {
            case "dark": view.appearance = NSAppearance(named: .darkAqua)
            case "light": view.appearance = NSAppearance(named: .aqua)
            case "system": view.appearance = nil
            default: throw refusal("colorScheme is light, dark or system.")
            }
        }
        if let locale = arguments["locale"].string {
            guard locale.isEmpty || locale.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else { throw refusal("locale is a language tag like en-GB or ur-PK.") }
            automation.emulation["locale"] = locale.isEmpty ? nil : locale; scriptChanged = true
        }
        if let zone = arguments["timezone"].string {
            guard zone.isEmpty || TimeZone(identifier: zone) != nil else { throw refusal("timezone is an IANA name like Asia/Dubai.") }
            automation.emulation["timezone"] = zone.isEmpty ? nil : zone; scriptChanged = true
        }
        if arguments.has("geolocation") {
            if arguments["geolocation"].isNullish { automation.emulation["geolocation"] = nil }
            else {
                guard let latitude = arguments["geolocation"]["latitude"].number, let longitude = arguments["geolocation"]["longitude"].number,
                      (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw refusal("geolocation is {latitude, longitude, accuracy?}.") }
                automation.emulation["geolocation"] = ["latitude": latitude, "longitude": longitude, "accuracy": arguments["geolocation"]["accuracy"].number ?? 10]
            }
            scriptChanged = true
        }
        if scriptChanged {
            let script = BrowserPageHooks.emulate(automation.emulation)
            installUserScript(view, script)
            automation.emulationInstalled = true
            _ = try? await js(view, script, world: .page)
        }
        let viewport: NativeRPCValue = automation.viewport.map { .object([.init("width", .number(Double($0.width))), .init("height", .number(Double($0.height)))]) } ?? .null
        let appearance = view.appearance?.name == .darkAqua ? "dark" : view.appearance?.name == .aqua ? "light" : "system"
        return .object([.init("viewport", viewport), .init("device", tab.deviceID.map(NativeRPCValue.string) ?? .null),
            .init("colorScheme", .string(appearance)), .init("emulation", try NativeRPCValue.fromFoundation(automation.emulation)),
            .init("onScreen", .bool(NativeBrowserPageDelegate.onScreen(view))),
            .init("scope", .string("Viewport and device size the page (on screen it is shrunk to fit the window). Locale, timezone and geolocation are what the page's scripts see; the Mac's own settings and the language header stay as they are. The user agent is browser_page useragent.")),
            .init("url", .string(pageURL(id)))])
    }

    private func storageCommand(_ id: String, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let mode = arguments["mode"].string ?? "export"
        guard let page = view.url, let host = page.host()?.lowercased(), ["http", "https"].contains(page.scheme ?? "") else {
            throw refusal("Storage belongs to a web page; open one first.")
        }
        let store = view.configuration.websiteDataStore.httpCookieStore
        func cookieMatches(_ domain: String) -> Bool {
            let bare = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == bare || host.hasSuffix("." + bare)
        }
        switch mode {
        case "export":
            let storage = try await asyncJS(view, Self.storageExport, [:], world: .defaultClient)
            let cookies = await store.allCookies().filter { cookieMatches($0.domain) }.map { cookie -> [String: Any] in
                var row: [String: Any] = ["name": cookie.name, "domain": cookie.domain, "path": cookie.path, "secure": cookie.isSecure,
                                          "httpOnly": cookie.isHTTPOnly, "sameSite": cookie.sameSitePolicy?.rawValue ?? ""]
                if let expires = cookie.expiresDate { row["expires"] = expires.timeIntervalSince1970 }
                // A page's own scripts can read these anyway; HttpOnly ones (sign-ins) never leave the browser.
                row["value"] = cookie.isHTTPOnly ? NSNull() : cookie.value
                return row
            }
            var fields = ((try? NativeRPCValue.fromFoundation(storage)) ?? .object([])).fields ?? []
            fields.append(.init("cookies", try NativeRPCValue.fromFoundation(cookies)))
            fields.append(.init("note", .string("HttpOnly cookie values (how sites keep you signed in) are never exported.")))
            return .object(fields)
        case "import":
            var setLocal = 0, setSession = 0, setCookies = 0
            let local = arguments["localStorage"].foundation as? [String: Any] ?? [:]
            let session = arguments["sessionStorage"].foundation as? [String: Any] ?? [:]
            if !local.isEmpty || !session.isEmpty {
                let raw = try await view.callAsyncJavaScript(Self.storageImport, arguments: ["local": local.mapValues { String(describing: $0) }, "session": session.mapValues { String(describing: $0) }],
                                                             in: nil, contentWorld: .defaultClient) as? [String: Any] ?? [:]
                setLocal = (raw["local"] as? NSNumber)?.intValue ?? 0; setSession = (raw["session"] as? NSNumber)?.intValue ?? 0
            }
            for cookie in arguments["cookies"].elements ?? [] {
                let name = try cookie["name"].requireString("cookie name", nonempty: true)
                let domain = cookie["domain"].string ?? host
                guard cookieMatches(domain) else { throw refusal("A cookie for \(domain) cannot be set from a page on \(host).") }
                var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: cookie["value"].string ?? "", .domain: domain,
                                                                .path: cookie["path"].string ?? "/"]
                if cookie["secure"].bool == true { properties[.secure] = "TRUE" }
                if let expires = cookie["expires"].number { properties[.expires] = Date(timeIntervalSince1970: expires) }
                if let same = cookie["sameSite"].string { properties[HTTPCookiePropertyKey("SameSite")] = same }
                if cookie["httpOnly"].bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                guard let made = HTTPCookie(properties: properties) else { throw refusal("The cookie \(name) is not valid.") }
                await store.setCookie(made); setCookies += 1
            }
            return .object([.init("localStorage", .number(Double(setLocal))), .init("sessionStorage", .number(Double(setSession))),
                            .init("cookies", .number(Double(setCookies))), .init("url", .string(page.absoluteString))])
        case "clear":
            _ = try await asyncJS(view, "try{localStorage.clear()}catch(e){} try{sessionStorage.clear()}catch(e){} return true;", [:], world: .defaultClient)
            var removed = 0
            if arguments["cookies"].bool == true {
                for cookie in await store.allCookies() where cookieMatches(cookie.domain) { await store.deleteCookie(cookie); removed += 1 }
            }
            return .object([.init("cleared", .bool(true)), .init("cookiesRemoved", .number(Double(removed))), .init("url", .string(page.absoluteString))])
        default:
            throw refusal("mode is export, import or clear.")
        }
    }

    static let storageExport = #"""
    var read = function (s) { var out = {}, n = 0; try { for (var i = 0; i < s.length && n < 1000; i++) { var k = s.key(i); var v = s.getItem(k); out[k] = v && v.length > 100000 ? v.slice(0, 100000) : v; n++ } } catch (e) {} return out };
    return { origin: String(location.origin), localStorage: read(window.localStorage), sessionStorage: read(window.sessionStorage) };
    """#
    static let storageImport = #"""
    var put = function (s, items) { var n = 0; try { for (var k in items) { s.setItem(k, String(items[k])); n++ } } catch (e) {} return n };
    return { local: put(window.localStorage, local || {}), session: put(window.sessionStorage, session || {}) };
    """#

    /// Records across pages: read rows, then follow "next" (or scroll for more),
    /// until there are no more, the limit, or the page leaves the site.
    private func collectCommand(_ id: String, tab: NativeBrowserTab, view: WKWebView, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let rows = BrowserElementRef.selector(for: try arguments["rows"].requireString("rows", nonempty: true))
        let next = arguments["next"].string.map(BrowserElementRef.selector(for:))
        let scroll = arguments["scroll"].bool == true
        guard next != nil || scroll else { throw refusal("collect needs next (the selector of the next-page link) or scroll: true.") }
        let maxPages = Int(min(50, max(1, arguments["maxPages"].number ?? 5)))
        let maxRows = Int(min(5_000, max(1, arguments["maxRows"].number ?? 500)))
        let fields = arguments["fields"].foundation as? [String: Any]
        let origin = BackendBrowserOrigin.exact(pageURL(id))
        var collected: [[String: Any]] = [], seen = Set<String>(), pages = 0, stopped = "the page limit"
        var stalls = 0
        func read() async throws -> [[String: Any]] {
            var args: [String: Any] = ["mode": "extract", "rows": rows, "limit": maxRows]
            if let fields { args["fields"] = fields }
            let raw = (try await evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.readMode, args: args))) as? [String: Any] ?? [:]
            if raw["invalid"] as? Bool == true { throw BrowserDriverRefusal("rows is not a selector this can read") }
            return (raw["rows"] as? [[String: Any]]) ?? []
        }
        while pages < maxPages {
            pages += 1
            var added = 0
            for row in try await read() {
                let key = String(decoding: (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
                if seen.insert(key).inserted { collected.append(row); added += 1 }
                if collected.count >= maxRows { break }
            }
            if collected.count >= maxRows { stopped = "the row limit"; break }
            if pages >= maxPages { stopped = "the page limit"; break }
            if let next {
                let probe = (try await evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.probe, args: ["selector": next]))) as? [String: Any] ?? [:]
                guard probe["found"] as? Bool == true, probe["visible"] as? Bool == true, probe["enabled"] as? Bool == true else { stopped = "no next page"; break }
                let before = pageURL(id)
                _ = try await evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.scriptedInput, args: ["action": "click", "selector": next]))
                // A link loads a new page; a script swaps rows in place. Wait for either.
                _ = await NativeBrowserSignalWait.until(timeout: .seconds(3)) { [weak tab] in tab?.isLoading == true || (tab?.url?.absoluteString ?? before) != before }
                _ = await tab.settle(timeout: .seconds(15))
                await pause(ms: 400)
                if let origin, BackendBrowserOrigin.exact(pageURL(id)) != origin { stopped = "the next page is on another site"; break }
            } else {
                _ = try await evaluate(id, BrowserDriverScripts.with(BrowserDriverScripts.domAction, args: ["action": "scroll", "x": 0, "y": 100_000]))
                await pause(ms: 1_200)
                if added == 0 { stalls += 1 } else { stalls = 0 }
                if stalls >= 2 { stopped = "nothing more loaded"; break }
            }
        }
        return .object([.init("rows", try NativeRPCValue.fromFoundation(collected)), .init("count", .number(Double(collected.count))),
            .init("pages", .number(Double(pages))), .init("stoppedBecause", .string(stopped)), .init("url", .string(pageURL(id)))])
    }
}

/// The first of a script's answer and a deadline: a page script that never
/// settles returns a refusal to the agent instead of holding its call forever.
@MainActor
enum NativeBrowserRace {
    static func within<T: Sendable>(_ ms: Int, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = NativeBrowserRaceGate()
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do { let value = try await body(); if !once.done { once.done = true; continuation.resume(returning: value) } }
                catch { if !once.done { once.done = true; continuation.resume(throwing: error) } }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(ms))
                if !once.done { once.done = true; continuation.resume(throwing: BrowserDriverRefusal("the page script did not finish within \(ms) ms")) }
            }
        }
    }
}

@MainActor final class NativeBrowserRaceGate { var done = false }

/// A WebKit answer carried across the race (it is only ever read on the main actor).
struct NativeBrowserUnchecked: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

enum UTTypeLookup {
    static func mime(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.preferredMIMEType) ?? "application/octet-stream"
    }
}
