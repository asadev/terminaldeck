import AppKit
import Observation
import TerminalDeckNativeCore

/// The Simulators screen's state and every call it makes to the engine.
///
/// The same channels as the web page (`src/main/devices/ipc.ts`), through
/// `EngineBridge`: the list, starting and opening a device, watching its screen
/// (`devices:watch` + the `devices:frame` stream), input, buttons, rotation,
/// screenshots, and `devices:freeze` — the exact picture with the element tree
/// read against it, which is what the inspector stands on. A round is saved
/// with `annotate:save` and typed into a session with `session:write`, the
/// path the page's Annotate and "Send" take.
@MainActor
@Observable
final class NativeSimulatorModel {
    enum InspectorSection: String, CaseIterable, Identifiable {
        case element = "Element"
        case outline = "Outline"
        case checks = "Checks"
        var id: String { rawValue }
    }

    /// One reading of the screen: the exact picture and the elements on it.
    struct Snapshot {
        let frozen: FrozenScreen
        let image: NSImage
        let cgImage: CGImage?
        let takenAt: Date
        /// The screen in points (dp) the way up the picture is, when the device said.
        let points: CGSize?
        /// Every node, flattened once — the pointer asks of it on every move.
        let nodes: [DeviceNode]
        let byRef: [String: DeviceNode]
        var size: CGSize { CGSize(width: frozen.width, height: frozen.height) }
        var root: DeviceNode? { frozen.tree?.root }

        init(frozen: FrozenScreen, image: NSImage, points: CGSize?) {
            self.frozen = frozen
            self.image = image
            self.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            self.takenAt = Date()
            self.points = points
            let nodes = frozen.tree.map { DeviceTreeQuery.flatten($0.root) } ?? []
            self.nodes = nodes
            self.byRef = Dictionary(nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    struct ShotState {
        let shot: DeviceShot
        let preview: NSImage?
        var instruction = ""
        var problem = ""
        var sending = false
    }

    // MARK: List

    private(set) var list: DeviceList?
    private(set) var busy: [String: String] = [:]
    private(set) var opening = ""
    var problem = "" { didSet { if !problem.isEmpty { said = "" } } }
    private(set) var said = ""

    // MARK: The open device

    private(set) var device: DeviceDetails?
    @ObservationIgnored let player = DeviceScreenPlayer()
    private(set) var videoSize: CGSize?
    private(set) var freezing = false
    var diagnostics = false { didSet { diagnosticsChanged() } }
    private(set) var diagnosticLines: [String] = []

    // MARK: Inspector

    /// Annotate is on: the screen is frozen, pointed at, and sent from.
    private(set) var annotating = false
    private(set) var snapshot: Snapshot?
    private(set) var reading = false
    private(set) var readProblem = ""
    private(set) var hoverRef: String?
    var focusRef: String?
    /// A row under the pointer in the outline or the checks: highlighted on the screen.
    var listHoverRef: String?
    var expanded: Set<String> = []
    var section: InspectorSection = .element
    private(set) var markers: [Annotation] = []
    private(set) var findings: [DeviceFinding] = []
    var note = ""
    var confirmingDiscard = false
    /// Bumped when an element is chosen from the screen, so the outline scrolls to it.
    private(set) var revealTick = 0

    // MARK: Sessions

    private(set) var sessions: [AgentSessionRow] = []
    private(set) var sessionsAvailable = true
    var chosenSessionId = ""
    private(set) var sending = false
    private(set) var sendProblem = ""

    // MARK: Screenshot

    var shot: ShotState?

    // MARK: Inside

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var saidTask: Task<Void, Never>?
    @ObservationIgnored private var watchChain: Task<Void, Never>?
    @ObservationIgnored private var inputQueue = DeviceInputQueue()
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var inputCheck: Task<Void, Never>?
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var appeared = false
    @ObservationIgnored private var lastPictureAt = Date.distantPast
    @ObservationIgnored private var lastInputAt = Date.distantPast

    private static let lastKey = "simulators.last"
    private var bridge: EngineBridge { EngineBridge.shared }

    init() {
        player.onPictureSize = { [weak self] size in self?.videoSize = size }
        player.onPicture = { [weak self] in self?.lastPictureAt = Date() }
        player.needKeyframe = { [weak self] in
            guard let self, self.visible, self.device != nil, !self.annotating else { return }
            self.watch(true)
        }
    }

    /// The picture the screen is fitted to: the reading's while frozen, the live one otherwise.
    var fitSize: CGSize? {
        if annotating, let snapshot { return snapshot.size }
        return videoSize ?? snapshot?.size
    }

    /// The frozen picture is up: everything that would move the device waits.
    var isFrozen: Bool { annotating && snapshot != nil }

    // MARK: - Appearing

    func appear() {
        guard !appeared else { return }
        appeared = true
        subscriptions = [
            bridge.on("devices:frame") { [weak self] args in
                guard let self, args.count >= 2, let id = args[0] as? String, id == self.device?.id,
                      let packet = args[1] as? Data else { return }
                self.player.push(packet)
            },
            bridge.on("devices:closed") { [weak self] args in
                guard let self, let id = args.first as? String, id == self.device?.id else { return }
                let reason = args.count > 1 ? (args[1] as? String ?? "") : ""
                self.closeDevice(remember: true)
                self.problem = reason.isEmpty ? "The device stopped." : reason
                Task { await self.refresh() }
            },
            bridge.on("session:created") { [weak self] _ in Task { await self?.loadSessions() } },
            bridge.on("session:exit") { [weak self] _ in Task { await self?.loadSessions() } },
        ]
        startListLoop()
        Task { await loadSessions() }
        if device != nil && !annotating { watch(visible ? true : nil) }
    }

    func disappear() {
        guard appeared else { return }
        appeared = false
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        listTask?.cancel()
        diagnosticsTask?.cancel()
        if device != nil { watch(false) }
    }

    /// The app came to the front: a simulator started from Xcode meanwhile should simply be there.
    func appBecameActive() {
        guard device == nil else { return }
        Task { await refresh() }
    }

    // MARK: - The list

    private func startListLoop() {
        listTask?.cancel()
        listTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                // The first list is read whatever the window's state; after that, only while it can be seen.
                if self.device == nil, first || self.windowsCanBeSeen() {
                    let next = await self.refresh()
                    if first, let next {
                        first = false
                        let last = UserDefaults.standard.string(forKey: Self.lastKey) ?? ""
                        if !last.isEmpty, next.devices.contains(where: { $0.id == last && $0.available }) {
                            await self.open(last)
                        }
                    }
                }
                let changing = !self.busy.isEmpty || (self.list?.isChanging ?? false)
                let wait: Double = self.list == nil ? 1 : (changing ? 2 : 10)
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    private func windowsCanBeSeen() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) }
    }

