import AppKit
import SwiftUI
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
    /// HOSTLOST: in-process note from the session-host bridge (no engine channel involved).
    @ObservationIgnored private var hostLostObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var holdTimer: Task<Void, Never>?
    @ObservationIgnored private var quietTimer: Task<Void, Never>?
    @ObservationIgnored private var noteTimer: Task<Void, Never>?
    @ObservationIgnored private var remoteChain: Task<Void, Never>?
    @ObservationIgnored private var lastSentSize: (cols: Int, rows: Int)?
    /// 28 Oct (Asad: the session follows the device where it was chosen last): who has this session's size now.
    /// While it is not this Mac, this terminal is frozen at the last frame drawn for it (what the program prints
    /// meanwhile is drawn for another screen and is not written here); it is redrawn from the session when it comes
    /// back. Nil until the session has said.
    private(set) var owner: TerminalOwner?
    /// "Open on <device>" with "Move back here": the other device took the session while this terminal was showing
    /// it (or it came on screen here without being chosen). Never shown when he chose it here: it just comes.
    private(set) var showsMoveBack = false
    /// Taking it back here is under way: the cover (that panel, or the frozen last frame) stays until the program
    /// has redrawn for this Mac.
    private(set) var takingBack = false
    /// He chose the session on this Mac (its session list, tab strip, ⌘-number): it comes here once it has a size.
    @ObservationIgnored private var chosenHere = false
    /// 28 Oct (bug B): this terminal is on screen but the phone screen beside it holds the keyboard, so what he types
    /// goes into the phone (and into whatever session the phone app has open), not here. Drawn over the terminal.
    private(set) var keyboardInPhone = false
    @ObservationIgnored private var keyboardObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var frozen = false
    /// A terminal on a server: what its tab says, and the shell once it is open.
    private(set) var serverInfo: ServerTabInfo?
    private(set) var shellId: String?
    @ObservationIgnored private var frames = ShellFrames()
    /// True while history is being written: answers the terminal would give to
    /// queries in old output (cursor reports, device attributes) and clipboard
    /// copies made long ago must not reach the live program or this Mac's clipboard.
    @ObservationIgnored private var replaying = false
    @ObservationIgnored private var visibleScreens = 0
    /// PERF: live output waiting for the next main-queue turn (`receive`), and whether that turn is booked.
    @ObservationIgnored private var pendingOutput = ""
    @ObservationIgnored private var outputFlushQueued = false
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

    /// A chat session (Asad, 13 Oct): its window is Hoot's own chat screen on this session's conversation.
    var isChat: Bool { info?.chat == true }
    @ObservationIgnored private var chatModelMade: NativeHootChatModel?
    var chatLoading: Bool? { chatModelMade?.loading }
    var chatDisplayState: NativeRPCValue? { chatModelMade?.displayState }
    /// The one chat model of this session (made the first time its screen shows it).
    func chatModel() -> NativeHootChatModel {
        if let chatModelMade { return chatModelMade }
        let source = HootChatSource.session(sessionId, provider: info?.provider ?? "claude")
        let made = NativeHootChatModel.forSession(sessionId, name: source.agentName)
        chatModelMade = made
        return made
    }

    /// On another machine or a server: nothing in the engine says when its tab closed.
    var isRemote: Bool {
        if case .local = target { return false }
        return true
    }

    /// `attached: false` is a session already gone: its bar and ended card, with nothing asked of the engine.
    @ObservationIgnored private let restart: @MainActor () -> Void

    init(target: SessionTarget, attached: Bool = true, restart: @escaping @MainActor () -> Void = NativeTerminalSession.restartAndResume) {
        self.restart = restart
        self.target = target
        controlsState = NativeSessionControlsState(target: target)
        usageState = NativeUsageState(target: target)
        let settings = NativeTerminalSettings.shared
        terminal = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: settings.preferences.nsFont)
        container = DeckTerminalContainer(terminal: terminal)
        terminal.host = self
        delegateProxy.owner = self
        controlsState.session = self
        terminal.eventDelegate = delegateProxy
        terminal.optionAsMetaKey = false       // xterm's default: ⌥ types the character the layout gives
        terminal.lineSpacing = Self.lineSpacing
        terminal.alphaValue = 0                // held until the history is in
        applyAppearance()
        settings.follow(self)
        settings.start()
        guard attached else {
            removed = true
            _ = backfill.release(backlog: nil)
            setEnd(.exited(code: nil))
            return
        }
        keyboardObserver = NotificationCenter.default.addObserver(forName: NativeTerminalKeyboard.holderChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyboardPlace() }
        }
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
        subscriptions.append(bridge.on("session:owner") { [weak self] args in
            guard let self, Self.string(args, 0) == id, let owner = TerminalOwner.parse(args.count > 1 ? args[1] : nil) else { return }
            self.ownerSaid(owner)
        })
        hostLostObserver = NotificationCenter.default.addObserver(forName: .tdSessionHostLost, object: nil, queue: .main) { [weak self] note in
            guard let ids = note.userInfo?["ids"] as? [String], ids.contains(id) else { return }
            MainActor.assumeIsolated {
                guard let self, self.end == nil else { return }
                let provider = self.info?.provider ?? ""
                self.setEnd(.hostLost(agent: ["claude", "codex", "gemini"].contains(provider)))
            }
        }
        subscriptions.append(bridge.on("session:removed") { [weak self] args in
            guard let self, Self.string(args, 0) == id else { return }
            self.removed = true
            if self.end == nil { self.setEnd(.exited(code: nil)) }
            NativeTerminalSessions.shared.forget(self.sessionId)
        })
        startHoldClock()
        Task { [weak self] in
            // Who has it first (28 Oct): a screen drawn for another device is never shown here.
            let owner = try? await bridge.invoke("session:owner", [id])
            self?.ownerSaid(TerminalOwner.parse(owner) ?? .mac)
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
            do { try AppModel.shared.buttonActions.serverEnded(tabId) }
            catch { self.say("The terminal ended, but its tab could not be updated.", sticky: true) }
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
        do { try AppModel.shared.buttonActions.serverOpened(sessionId, shell: id) }
        catch { say("The terminal opened, but its tab could not be updated.", sticky: true) }
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
        // Drawn for another device's screen (28 Oct): this terminal keeps its last frame; it is redrawn from the
        // session when the session comes back here.
        if frozen, !backfill.isHolding { return }
        guard let now = backfill.push(chunk) else { scheduleControlsRead(); return }
        // PERF: output arrives as many small chunks (one engine event each). Chunks that arrive
        // together are written to the terminal in one go on the next turn of the main queue, so the
        // terminal parses, schedules its redraw and the session bar re-arms its read once per batch,
        // not once per chunk. Order is kept: every other write first flushes what is waiting.
        pendingOutput += now
        guard !outputFlushQueued else { return }
        outputFlushQueued = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushOutput() } }
    }

    private func flushOutput() {
        outputFlushQueued = false
        guard !pendingOutput.isEmpty else { return }
        let text = pendingOutput
        pendingOutput = ""
        terminal.feed(text: text)
        scheduleControlsRead()
    }

    private func release(_ history: String?) {
        flushOutput()
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
        // Drawn for another device (28 Oct): kept out of sight until it is taken back here or the panel covers it.
        terminal.alphaValue = end != nil ? Self.endedAlpha : owner?.here == false && !takingBack ? 0 : 1
        sendSize(force: true)
        reconsider()
    }

    /// A completed account switch already returned this metadata. Use it before
    /// painting the replacement so a chat never briefly looks like a terminal.
    func adoptSessionMetadata(_ row: [String: Any]) {
        guard let found = TerminalSessionInfo.decode(row), found.id == sessionId else { return }
        if info?.provider != found.provider { chatModelMade = nil }
        info = found
        usageState.useChatContext(found.chat)
    }

    /// The session record: title, folder, agent, account and whether it has already ended.
    func refreshInfo() {
        guard case .local(let id) = target else { return }
        Task { [weak self] in
            guard let list = try? await EngineBridge.shared.invoke("session:list") else { return }
            guard let self, let found = TerminalSessionInfo.find(id, in: list) else { return }
            self.info = found
            self.usageState.useChatContext(found.chat)
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
        refreshKeyboardPlace()
    }

    func screenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
        // 28 Oct (bug B): a screen that has gone never takes the keyboard later (a stale ask grabbed it the next time
        // this terminal was laid out anywhere, away from the session he was typing in).
        if visibleScreens == 0 { wantsFocus = false }
        refreshKeyboardPlace()
    }

    /// The terminal joined a window: once it has been laid out there, tell the
    /// session its size again — the page's own terminal for this session may have
    /// resized it in between — and take the keyboard if a screen just asked for it.
    func viewDidAppearInWindow() {
        announceSize = true
        // 28 Oct (bug B): the keyboard comes with the session he switched to as soon as its terminal is in the
        // window, not only if a later layout happens (a pane the same size as the last one is not laid out again).
        if wantsFocus {
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.wantsFocus == true { self?.focus() } } }
        }
    }

    /// 28 Oct (bug B): whether "Typing goes to the phone" shows over this terminal (`TerminalKeyboardNotice`).
    func refreshKeyboardPlace() {
        let next = TerminalKeyboardNotice.phoneHasTheKeyboard(terminalOnScreen: visibleScreens > 0 && terminal.window != nil,
            sessionLive: end == nil && !isChat && !showsMoveBack, holderIsPhoneInSameWindow: NativeTerminalKeyboard.phoneHolds(terminal.window))
        if next != keyboardInPhone { keyboardInPhone = next }
    }

    /// The notice's own click: the keyboard comes to this terminal (a click is his, so a phone screen lets go).
    func typeHere() {
        guard end == nil, !showsMoveBack, let window = terminal.window else { return }
        window.makeFirstResponder(terminal)
        refreshKeyboardPlace()
    }

    /// The pane has its real size (called from the container's layout).
    func layoutSettled() {
        reconsider()
        if announceSize, terminal.bounds.width > 0, terminal.bounds.height > 0 {
            announceSize = false
            sendSize(force: true)
        }
        if wantsFocus { focus() }
    }

    /// Give the terminal the keyboard (the web pane focuses the terminal it shows).
    func cancelPendingFocus() { wantsFocus = false }

    func focus() {
        guard terminal.inputActive else { wantsFocus = false; return }
        guard !showsMoveBack else { return }
        guard end == nil, let window = terminal.window else {
            wantsFocus = end == nil && !isChat && visibleScreens > 0
            return
        }
        wantsFocus = false
        if window.firstResponder !== terminal { DeckTerminalSlot.requestFocus(for: terminal) }
        refreshKeyboardPlace()
    }

    /// The press on the ended card. A local session: the same New session dialog
    /// every other new session in the app opens, on this session's project. A
    /// session on another machine: dial it (`connectMachine`, as `RemoteTerminal`).
    func act(_ action: SessionEndNotice.ActionID) {
        if action == .relaunch { restart(); return }
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

    /// A name typed on the bar: given to the session here (`session:rename`, straight to the engine, never through
    /// the page: Asad, 12 Oct, renames did nothing), or to the far machine, which announces it back to every window.
    /// A name that cannot be saved is said on this session's own line.
    func rename(to name: String) {
        switch target {
        case .local:
            if let info { self.info = info.renamed(name) }
            NativeSessionNames.shared.rename(tabId: target.tabId, typed: name) { [weak self] line in self?.say(line) }
        case .machine:
            NativeSessionNames.shared.rename(tabId: target.tabId, typed: name) { [weak self] line in self?.say(line) }
        case .server:
            break
        }
    }

    // MARK: Ending

    /// HOSTLOST: quit (detaching whatever still runs) and open this app again; the saved tabs of the
    /// lost sessions are still on record, so the restore at launch resumes them.
    static func restartAndResume() {
        let bundle = Bundle.main.bundleURL.path, pid = getpid()
        // It must outlive this app: its own group, kept by nothing here.
        do { try NativeChild.launchDetached(.init("/bin/sh", ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", bundle])) }
        catch { return }
        NativeSVResident.shared.noteSignal() // no question, no detach handshake with a host that is gone
        NativeQuit.terminate("the session host being lost (the app opens again to resume)")
    }

    static let endedAlpha: CGFloat = 0.45

    /// A local or server session ends once; a machine's can come back with its link.
    private func setEnd(_ next: SessionEnd?) {
        guard next != end else { return }
        if end != nil, next == nil, target.machineId == nil { return }
        end = next
        terminal.freeze(next != nil)
        refreshKeyboardPlace()
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
        // While another device has the session and its panel shows here, nothing typed here reaches the program
        // (Asad, 28 Oct: typing is not choosing; he chooses with "Move back here" or the session list).
        guard !replaying, end == nil, !bytes.isEmpty, !showsMoveBack else { return }
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
        terminal.sendExplicitText(TerminalText.pasteData(text, bracketed: terminal.getTerminal().bracketedPasteMode))
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
            // The session takes this size while this Mac has it (28 Oct, `owner`); otherwise it is kept for later.
            EngineBridge.shared.send("session:resize", [id, size.cols, size.rows])
        case .machine(let machineId, let sessionId):
            remote("machines:resize", [machineId, sessionId, size.cols, size.rows])
        case .server:
            if let shellId { remote("servers:shell:resize", [shellId, size.cols, size.rows]) }
        }
    }

    // MARK: Where the session is used (28 Oct)

    /// The session said who has its size (an answer or an event; a later turn wins).
    private func ownerSaid(_ next: TerminalOwner) {
        if let owner, next.turn < owner.turn { return }
        let wasHere = owner?.here ?? true
        owner = next
        if !next.here {
            frozen = true
            // Taken by the other device while this terminal is showing it: the panel, at once.
            if terminal.window != nil, !chosenHere, !takingBack { showMoveBack() }
        } else if !wasHere, frozen, !takingBack {
            // Back here without this Mac choosing it (it never happens today): redraw from the session all the same.
            takeBack()
            return
        }
        reconsider()
    }

    /// He chose this session on this Mac: it comes here, with no question (`NativeTerminalSessions.chosenHere`).
    func choseHere() {
        guard case .local = target, !removed else { return }
        chosenHere = true
        reconsider()
    }

    /// The panel's "Move back here".
    func moveBackHere() {
        guard showsMoveBack, !takingBack else { return }
        takeBack()
    }

    /// Decides what this terminal does now: take the session (chosen here, once it has a size), show the panel (it
    /// is showing a session another device has), or nothing.
    private func reconsider() {
        guard case .local = target, !removed, end == nil, !isChat, let owner else { return }
        let shown = terminal.window != nil && terminal.bounds.width > 0 && terminal.bounds.height > 0 && !backfill.isHolding
        if owner.here {
            chosenHere = false
            return
        }
        guard shown, !takingBack else { return }
        if chosenHere {
            chosenHere = false
            takeBack()
        } else if !showsMoveBack {
            showMoveBack()
        }
    }

    private func showMoveBack() {
        showsMoveBack = true
        // Typing is not choosing (Asad, 28 Oct): the keyboard lets go of a terminal that is not drawn here.
        if let window = terminal.window, window.firstResponder === terminal { window.makeFirstResponder(nil) }
        refreshKeyboardPlace()
    }

    /// Take the session here: this Mac owns its size again (`session:use`, which answers once the program has
    /// redrawn for this size), then this terminal is redrawn from the session as it is now and fades in. The cover
    /// meanwhile is the panel, or the frozen last frame when he chose the session here.
    private func takeBack() {
        guard case .local(let id) = target, !takingBack else { return }
        takingBack = true
        let size = terminal.getTerminal()
        lastSentSize = (size.cols, size.rows)
        Task { [weak self] in
            let answer = try? await EngineBridge.shared.invoke("session:use", [id, size.cols, size.rows])
            guard let self else { return }
            guard let taken = TerminalOwner.parse(answer), !self.removed, self.end == nil else {
                self.takingBack = false
                if self.owner?.here == false, self.terminal.window != nil { self.showMoveBack() }
                return
            }
            self.ownerSaid(taken)
            self.flushOutput()
            self.backfill = TerminalBackfill()
            self.frozen = false
            self.startHoldClock()
            let history = try? await EngineBridge.shared.invoke("session:scrollback", [id])
            // A full reset first: what this terminal held was drawn for the other screen.
            self.release(history.flatMap { Self.decodeText($0) }.map { "\u{1b}c" + $0 })
            self.takingBack = false
            // Another device chose it again while it was coming here: it stays with that one.
            if self.owner?.here == false {
                self.frozen = true
                if self.terminal.window != nil { self.showMoveBack() }
                return
            }
            if self.showsMoveBack {
                withAnimation(.easeOut(duration: 0.18)) { self.showsMoveBack = false }
                self.refreshKeyboardPlace()
            } else {
                // Chosen here: the frozen frame gives way to the finished screen, faded in.
                self.terminal.alphaValue = 0
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    self.terminal.animator().alphaValue = 1
                }, completionHandler: nil)
            }
            self.focus()
        }
    }

    /// The terminal left its window (its tab is no longer the selected one): it shows nothing, so no panel either.
    func windowChanged() {
        if terminal.window == nil, !takingBack { showsMoveBack = false }
        reconsider()
        refreshKeyboardPlace()
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
        // U143 (#183): a closed terminal leaves no host-lost listener behind.
        if let hostLostObserver { NotificationCenter.default.removeObserver(hostLostObserver) }
        hostLostObserver = nil
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        keyboardObserver = nil
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
@Observable
final class NativeTerminalSessions {
    static let shared = NativeTerminalSessions()
    private var sessions: [String: NativeTerminalSession] = [:]
    private var watchingRail = false
    /// Sessions let go this run. A screen rebuilt for one gets it back shut down; it never attaches again.
    private(set) var gone: Set<String> = []
    /// The last few of those, as they were, so a screen still showing one keeps its last frame and card.
    @ObservationIgnored private var ended: [String: NativeTerminalSession] = [:]
    @ObservationIgnored private var endedOrder: [String] = []
    private static let endedKept = 6

    func isChat(_ id: String) -> Bool { sessions[id]?.isChat == true }

    func session(for id: String) -> NativeTerminalSession {
        let switching = NativeSessionRailContinuity.shared.isSwitching(id)
        if let existing = sessions[id], !existing.removed || switching { return existing }
        if gone.contains(id), !switching {
            if let kept = ended[id] { return kept }
            let closed = NativeTerminalSession(target: SessionTarget(tabId: id) ?? .local(id), attached: false)
            keepEnded(id, closed)
            return closed
        }
        let made = NativeTerminalSession(target: SessionTarget(tabId: id) ?? .local(id))
        sessions[id] = made
        watchRail()
        if chosenBeforeMade == id { chosenBeforeMade = nil; made.choseHere() }
        return made
    }

    /// 28 Oct (Asad: "On the Mac, if I'm on another session and click that session, it comes to the Mac"): a session
    /// selected while he is choosing in the session list, the tab strip or with ⌘-number (`chooser`) comes here at
    /// once, from a phone that had it. A selection from anywhere else (Hoot moving through the app, a restored tab, a
    /// tool) never takes a session from his phone, however soon after one of his clicks it comes.
    func chosenHere(_ id: String) {
        guard chooser.place != nil else { return }
        // 28 Oct (bug B): his choice of a session also brings the keyboard to it, from a phone screen holding it
        // too (`TerminalKeyboardChoice`); its terminal takes it now if it is already showing, or as it lands.
        NativeTerminalKeyboard.noteChoice()
        if let session = sessions[id], !session.removed, session.terminal.window != nil { session.focus() }
        guard case .local? = SessionTarget(tabId: id) else { return }
        if let session = sessions[id], !session.removed { session.choseHere() } else { chosenBeforeMade = id }
    }
    @ObservationIgnored private var chosenBeforeMade: String?
    /// Which of those places his current selection is being made in (`TerminalChooser`).
    let chooser = TerminalChooser()
    func retainedSession(_ id: String) -> NativeTerminalSession? { sessions[id] }
    var chatDisplayStates: NativeRPCValue {
        .object(sessions.compactMap { id, session in session.chatDisplayState.map { .init(id, $0) } })
    }

    /// The session is gone from the engine (or its tab from the page): stop
    /// listening for it. A screen still showing it keeps its last frame and the card.
    func forget(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.shutDown()
        gone.insert(id)
        keepEnded(id, session)
        watchRail()
    }

    private func keepEnded(_ id: String, _ session: NativeTerminalSession) {
        ended[id] = session
        endedOrder.removeAll { $0 == id }
        endedOrder.append(id)
        while endedOrder.count > Self.endedKept { ended[endedOrder.removeFirst()] = nil }
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
                // A row back on the rail (a machine linked again) is live again: its next screen attaches.
                for id in self.gone.intersection(now.subtracting(ids)) {
                    self.gone.remove(id)
                    self.ended[id] = nil
                    self.endedOrder.removeAll { $0 == id }
                }
                if !self.sessions.isEmpty || !self.gone.isEmpty { self.watchRail() }
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

extension Notification.Name {
    /// HOSTLOST (9 Oct): userInfo["ids"] = the sessions whose background host died or was replaced.
    static let tdSessionHostLost = Notification.Name("dev.terminaldeck.session-host-lost")
}
