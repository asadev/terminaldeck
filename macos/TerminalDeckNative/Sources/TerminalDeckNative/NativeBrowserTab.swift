import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// One browser tab: its page (a WKWebView — Safari's engine) and what the
/// screen shows about it. A tab restored from the last launch keeps only its
/// address and title until it is first shown, then loads.
@MainActor
@Observable
final class NativeBrowserTab: Identifiable {
    let id: String
    /// Own cookies, in memory only — the web browser's Shared/Isolated toggle.
    private(set) var isolated: Bool
    /// The browser profile whose cookies the tab uses ("" = the default one).
    private(set) var profile: String

    private(set) var title: String
    /// The page's address — nil while the tab shows "Open a page".
    private(set) var url: URL?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var favicon: NSImage?
    private(set) var zoom: Double = 1
    /// The last load failed; the start view shows why, above the ports list.
    private(set) var failure: LoadFailure?
    var findText = ""
    private(set) var findMissed = false
    var findVisible = false
    /// Bumped to put the caret in the find field / the address field.
    private(set) var focusFindRequest = 0
    private(set) var focusAddressRequest = 0
    /// The screenshot waiting in the Shot popover.
    var pendingShot: NativeBrowserShot?
    /// Safe offer metadata only. Password bytes stay in the private adapter.
    var savedSignInOffer: NativeRPCValue?
    var savedPasswordOffer: BackendBrowserPasswordOffer?
    var savedLoginPending = false
    var savedLoginMessage: String?
    @ObservationIgnored private(set) var documentEpoch = UUID()
    /// The "Size" frame: a device preset id, or nil to fill the room.
    var deviceID: String?
    var deviceLandscape = false
    /// "Custom" in Size: the typed width and height (DeviceBar.tsx; 200–4000 each).
    var customWidth = BRDeviceSize.defaultWidth
    var customHeight = BRDeviceSize.defaultHeight
    /// The recorded flow's panel, put away (TS: the flow popup closed; ⋮ ▸ Recorded flow brings it back).
    var flowHidden = false
    /// ⋮ ▸ History, open over this tab.
    var historyShown = false
    /// Present the page as a phone (the web browser's mobile user agent).
    private(set) var mobileUserAgent = false
    /// Home with no start page set: show "Open a page" over whatever was there.
    private(set) var showingHome = false
    /// An agent handed this page to the person (`browser_handover`): what it asks.
    /// While set, the agent can neither read nor act on the page.
    private(set) var handoverPrompt: String?
    /// The agent's waiting call, answered with the handover's outcome.
    @ObservationIgnored var handoverWaiter: ((String) -> Void)?

    /// Annotate or Draw: the page frozen as a picture, marked over the top.
    enum Markup: Equatable {
        case annotate(NativeBrowserShot)
        case draw(NativeBrowserShot)
        var shot: NativeBrowserShot {
            switch self {
            case .annotate(let shot), .draw(let shot): shot
            }
        }
    }
    var markup: Markup?
    /// Annotate's first half (lane BR, TS `inspecting`): the live page outlines what
    /// is under the pointer and a click freezes it as marker 1.
    private(set) var inspecting = false
    /// That click's element, for the Annotate surface to start from.
    @ObservationIgnored private var annotateStart: BrowserAnnotation?
    /// Record: the steps taken on the page while recording.
    private(set) var recording = false
    private(set) var steps: [BrowserRecordedStep] = []
    /// The address field's suggestions while it is being edited, and the chosen row.
    var suggestions: [BrowserVisit] = []
    var suggestionCursor = -1
    @ObservationIgnored private var suggestionEpoch = UUID()

    struct LoadFailure: Equatable {
        let message: String
        let url: URL?
    }

    private(set) var webView: NativeBrowserWebView?
    @ObservationIgnored private weak var owner: NativeBrowserTabs?
    /// The address to load when the page is first made (a restored tab).
    @ObservationIgnored private var pendingURL: URL?
    /// WebKit's configuration for a page that asked for this window.
    @ObservationIgnored private var givenConfiguration: WKWebViewConfiguration?
    /// Made for a page's window request: WebKit loads it, so no start view meanwhile.
    @ObservationIgnored private var awaitingWebKitLoad = false
    @ObservationIgnored private var delegate: NativeBrowserPageDelegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var ownedLoad: Task<Void, Never>?
    @ObservationIgnored private var ownedLoadEpoch = UUID()