    @discardableResult
    func refresh() async -> DeviceList? {
        guard bridge.isReady else { return nil }
        do {
            let answer = try await bridge.invoke("devices:list")
            guard let next = DeviceList(json: answer) else { return nil }
            list = next
            return next
        } catch {
            problem = Self.sentence(error)
            return nil
        }
    }

    func open(_ id: String) async {
        opening = id
        problem = ""
        defer { opening = "" }
        do {
            let answer = try await bridge.invoke("devices:open", [id])
            guard let details = DeviceDetails(json: answer) else {
                problem = "That device could not be opened."
                return
            }
            player.reset()
            videoSize = nil
            device = details
            UserDefaults.standard.set(id, forKey: Self.lastKey)
            watch(visible ? true : nil)
            expectPicture(since: Date())
        } catch {
            problem = Self.sentence(error)
        }
    }

    func start(_ entry: DeviceEntry) async {
        busy[entry.id] = "Starting…"
        problem = ""
        let answer: Any?
        do {
            answer = try await bridge.invoke("devices:boot", [entry.id])
        } catch {
            busy[entry.id] = nil
            problem = Self.sentence(error)
            return
        }
        busy[entry.id] = nil
        switch DeviceOutcome(json: answer, fallback: "It would not start.") {
        case .refused(let message):
            problem = message
        case .ok(let id):
            await refresh()
            await open(id ?? entry.id)
        }
    }

    func shutDown() async {
        guard let id = device?.id else { return }
        closeDevice(remember: false)
        busy[id] = "Shutting down…"
        let answer = try? await bridge.invoke("devices:shutdown", [id])
        busy[id] = nil
        if case .refused(let message) = DeviceOutcome(json: answer, fallback: "It would not shut down.") { problem = message }
        await refresh()
    }

    /// Back to the list.
    func back() {
        closeDevice(remember: false)
        Task { await refresh() }
    }

    private func closeDevice(remember: Bool) {
        if device != nil { watch(false) }
        stopAnnotating(resume: false)
        device = nil
        videoSize = nil
        shot = nil
        player.reset()
        inputQueue.removeAll()
        if !remember { UserDefaults.standard.removeObject(forKey: Self.lastKey) }
    }

    // MARK: - Watching

