import AppKit
import Observation
@preconcurrency import SwiftTerm
import TerminalDeckNativeCore

/// One local session's native terminal and everything its screen shows about it.
///
/// Lives as long as the session does (see `NativeTerminalSessions`), not as long
/// as its screen: switching to another session and back shows the same terminal,
/// still at the same place, the way the web keeps a hidden one mounted. It keeps
/// receiving the session's output the whole time.
///
/// Attaching is the web pane's order: listen to `session:data` first, ask for
/// `session:scrollback`, show nothing until the history is written
/// (`TerminalBackfill`), then live output. Keystrokes go out on `session:write`,
/// sizes on `session:resize`, both in order through `EngineBridge.send`.
@MainActor
@Observable
final class NativeTerminalSession {
    let sessionId: String

    // What the header and the overlays draw.
    private(set) var info: TerminalSessionInfo?
    private(set) var status: TerminalStatus?
    private(set) var ended: TerminalEndNotice?
    private(set) var controls: TerminalControls?
    private(set) var busyControl: String?
    private(set) var controlNotice: (ok: Bool, text: String)?
    /// The one line a refused paste, drop or copy says (`TransferNote`).
    private(set) var note: String?

    @ObservationIgnored let terminal: DeckTerminalView
    @ObservationIgnored let container: DeckTerminalContainer
    @ObservationIgnored private var backfill = TerminalBackfill()
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var holdTimer: Task<Void, Never>?
    @ObservationIgnored private var noteTimer: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var controlsSettle: Task<Void, Never>?
    @ObservationIgnored private var lastSentSize: (cols: Int, rows: Int)?
    /// True while history is being written: answers the terminal would give to
    /// queries in old output (cursor reports, device attributes) and clipboard
    /// copies made long ago must not reach the live program or this Mac's clipboard.
    @ObservationIgnored private var replaying = false
    @ObservationIgnored private var visibleScreens = 0
    @ObservationIgnored private var announceSize = false
    @ObservationIgnored private var wantsFocus = false
    @ObservationIgnored private var appliedPreferences: TerminalPreferences?
    @ObservationIgnored private var appliedScheme: TerminalScheme?
    @ObservationIgnored private(set) var removed = false
    @ObservationIgnored private let delegateProxy = DelegateProxy()

    /// The web terminal's line height (xterm `lineHeight: 1.35`).
    static let lineSpacing: CGFloat = 1.35

