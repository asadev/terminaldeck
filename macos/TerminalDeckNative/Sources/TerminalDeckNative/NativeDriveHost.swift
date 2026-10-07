import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Hoot driving the app, drawn natively — copilot/driving/DriveHost.tsx with
/// driving/DriveLayer, FocusOverlay and ScanField. It takes `deck-control:tour`,
/// plays it on the native screens (the tour player in Core), boxes each stop over
/// the main window with the rest dimmed, runs the scan field, shows the drive panel
/// over the side panel, and reports back on `deck-control:tour-report`.
///
/// The overlay is two windows of this app's own, attached to the main window: one
/// that draws and never takes a click, one for the panel. Neither activates the app.
@MainActor
@Observable
final class DriveHost: DriveNavigating, DriveFocusing {
    static let shared = DriveHost()

    /// The page's id for this, in `NativeScreens.registered`: while it is there the
    /// page stops mounting its own DriveHost and the native one runs.
    static let screenId = "drive"

    private(set) var view: TourView?
    private(set) var target: FocusTarget?
    private(set) var lit = true
    private(set) var resolution: DriveResolution?
    /// The browser the agent is driving, for the rail (`DriveNow`).
    private(set) var now: DriveNow?
    private(set) var copilotSessionId: String?

    @ObservationIgnored private var player: TourPlayer?
    @ObservationIgnored private var unplay: (() -> Void)?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var cachedRegion: BufferRegion?
    @ObservationIgnored private var cwds: [String: String] = [:]
    @ObservationIgnored private var measureTimer: Timer?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored let overlay = DriveOverlay()

    var playing: Bool { view != nil }

    /// Hoot's own row is in front: the panel steps aside, as on the page.
    var copilotFront: Bool { AppModel.shared.currentScreen?.kind == "hoot" }

    // MARK: Start

    /// Once, at launch. Inert unless the native side owns driving (see `screenId`).
    func start() {
        guard !started, NativeScreens.registered.contains(Self.screenId) else { return }
        started = true
        let bridge = EngineBridge.shared
        subscriptions.append(bridge.on(DriveTour.channel) { [weak self] args in self?.play(args.first) })
        subscriptions.append(bridge.on("browser:drive-state") { [weak self] args in self?.now = DriveNow.of(args.first) })
        Task {
            if let state = try? await bridge.invoke("copilot:state", []) as? [String: Any] {
                copilotSessionId = state["sessionId"] as? String
            }
            now = DriveNow.of(try? await bridge.invoke("browser:drive-status", []))
        }
    }

    // MARK: A tour

    private func play(_ raw: Any?) {
        guard let message = DriveTour.read(raw) else { return }
        player?.end()
        Task {
            // The folder each session runs in, for a git stop and for `where`.
            if let list = try? await EngineBridge.shared.invoke("session:list", []) as? [Any] {
                for case let row as [String: Any] in list {
                    if let id = row["id"] as? String, let cwd = row["cwd"] as? String { cwds[id] = cwd }
                }
            }
            begin(message)
        }
    }

    private func begin(_ message: TourMessage) {
        let start = ProcessInfo.processInfo.systemUptime
        let engine = ScanEngine(
            now: { (ProcessInfo.processInfo.systemUptime - start) * 1000 },
            requestFrame: { tick in
                let timer = Timer(timeInterval: 1.0 / 60, repeats: false) { _ in tick() }
                RunLoop.main.add(timer, forMode: .common)
                return timer
            },
            cancelFrame: { ($0 as? Timer)?.invalidate() })
        let running = TourPlayer(
            message: message, copilotSessionId: copilotSessionId, engine: engine, navigator: self, focus: self,
            report: { kind, record in
                Task {
                    _ = try? await EngineBridge.shared.invoke(DriveTour.reportChannel,
                                                              [["kind": kind.rawValue, "tourId": record.id, "record": record.wire]])
                }
            },
            now: { Date().timeIntervalSince1970 * 1000 },
            perfNow: { (ProcessInfo.processInfo.systemUptime - start) * 1000 },
            schedule: { ms, action in
                let job = DriveJob(run: action)
                let timer = Timer(timeInterval: ms / 1000, repeats: false) { _ in MainActor.assumeIsolated { job.run() } }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            })
        player = running
        view = running.view
        unplay = running.subscribe { [weak self, weak running] in
            MainActor.assumeIsolated {
                guard let self, let running else { return }
                let next = running.view
                if next.ended {
                    self.unplay?()
                    if self.player === running { self.player = nil }
                    self.view = nil
                    self.overlay.hide()
                    self.stopWatching()
                } else {
                    self.view = next
                }
            }
        }
        overlay.show(host: self)
        startWatching()
    }

    /// TourRecap's "Take me there": box one recorded stop with no tour running; nil takes it off.
    func point(_ target: FocusTarget?) {
        guard player == nil else { return }
        guard let target else {
            clearFocus()
            overlay.hide()
            return
        }
        overlay.show(host: self, panel: false)
        setFocus(target, lit: true)
    }

    func command(_ name: TourCommand) { player?.command(name) }
    func jump(_ index: Int) { player?.jump(index) }

