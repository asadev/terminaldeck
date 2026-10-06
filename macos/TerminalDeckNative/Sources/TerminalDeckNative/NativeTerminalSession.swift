import AppKit
import Observation
@preconcurrency import SwiftTerm
import TerminalDeckNativeCore

/// One session's native terminal and everything its screen shows about it —
/// a pty on this Mac or a session on one of his paired machines.
///
/// Lives as long as the session does (see `NativeTerminalSessions`), not as long
/// as its screen: switching to another session and back shows the same terminal,
/// still at the same place, the way the web keeps a hidden one mounted. It keeps
/// receiving the session's output the whole time.
///
/// A local session attaches in the web pane's order: listen to `session:data`
/// first, ask for `session:scrollback`, show nothing until the history is written
/// (`TerminalBackfill`), then live output; keystrokes on `session:write`, sizes on
/// `session:resize`. A session on another machine attaches as `RemoteTerminal`
/// does: `machines:attach`, whose answer is a replay of `machines:output` frames
/// marked `replay`, held until the first live frame or a quiet moment; keystrokes
/// on `machines:input` (in order), sizes on `machines:resize`, and its end read
/// off the machine's link (`machines:state`).
@MainActor
@Observable
final class NativeTerminalSession {
    let target: SessionTarget
    /// The tab id it is drawn under (the registry's key).
    var sessionId: String { target.tabId }

    // What the header and the overlays draw.
    private(set) var info: TerminalSessionInfo?
    private(set) var status: TerminalStatus?
    /// Why the screen is a photograph, or nil while it is a session.
    private(set) var end: SessionEnd?
    /// Model, effort and fast mode (`NativeSessionControls`).
    @ObservationIgnored let controlsState: NativeSessionControlsState
    /// Plan limits and the context window (`NativeUsageBar`).
    @ObservationIgnored let usageState: NativeUsageState
    /// The one line a refused paste, drop or copy says (`TransferNote`).
    private(set) var note: String?

    @ObservationIgnored let terminal: DeckTerminalView
    @ObservationIgnored let container: DeckTerminalContainer
    @ObservationIgnored private var backfill = TerminalBackfill()
    @ObservationIgnored private var replayed = ""
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var holdTimer: Task<Void, Never>?
    @ObservationIgnored private var quietTimer: Task<Void, Never>?
    @ObservationIgnored private var noteTimer: Task<Void, Never>?
    @ObservationIgnored private var remoteChain: Task<Void, Never>?
    @ObservationIgnored private var lastSentSize: (cols: Int, rows: Int)?
    /// A terminal on a server: what its tab says, and the shell once it is open.
    private(set) var serverInfo: ServerTabInfo?
    private(set) var shellId: String?
    @ObservationIgnored private var frames = ShellFrames()
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
    /// `QUIET_MS`: silence that means a far machine has finished replaying.
    static let replayQuiet: Duration = .milliseconds(150)

    var ended: Bool { end != nil }

    /// On another machine or a server: nothing in the engine says when its tab closed.
    var isRemote: Bool {
        if case .local = target { return false }
        return true
    }

