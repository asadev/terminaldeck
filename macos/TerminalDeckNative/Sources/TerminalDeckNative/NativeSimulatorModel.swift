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

    private(set) var inspecting = false
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
    @ObservationIgnored private var inspectTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var saidTask: Task<Void, Never>?
    @ObservationIgnored private var watchChain: Task<Void, Never>?
    @ObservationIgnored private var inputQueue = DeviceInputQueue()
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var inputCheck: Task<Void, Never>?
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var appeared = false
    @ObservationIgnored private var lastPictureAt = Date.distantPast
    @ObservationIgnored private var lastRequestAt = Date.distantPast
    @ObservationIgnored private var lastInputAt = Date.distantPast
    @ObservationIgnored private var receivedBefore = 0
    @ObservationIgnored private var enqueuedBefore = 0

    private static let lastKey = "simulators.last"
    private var bridge: EngineBridge { EngineBridge.shared }

    init() {
        player.onPictureSize = { [weak self] size in self?.videoSize = size }
        player.onPicture = { [weak self] in self?.lastPictureAt = Date() }
        player.needKeyframe = { [weak self] in
            guard let self, self.visible, self.device != nil else { return }
            self.watch(true)
        }
    }

    /// The picture the screen is fitted to: the reading's while frozen, the live one otherwise.
    var fitSize: CGSize? {
        if isFrozen, let snapshot { return snapshot.size }
        return videoSize ?? snapshot?.size
    }

    /// Marked elements hold the picture still, so the markers can never drift off what they mark.
    var isFrozen: Bool { inspecting && !markers.isEmpty && snapshot != nil }

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
        if device != nil { watch(visible ? true : nil) }
    }

    func disappear() {
        guard appeared else { return }
        appeared = false
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        listTask?.cancel()
        inspectTask?.cancel()
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
                if self.device == nil, self.windowsCanBeSeen() {
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
        stopInspecting()
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
        guard device != nil, appeared else { return }
        watch(now ? true : nil)
        if now { expectPicture(since: Date()) }
    }

    // MARK: - Input

    func sendInput(_ input: DeviceInput) {
        guard let id = device?.id, !isFrozen else { return }
        inputQueue.push(input)
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
            guard self.device != nil, self.visible, self.lastPictureAt < sent else { return }
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

    func toggleInspect() {
        if inspecting {
            leaveInspect()
        } else {
            inspecting = true
            readProblem = ""
            Task { await loadSessions() }
            Task { await readScreen() }
            startInspectLoop()
        }
    }

    /// Done: asks first when there are markers that would be lost.
    func leaveInspect() {
        if !markers.isEmpty {
            confirmingDiscard = true
            return
        }
        stopInspecting()
    }

    func stopInspecting() {
        inspectTask?.cancel()
        inspectTask = nil
        inspecting = false
        markers = []
        note = ""
        snapshot = nil
        findings = []
        hoverRef = nil
        focusRef = nil
        listHoverRef = nil
        sendProblem = ""
        confirmingDiscard = false
    }

    /// Read the screen again once it settles: a picture has arrived since the last reading,
    /// none for 0.6 s, and the last reading was 2 s ago or more. Never while something is marked.
    private func startInspectLoop() {
        inspectTask?.cancel()
        inspectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.inspecting else { return }
                let now = Date()
                if self.markers.isEmpty, !self.reading, self.lastPictureAt > self.lastRequestAt,
                   now.timeIntervalSince(self.lastPictureAt) >= 0.6, now.timeIntervalSince(self.lastRequestAt) >= 2 {
                    await self.readScreen()
                }
            }
        }
    }

    /// `devices:freeze`: the exact picture and the tree read against it.
    func readScreen() async {
        guard let device, !reading, markers.isEmpty else { return }
        reading = true
        lastRequestAt = Date()
        defer { reading = false }
        do {
            let answer = try await bridge.invoke("devices:freeze", [device.id])
            // Something was marked on the last reading meanwhile: it stays the reading.
            guard inspecting, markers.isEmpty, self.device?.id == device.id else { return }
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
        guard inspecting, let point, let nodes = snapshot?.nodes,
              let node = DeviceTreeQuery.elementAt(in: nodes, x: point.x, y: point.y) else {
            if hoverRef != nil { hoverRef = nil }
            return
        }
        if hoverRef != node.ref { hoverRef = node.ref }
    }

    /// A click on the screen while inspecting: choose the element there and mark it.
    func pick(at point: CGPoint) {
        guard inspecting, let snapshot else { return }
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

    /// Tap the element's centre — an inspector's "activate".
    func tap(_ ref: String) {
        guard let node = node(ref), let centre = DeviceTreeQuery.centre(of: node), !isFrozen else { return }
        sendInput(.tap(x: centre.x, y: centre.y, holdMs: nil))
    }

    // MARK: - Sending

    func loadSessions() async {
        guard bridge.isReady else { return }
        do {
            sessions = AgentSessions.read(try await bridge.invoke("session:list"))
            sessionsAvailable = true
        } catch {
            sessionsAvailable = false
        }
    }

    var sessionReason: String {
        AgentSessions.whyDisabled(chosenSessionId, in: sessions, available: sessionsAvailable)
    }

    var target: AgentSessionRow? { AgentSessions.resolve(chosenSessionId, in: sessions) }

    /// Why the round cannot be sent yet — shown only on Send's own hover.
    var roundNotReady: String {
        if markers.isEmpty { return "Mark something on the screen first." }
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Say what should change." }
        if target == nil { return "Choose a session first." }
        return ""
    }

    /// The marked picture saved with `annotate:save`, the round's one line typed into the
    /// session and submitted, and `annotate:sent` — the page's Annotate, end to end.
    func sendRound() async {
        guard roundNotReady.isEmpty, !sending, let snapshot, let cgImage = snapshot.cgImage else { return }
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
        await write(Handoff.composeRound(round, picturePath: path), to: target)
        _ = try? await bridge.invoke("annotate:sent", [round.id, ["sessionId": target.id, "label": target.label]])
        markers = []
        note = ""
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
        await write(line, to: target)
        shot = nil
        say("Sent to \(target.label).")
    }

    /// Two writes with a real gap between them: the line, then Return on its own, so the
    /// agent's CLI reads the Return as a key rather than as part of pasted text.
    private func write(_ message: String, to target: AgentSessionRow) async {
        for (index, data) in Handoff.terminalWrites(message).enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(Handoff.submitGapMilliseconds)) }
            bridge.send("session:write", [target.id, data])
        }
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

    private func diagnosticsChanged() {
        diagnosticsTask?.cancel()
        guard diagnostics else {
            diagnosticLines = []
            return
        }
        receivedBefore = player.received
        enqueuedBefore = player.enqueued
        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                let received = self.player.received
                let enqueued = self.player.enqueued
                let arriving = Double(received - self.receivedBefore) * 2
                let shown = Double(enqueued - self.enqueuedBefore) * 2
                self.receivedBefore = received
                self.enqueuedBefore = enqueued
                let stream = self.videoSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "–"
                self.diagnosticLines = [
                    self.visible ? String(format: "shown %.1f fps · arriving %.1f fps", shown, arriving) : "paused — window hidden",
                    "decoder \(self.player.hardware) · restarts \(self.player.resets)",
                    "stream \(stream)\(self.player.codec.map { " · \($0)" } ?? "")",
                ]
            }
        }
    }

    static func sentence(_ error: Error) -> String {
        if let wire = error as? EngineWireError { return wire.description }
        return error.localizedDescription
    }
}
