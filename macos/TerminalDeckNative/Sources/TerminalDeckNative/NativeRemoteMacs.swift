import AppKit
import Carbon.HIToolbox
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// Asad, 31 Oct 2026 ("yes let it have that too"): from this Mac, see and fully use another Mac running Terminal Deck.
// The other Mac is one this Mac is already linked to (Devices › Machines you can reach: its pairing code, then "Let it
// in" with an access level on that Mac, as for a phone). Devices shows them under "Other Macs"; Open puts the screen in
// its own window. While the pointer is over the picture, this Mac's mouse and keyboard go to the other Mac.

/// The one door from the app to other Macs' screens.
@MainActor final class NativeRemoteMacs {
    static let shared = NativeRemoteMacs()
    private(set) var coordinator: BackendMachineCoordinator?
    private var windows: [String: NativeRemoteMacWindow] = [:]

    /// Called once the machine links exist (composition).
    func bind(_ coordinator: BackendMachineCoordinator) {
        self.coordinator = coordinator
        let link = BackendRemoteMacScreens.Link(
            send: { machine, type, fields in try await coordinator.link(machine).send(type: type, fields: fields, capability: "sims") },
            request: { machine, type, fields, replies in
                try await coordinator.link(machine).request(type: type, fields: fields, capability: "sims", replies: replies, timeoutMilliseconds: 15_000)
            },
            name: { machine in await coordinator.name(machine) },
            route: { machine in (try? await coordinator.link(machine).state().linkPath) ?? "" })
        Task { await BackendRemoteMacScreens.shared.bind(link) }
    }

    /// Shows one display of another Mac in its own window (or brings that window forward). Only for the person's own
    /// press (Open in Devices): the window never comes forward on its own (NativeFront).
    func open(machine: String, name: String, display: String, displays: [OtherMacDisplay]) {
        let key = machine + "|" + display
        NativeFront.whenPersonActs("remote-mac:" + key) { [weak self] in
            guard let self else { return }
            if let window = self.windows[key] { window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); return }
            let model = RemoteMacViewerModel(machine: machine, machineName: name, display: display, displays: displays)
            let window = NativeRemoteMacWindow(model: model) { [weak self] in self?.windows[key] = nil }
            self.windows[key] = window
            window.showWindow(nil)
            model.start()
        }
    }

    /// Every window showing another Mac (the MCP stop closes them).
    func closeAll() { for window in windows.values { window.close() } }
}

/// One display of another Mac, as its Devices row and the viewer's display menu show it.
struct OtherMacDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let pixels: String
    let canWatch: Bool
    let canControl: Bool
    let note: String
}

/// One linked Mac under "Other Macs".
struct OtherMac: Identifiable, Equatable {
    let id: String
    let name: String
    var phase: MachineLinkPhase
    var displays: [OtherMacDisplay] = []
    /// Why its displays are not listed (it refused, or it has no screen sharing yet).
    var problem: String?
}

/// "Other Macs" in the Devices window: the Macs this one is linked to, their state and their displays.
@MainActor @Observable final class OtherMacsModel {
    private(set) var macs: [OtherMac] = []
    @ObservationIgnored private var asked: Set<String> = []

    init(fixture: [OtherMac]? = nil) { if let fixture { macs = fixture } }

    /// Follows the machines view (paired machines and their links); a Mac that comes online is asked for its displays.
    func update(_ view: MachinesView) {
        let next = view.machines.filter { machine in
            let platform = view.link(for: machine.id).hostPlatform.isEmpty ? machine.platform : view.link(for: machine.id).hostPlatform
            return platform == "darwin" || platform.lowercased().hasPrefix("mac")
        }.map { machine -> OtherMac in
            let link = view.link(for: machine.id)
            var mac = macs.first { $0.id == machine.id } ?? OtherMac(id: machine.id, name: machine.name, phase: .offline)
            mac.phase = link.phase
            if link.phase == .online, !link.capabilities.contains("sims") {
                mac.problem = "\(machine.name) needs a newer Terminal Deck, with Work or Full control for this Mac, to share its screen."
            }
            if mac.phase != .online { mac.displays = []; asked.remove(machine.id) }
            return OtherMac(id: mac.id, name: machine.name, phase: mac.phase, displays: mac.displays, problem: mac.problem)
        }
        macs = next
        for mac in next where mac.phase == .online && !asked.contains(mac.id) { asked.insert(mac.id); Task { await readDisplays(mac.id) } }
    }