    /// Pictures to this screen on (`true`), off (`false`), or paused while it cannot be seen (`nil`).
    /// One at a time, in order: the engine serialises them too, but only in the order they arrive.
    private func watch(_ on: Bool?) {
        guard let id = device?.id else { return }
        let previous = watchChain
        let value: Any = on.map { $0 as Any } ?? "paused"
        watchChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            _ = try? await self.bridge.invoke("devices:watch", [id, value])
        }
    }

    func setVisible(_ now: Bool) {
        guard now != visible else { return }
        visible = now
        guard device != nil, appeared, !annotating else { return }
        watch(now ? true : nil)
        if now { expectPicture(since: Date()) }
    }

    // MARK: - Input

    func sendInput(_ input: DeviceInput) {
        guard let id = device?.id, !annotating else { return }
        inputQueue.push(input)
        player.markInput()
        lastInputAt = Date()
        expectPicture(since: lastInputAt)
        guard !pumping else { return }
        pumping = true
        Task { [weak self] in
            while let self, let next = self.inputQueue.next() {
                let call = next.call(device: id)
                _ = try? await self.bridge.invoke(call.channel, call.args)
            }
            self?.pumping = false
        }
    }

    func button(_ name: String) { sendInput(.button(name)) }

    /// A touch, an opening or a window coming back with no picture after it means the stream
    /// stopped — the engine keys watchers by sender, and every bridge call shares one, so a
    /// hidden page watching the same device can pause it. Watching again brings it back. One
    /// check at a time, never a poll.
    private func expectPicture(since sent: Date) {
        guard inputCheck == nil else { return }
        inputCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.inputCheck = nil
            guard self.device != nil, self.visible, !self.annotating, self.lastPictureAt < sent else { return }
            self.watch(true)
        }
    }

    func rotate() async {
        guard let id = device?.id else { return }
        _ = try? await bridge.invoke("devices:rotate", [id])
    }

    func screenshot() async {
        guard let id = device?.id else { return }
        do {
            let answer = try await bridge.invoke("devices:screenshot", [id])
            guard let shot = DeviceShot(json: answer) else { return }
            self.shot = ShotState(shot: shot, preview: shot.preview.flatMap(NSImage.init(data:)))
            await loadSessions()
        } catch {
            problem = Self.sentence(error)
        }
    }

    func revealShot() {
        guard let path = shot?.shot.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Inspector

    /// Annotate, as the page has it: on freezes the screen at once (the live picture
    /// stops while the frozen one is pointed at); off asks first when markers would be lost.
    func toggleAnnotate() {
        if annotating {
            leaveAnnotate()
            return
        }
        guard device != nil, !freezing else { return }
        annotating = true
        freezing = true
        problem = ""
        said = ""
        readProblem = ""
        watch(false)
        Task { await loadSessions() }
        Task {
            await readScreen()
            freezing = false
            guard annotating, snapshot == nil else { return }
            let why = readProblem
            stopAnnotating()
            problem = why.isEmpty ? "The screen could not be frozen." : why
        }
    }

    /// Done: asks first when there are markers that would be lost; a second Done discards.
    func leaveAnnotate() {
        if !markers.isEmpty && !confirmingDiscard {
            confirmingDiscard = true
            return
        }
        stopAnnotating()
    }

    /// Escape: closes the question if one is open, otherwise it is Done.
    func escapeAnnotate() {
        guard annotating else { return }
        if confirmingDiscard { confirmingDiscard = false } else { leaveAnnotate() }
    }

    /// Leave Annotate and, unless the device is going away, bring the live picture back.
    func stopAnnotating(resume: Bool = true) {
        let was = annotating
        annotating = false
        freezing = false
        markers = []
        note = ""
        snapshot = nil
        findings = []
        hoverRef = nil
        focusRef = nil
        listHoverRef = nil
        sendProblem = ""
        readProblem = ""
        confirmingDiscard = false
        guard was, resume, device != nil, appeared else { return }
        watch(visible ? true : nil)
        if visible { expectPicture(since: Date()) }
    }

    /// `devices:freeze`: the exact picture and the tree read against it.
    func readScreen() async {
        guard let device, !reading, markers.isEmpty else { return }
        reading = true
        defer { reading = false }
        do {
            let answer = try await bridge.invoke("devices:freeze", [device.id])
            // Something was marked on the last reading meanwhile: it stays the reading.
            guard annotating, markers.isEmpty, self.device?.id == device.id else { return }
            guard let frozen = FrozenScreen(json: answer), let image = NSImage(data: frozen.png) else {
                readProblem = "The screen could not be read."
                return
            }
            let points = DeviceGeometry.screenPoints(pointWidth: device.pointWidth, pointHeight: device.pointHeight,
                                                     pictureWidth: Double(frozen.width), pictureHeight: Double(frozen.height))
            let next = Snapshot(frozen: frozen, image: image, points: points)
            let firstTree = snapshot?.root == nil
            snapshot = next
            readProblem = ""
            if let root = next.root {
                findings = DeviceChecks.run(root, points: points,
                                            minimum: DeviceChecks.minimumTarget(platform: device.platform))
                let known = Set(next.byRef.keys)
                // What was open stays open; a screen that changed opens as a new one does.
                let initial = DeviceTreeQuery.initiallyExpanded(root)
                expanded = firstTree ? initial : expanded.intersection(known).union(initial)
                if let focusRef, !known.contains(focusRef) { self.focusRef = nil }
                if let hoverRef, !known.contains(hoverRef) { self.hoverRef = nil }
            } else {
                findings = []
                focusRef = nil
            }
        } catch {
            readProblem = Self.sentence(error)
        }
    }

    /// The element under the pointer, from the latest reading. Only changes what is observed when it changes.
    func hover(at point: CGPoint?) {
        guard annotating, let point, let nodes = snapshot?.nodes,
              let node = DeviceTreeQuery.elementAt(in: nodes, x: point.x, y: point.y) else {
            if hoverRef != nil { hoverRef = nil }
            return
        }
        if hoverRef != node.ref { hoverRef = node.ref }
    }

    /// A click on the frozen screen: choose the element there and mark it (a click on one
    /// already marked chooses it rather than marking it twice).
    func pick(at point: CGPoint) {
        guard annotating, let snapshot else { return }
        if snapshot.root != nil, let node = DeviceTreeQuery.elementAt(in: snapshot.nodes, x: point.x, y: point.y) {
            focus(node.ref, reveal: true)
            if !markers.contains(where: { $0.nodeRef == node.ref }) { mark(node) }
        } else {
            // No elements described: a mark by position, as the page's Annotate does.
            let rect = DeviceGeometry.boxAround(x: point.x, y: point.y)
            markers = Annotation.adding(markers, id: "a-\(UUID().uuidString)", rect: rect, element: nil)
        }
    }

    func focus(_ ref: String, reveal: Bool) {
        focusRef = ref
        guard reveal, let root = snapshot?.root else { return }
        expanded.formUnion(DeviceTreeQuery.ancestors(of: ref, in: root))
        revealTick += 1
    }

    func node(_ ref: String?) -> DeviceNode? {
        guard let ref else { return nil }
        return snapshot?.byRef[ref]
    }

    /// What the details show: the element under the pointer, or the one chosen.
    var detailNode: DeviceNode? { node(hoverRef) ?? node(focusRef) }

    func marker(for ref: String) -> Annotation? { markers.first { $0.nodeRef == ref } }

    func mark(_ node: DeviceNode) {
        guard !markers.contains(where: { $0.nodeRef == node.ref }) else { return }
        let rect = node.usableFrame ?? DeviceGeometry.boxAround(x: 0.5, y: 0.5)
        markers = Annotation.adding(markers, id: "a-\(UUID().uuidString)", rect: rect,
                                    element: AnnotatedElement(node: node), nodeRef: node.ref)
        sendProblem = ""
    }

    func toggleMark(_ ref: String) {
        if let existing = marker(for: ref) {
            unmark(existing.id)
        } else if let node = node(ref) {
            mark(node)
        }
    }

    func unmark(_ id: String) {
        markers = Annotation.removing(markers, id: id)
        if markers.isEmpty { sendProblem = "" }
    }

    func clearMarkers() {
        markers = []
        sendProblem = ""
    }

    // MARK: - Sending

    /// This Mac's sessions and the ones on paired machines, called by the names the rail shows.
    func loadSessions() async {
        guard bridge.isReady else { return }
        do {
            let here = try await bridge.invoke("session:list")
            // A machines half that fails costs the remote rows and nothing else.
            let machines = try? await bridge.invoke("machines:list")
            let projects = AppModel.shared.sidebar?.projects ?? []
            let rail = projects.flatMap(\.sessions).map { (id: $0.id, title: $0.title) }
            let servers = projects.filter { $0.id.hasPrefix("server:") }
                .map { (name: $0.title, shells: $0.sessions.map { (tabId: $0.id, title: $0.title) }) }
            sessions = AgentSessions.read(here, names: AgentSessions.railNames(rail), machines: machines, servers: servers)
            sessionsAvailable = true
        } catch {
            sessionsAvailable = false
        }
    }

    var sessionReason: String {
        AgentSessions.whyDisabled(chosenSessionId, in: sessions, available: sessionsAvailable)
    }

    var target: AgentSessionRow? { AgentSessions.resolve(chosenSessionId, in: sessions) }

    /// Send is off until a session is chosen, something is marked, and the box says what to change.
    var canSendRound: Bool {
        target != nil && !markers.isEmpty && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Send's own hover, as the page words it: the reason when it is off, its target when it is on.
    var sendRoundHint: String {
        if canSendRound { return "Send to \(target?.label ?? "")" }
        if target == nil { return sessionReason }
        return markers.isEmpty ? "Mark something on the screen first." : ""
    }

    /// The marked picture saved with `annotate:save`, the round's one line typed into the
    /// session and submitted, and `annotate:sent` — the page's Annotate, end to end.
    func sendRound() async {
        guard canSendRound, !sending, let snapshot, let cgImage = snapshot.cgImage else { return }
        sending = true
        sendProblem = ""
        defer { sending = false }
        await loadSessions()
        guard let target = AgentSessions.resolve(chosenSessionId, in: sessions) else {
            sendProblem = sessionReason
            return
        }
        guard let drawn = MarkedPicture.draw(cgImage, markers: markers) else {
            sendProblem = "The picture could not be saved, so nothing was sent."
            return
        }
        let round = AnnotationRound(id: "round-\(UUID().uuidString)", createdAt: (Date().timeIntervalSince1970 * 1000).rounded(),
                                    where_: snapshot.frozen.where_, frameWidth: drawn.width, frameHeight: drawn.height,
                                    annotations: markers, note: note)
        let saved = try? await bridge.invoke("annotate:save", ["data:image/png;base64,\(drawn.png.base64EncodedString())", round.json])
        guard let path = (saved as? [String: Any])?["path"] as? String, !path.isEmpty else {
            sendProblem = "The picture could not be saved, so nothing was sent."
            return
        }
        if let refusal = await write(Handoff.composeRound(round, picturePath: path), to: target) {
            sendProblem = refusal
            return
        }
        _ = try? await bridge.invoke("annotate:sent", [round.id, ["sessionId": target.id, "label": target.label]])
        stopAnnotating()
        say("Sent to \(target.label).")
    }

    /// The screenshot and what was typed about it, as the page's screenshot popup sends it.
    func sendShot() async {
        guard var state = shot, !state.sending, let device else { return }
        await loadSessions()
        guard let target = AgentSessions.resolve(chosenSessionId, in: sessions) else {
            state.problem = sessionReason
            shot = state
            return
        }
        state.sending = true
        shot = state
        let line = Handoff.composeScreenshot(path: state.shot.path, width: state.shot.width, height: state.shot.height,
                                             kind: device.kindWords, deviceName: device.name, instruction: state.instruction)
        if let refusal = await write(line, to: target) {
            state.sending = false
            state.problem = refusal
            shot = state
            return
        }
        shot = nil
        say("Sent to \(target.label).")
    }

    /// Two writes with a real gap between them: the line, then Return on its own, so the
    /// agent's CLI reads the Return as a key rather than as part of pasted text. Through the
    /// window's one send (`NativeSessionInput`): this Mac, a paired machine, or a server's
    /// terminal; a refusal comes back in the far end's own words.
    private func write(_ message: String, to target: AgentSessionRow) async -> String? {
        for (index, data) in Handoff.terminalWrites(message).enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(Handoff.submitGapMilliseconds)) }
            let outcome = await NativeSessionInput.send(tabId: target.tabId, text: data,
                                                        name: target.machineName.isEmpty ? "that machine" : target.machineName)
            if !outcome.ok { return outcome.message ?? "\(target.label) did not take it." }
        }
        return nil
    }

    private func say(_ words: String) {
        problem = ""
        said = words
        saidTask?.cancel()
        saidTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.said = ""
        }
    }

    // MARK: - Diagnostics

    /// The readout, twice a second, only while it is on — `diagnosticLines`.
    private func diagnosticsChanged() {
        diagnosticsTask?.cancel()
        guard diagnostics else {
            diagnosticLines = []
            return
        }
        diagnosticsTask = Task { [weak self] in
            var before: (stats: PlayerStats, at: Date)?
            while !Task.isCancelled {
                guard let self else { return }
                let stats = self.player.stats()
                let at = Date()
                self.diagnosticLines = DeviceDiagnostics.lines(before: before?.stats, now: stats,
                                                               seconds: before.map { at.timeIntervalSince($0.at) } ?? 0,
                                                               scale: self.player.backingScale, paused: !self.visible)
                before = (stats, at)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        return error.localizedDescription
    }
}