    init(record: BrowserTabRecord, owner: NativeBrowserTabs, configuration: WKWebViewConfiguration? = nil) {
        id = record.id
        isolated = record.isolated
        profile = record.profile
        title = record.title
        url = record.url.isEmpty ? nil : URL(string: record.url)
        pendingURL = url
        self.owner = owner
        givenConfiguration = configuration
        awaitingWebKitLoad = configuration != nil
    }

    // MARK: What the screen shows

    var showsStartView: Bool {
        if failure != nil || showingHome { return true }
        if awaitingWebKitLoad { return false }
        return url == nil && !isLoading
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host(), !host.isEmpty { return host }
        if url != nil { return url!.absoluteString }
        return "New Tab"
    }

    // MARK: The page

    /// Make the page if it does not exist yet (and load the remembered address).
    func ensurePage() {
        guard webView == nil, let owner else { return }
        let configuration = givenConfiguration ?? owner.makeConfiguration(profile: profile, isolated: isolated)
        owner.browserComposition?.prepareConfiguration(configuration)
        givenConfiguration = nil
        let view = NativeBrowserWebView(frame: .zero, configuration: configuration)
        view.isInspectable = true // Safari ▸ Develop ▸ <this Mac> lists every tab
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        if mobileUserAgent { view.customUserAgent = BrowserDevicePreset.mobileUserAgent }
        view.pageZoom = zoom
        let delegate = NativeBrowserPageDelegate(tab: self)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        self.delegate = delegate
        webView = view
        observe(view)
        owner.browserComposition?.attached(self)
        if let pendingURL {
            self.pendingURL = nil
            loadView(view, target: pendingURL)
        }
    }

    /// Stop everything and let the page go.
    func tearDown() {
        owner?.browserComposition?.detached(self)
        ownedLoadEpoch = UUID(); ownedLoad?.cancel(); ownedLoad = nil
        if handoverPrompt != nil { endHandover("drive-ended") }
        faviconTask?.cancel()
        observations.forEach { $0.invalidate() }
        observations = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        delegate = nil
    }

    func load(_ target: URL) {
        ensurePage()
        failure = nil
        showingHome = false
        url = target
        if let webView { loadView(webView, target: target) }
    }

    private func loadView(_ view: WKWebView, target: URL) {
        guard let composition = owner?.browserComposition else { view.load(URLRequest(url: target)); return }
        ownedLoad?.cancel(); ownedLoadEpoch = UUID()
        let epoch = ownedLoadEpoch
        isLoading = true; awaitingWebKitLoad = true
        ownedLoad = Task { [weak self, weak view] in
            guard let self, let view else { return }
            defer { if self.ownedLoadEpoch == epoch { self.ownedLoad = nil } }
            do {
                try await composition.prepareNavigation(self, url: target)
                try Task.checkCancellation()
                guard self.ownedLoadEpoch == epoch, self.webView === view else { return }
                view.load(URLRequest(url: target))
            } catch {
                guard self.ownedLoadEpoch == epoch else { return }
                self.awaitingWebKitLoad = false; self.isLoading = false
                if !(error is CancellationError) {
                    self.failure = .init(message: error.localizedDescription, url: target)
                    self.owner?.show(error.localizedDescription)
                }
            }
        }
    }