    init(sessionId: String) {
        self.sessionId = sessionId
        let settings = NativeTerminalSettings.shared
        terminal = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: settings.preferences.nsFont)
        container = DeckTerminalContainer(terminal: terminal)
        terminal.host = self
        delegateProxy.owner = self
        terminal.terminalDelegate = delegateProxy
        terminal.optionAsMetaKey = false       // xterm's default: ⌥ types the character the layout gives
        terminal.lineSpacing = Self.lineSpacing
        terminal.alphaValue = 0                // held until the history is in
        applyAppearance()
        settings.follow(self)
        settings.start()
        attach()
    }

    // MARK: Attaching

    private func attach() {
        let id = sessionId
        let bridge = EngineBridge.shared
        subscriptions.append(bridge.on("session:data") { [weak self] args in
            guard let self, Self.string(args, 0) == id, let chunk = Self.text(args, 1) else { return }
            self.receive(chunk)
        })
        subscriptions.append(bridge.on("session:exit") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            self.receive(TerminalEndNotice.exitLine)
            self.end(code: args.count > 1 ? TerminalJSON.int(args[1]) : nil)
        })
        subscriptions.append(bridge.on("session:status") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            if let status = TerminalStatus.parse(args.count > 1 ? args[1] : nil) { self.status = status }
        })
        subscriptions.append(bridge.on("session:renamed") { [weak self] args in
            guard let self, Self.string(args, 0) == id, let title = Self.string(args, 1), let info = self.info else { return }
            self.info = TerminalSessionInfo(id: info.id, cwd: info.cwd, title: title, provider: info.provider,
                                            exitCode: info.exitCode, profileName: info.profileName)
        })
        subscriptions.append(bridge.on("session:removed") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            self.removed = true
            if self.ended == nil { self.end(code: nil) }
            NativeTerminalSessions.shared.forget(id)
        })

        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TerminalBackfill.holdLimit))
            guard !Task.isCancelled else { return }
            self?.release(nil)
        }
        Task { [weak self] in
            let history = try? await bridge.invoke("session:scrollback", [id])
            self?.release(history.flatMap { Self.decodeText($0) })
        }
        refreshInfo()
    }

    private func receive(_ chunk: String) {
        if let now = backfill.push(chunk) { terminal.feed(text: now) }
        scheduleControlsRead()
    }

    private func release(_ history: String?) {
        guard let released = backfill.release(backlog: history) else { return }
        holdTimer?.cancel()
        holdTimer = nil
        if !released.history.isEmpty {
            replaying = true
            terminal.feed(text: released.history)
            replaying = false
        }
        if !released.live.isEmpty { terminal.feed(text: released.live) }
        // If the session already ended, the caret goes again after the history put it back.
        if ended != nil { terminal.feed(text: "\u{1b}[?25l") }
        terminal.scroll(toPosition: 1)
        terminal.alphaValue = ended == nil ? 1 : Self.endedAlpha
        sendSize(force: true)
    }

    /// The session record: title, folder, agent, account and whether it has already ended.
    func refreshInfo() {
        Task { [weak self] in
            guard let list = try? await EngineBridge.shared.invoke("session:list") else { return }
            guard let self, let found = TerminalSessionInfo.find(self.sessionId, in: list) else { return }
            self.info = found
            if let code = found.exitCode, self.ended == nil { self.end(code: code) }
        }
    }

    // MARK: The screen

    /// A screen showing this session appeared.
    func screenAppeared() {
        visibleScreens += 1
        NativeTerminalSettings.shared.start()
        refreshInfo()
        readControls()
        focus()
    }

    func screenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
    }

    /// The terminal joined a window: once it has been laid out there, tell the
    /// session its size again — the page's own terminal for this session may have
    /// resized it in between — and take the keyboard if a screen just asked for it.
    func viewDidAppearInWindow() {
        announceSize = true
    }

    /// The pane has its real size (called from the container's layout).
    func layoutSettled() {
        if announceSize, terminal.bounds.width > 0, terminal.bounds.height > 0 {
            announceSize = false
            sendSize(force: true)
        }
        if wantsFocus { focus() }
    }

    /// Give the terminal the keyboard (the web pane focuses the terminal it shows).
    func focus() {
        guard ended == nil, let window = terminal.window else {
            wantsFocus = ended == nil
            return
        }
        wantsFocus = false
        if window.firstResponder !== terminal { window.makeFirstResponder(terminal) }
    }

    /// "Start another session here": the same New session dialog every other new
    /// session in the app opens, on this session's project.
    func startAnother() {
        let model = AppModel.shared
        let projects = model.sidebar?.projects ?? []
        let project = projects.first { $0.sessions.contains { $0.id == sessionId } }?.id
            ?? projects.first { $0.id == info?.cwd }?.id
        if let project {
            model.newSession(in: project)
        } else {
            model.newSession()
        }
    }

    // MARK: Ending

    static let endedAlpha: CGFloat = 0.45

    private func end(code: Int?) {
        guard ended == nil else { return }
        ended = .exited(code: code)
        status = .exited
        terminal.freeze(true)
        if !backfill.isHolding { terminal.alphaValue = Self.endedAlpha }
        controls = nil
    }

    // MARK: Input

    fileprivate func send(_ bytes: ArraySlice<UInt8>) {
        guard !replaying, ended == nil, !bytes.isEmpty else { return }
        EngineBridge.shared.send("session:write", [sessionId, String(decoding: bytes, as: UTF8.self)])
    }

    /// Text as xterm's `paste()` sends it: Returns for line ends, bracketed when the program asked.
    func type(paste text: String) {
        guard ended == nil, !text.isEmpty else { return }
        terminal.send(txt: TerminalText.pasteData(text, bracketed: terminal.getTerminal().bracketedPasteMode))
    }

    /// ⌘V, through the web terminal's rules: files copied in Finder are typed as
    /// their paths, a clipboard image becomes a file on this Mac first, and text is text.
    func paste(from pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let types = pasteboard.types ?? []
        let imageType: String? = types.contains(.png) ? "image/png" : types.contains(.tiff) ? "image/png" : nil
        let plan = TerminalPastePlan.decide(filePaths: urls.map(\.path), hasImage: imageType != nil, imageType: imageType,
                                            text: pasteboard.string(forType: .string), now: Date())
        switch plan {
        case .paths(let paths):
            for path in paths { type(paste: TerminalText.promptWord(path)) }
        case .text(let text):
            type(paste: text)
        case .stageImage(let name):
            guard let bytes = Self.pngData(from: pasteboard) else {
                say("That image could not be read from the clipboard.")
                return
            }
            stage(name: name, bytes: bytes)
        case .nothing:
            break
        }
    }

    private func stage(name: String, bytes: Data) {
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke("transfer:stage", [name, bytes])
            guard let self else { return }
            switch TerminalHandover.read(answer) {
            case .path(let path):
                self.say(nil)
                self.type(paste: TerminalText.promptWord(path))
            case .refused(let message):
                self.say(message)
            }
        }
    }

    /// A drop from Finder (or any app): files become their quoted paths at the
    /// prompt, anything else that is text is typed as text. No Return is sent.
    func drop(from pasteboard: NSPasteboard) -> Bool {
        guard ended == nil else { return false }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            for url in urls { type(paste: TerminalText.promptWord(url.path)) }
            return true
        }
        let raw = pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
            ?? ""
        let text = TerminalText.droppedText(raw)
        guard !text.isEmpty else { return false }
        type(paste: text)
        return true
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    // MARK: Things the terminal asks for

    fileprivate func resized(cols: Int, rows: Int) {
        sendSize(force: false, cols: cols, rows: rows)
    }

    private func sendSize(force: Bool, cols: Int? = nil, rows: Int? = nil) {
        guard ended == nil, terminal.window != nil, terminal.bounds.width > 0, terminal.bounds.height > 0 else { return }
        let size = (cols: cols ?? terminal.getTerminal().cols, rows: rows ?? terminal.getTerminal().rows)
        guard size.cols > 0, size.rows > 0 else { return }
        if !force, let last = lastSentSize, last == size { return }
        lastSentSize = size
        EngineBridge.shared.send("session:resize", [sessionId, size.cols, size.rows])
    }

    fileprivate func open(link: String) {
        guard let url = TerminalLinks.openable(link) else { return }
        Task { _ = try? await EngineBridge.shared.invoke("link:open", [["url": url, "sessionId": sessionId]]) }
    }

    fileprivate func copyFromProgram(_ content: Data) {
        guard !replaying else { return }
        switch TerminalClipboard.decide(content) {
        case .copy(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if !pasteboard.setString(text, forType: .string) { say(TerminalClipboard.didNotReach) }
        case .refuse(let line):
            say(line)
        case .ignore:
            break
        }
    }

    /// One short line over the terminal for four seconds, or clear it (`useTransferNote`).
    func say(_ line: String?) {
        noteTimer?.cancel()
        note = (line?.isEmpty ?? true) ? nil : line
        guard note != nil else { return }
        noteTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    // MARK: Model and effort

    /// Read again once output has been quiet for a moment, while a screen shows this session.
    private func scheduleControlsRead() {
        guard visibleScreens > 0, ended == nil else { return }
        controlsSettle?.cancel()
        controlsSettle = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.readControls()
        }
    }

    func readControls() {
        guard ended == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let answer = try? await EngineBridge.shared.invoke("agent:controls:read", [self.controlsRequest()])
            if let read = TerminalControls.decode(answer), self.ended == nil { self.controls = read }
        }
    }

    func pick(control: String, value: String) {
        guard busyControl == nil, ended == nil else { return }
        busyControl = control
        controlNotice = nil
        Task { [weak self] in
            guard let self else { return }
            var request = self.controlsRequest()
            request["control"] = control
            request["value"] = value
            let answer: Any?
            do { answer = try await EngineBridge.shared.invoke("agent:controls:apply", [request]) } catch {
                self.busyControl = nil
                self.showControlNotice(ok: false, text: (error as? EngineWireError)?.description ?? "The change failed.")
                return
            }
            let result = TerminalControlResult.decode(answer)
            self.busyControl = nil
            self.showControlNotice(ok: result.ok, text: result.message)
            if let current = self.controls {
                self.controls = TerminalControls(
                    model: control == "model" ? result.reading : current.model,
                    effort: control == "effort" ? result.reading : current.effort,
                    live: current.live, agentRunning: current.agentRunning,
                    canType: current.canType, gateReason: current.gateReason)
            }
            self.readControls()
        }
    }

    func dismissControlNotice() {
        noticeTimer?.cancel()
        controlNotice = nil
    }

    /// A confirmation goes after four seconds; a failure stays until dismissed.
    private func showControlNotice(ok: Bool, text: String) {
        noticeTimer?.cancel()
        guard !text.isEmpty else {
            controlNotice = nil
            return
        }
        controlNotice = (ok, text)
        guard ok else { return }
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.controlNotice = nil
        }
    }

    private func controlsRequest() -> [String: Any?] {
        var request: [String: Any?] = ["sessionId": sessionId]
        if let cwd = info?.cwd, !cwd.isEmpty { request["cwd"] = cwd }
        if let provider = info?.provider { request["provider"] = provider }
        return request
    }

    // MARK: Appearance

    /// Font, size, copy on select and the colours, applied to the live terminal.
    func applyAppearance() {
        let settings = NativeTerminalSettings.shared
        let preferences = settings.preferences
        let scheme = settings.scheme
        terminal.copyOnSelect = preferences.copyOnSelect
        if appliedPreferences?.fontSize != preferences.fontSize || appliedPreferences?.fontFamily != preferences.fontFamily {
            let font = preferences.nsFont
            if terminal.font != font {
                terminal.font = font
                // SwiftTerm re-measures the cell but not the grid; this re-fits it and the
                // new size reaches the session through `sizeChanged`.
                terminal.setFrameSize(terminal.frame.size)
            }
        }
        appliedPreferences = preferences
        guard scheme != appliedScheme else { return }
        appliedScheme = scheme
        let background = scheme.colour(scheme.background, fallback: .black)
        terminal.nativeBackgroundColor = background
        terminal.nativeForegroundColor = scheme.colour(scheme.foreground, fallback: .white)
        terminal.caretColor = scheme.colour(scheme.cursor, fallback: .controlAccentColor)
        terminal.caretTextColor = scheme.colour(scheme.cursorAccent, fallback: background)
        terminal.selectedTextBackgroundColor = scheme.colour(scheme.selectionBackground, fallback: .selectedTextBackgroundColor)
        terminal.installColors(scheme.ansi.map { hex in
            let c = TerminalColour(hex: hex) ?? TerminalColour(red: 0.5, green: 0.5, blue: 0.5)
            return SwiftTerm.Color(red: UInt16(c.red * 65535), green: UInt16(c.green * 65535), blue: UInt16(c.blue * 65535))
        })
        container.ground = background
        container.appearance = NSAppearance(named: scheme.isLight ? .aqua : .darkAqua)
    }

    /// The ground colour the screen paints around the terminal.
    var ground: NSColor {
        let scheme = NativeTerminalSettings.shared.scheme
        return scheme.colour(scheme.background, fallback: .black)
    }

    // MARK: Teardown

    func shutDown() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
        holdTimer?.cancel()
        noteTimer?.cancel()
        noticeTimer?.cancel()
        controlsSettle?.cancel()
    }

    // MARK: Values off the wire

    private static func string(_ args: [Any], _ index: Int) -> String? {
        args.count > index ? args[index] as? String : nil
    }

    private static func text(_ args: [Any], _ index: Int) -> String? {
        args.count > index ? decodeText(args[index]) : nil
    }

    /// Output arrives as a string; bytes (should the engine ever send them) are UTF-8.
    private static func decodeText(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let data = value as? Data { return String(decoding: data, as: UTF8.self) }
        return nil
    }
}

// MARK: - SwiftTerm's delegate

/// SwiftTerm calls this on the main thread; it forwards to the session.
@MainActor
private final class DelegateProxy: TerminalViewDelegate {
    weak var owner: NativeTerminalSession?

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { owner?.resized(cols: newCols, rows: newRows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { owner?.send(data) }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated { owner?.open(link: link) }
    }

    /// xterm's default: no bell.
    nonisolated func bell(source: TerminalView) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated { owner?.copyFromProgram(content) }
    }

    /// A program asking what is on this Mac's clipboard is never answered.
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }

    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Every native session terminal, one per session, kept while the session lives.
@MainActor
final class NativeTerminalSessions {
    static let shared = NativeTerminalSessions()
    private var sessions: [String: NativeTerminalSession] = [:]

    func session(for id: String) -> NativeTerminalSession {
        if let existing = sessions[id], !existing.removed { return existing }
        let made = NativeTerminalSession(sessionId: id)
        sessions[id] = made
        return made
    }

    /// The session is gone from the engine: stop listening for it. A screen still
    /// showing it keeps its last frame and the ended card.
    func forget(_ id: String) {
        sessions[id]?.shutDown()
        sessions[id] = nil
    }
}