    init(target: SessionTarget) {
        self.target = target
        controlsState = NativeSessionControlsState(target: target)
        usageState = NativeUsageState(target: target)
        let settings = NativeTerminalSettings.shared
        terminal = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: settings.preferences.nsFont)
        container = DeckTerminalContainer(terminal: terminal)
        terminal.host = self
        delegateProxy.owner = self
        controlsState.session = self
        terminal.terminalDelegate = delegateProxy
        terminal.optionAsMetaKey = false       // xterm's default: ⌥ types the character the layout gives
        terminal.lineSpacing = Self.lineSpacing
        terminal.alphaValue = 0                // held until the history is in
        applyAppearance()
        settings.follow(self)
        settings.start()
        // Hoot's tour can box a quote in this terminal and scroll to it (lane A).
        let tabId = target.tabId
        DriveAnchors.shared.terminals[tabId] = { [weak self] in self?.driveView() }
        DriveAnchors.shared.scrollers[tabId] = { [weak self] line in self?.scrollDrive(toLine: line) }
        switch target {
        case .local(let id): attachLocal(id)
        case .machine(let machineId, let sessionId): attachMachine(machineId, sessionId)
        case .server: attachServer()
        }
    }

    // MARK: Attaching — a pty on this Mac

    private func attachLocal(_ id: String) {
        let bridge = EngineBridge.shared
        subscriptions.append(bridge.on("session:data") { [weak self] args in
            guard let self, Self.string(args, 0) == id, let chunk = Self.text(args, 1) else { return }
            self.receive(chunk)
        })
        subscriptions.append(bridge.on("session:exit") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            self.receive(TerminalEndNotice.exitLine)
            self.setEnd(.exited(code: args.count > 1 ? TerminalJSON.int(args[1]) : nil))
        })
        subscriptions.append(bridge.on("session:status") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            if let status = TerminalStatus.parse(args.count > 1 ? args[1] : nil) { self.status = status }
        })
        subscriptions.append(bridge.on("session:renamed") { [weak self] args in
            guard let self, Self.string(args, 0) == id, let title = Self.string(args, 1), let info = self.info else { return }
            self.info = info.renamed(title)
        })
        subscriptions.append(bridge.on("session:removed") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            self.removed = true
            if self.end == nil { self.setEnd(.exited(code: nil)) }
            NativeTerminalSessions.shared.forget(self.sessionId)
        })
        startHoldClock()
        Task { [weak self] in
            let history = try? await bridge.invoke("session:scrollback", [id])
            self?.release(history.flatMap { Self.decodeText($0) })
        }
        refreshInfo()
    }

    // MARK: Attaching — a session on another machine

    private func attachMachine(_ machineId: String, _ sessionId: String) {
        let bridge = EngineBridge.shared
        subscriptions.append(bridge.on("machines:output") { [weak self] args in
            guard let self, let chunk = args.first as? [String: Any],
                  chunk["machineId"] as? String == machineId, chunk["sessionId"] as? String == sessionId,
                  let data = chunk["data"].flatMap(Self.decodeText) else { return }
            self.receiveRemote(data, replay: TerminalJSON.bool(chunk["replay"]) == true)
        })
        subscriptions.append(bridge.on("machines:upload:progress") { [weak self] args in
            guard let self, let frame = args.first as? [String: Any], frame["machineId"] as? String == machineId,
                  let progress = frame["progress"] as? [String: Any] else { return }
            let phase = progress["phase"] as? String ?? ""
            let line = TerminalTransfer.line(name: progress["name"] as? String ?? "That file",
                                             size: TerminalJSON.number(progress["size"]) ?? 0,
                                             sent: TerminalJSON.number(progress["sent"]) ?? 0,
                                             phase: phase, message: progress["message"] as? String ?? "")
            self.say(line, sticky: phase != "failed")
        })
        let links = NativeMachineLinks.shared
        links.follow(self)
        links.start()
        startHoldClock()
        let size = terminal.getTerminal()
        remote("machines:attach", [machineId, sessionId, size.cols, size.rows])
        machineLinksChanged()
    }

    /// The far machine's link or session list moved: the session's facts and its end.
    func machineLinksChanged() {
        guard case .machine(let machineId, let sessionId) = target else { return }
        let links = NativeMachineLinks.shared
        let machineName = links.snapshot.names[machineId] ?? "that machine"
        let link = links.snapshot.links[machineId]
        let facts = link?.session(sessionId)
        if let facts {
            info = TerminalSessionInfo(id: sessionId, cwd: facts.cwd, title: facts.title, provider: facts.provider,
                                       exitCode: facts.exitCode, profileName: nil)
            if let parsed = TerminalStatus.parse(facts.status) { status = parsed }
        }
        guard links.loaded else { return }
        setEnd(SessionEnd.ofMachineSession(machine: machineName, link: link, session: facts))
    }

    private func receiveRemote(_ data: String, replay: Bool) {
        guard backfill.isHolding else {
            if replay {
                // A replay after the screen is up (a second attach): history, not the program speaking now.
                replaying = true
                terminal.feed(text: data)
                replaying = false
            } else {
                terminal.feed(text: data)
            }
            scheduleControlsRead()
            return
        }
        if replay {
            replayed += data
            quietTimer?.cancel()
            quietTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.replayQuiet)
                guard !Task.isCancelled, let self else { return }
                self.release(self.replayed)
            }
        } else {
            _ = backfill.push(data)
            release(replayed)
        }
    }

    /// Calls to the far machine go in order: keystrokes must not overtake each other.
    private func remote(_ channel: String, _ args: [Any?], onAnswer: (@MainActor (Any?) -> Void)? = nil) {
        let previous = remoteChain
        remoteChain = Task { [weak self] in
            await previous?.value
            let answer = try? await EngineBridge.shared.invoke(channel, args)
            if let onAnswer { onAnswer(answer) }
            _ = self
        }
    }

    // MARK: Attaching — a shell on a server

    /// `ServerTerminal`: open a shell on the server (where the tab says), hold its
    /// output until the shell's id is known, type the tab's command once, and tell
    /// the page which shell this tab is. There is no history: the shell exists only
    /// here, which is why the session object outlives its screen.
    private func attachServer() {
        let tabId = sessionId
        let info = AppModel.shared.tabs?.tabs.first { $0.id == tabId }?.server
        serverInfo = info
        release(nil)
        guard let info else {
            setEnd(.neverOpened(why: "This copy of the app could not open a terminal on that server."))
            return
        }
        let bridge = EngineBridge.shared
        subscriptions.append(bridge.on("servers:shell:output") { [weak self] args in
            guard let self, let chunk = args.first as? [String: Any], let id = chunk["shellId"] as? String, !id.isEmpty else { return }
            let data = self.frames.arrived(shellId: id, data: chunk["data"] as? String ?? "")
            if !data.isEmpty {
                self.terminal.feed(text: data)
                self.scheduleControlsRead()
            }
        })
        subscriptions.append(bridge.on("servers:shell:closed") { [weak self] args in
            guard let self, let chunk = args.first as? [String: Any], let id = chunk["shellId"] as? String,
                  id == self.shellId else { return }
            self.terminal.feed(text: "\r\n\r\n\u{1b}[2m[This terminal ended.]\u{1b}[0m\r\n")
            self.shellId = nil
            NativeServerShells.closed(tabId: tabId)
            AppModel.shared.web.run(.serverShellEnded(tabId))
            self.setEnd(.shellGone(server: info.serverName))
        })
        if let open = info.shellId {
            // The page opened this one before the window drew it: carry on with it.
            shellOpened(open, run: nil)
            return
        }
        let size = terminal.getTerminal()
        Task { [weak self] in
            let answer = try? await bridge.invoke("servers:shell:open", [info.serverId, size.cols, size.rows, info.startIn])
            guard let self else { return }
            let opened = (answer as? [String: Any]).flatMap { TerminalJSON.bool($0["ok"]) == true ? TerminalJSON.text($0["shellId"]) : nil }
            if self.removed {
                if let opened { _ = try? await bridge.invoke("servers:shell:close", [opened]) }
                return
            }
            guard let opened else {
                self.frames.give()
                self.setEnd(.neverOpened(why: answer == nil ? "That server would not open a terminal."
                                                            : "This copy of the app could not open a terminal on that server."))
                return
            }
            self.shellOpened(opened, run: info.run)
        }
    }

    private func shellOpened(_ id: String, run: String?) {
        shellId = id
        NativeServerShells.opened(tabId: sessionId, shellId: id)
        AppModel.shared.web.run(.serverShellOpened(sessionId, shellId: id))
        let missed = frames.settled(id)
        if !missed.isEmpty { terminal.feed(text: missed) }
        if let run, !run.isEmpty { remote("servers:shell:write", [id, run + "\r"]) }
        sendSize(force: true)
        readControls()
    }

    // MARK: History and live output

    private func startHoldClock() {
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TerminalBackfill.holdLimit))
            guard !Task.isCancelled, let self else { return }
            self.release(self.target.machineId == nil ? nil : self.replayed)
        }
    }

    private func receive(_ chunk: String) {
        if let now = backfill.push(chunk) { terminal.feed(text: now) }
        scheduleControlsRead()
    }

    private func release(_ history: String?) {
        guard let released = backfill.release(backlog: history) else { return }
        holdTimer?.cancel()
        holdTimer = nil
        quietTimer?.cancel()
        quietTimer = nil
        replayed = ""
        if !released.history.isEmpty {
            replaying = true
            terminal.feed(text: released.history)
            replaying = false
        }
        if !released.live.isEmpty { terminal.feed(text: released.live) }
        terminal.scroll(toPosition: 1)
        terminal.alphaValue = end == nil ? 1 : Self.endedAlpha
        sendSize(force: true)
    }

    /// The session record: title, folder, agent, account and whether it has already ended.
    func refreshInfo() {
        guard case .local(let id) = target else { return }
        Task { [weak self] in
            guard let list = try? await EngineBridge.shared.invoke("session:list") else { return }
            guard let self, let found = TerminalSessionInfo.find(id, in: list) else { return }
            self.info = found
            if let code = found.exitCode, self.end == nil { self.setEnd(.exited(code: code)) }
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
        guard end == nil, let window = terminal.window else {
            wantsFocus = end == nil
            return
        }
        wantsFocus = false
        if window.firstResponder !== terminal { window.makeFirstResponder(terminal) }
    }

    /// The press on the ended card. A local session: the same New session dialog
    /// every other new session in the app opens, on this session's project. A
    /// session on another machine: dial it (`connectMachine`, as `RemoteTerminal`).
    func act(_ action: SessionEndNotice.ActionID) {
        switch target {
        case .machine(let machineId, _):
            Task { _ = try? await EngineBridge.shared.invoke("machines:connect", [machineId]) }
        case .server(let serverId, _):
            // Another terminal on that server, from its heading's ＋.
            AppModel.shared.newSession(in: "server:\(serverId)")
        case .local:
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
    }

    /// A name typed on the bar: given to the pty here (`session:rename`), or to the
    /// far machine, which announces it back to every window.
    func rename(to name: String) {
        switch target {
        case .local(let id):
            if let info { self.info = info.renamed(name) }
            // The page renames as its rail does, and tells the engine itself.
            AppModel.shared.web.run(.renameSession(id, name))
        case .machine(let machineId, let sessionId):
            Task { _ = try? await EngineBridge.shared.invoke("machines:session:rename", [machineId, sessionId, name]) }
        case .server:
            break
        }
    }

    // MARK: Ending

    static let endedAlpha: CGFloat = 0.45

    /// A local or server session ends once; a machine's can come back with its link.
    private func setEnd(_ next: SessionEnd?) {
        guard next != end else { return }
        if end != nil, next == nil, target.machineId == nil { return }
        end = next
        terminal.freeze(next != nil)
        if !backfill.isHolding { terminal.alphaValue = next == nil ? 1 : Self.endedAlpha }
        if next != nil {
            if case .exited = next { status = .exited }
            controlsState.sessionEnded()
        } else {
            sendSize(force: true)
            readControls()
        }
    }

    // MARK: Input

    fileprivate func send(_ bytes: ArraySlice<UInt8>) {
        guard !replaying, end == nil, !bytes.isEmpty else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        switch target {
        case .local(let id):
            EngineBridge.shared.send("session:write", [id, text])
        case .machine(let machineId, let sessionId):
            remote("machines:input", [machineId, sessionId, text]) { [weak self] answer in
                if TerminalJSON.bool(answer) == false { self?.say(TerminalTransfer.noLink) }
            }
        case .server:
            if let shellId { remote("servers:shell:write", [shellId, text]) }
        }
    }

    /// Text as xterm's `paste()` sends it: Returns for line ends, bracketed when the program asked.
    func type(paste text: String) {
        guard end == nil, !text.isEmpty else { return }
        terminal.send(txt: TerminalText.pasteData(text, bracketed: terminal.getTerminal().bracketedPasteMode))
    }

    /// ⌘V, through the web terminal's rules: files copied in Finder are typed as
    /// their paths (sent to the far machine first when the session runs there), a
    /// clipboard image becomes a file on this Mac first, and text is text — capped
    /// at a megabyte for a session on another machine.
    func paste(from pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let types = pasteboard.types ?? []
        let imageType: String? = types.contains(.png) ? "image/png" : types.contains(.tiff) ? "image/png" : nil
        let plan = TerminalPastePlan.decide(filePaths: urls.map(\.path), hasImage: imageType != nil, imageType: imageType,
                                            text: pasteboard.string(forType: .string), now: Date())
        switch plan {
        case .paths(let paths):
            hand(paths: paths)
        case .text(let text):
            if target.machineId != nil, TerminalTransfer.overPasteCap(text) {
                say(TerminalTransfer.pasteTooBig)
                return
            }
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

    /// Files that exist on this Mac, typed at the prompt as the session can open them
    /// (`pathForSession`): as they are here, or sent over first and typed as the far
    /// machine answers. One at a time, each typed as it lands.
    private func hand(paths: [String]) {
        let upload: (channel: String, id: String)
        switch target {
        case .local:
            for path in paths { type(paste: TerminalText.promptWord(path)) }
            return
        case .machine(let machineId, _): upload = ("machines:upload", machineId)
        case .server(let serverId, _): upload = ("servers:upload", serverId)
        }
        Task { [weak self] in
            for path in paths {
                let answer = try? await EngineBridge.shared.invoke(upload.channel, [upload.id, path])
                guard let self, !self.removed else { return }
                switch TerminalHandover.read(answer) {
                case .path(let there):
                    self.say(nil)
                    self.type(paste: TerminalText.promptWord(there))
                case .refused(let message):
                    self.say(message)
                    return
                }
            }
        }
    }

    private func stage(name: String, bytes: Data) {
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke("transfer:stage", [name, bytes])
            guard let self else { return }
            switch TerminalHandover.read(answer) {
            case .path(let path):
                if case .local = self.target {
                    self.say(nil)
                    self.type(paste: TerminalText.promptWord(path))
                } else {
                    self.hand(paths: [path])
                }
            case .refused(let message):
                self.say(message)
            }
        }
    }

    /// A drop from Finder (or any app): files become their quoted paths at the
    /// prompt, anything else that is text is typed as text. No Return is sent.
    func drop(from pasteboard: NSPasteboard) -> Bool {
        guard end == nil else { return false }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            hand(paths: urls.map(\.path))
            return true
        }
        let raw = pasteboard.string(forType: .string)
            ?? (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
            ?? ""
        let text = TerminalText.droppedText(raw)
        guard !text.isEmpty else {
            if target.machineId != nil, pasteboard.types?.contains(.fileContents) == true || pasteboard.types?.contains(.filePromise) == true {
                say(TerminalTransfer.noFileInDrop)
            }
            return false
        }
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
        guard end == nil, terminal.window != nil, terminal.bounds.width > 0, terminal.bounds.height > 0 else { return }
        let size = (cols: cols ?? terminal.getTerminal().cols, rows: rows ?? terminal.getTerminal().rows)
        guard size.cols > 0, size.rows > 0 else { return }
        if !force, let last = lastSentSize, last == size { return }
        lastSentSize = size
        switch target {
        case .local(let id):
            EngineBridge.shared.send("session:resize", [id, size.cols, size.rows])
        case .machine(let machineId, let sessionId):
            remote("machines:resize", [machineId, sessionId, size.cols, size.rows])
        case .server:
            if let shellId { remote("servers:shell:resize", [shellId, size.cols, size.rows]) }
        }
    }

    fileprivate func open(link: String) {
        guard let url = TerminalLinks.openable(link) else { return }
        var request: [String: Any] = ["url": url]
        switch target {
        case .local(let id): request["sessionId"] = id
        case .machine(let machineId, let sessionId):
            request["sessionId"] = sessionId
            request["machineId"] = machineId
        case .server(let serverId, _):
            if let shellId { request["sessionId"] = shellId }
            request["machineId"] = serverId
        }
        Task { _ = try? await EngineBridge.shared.invoke("link:open", [request]) }
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

    /// One short line over the terminal for four seconds — or until the next, when
    /// `sticky` — or clear it (`useTransferNote`).
    func say(_ line: String?, sticky: Bool = false) {
        noteTimer?.cancel()
        note = (line?.isEmpty ?? true) ? nil : line
        guard note != nil, !sticky else { return }
        noteTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    // MARK: Model, effort and fast mode

    /// Read again once output has been quiet for a moment, while a screen shows this session.
    private func scheduleControlsRead() {
        guard visibleScreens > 0, end == nil else { return }
        controlsState.outputArrived()
        usageState.readContext(force: false)
    }

    func readControls() {
        guard end == nil else { return }
        controlsState.read()
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
        terminal.liveCaret = (scheme.colour(scheme.cursor, fallback: .controlAccentColor),
                              scheme.colour(scheme.cursorAccent, fallback: background))
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
        DriveAnchors.shared.terminals[sessionId] = nil
        DriveAnchors.shared.scrollers[sessionId] = nil
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
        holdTimer?.cancel()
        quietTimer?.cancel()
        noteTimer?.cancel()
        switch target {
        case .machine(let machineId, let sessionId):
            remote("machines:detach", [machineId, sessionId])
        case .server:
            if let shellId {
                remote("servers:shell:close", [shellId])
                NativeServerShells.closed(tabId: sessionId)
                self.shellId = nil
            }
        case .local:
            break
        }
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

// MARK: - Every terminal, and the machines they run on

/// Every native session terminal, one per session, kept while the session lives.
@MainActor
final class NativeTerminalSessions {
    static let shared = NativeTerminalSessions()
    private var sessions: [String: NativeTerminalSession] = [:]
    private var watchingRail = false

    func session(for id: String) -> NativeTerminalSession {
        if let existing = sessions[id], !existing.removed { return existing }
        let made = NativeTerminalSession(target: SessionTarget(tabId: id) ?? .local(id))
        sessions[id] = made
        watchRail()
        return made
    }

    /// The session is gone from the engine (or its tab from the page): stop
    /// listening for it. A screen still showing it keeps its last frame and the card.
    func forget(_ id: String) {
        sessions[id]?.shutDown()
        sessions[id] = nil
    }

    /// A session on another machine has nothing in the engine that says its tab
    /// closed; the rail does. When its row leaves the rail, detach — as the page's
    /// pane did when it unmounted.
    private func watchRail() {
        guard !watchingRail else { return }
        watchingRail = true
        let ids = Self.railIds()
        withObservationTracking { _ = AppModel.shared.sidebar } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchingRail = false
                let now = Self.railIds()
                for (id, session) in self.sessions where session.isRemote && ids.contains(id) && !now.contains(id) {
                    self.forget(id)
                }
                if !self.sessions.isEmpty { self.watchRail() }
            }
        }
    }

    private static func railIds() -> Set<String> {
        Set((AppModel.shared.sidebar?.projects ?? []).flatMap { $0.sessions.map(\.id) })
    }
}

/// What `machines:list` / `machines:state` say about his paired machines — the
/// names, the links and their sessions — for every native terminal on one of them.
@MainActor
@Observable
final class NativeMachineLinks {
    static let shared = NativeMachineLinks()
    private(set) var snapshot = MachinesSnapshot.empty
    private(set) var loaded = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private let terminals = NSHashTable<NativeTerminalSession>.weakObjects()

    func follow(_ terminal: NativeTerminalSession) { terminals.add(terminal) }

    func start() {
        guard !started else { return }
        started = true
        subscription = EngineBridge.shared.on("machines:state") { [weak self] args in
            guard let self, let view = MachinesSnapshot.decode(args.first) else { return }
            self.update(view)
        }
        Task { [weak self] in
            guard let view = MachinesSnapshot.decode(try? await EngineBridge.shared.invoke("machines:list")) else { return }
            self?.update(view)
        }
    }

    private func update(_ view: MachinesSnapshot) {
        snapshot = view
        loaded = true
        for terminal in terminals.allObjects { terminal.machineLinksChanged() }
    }
}

// MARK: - What Hoot's tour reads of this terminal (lane A's `DriveTerminalView`)

/// SwiftTerm's buffer as `locateQuote` reads it, in scroll-invariant line numbers
/// (they hold while old lines are trimmed off the top). Read on the main thread only.
private struct SwiftTermBufferReader: TerminalBufferReader {
    let terminal: Terminal
    let first: Int
    let end: Int
    var cols: Int { terminal.cols }

    init(_ terminal: Terminal) {
        self.terminal = terminal
        first = terminal.buffer.totalLinesTrimmed
        // One past the last line held: at least the screen, found by doubling then halving.
        var low = first + terminal.buffer.yDisp + terminal.rows
        while terminal.getScrollInvariantLine(row: low - 1) == nil, low > first { low -= 1 }
        var step = 1
        while terminal.getScrollInvariantLine(row: low + step - 1) != nil { low += step; step *= 2 }
        while step > 1 {
            step /= 2
            if terminal.getScrollInvariantLine(row: low + step - 1) != nil { low += step }
        }
        end = low
    }

    func line(_ index: Int) -> String? {
        terminal.getScrollInvariantLine(row: index)?.translateToString(trimRight: true)
    }
}

extension NativeTerminalSession {
    /// The terminal's screen in the main window (top-left origin), its size in cells,
    /// and where its view is in the buffer. Not rendered while it is out in another window.
    func driveView() -> DriveTerminalView? {
        let model = terminal.getTerminal()
        guard model.cols > 0, model.rows > 0 else { return nil }
        let font = terminal.font
        let cellWidth = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(model.rows)
        var screen = DriveRect(x: 0, y: 0, width: 0, height: 0)
        let window = terminal.window
        if let window, let content = window.contentView {
            let r = terminal.convert(terminal.bounds, to: nil)
            screen = DriveRect(x: r.minX, y: content.frame.height - r.maxY,
                               width: cellWidth * CGFloat(model.cols), height: cellHeight * CGFloat(model.rows))
        }
        let rendered = window != nil && window === AppModel.shared.web.webView.window
            && !terminal.isHiddenOrHasHiddenAncestor && terminal.alphaValue > 0 && screen.hasArea
        return DriveTerminalView(reader: SwiftTermBufferReader(model),
                                 metrics: TerminalMetrics(screen: screen, cols: model.cols, rows: model.rows),
                                 viewportY: model.buffer.totalLinesTrimmed + model.buffer.yDisp,
                                 alternateBuffer: model.isCurrentBufferAlternate,
                                 rendered: rendered)
    }

    /// `term.scrollToLine`: a scroll-invariant line at the top of the screen.
    func scrollDrive(toLine line: Int) {
        let model = terminal.getTerminal()
        terminal.scrollTo(row: max(0, line - model.buffer.totalLinesTrimmed))
    }
}