    /// What was typed in the address field: an address, or a search.
    func navigate(_ input: String) {
        guard let target = BrowserAddress.resolve(input).target else { return }
        load(target)
    }

    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        if let failed = failure?.url {
            load(failed)
        } else if webView.url == nil, let url {
            load(url)
        } else if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
    }

    func stop() { webView?.stopLoading() }

    func goBack() {
        if failure != nil || showingHome, webView?.url != nil {
            failure = nil
            showingHome = false
            return
        }
        webView?.goBack()
    }

    func goForward() { webView?.goForward() }

    func go(to item: WKBackForwardListItem) {
        failure = nil
        webView?.go(to: item)
    }

    /// Home: the start page the web browser's "Set as start page" chose
    /// (`browser.startUrl`), else "Open a page".
    func goHome() {
        Task {
            var start: URL?
            if EngineBridge.shared.isReady,
               let settings = try? await EngineBridge.shared.invoke("settings:get") as? [String: Any],
               let text = settings["browser.startUrl"] as? String, !text.isEmpty {
                start = BrowserAddress.resolve(text).target
            }
            if let start {
                load(start)
            } else {
                failure = nil
                showingHome = true
            }
        }
    }

    func setAsStartPage() {
        guard let url else { return }
        Task {
            _ = try? await EngineBridge.shared.invoke("settings:set", [["browser.startUrl": url.absoluteString]])
            owner?.show("Start page set")
        }
    }

    func printPage() {
        guard let webView, let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func copyAddress() {
        guard let url else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        owner?.show("Address copied")
    }

    func openInDefaultBrowser() {
        guard let url else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    func focusAddress() { focusAddressRequest += 1 }

    func showFind() {
        guard webView != nil, !showsStartView else { return }
        findVisible = true
        focusFindRequest += 1
    }

    func hideFind() {
        findVisible = false
        clearFind()
    }

    /// Shot: capture the page, save it beside the web browser's screenshots, and
    /// open the popover (preview, Copy, Reveal, send to a session).
    func takeShot() {
        Task {
            guard let shot = await snapshot() else { owner?.show("The page could not be captured"); return }
            do {
                if let composition = owner?.browserComposition { pendingShot = try await composition.saveShot(shot, tabID: id) }
                else { pendingShot = try shot.saved() }
            } catch {
                owner?.show("The screenshot could not be saved")
            }
        }
    }

    /// Shared ↔ Isolated, or another profile: the page moves to the other cookie
    /// store and reloads where it was.
    func switchStore(profile newProfile: String, isolated newIsolated: Bool) {
        guard newProfile != profile || newIsolated != isolated else { return }
        let current = webView?.url ?? url
        tearDown()
        profile = newProfile
        isolated = newIsolated
        pendingURL = current
        owner?.tabChanged(self)
        ensurePage()
    }

    /// Rebuild a restored legacy page so document-start integrations are on
    /// its real configuration. The selected address stays with the same tab.
    func reopenForNativeComposition() {
        let hadPage = webView != nil
        let current = webView?.url ?? url
        tearDown(); pendingURL = current
        if hadPage || owner?.selectedID == id { ensurePage() }
    }

    func setMobileUserAgent(_ on: Bool) {
        mobileUserAgent = on
        webView?.customUserAgent = on ? BrowserDevicePreset.mobileUserAgent : nil
        webView?.reload()
    }

    /// Browser shortcuts while this tab's screen is in the key window. Returns
    /// true when the key was used. ⌘T here is a new browser tab, not a new session.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if flags.isEmpty, !suggestions.isEmpty {
            switch event.keyCode {
            case 125: suggestionCursor = suggestionCursor + 1 >= suggestions.count ? -1 : suggestionCursor + 1; return true
            case 126: suggestionCursor = suggestionCursor <= -1 ? suggestions.count - 1 : suggestionCursor - 1; return true
            case 53: dismissSuggestions(); return true
            default: break
            }
        }
        if flags.isEmpty, event.keyCode == 53, case .draw = markup {
            markup = nil
            return true
        }
        // Esc stops Annotate's picker (TS BrowserWorkspace onKeyDown); the frozen surface answers its own Esc.
        if flags.isEmpty, event.keyCode == 53, inspecting, markup == nil {
            setInspecting(false)
            return true
        }
        // ⌥← / ⌥→: back and forward from the browser's own chrome (TS onKeyDown) — not
        // while typing, where they move by word, and not inside the page, which has its own.
        if flags == .option, event.keyCode == 123 || event.keyCode == 124,
           let responder = event.window?.firstResponder, !(responder is NSText),
           !((responder as? NSView).map { view in webView.map { view.isDescendant(of: $0) } ?? false } ?? false) {
            if event.keyCode == 123 { goBack() } else { goForward() }
            return true
        }
        if flags == .command {
            switch key {
            case "t": owner?.create(after: id); return true
            case "w": owner?.close(id); return true
            case "l": focusAddress(); return true
            case "f": showFind(); return true
            case "g": findAgain(backwards: false); return true
            case "r": reload(); return true
            case ".": stop(); return true
            case "[": goBack(); return true
            case "]": goForward(); return true
            case "=", "+": zoom(by: 1); return true
            case "-": zoom(by: -1); return true
            case "0": resetZoom(); return true
            case "p": printPage(); return true
            default: return false
            }
        }
        if flags == [.command, .shift] {
            switch key {
            case "n": owner?.create(after: id, isolated: true, profile: profile); return true
            case "g": findAgain(backwards: true); return true
            case "r": reload(fromOrigin: true); return true
            case "=", "+": zoom(by: 1); return true
            case "h": goHome(); return true
            default: return false
            }
        }
        if flags == [.command, .option], key == "i" {
            showWebInspector()
            return true
        }
        return false
    }

    // MARK: Handover (an agent gives the page to the person)

    func beginHandover(_ prompt: String) {
        handoverPrompt = prompt
    }

    /// "resumed" (Done), "stopped" (Stop) or "drive-ended" (the tab closed).
    func endHandover(_ outcome: String) {
        handoverPrompt = nil
        let waiter = handoverWaiter
        handoverWaiter = nil
        waiter?(outcome)
    }

    /// Wait for the page to stop loading, up to `timeout`. True when it did.
    func settle(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        // A load that has only just been asked for may not have started yet.
        try? await Task.sleep(for: .milliseconds(120))
        while isLoading || awaitingWebKitLoad {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// Run one of the driver's scripts in the page, in WebKit's isolated world.
    func evaluate(_ script: String) async throws -> Any? {
        guard let webView else { throw BrowserDriverRefusal("the page is not open") }
        return try await webView.evaluateJavaScript(script, contentWorld: .defaultClient)
    }

    // MARK: Record (the steps taken on the page)

    func toggleRecording() {
        if recording {
            recording = false
            flowHidden = false // the flow opens itself when a recording stops (TS)
            tellRecorder()
            return
        }
        guard let current = webView?.url ?? url else { return }
        // One mode at a time (modes.ts): Annotate's picker and Draw go off first.
        if inspecting { setInspecting(false) }
        if case .draw = markup { markup = nil }
        recording = true
        steps = BrowserFlow.append(steps, BrowserFlow.navigate(current.absoluteString, at: Date().timeIntervalSince1970 * 1000))
        tellRecorder()
    }

    func clearRecording() {
        steps = []
    }

    /// A step the page's recorder posted.
    func recorded(_ body: Any) {
        guard recording, let step = BrowserFlow.parse(body, url: (webView?.url ?? url)?.absoluteString ?? "",
                                                      at: Date().timeIntervalSince1970 * 1000) else { return }
        steps = BrowserFlow.append(steps, step)
    }

    /// The page's recorder listens only while this is true (set again on every new page).
    private func tellRecorder() {
        guard let webView else { return }
        webView.evaluateJavaScript("window.__tdRecording = \(recording ? "true" : "false")", in: nil, in: .defaultClient,
                                   completionHandler: nil)
    }

    func copyFlow() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BrowserFlow.text(steps), forType: .string)
        owner?.show("Flow copied")
    }

    // MARK: Annotate and Draw

    /// The Annotate button (TS toggleMode('inspect')): the picker goes on in the live
    /// page — hover outlines, a click freezes the page with that element as marker 1
    /// (`inspected`). The same button again stops it. Without the native browser
    /// graph there is no picker, and the page is frozen at once instead.
    func toggleAnnotate() {
        if case .annotate = markup {
            markup = nil
            if inspecting { setInspecting(false) }
            return
        }
        guard owner?.browserComposition != nil else { startMarkup(annotate: true); return }
        if inspecting { setInspecting(false); return }
        // One mode at a time (modes.ts): Record and Draw go off first.
        if recording { toggleRecording() }
        markup = nil
        findVisible = false
        setInspecting(true)
    }

    /// `browser:inspect` — the page's picker on or off; the answer is the page's state.
    func setInspecting(_ on: Bool) {
        inspecting = on
        if !on { annotateStart = nil }
        Task {
            let answer = try? await EngineBridge.shared.invoke("browser:inspect", [id, on])
            if let state = answer as? [String: Any], let now = state["inspecting"] as? Bool {
                inspecting = now
            } else if on {
                inspecting = false
                owner?.show("Annotate could not start on this page")
            }
        }
    }

    /// The page said its picker went off (Esc in the page, a new document).
    func inspectStateChanged(_ on: Bool) {
        if inspecting != on { inspecting = on }
    }

    /// A click on the live page while Annotate is on: the photograph taken at the
    /// click, with the clicked element as marker 1. No photograph, no round (TS).
    func inspected(_ capture: BRInspectCapture) {
        guard inspecting, markup == nil, let data = BRInspectCapture.imageData(capture.pageImage),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let viewport = webView.map { CGSize(width: $0.bounds.width / $0.pageZoom, height: $0.bounds.height / $0.pageZoom) } ?? .zero
        annotateStart = capture.markerRect(viewport: viewport).map { BrowserAnnotation(rect: $0, element: capture.element) }
        let pageURL = URL(string: capture.url) ?? webView?.url ?? url
        markup = .annotate(NativeBrowserShot(image: image, cgImage: cgImage, url: pageURL, title: title))
    }

    /// Marker 1 for the surface that just opened, once.
    func takeAnnotateStart() -> BrowserAnnotation? {
        defer { annotateStart = nil }
        return annotateStart
    }

    func startMarkup(annotate: Bool) {
        if case .some(let current) = markup {
            // The same button again leaves; the other one switches.
            if case .annotate = current, annotate { markup = nil; return }
            if case .draw = current, !annotate { markup = nil; return }
        }
        if inspecting { setInspecting(false) } // one mode at a time (modes.ts)
        findVisible = false
        Task {
            guard let shot = await snapshot() else { owner?.show("The page could not be captured"); return }
            markup = annotate ? .annotate(shot) : .draw(shot)
        }
    }

    /// What is on the page at a point (fractions of the frozen picture).
    func pick(x: Double, y: Double) async -> (rect: CGRect, element: BrowserAnnotatedElement?)? {
        if let composition = owner?.browserComposition { return try? await composition.pick(self, x: x, y: y) }
        guard let raw = try? await evaluate(BrowserDriverScripts.with(BrowserDriverScripts.pickAt, args: ["x": x, "y": y])),
              let fields = raw as? [String: Any], fields["found"] as? Bool == true else { return nil }
        let viewport = fields["viewport"] as? [String: Any]
        let size = CGSize(width: (viewport?["width"] as? NSNumber)?.doubleValue ?? 0,
                          height: (viewport?["height"] as? NSNumber)?.doubleValue ?? 0)
        guard let rect = BrowserAnnotate.normalise(BrowserDriverEngine.rect(fields["rect"]), viewport: size) else { return nil }
        return (rect, BrowserAnnotatedElement.read(fields))
    }

    /// A drawn-on picture, saved and handed to the Shot popover (copy or send).
    func finishDrawing(_ image: NSImage, cgImage: CGImage, marks: Int, from shot: NativeBrowserShot) {
        var marked = NativeBrowserShot(image: image, cgImage: cgImage, url: shot.url, title: shot.title)
        marked.marks = marks
        if let composition = owner?.browserComposition {
            Task {
                do { pendingShot = try await composition.saveShot(marked, tabID: id); markup = nil }
                catch { owner?.show(error.localizedDescription) }
            }
            return
        }
        do {
            pendingShot = try marked.saved(suffix: "-marked")
            markup = nil
        } catch {
            owner?.show("The marked page could not be saved")
        }
    }

    // MARK: Address suggestions

    func updateSuggestions(for typed: String) {
        suggestionEpoch = UUID()
        let epoch = suggestionEpoch
        suggestionCursor = -1
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == BrowserAddress.display(url) {
            suggestions = []
            return
        }
        if let composition = owner?.browserComposition {
            suggestions = []
            Task { [weak self] in
                guard let self else { return }
                do {
                    let rows = try await composition.suggest(profile: self.profile, typed: trimmed)
                    guard self.suggestionEpoch == epoch else { return }
                    self.suggestions = rows
                } catch { self.owner?.show(error.localizedDescription) }
            }
        } else { suggestions = NativeBrowserHistoryStore.shared.suggest(profile: profile, typed: trimmed) }
    }

    func dismissSuggestions() {
        suggestionEpoch = UUID()
        suggestions = []
        suggestionCursor = -1
    }

    // MARK: Zoom

    func zoom(by delta: Int) { setZoom(BrowserZoom.step(zoom, by: delta)) }
    func resetZoom() { setZoom(1) }

    private func setZoom(_ value: Double) {
        zoom = value
        webView?.pageZoom = value
    }

    // MARK: Find in page

    /// Search from the top as the text changes.
    func findFromStart() {
        guard let webView else { return }
        let text = findText
        guard !text.isEmpty else {
            findMissed = false
            clearSelection()
            return
        }
        clearSelection()
        find(text, backwards: false, in: webView)
    }

    func findAgain(backwards: Bool) {
        guard let webView, !findText.isEmpty else {
            showFind()
            return
        }
        find(findText, backwards: backwards, in: webView)
    }

    func clearFind() {
        findMissed = false
        clearSelection()
    }

    private func find(_ text: String, backwards: Bool, in webView: WKWebView) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            guard let self, self.findText == text else { return }
            self.findMissed = !result.matchFound
        }
    }

    private func clearSelection() {
        webView?.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", completionHandler: nil)
    }

    // MARK: Screenshot, inspector

    /// The visible page as a picture.
    func snapshot() async -> NativeBrowserShot? {
        if let composition = owner?.browserComposition { return try? await composition.snapshot(self) }
        guard let webView, !showsStartView, webView.bounds.width > 0, webView.bounds.height > 0 else { return nil }
        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NativeBrowserShot(image: image, cgImage: cgImage, url: webView.url ?? url, title: title)
    }

    /// Open Safari's Web Inspector for this page, docked in the tab. WebKit has no
    /// public call for this, so it is asked only if this WebKit still answers to it;
    /// right-click ▸ Inspect Element and Safari's Develop menu always work.
    func showWebInspector() {
        guard let webView else { return }
        let getter = NSSelectorFromString("_inspector")
        guard webView.responds(to: getter),
              let inspector = webView.perform(getter)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("show")) else {
            NSSound.beep()
            return
        }
        inspector.perform(NSSelectorFromString("show"))
    }

    var backList: [WKBackForwardListItem] { Array((webView?.backForwardList.backList ?? []).reversed().prefix(20)) }
    var forwardList: [WKBackForwardListItem] { Array((webView?.backForwardList.forwardList ?? []).prefix(20)) }

    // MARK: From the page

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageTitleChanged(view.title ?? "") }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.pageURLChanged(view.url) }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    private func pageTitleChanged(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        owner?.tabChanged(self)
        if let composition = owner?.browserComposition { composition.titleChanged(self) }
        else if !isolated, let url { NativeBrowserHistoryStore.shared.retitle(profile: profile, url: url, title: newTitle) }
    }

    private func pageURLChanged(_ newURL: URL?) {
        guard let newURL, newURL != url else { return }
        if newURL.host() != url?.host() { favicon = nil }
        url = newURL
        owner?.tabChanged(self)
        if recording, let scheme = newURL.scheme, scheme == "http" || scheme == "https" {
            steps = BrowserFlow.append(steps, BrowserFlow.navigate(newURL.absoluteString, at: Date().timeIntervalSince1970 * 1000))
        }
    }

    func navigationStarted() {
        clearSavedLoginOffers()
        owner?.browserComposition?.navigationStarted(self)
        failure = nil
        showingHome = false
        awaitingWebKitLoad = false
    }

    func navigationCommitted() {
        failure = nil
        awaitingWebKitLoad = false
        findMissed = false
        if recording { tellRecorder() }
        owner?.browserComposition?.committed(self)
    }

    func clearSavedLoginOffers() {
        documentEpoch = UUID(); savedSignInOffer = nil; savedPasswordOffer = nil
        savedLoginMessage = nil
    }
    func answerSavedPassword(keep: Bool) {
        guard !savedLoginPending, let composition = owner?.browserComposition else { return }
        savedLoginPending = true; savedLoginMessage = nil
        Task {
            defer { savedLoginPending = false }
            do { savedLoginMessage = try await composition.answerPassword(self, keep: keep).message }
            catch { savedLoginMessage = error.localizedDescription }
        }
    }
    func fillSavedLogin(username: String) {
        guard !savedLoginPending, let composition = owner?.browserComposition else { return }
        savedLoginPending = true; savedLoginMessage = nil
        Task {
            defer { savedLoginPending = false }
            do {
                let filled = try await composition.fillSavedLogin(self, username: username)
                savedLoginMessage = filled ? "Filled the current sign-in form." : "The sign-in form changed. Try again on the current page."
            } catch { savedLoginMessage = error.localizedDescription }
        }
    }

    func navigationFinished() {
        loadFavicon()
        if recording { tellRecorder() }
        // Isolated tabs keep nothing, history included.
        if let composition = owner?.browserComposition { composition.settled(self) }
        else if !isolated, let current = webView?.url {
            NativeBrowserHistoryStore.shared.note(profile: profile, url: current, title: title)
        }
    }

    func navigationFailed(_ error: Error, provisional: Bool) {
        owner?.browserComposition?.settled(self, error: error)
        let error = error as NSError
        // A cancelled load (a new one began, or it became a download) is not a failure.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return }
        awaitingWebKitLoad = false
        guard provisional else { return } // a sub-resource failing leaves the page as it is
        let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        failure = LoadFailure(message: Self.sentence(for: error, url: failed), url: failed)
    }

    /// One plain sentence for a page that did not open.
    static func sentence(for error: NSError, url: URL?) -> String {
        let place = url.map { u -> String in
            if let host = u.host(), let port = u.port { return "\(host):\(port)" }
            return u.host() ?? u.absoluteString
        } ?? "that address"
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorCannotConnectToHost:
            return "Nothing is answering at \(place). If it is a dev server, start it and try again."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "\(place) could not be found. Check the address."
        case NSURLErrorNotConnectedToInternet:
            return "This Mac is not connected to the internet."
        case NSURLErrorTimedOut:
            return "\(place) took too long to answer."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "\(place) only offers a plain-http page, and this app opens plain http only on this machine and the local network. Try https://."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return "\(place) has a certificate this Mac does not trust, so it was not opened."
        default:
            return error.localizedDescription
        }
    }

    // MARK: Favicon

    /// The site's icon: the page's own `<link rel=icon>`, else /favicon.ico.
    private func loadFavicon() {
        guard let webView, let pageURL = webView.url, let scheme = pageURL.scheme,
              scheme == "http" || scheme == "https" else { return }
        let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel]')].filter(l => /(^|\\s)(icon|apple-touch-icon)(\\s|$)/i.test(l.rel) && l.href);
          if (!links.length) return '';
          const size = l => { const m = /(\\d+)x(\\d+)/.exec(l.sizes ? String(l.sizes) : ''); return m ? parseInt(m[1], 10) : 0 };
          links.sort((a, b) => Math.abs((size(a) || 32) - 32) - Math.abs((size(b) || 32) - 32));
          return links[0].href;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var icon: URL?
                if let text = value as? String, !text.isEmpty { icon = URL(string: text) }
                if icon == nil, var parts = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) {
                    parts.path = "/favicon.ico"
                    parts.query = nil
                    parts.fragment = nil
                    icon = parts.url
                }
                if let icon { self.fetchFavicon(icon) }
            }
        }
    }

    private func fetchFavicon(_ icon: URL) {
        if let cached = owner?.cachedFavicon(icon) {
            favicon = cached
            return
        }
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let data = try? await NativeBrowserTab.faviconSession.data(from: icon).0,
                  !Task.isCancelled,
                  let image = NSImage(data: data), image.isValid else { return }
            guard let self else { return }
            image.size = NSSize(width: 16, height: 16)
            self.owner?.cacheFavicon(image, for: icon)
            self.favicon = image
        }
    }

    /// No cookies, short timeout: an icon is never worth a wait or a login.
    private static let faviconSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    // MARK: Asking the person (page dialogs)

    func presentAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window = webView?.window {
            return await alert.beginSheetModal(for: window)
        }
        // A page with no window on screen asks nobody: an app-modal alert took the front and
        // blocked quitting (walk 2). The page's dialog is answered Cancel.
        return .cancel
    }

    var owningModel: NativeBrowserTabs? { owner }
}