    func readDisplays(_ id: String) async {
        do {
            let rows = try await BackendRemoteMacScreens.shared.displays(id)
            let displays = rows.compactMap { row -> OtherMacDisplay? in
                guard let display = row["id"].string else { return nil }
                return OtherMacDisplay(id: display, name: row["name"].string ?? display, pixels: row["runtime"].string ?? "",
                                       canWatch: row["canWatch"].bool ?? true, canControl: row["canControl"].bool ?? true, note: row["note"].string ?? "")
            }
            set(id) { $0.displays = displays; $0.problem = displays.isEmpty ? "That Mac lists no displays." : nil }
        } catch {
            let words = (error as? NativeRPCError)?.message ?? error.localizedDescription
            set(id) { $0.problem = words }
        }
    }

    private func set(_ id: String, _ change: (inout OtherMac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else { return }
        change(&macs[index])
    }
}

/// The "Other Macs" card in the Devices window.
struct NativeOtherMacsCard: View {
    let model: OtherMacsModel
    var open: (OtherMac, OtherMacDisplay) -> Void = { mac, display in
        NativeRemoteMacs.shared.open(machine: mac.id, name: mac.name, display: display.id, displays: mac.displays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Other Macs").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("See and use their screens").font(.caption).foregroundStyle(.secondary)
            }
            if model.macs.isEmpty {
                Text("Pair another Mac running Terminal Deck (Pair a device on that Mac, then its code here) to see and use its screen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.macs) { mac in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").font(.system(size: 18)).foregroundStyle(mac.phase == .online ? Color.accentColor : .secondary)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill((mac.phase == .online ? Color.accentColor : Color.secondary).opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).font(.system(size: 13, weight: .semibold))
                            HStack(spacing: 5) {
                                Circle().fill(mac.phase == .online ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                                Text(mac.phase == .online ? "Online" : mac.phase.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if mac.phase == .online, mac.displays.count == 1, let display = mac.displays.first {
                            Button("Open") { open(mac, display) }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    if mac.phase == .online, mac.displays.count > 1 {
                        ForEach(mac.displays) { display in
                            HStack {
                                Image(systemName: "display").foregroundStyle(.secondary)
                                Text(display.name).font(.callout)
                                Text(display.pixels).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Open") { open(mac, display) }.buttonStyle(.bordered).controlSize(.small)
                            }
                            .padding(.leading, 42)
                        }
                    }
                    if let note = mac.displays.first(where: { !$0.note.isEmpty })?.note ?? mac.problem {
                        Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 42).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("otherMacs.\(mac.id)")
            }
        }
    }
}

// MARK: - The viewer

/// One other Mac's screen in its window: the picture, its state, and what this Mac sends.
@MainActor @Observable final class RemoteMacViewerModel {
    let machine: String
    let machineName: String
    private(set) var display: String
    let displays: [OtherMacDisplay]
    private(set) var state = "opening"
    private(set) var note = ""
    /// A click, key or watch the other Mac refused, shown for a few seconds.
    var refusal: String?
    private(set) var image: CGImage?
    /// How the screen comes: "direct" or "via Cloudflare" (3 Nov: the direct link); empty on an older Mac's relay.
    private(set) var route = ""
    /// Actual size (one picture pixel per screen pixel here) instead of fitting the window.
    var actualSize = false
    /// ⌘ shortcuts (⌘Q, ⌘W, ⌘Tab's ⌘ part, ⌘Space…) go to the other Mac while the pointer is over the picture.
    var commandKeysToRemote = true
    @ObservationIgnored var onImage: ((CGImage) -> Void)?
    /// Lets go of every button and key this window holds on the other Mac (set by the screen view).
    @ObservationIgnored var releaseAll: (() -> Void)?
    /// Closes this viewer's own window (Stop).
    @ObservationIgnored var closeWindow: (() -> Void)?
    /// The window is minimised or hidden: no pictures are asked for until it shows again (Reviewer, 31 Oct).
    @ObservationIgnored private var paused = false
    @ObservationIgnored private let fixture: Bool

    init(machine: String, machineName: String, display: String, displays: [OtherMacDisplay], fixtureImage: CGImage? = nil) {
        self.machine = machine; self.machineName = machineName; self.display = display; self.displays = displays
        fixture = fixtureImage != nil
        if let fixtureImage { image = fixtureImage; state = "live" }
    }

    var title: String {
        let screen = displays.first { $0.id == display }
        return displays.count > 1 ? "\(machineName) · \(screen?.name ?? display)" : machineName
    }
    var canControl: Bool { displays.first { $0.id == display }?.canControl ?? true }

    func start() {
        guard !fixture else { return }
        let machine = self.machine, display = self.display
        Task {
            do {
                try await BackendRemoteMacScreens.shared.open(machine, display: display,
                    onPicture: { [weak self] picture in
                        let image = picture.image
                        Task { @MainActor in
                            guard let self, self.display == picture.display else { return }
                            self.image = image
                            if self.state != "live" { self.state = "live"; self.note = "" }
                            self.onImage?(image)
                        }
                    },
                    onEvent: { [weak self] event in
                        Task { @MainActor in self?.apply(event) }
                    })
            } catch {
                apply(.state("ended", note: (error as? NativeRPCError)?.message ?? error.localizedDescription))
            }
        }
    }

    private func apply(_ event: BackendRemoteMacEvent) {
        switch event {
        case let .state(state, note):
            self.state = state
            self.note = note
        case let .refused(words):
            refusal = words
            Task { try? await Task.sleep(for: .seconds(4)); if refusal == words { refusal = nil } }
        case let .live(route):
            self.route = route
        }
    }

    func switchDisplay(_ id: String) {
        guard id != display else { return }
        let old = display
        display = id; image = nil; state = "opening"
        Task {
            await BackendRemoteMacScreens.shared.close(machine, display: old)
            start()
        }
    }

    func stop() {
        guard !fixture else { return }
        let machine = self.machine, display = self.display
        Task { await BackendRemoteMacScreens.shared.close(machine, display: display) }
    }

    /// Hidden (minimised, covered, another Space): stop the pictures; shown again: ask again.
    func setVisible(_ visible: Bool) {
        guard !fixture, visible == paused else { return }
        paused = !visible
        if visible { start() } else { releaseAll?(); stop() }
    }

    func send(_ fields: [NativeRPCValue.Field]) {
        guard !fixture, canControl else { return }
        let machine = self.machine, display = self.display
        Task { await BackendRemoteMacScreens.shared.input(machine, display: display, fields) }
    }
}

/// The viewer's own window: resizable, full screen with ⌃⌘F, named after the other Mac.
@MainActor final class NativeRemoteMacWindow: NSWindowController, NSWindowDelegate {
    let model: RemoteMacViewerModel
    private let closed: () -> Void

    init(model: RemoteMacViewerModel, closed: @escaping () -> Void) {
        self.model = model; self.closed = closed
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 860), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = model.title
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = CGSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RemoteMac-" + model.machine)
        window.contentView = NSHostingView(rootView: NativeRemoteMacViewer(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.closeWindow = { [weak self] in self?.close() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        model.releaseAll?()
        model.stop()
        closed()
    }

    /// This Mac's keys belong to this window only while it is the key window: leaving it lets go of everything held.
    func windowDidResignKey(_ notification: Notification) { model.releaseAll?() }
    func windowDidMiniaturize(_ notification: Notification) { model.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setVisible(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        model.setVisible(window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }
}

/// The window's content: a slim bar (display, fit or actual size, where ⌘ keys go, Stop) over the screen.
struct NativeRemoteMacViewer: View {
    @Bindable var model: RemoteMacViewerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(model.state == "live" ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if model.state == "live", !model.route.isEmpty { Text(model.route).font(.caption).foregroundStyle(.secondary) }
                if !model.canControl { Text("Watch only").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if model.displays.count > 1 {
                    Picker("Display", selection: Binding(get: { model.display }, set: { model.switchDisplay($0) })) {
                        ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                    }
                    .labelsHidden().frame(maxWidth: 200)
                }
                Picker("Size", selection: $model.actualSize) {
                    Text("Fit").tag(false)
                    Text("Actual size").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(isOn: $model.commandKeysToRemote) { Text("⌘ keys to \(model.machineName)").lineLimit(1) }
                    .toggleStyle(.checkbox)
                    .help("On: ⌘ shortcuts such as ⌘Q and ⌘W go to the other Mac while the pointer is over its screen. Off: they stay on this Mac.")
                Button("Stop") { model.closeWindow?() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 78).padding(.trailing, 12)
            .frame(height: 38)
            .background(.bar)
            ZStack {
                Color.black
                RemoteMacScreen(model: model)
                if model.state != "live" || model.image == nil {
                    VStack(spacing: 10) {
                        if model.state == "ended" { Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.white.opacity(0.8)) }
                        else { ProgressView().controlSize(.large).tint(.white) }
                        Text(model.note.isEmpty ? "Opening \(model.title)…" : model.note)
                            .foregroundStyle(.white).multilineTextAlignment(.center).frame(maxWidth: 420)
                        if model.state == "ended" { Button("Try again") { model.start() } }
                    }
                }
                if let refusal = model.refusal {
                    VStack {
                        Text(refusal).font(.callout).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.75))).padding(.top, 12)
                        Spacer()
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
    }
}

/// The picture, and this Mac's mouse and keyboard while the pointer is over it.
struct RemoteMacScreen: NSViewRepresentable {
    let model: RemoteMacViewerModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let screen = RemoteMacScreenView(model: model)
        scroll.documentView = screen
        model.onImage = { [weak screen] image in screen?.show(image) }
        model.releaseAll = { [weak screen] in screen?.releaseAll() }
        if let image = model.image { screen.show(image) }
        // The window resizes (or goes full screen): the picture follows the visible area.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.resized = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak screen, model] _ in
            MainActor.assumeIsolated { screen?.relayout(actual: model.actualSize) }
        }
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var resized: NSObjectProtocol?
        deinit { if let resized { NotificationCenter.default.removeObserver(resized) } }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? RemoteMacScreenView)?.relayout(actual: model.actualSize)
    }
}

/// Draws the other Mac's picture and turns this Mac's events over it into the other Mac's input.
final class RemoteMacScreenView: NSView {
    private let model: RemoteMacViewerModel
    private var image: CGImage?
    private var actual = false
    private var tracking: NSTrackingArea?
    private var lastMove = Date.distantPast
    private var pendingMove: CGPoint?
    private var moveTimer: Timer?
    private var buttonsDown: Set<String> = []
    /// Key codes sent down and not yet up.
    private var keysDown: Set<Int> = []
    /// Where the left button went down as (left, or right for a ⌃-click), and the last point sent.
    private var leftAs = "left"
    private var lastAt = CGPoint(x: 0.5, y: 0.5)

    init(model: RemoteMacViewerModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage) {
        let resized = self.image.map { $0.width != image.width || $0.height != image.height } ?? true
        self.image = image
        pictureLayer.contents = image
        // The layer shows each picture; the drawn copy (for snapshots of the window) is refreshed on size changes only.
        if resized { needsDisplay = true; relayout(actual: actual) }
    }

    private lazy var pictureLayer: CALayer = {
        let picture = CALayer()
        picture.contentsGravity = .resize
        picture.magnificationFilter = .linear
        picture.minificationFilter = .trilinear
        layer?.addSublayer(picture)
        return picture
    }()

    /// Fit: the document fills the window and the picture keeps its shape inside it. Actual size: one picture pixel
    /// per screen pixel of this window, scrolled when larger.
    func relayout(actual: Bool) {
        self.actual = actual
        guard let scroll = enclosingScrollView else { return }
        let visible = scroll.contentSize
        if actual, let image {
            let scale = window?.backingScaleFactor ?? 2
            setFrameSize(CGSize(width: max(visible.width, CGFloat(image.width) / scale), height: max(visible.height, CGFloat(image.height) / scale)))
        } else {
            setFrameSize(visible)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pictureLayer.frame = pictureRect
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pictureLayer.frame = pictureRect
        CATransaction.commit()
    }

    override func viewDidEndLiveResize() { super.viewDidEndLiveResize(); relayout(actual: actual) }

    /// The picture drawn into the view too, so a snapshot of the window (and a still of it) shows it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = pictureRect
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// Where the picture is in this view.
    var pictureRect: CGRect {
        guard let image, image.width > 0, image.height > 0 else { return bounds }
        let size = CGSize(width: image.width, height: image.height)
        if actual {
            let scale = window?.backingScaleFactor ?? 2
            let shown = CGSize(width: size.width / scale, height: size.height / scale)
            return CGRect(x: (bounds.width - shown.width) / 2, y: (bounds.height - shown.height) / 2, width: shown.width, height: shown.height)
        }
        let ratio = size.width / size.height
        var width = bounds.width, height = width / ratio
        if height > bounds.height { height = bounds.height; width = height * ratio }
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }

    /// The pointer as a share of the picture, or nil when it is outside it.
    private func unit(_ event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil), rect = pictureRect
        guard rect.width > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    private func mouse(_ phase: String, _ button: String, _ event: NSEvent, clicks: Int = 1) {
        guard let at = unit(event) else { return }
        lastAt = at
        model.send(Self.mouseFields(phase: phase, button: button, at: at, clicks: clicks))
    }

    /// The pointer as a share of the picture, held to its edges: a release outside the picture still lets go on the other Mac.
    private func clamped(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = pictureRect
        guard rect.width > 0, rect.height > 0 else { return lastAt }
        return CGPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1), y: min(max((point.y - rect.minY) / rect.height, 0), 1))
    }

    /// Lets go of a held button, wherever the pointer is now.
    private func release(_ button: String, _ event: NSEvent?) {
        guard buttonsDown.remove(button) != nil else { return }
        let at = event.map(clamped) ?? lastAt
        lastAt = at
        model.send(Self.mouseFields(phase: "up", button: button, at: at, clicks: event?.clickCount ?? 1))
    }

    /// Every button and key this window holds on the other Mac is let go (the pointer left, the window lost focus
    /// or closed, or it was hidden), so nothing stays pressed there (Reviewer, 31 Oct).
    func releaseAll() {
        flushMove()
        for button in buttonsDown.sorted() { release(button, nil) }
        for code in keysDown.sorted() { sendCode(code, down: false, mods: []) }
        keysDown.removeAll()
    }

    override func mouseExited(with event: NSEvent) { releaseAll() }
    override func resignFirstResponder() -> Bool { releaseAll(); return super.resignFirstResponder() }

    static func mouseFields(phase: String, button: String, at: CGPoint, clicks: Int) -> [NativeRPCValue.Field] {
        [.init("do", .string("mouse")), .init("phase", .string(phase)), .init("button", .string(button)),
         .init("x", .number((Double(at.x) * 10_000).rounded() / 10_000)), .init("y", .number((Double(at.y) * 10_000).rounded() / 10_000)),
         .init("clicks", .number(Double(min(max(clicks, 1), 3))))]
    }

    // Moves are sent at most 60 times a second; the newest position wins.
    override func mouseMoved(with event: NSEvent) { queueMove(event, phase: "move") }
    override func mouseDragged(with event: NSEvent) { queueMove(event, phase: "drag") }
    override func rightMouseDragged(with event: NSEvent) { queueMove(event, phase: "drag") }
    override func otherMouseDragged(with event: NSEvent) { queueMove(event, phase: "drag") }

    private var movePhase = "move"
    private func queueMove(_ event: NSEvent, phase: String) {
        guard let at = unit(event) else { return }
        pendingMove = at; movePhase = phase
        if Date().timeIntervalSince(lastMove) >= 1.0 / 60 { flushMove() }
        else if moveTimer == nil {
            moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.moveTimer = nil; self?.flushMove() }
            }
        }
    }

    private func flushMove() {
        guard let at = pendingMove else { return }
        pendingMove = nil; lastMove = Date()
        let button = buttonsDown.contains("left") ? "left" : buttonsDown.sorted().first ?? "left"
        lastAt = at
        model.send(Self.mouseFields(phase: movePhase, button: button, at: at, clicks: 1))
    }

    /// A press counts only inside the picture; its release is always sent, clamped to the picture's edge.
    private func press(_ button: String, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        flushMove()
        guard unit(event) != nil else { return }
        buttonsDown.insert(button)
        mouse("down", button, event, clicks: event.clickCount)
    }
    override func mouseDown(with event: NSEvent) {
        leftAs = event.modifierFlags.contains(.control) ? "right" : "left"
        press(leftAs, event)
    }
    override func mouseUp(with event: NSEvent) { flushMove(); release(leftAs, event) }
    override func rightMouseDown(with event: NSEvent) { press("right", event) }
    override func rightMouseUp(with event: NSEvent) { flushMove(); release("right", event) }
    override func otherMouseDown(with event: NSEvent) { press("middle", event) }
    override func otherMouseUp(with event: NSEvent) { flushMove(); release("middle", event) }

    /// Trackpad and wheel: pixel deltas become a share of the picture, so the other Mac scrolls the same distance.
    override func scrollWheel(with event: NSEvent) {
        guard let at = unit(event) else { super.scrollWheel(with: event); return }
        if actual, enclosingScrollView != nil, event.modifierFlags.contains(.option) { super.scrollWheel(with: event); return }
        let rect = pictureRect
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * factor / rect.width, dy = event.scrollingDeltaY * factor / rect.height
        guard abs(dx) > 0.0001 || abs(dy) > 0.0001 else { return }
        model.send([.init("do", .string("scroll")), .init("x", .number(Double(at.x))), .init("y", .number(Double(at.y))),
                    .init("dx", .number(Double(max(-1, min(1, dx))))), .init("dy", .number(Double(max(-1, min(1, dy)))))])
    }

    // MARK: Keys

    private var pointerInside: Bool {
        guard let window else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return pictureRect.contains(point)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.function) { names.append("fn") }
        return names
    }

    /// Keys that are not text: arrows, Return, Tab, Esc, Delete, function keys, Home/End/Page keys.
    static let specialCodes: Set<UInt16> = [UInt16(kVK_Return), UInt16(kVK_Tab), UInt16(kVK_Space), UInt16(kVK_Delete), UInt16(kVK_Escape),
        UInt16(kVK_ForwardDelete), UInt16(kVK_Home), UInt16(kVK_End), UInt16(kVK_PageUp), UInt16(kVK_PageDown), UInt16(kVK_LeftArrow),
        UInt16(kVK_RightArrow), UInt16(kVK_DownArrow), UInt16(kVK_UpArrow), UInt16(kVK_ANSI_KeypadEnter), UInt16(kVK_Help),
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4), UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12)]