    /// Say something to Hoot while it works (`sendToTerminal`): the text, then Enter.
    func say(_ text: String) {
        guard let id = copilotSessionId else { return }
        let payload = text.contains("@") ? "\(text) " : text
        EngineBridge.shared.send("session:write", [id, payload])
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            EngineBridge.shared.send("session:write", [id, "\r"])
        }
    }

    var canSay: Bool { view != nil && copilotSessionId != nil }

    /// "Open Hoot’s own window".
    func fold() { AppModel.shared.select("hoot") }

    /// "Don’t show me next time": interactive mode off, and this tour ends.
    func quiet() {
        Task { _ = try? await EngineBridge.shared.invoke("settings:set", [["copilot.interactive": false]]) }
        player?.end()
    }

    // MARK: DriveNavigating

    func selectTab(_ sessionId: String) { AppModel.shared.select(sessionId) }
    func showPanel(_ id: String, focus: String?) { DeckPage.navigate(id, focus: focus) }

    func cwdOf(_ sessionId: String) -> String? {
        if let project = AppModel.shared.sidebar?.projects.first(where: { $0.sessions.contains { $0.id == sessionId } }),
           ArtifactRules.isFolder(project.id) {
            return project.id
        }
        return cwds[sessionId]
    }

    // MARK: DriveFocusing

    func setFocus(_ target: FocusTarget, lit: Bool) {
        if self.target != target { cachedRegion = nil }
        self.target = target
        self.lit = lit
        measure()
        startMeasuring()
    }

    func setLit(_ lit: Bool) { self.lit = lit }

    func clearFocus() {
        target = nil
        resolution = nil
        cachedRegion = nil
        measureTimer?.invalidate()
        measureTimer = nil
    }

    func failure(_ target: FocusTarget) -> FocusFailure? {
        var scratch: BufferRegion?
        if case .failed(let why) = resolve(target, cached: &scratch) { return why }
        return nil
    }

    func scrollTo(_ target: FocusTarget) {
        guard case .terminal(let sessionId, let quote) = target, failure(target) != nil,
              let view = DriveAnchors.shared.terminal(sessionId), let line = DriveFocusResolver.scrollLine(for: quote, in: view) else { return }
        DriveAnchors.shared.scrollers[sessionId]?(line)
        cachedRegion = nil
    }

    private func resolve(_ target: FocusTarget, cached: inout BufferRegion?) -> DriveResolution {
        let anchors = DriveAnchors.shared
        return DriveFocusResolver.resolve(target, viewport: overlay.viewport, frame: { anchors.frame($0) },
                                          page: anchors.frame(DriveAnchors.pageId), terminal: { anchors.terminal($0) }, cached: &cached)
    }

    /// Measure again; report to the player whenever the answer changes (`FocusReport`).
    private func measure() {
        guard let target else { return }
        let next = resolve(target, cached: &cachedRegion)
        let changed: Bool
        switch (resolution, next) {
        case (.drawn(let a, _, _)?, .drawn(let b, _, _)): changed = !DriveGeometry.same(a, b)
        case (.failed(let a)?, .failed(let b)): changed = a != b
        default: changed = true
        }
        guard changed else { return }
        resolution = next
        switch next {
        case .drawn: player?.reported(drawn: true, why: nil)
        case .failed(let why): player?.reported(drawn: false, why: why)
        }
    }

    /// The page re-measures on every scroll, resize and terminal render; here, a
    /// light 30 Hz check while something is boxed does the same job.
    private func startMeasuring() {
        guard measureTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
        RunLoop.main.add(timer, forMode: .common)
        measureTimer = timer
    }

    // MARK: Holding the scan when the person does something (interruption.ts)

    private func startWatching() {
        stopWatching()
        let panel = overlay.panelWindow
        func inPanel(_ event: NSEvent) -> Bool { event.window != nil && event.window === panel }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, let player = self.player else { return event }
            if inPanel(event), event.window?.firstResponder is NSTextView { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let name = Self.transportKey(event) {
                return player.key(name) ? nil : event
            }
            if !inPanel(event) { player.interrupt(.typed) }
            return event
        }) { monitors.append(keys) }
        if let pointer = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            if !inPanel(event) { self?.player?.interrupt(.clicked) }
            return event
        }) { monitors.append(pointer) }
        if let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            if !inPanel(event) { self?.player?.interrupt(.scrolled) }
            return event
        }) { monitors.append(wheel) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.interrupt(.leftWindow) }
        })
        observers.append(center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.interrupt(.hidden) }
        })
        observers.append(center.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { [weak self] note in
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let text = object as? NSTextView, text.window !== panel, text.selectedRange().length > 0 else { return }
                self?.player?.interrupt(.selected)
            }
        })
    }

    private func stopWatching() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }

    private static func transportKey(_ event: NSEvent) -> String? {
        switch event.keyCode {
        case 49: return " "
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 53: return "Escape"
        default: return nil
        }
    }

    // MARK: Where the person is (where.ts)

    /// The page stops publishing `__terminaldeckWhere` while this host drives
    /// (main.tsx mounts no DriveHost), so Hoot's `app.where` reads this instead.
    /// `describeWhere`: the heading, the session in front and its pane, whether
    /// Hoot is in front, whether a tour is on screen, and every open session.
    func whereView() -> [String: Any] {
        let app = AppModel.shared
        let sessions = (app.sidebar?.projects.flatMap(\.sessions) ?? []).filter { $0.kind == .session }.map(\.id)
        let selected = app.sidebarSelection
        let front = selected.flatMap { id in sessions.contains(id) ? id : nil }
        return [
            "title": app.windowTitle,
            "sessionId": front.map { $0 as Any } ?? NSNull(),
            "pane": front == nil ? NSNull() : "terminal" as Any,
            "copilotFront": copilotFront,
            "driving": playing,
            "openSessions": sessions,
        ]
    }
}

/// A main-actor action handed to a timer.
private struct DriveJob: @unchecked Sendable { let run: () -> Void }