/// A screenshot of the page.
struct NativeBrowserShot: Identifiable, Equatable {
    static func == (a: NativeBrowserShot, b: NativeBrowserShot) -> Bool { a.id == b.id && a.path == b.path }

    let id = UUID()
    let image: NSImage
    let cgImage: CGImage
    let url: URL?
    let title: String
    var path: String = ""
    /// How many marks were drawn on it (Draw).
    var marks = 0

    var width: Int { cgImage.width }
    var height: Int { cgImage.height }

    /// Written to ~/Pictures/Terminal Deck, where the web browser keeps its screenshots.
    func saved(now: Date = Date(), suffix: String = "") throws -> NativeBrowserShot {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        let folder = pictures.appendingPathComponent("Terminal Deck", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(BrowserShot.fileName(url: url, now: now, suffix: suffix))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: file, options: .atomic)
        var copy = self
        copy.path = file.path
        return copy
    }
}

/// The page view. Its right-click menu says "Tab" where WebKit says "Window",
/// because a new window from a page always becomes a tab here.
final class NativeBrowserWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            default: break
            }
        }
        addSystemBrowserRows(menu, event: event)
    }

    /// Lane BR: the web browser's three rows WebKit's menu has no equivalent of
    /// (browser-context-menu.ts): Open Link in System Browser after the link's own
    /// row, then Copy Page Address and Open Page in System Browser before Inspect Element.
    private func addSystemBrowserRows(_ menu: NSMenu, event: NSEvent) {
        func row(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
            let handler = BindMenuHandler(run)
            let item = NSMenuItem(title: title, action: #selector(BindMenuHandler.fire), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            return item
        }
        let ids = menu.items.map { $0.identifier?.rawValue ?? "" }
        if let link = ids.firstIndex(of: "WKMenuItemIdentifierOpenLinkInNewWindow") ?? ids.firstIndex(of: "WKMenuItemIdentifierCopyLink") {
            let local = convert(event.locationInWindow, from: nil)
            let scale = max(0.01, pageZoom * magnification)
            let css = CGPoint(x: local.x / scale, y: (isFlipped ? local.y : bounds.height - local.y) / scale)
            menu.insertItem(row("Open Link in System Browser") { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    let found = try? await self.callAsyncJavaScript(
                        "var e = document.elementFromPoint(x, y); var a = e && e.closest ? e.closest('a[href]') : null; return a ? String(a.href) : '';",
                        arguments: ["x": css.x, "y": css.y], in: nil, contentWorld: .defaultClient)
                    guard let text = found as? String, BRPageMenu.mayOpenOutside(text), let url = URL(string: text) else { NSSound.beep(); return }
                    NSWorkspace.shared.open(url)
                }
            }, at: link + 1)
        }
        guard let page = url, BRPageMenu.hasPage(page.absoluteString) else { return }
        var rows = [row("Copy Page Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(page.absoluteString, forType: .string)
        }]
        if BRPageMenu.mayOpenOutside(page.absoluteString) {
            rows.append(row("Open Page in System Browser") { NSWorkspace.shared.open(page) })
        }
        let at = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }
        if let at {
            // Inspect Element sits in its own section; the page's rows go just above that section.
            let start = at > 0 && menu.items[at - 1].isSeparatorItem ? at - 1 : at
            for (offset, item) in ([NSMenuItem.separator()] + rows).enumerated() { menu.insertItem(item, at: start + offset) }
        } else {
            menu.addItem(.separator())
            for item in rows { menu.addItem(item) }
        }
    }
}