    /// How one key event crosses: text in any language as text (the other Mac's keyboard layout does not matter), and
    /// shortcuts and special keys as the key itself with its modifiers.
    enum KeySend: Equatable { case text(String), code(Int, mods: [String]) }
    static func keySend(code: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> KeySend {
        let mods = modifiers(flags)
        if flags.contains(.command) || flags.contains(.control) || specialCodes.contains(code) { return .code(Int(code), mods: mods) }
        if let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0xF700...0xF8FF).contains($0.value) }) {
            return .text(characters)
        }
        return .code(Int(code), mods: mods)
    }

    /// Keys go to the other Mac only while the pointer is over its picture (Reviewer, 31 Oct); a key let go after the
    /// pointer left was already released by `releaseAll`.
    override func keyDown(with event: NSEvent) {
        guard pointerInside else { super.keyDown(with: event); return }
        switch Self.keySend(code: event.keyCode, characters: event.characters, flags: event.modifierFlags) {
        case .text(let text): model.send([.init("do", .string("type")), .init("text", .string(text))])
        case let .code(code, mods):
            keysDown.insert(code)
            sendCode(code, down: true, mods: mods)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard keysDown.contains(Int(event.keyCode)) else { return }
        if case let .code(code, mods) = Self.keySend(code: event.keyCode, characters: event.characters, flags: event.modifierFlags) {
            keysDown.remove(code)
            sendCode(code, down: false, mods: mods)
        }
    }

    /// ⌘ shortcuts reach a view only through key equivalents: sent to the other Mac while the pointer is over its
    /// picture and the switch is on; otherwise this Mac's own menus have them (⌃⌘F, ⌘W…).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, model.commandKeysToRemote, pointerInside else { return super.performKeyEquivalent(with: event) }
        // ⌃⌘F stays here: it is how this window goes full screen and back.
        if event.keyCode == UInt16(kVK_ANSI_F), event.modifierFlags.contains([.command, .control]) { return super.performKeyEquivalent(with: event) }
        let mods = Self.modifiers(event.modifierFlags)
        sendCode(Int(event.keyCode), down: true, mods: mods)
        sendCode(Int(event.keyCode), down: false, mods: mods)
        return true
    }

    private func sendCode(_ code: Int, down: Bool, mods: [String]) {
        model.send([.init("do", .string("keycode")), .init("code", .number(Double(code))), .init("down", .bool(down)),
                    .init("mods", .array(mods.map(NativeRPCValue.string)))])
    }
}