/// WebKit's questions for one tab, answered on its behalf.
@MainActor
final class NativeBrowserPageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: NativeBrowserTab?

    init(tab: NativeBrowserTab) {
        self.tab = tab
    }

    private static let pageSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            return (.cancel, preferences)
        }

        // ⌘-click or middle-click on a link: a new tab (⇧ brings it to the front).
        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated,
           flags.contains(.command) || navigationAction.buttonNumber == 2,
           Self.pageSchemes.contains(scheme), let tab, let owner = tab.owningModel {
            owner.create(url: url, after: tab.id, isolated: tab.isolated, profile: tab.profile,
                         show: flags.contains(.shift))
            return (.cancel, preferences)
        }

        if Self.pageSchemes.contains(scheme) {
            if navigationAction.targetFrame?.isMainFrame == true, let tab, let composition = tab.owningModel?.browserComposition {
                do { try await composition.prepareNavigation(tab, url: url) }
                catch { tab.owningModel?.show(error.localizedDescription); return (.cancel, preferences) }
            }
            return (.allow, preferences)
        }

        // mailto:, tel:, an app's own link — handed to the Mac, only from a click.
        if navigationAction.navigationType == .linkActivated, scheme != "javascript", scheme != "file" {
            NSWorkspace.shared.open(url)
        }
        return (.cancel, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let tab { tab.owningModel?.browserComposition?.response(tab, response: navigationResponse.response) }
        if !navigationResponse.canShowMIMEType { return .download }
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        tab?.owningModel?.downloads.adopt(download, webView: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        tab?.owningModel?.downloads.adopt(download, webView: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.navigationStarted()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.navigationCommitted()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.navigationFinished()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.navigationFailed(error, provisional: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.navigationFailed(error, provisional: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: Windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let tab, let owner = tab.owningModel else { return nil }
        if let composition = owner.browserComposition {
            return composition.adoptPopup(configuration: configuration, opener: tab,
                requestedURL: navigationAction.request.url, features: windowFeatures)
        }
        return owner.adoptWindowRequest(configuration: configuration, from: tab)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, let owner = tab.owningModel else { return }
        owner.close(tab.id)
    }

    // MARK: Page dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = Self.alert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await tab?.presentAlert(alert)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = Self.alert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await tab?.presentAlert(alert) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = Self.alert(prompt, frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard await tab?.presentAlert(alert) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            let response = await panel.beginSheetModal(for: window)
            return response == .OK ? panel.urls : nil
        }
        return nil // no window to put the chooser on (see presentAlert)
    }

    private static func alert(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(host) says"
        alert.informativeText = message
        return alert
    }
}
