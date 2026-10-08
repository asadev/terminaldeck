import AppKit
import Observation
import TerminalDeckNativeCore

/// The Simulators screen's state and every call it makes to the engine.
///
/// The same channels as the web page (`src/main/devices/ipc.ts`), through
/// `EngineBridge`: the list, starting and opening a device, watching its screen
/// (`devices:watch` + the `devices:frame` stream), input, buttons, rotation,
/// screenshots, and Inspect — on the LIVE screen, never paused (Asad, 7 Oct
/// 2026: freezing is gone). While Inspect is on the element tree is read in the
/// background (`devices:freeze`, used only for its tree — the engine has no
/// tree-only channel) whenever the picture settles after a change or input,
/// and each marker keeps the video frame on show when it was made. A round is
/// saved with `annotate:save` and typed into a session with `session:write`,
/// the path the page's Annotate and "Send" take.
@MainActor
@Observable
final class NativeSimulatorModel {
    enum InspectorSection: String, CaseIterable, Identifiable {
        case element = "Element"
        case outline = "Outline"
        case checks = "Checks"
        var id: String { rawValue }
    }

    /// One reading of the live screen's elements. Its picture is never shown —
    /// the frames are fractions of it, and so of the live picture of the same shape.
    struct Reading {
        let frozen: FrozenScreen
        /// The screen generation the read started on (`LiveTreeSchedule`).
        let generation: Int
        /// The screen in points (dp) the way up the picture is, when the device said.
        let points: CGSize?
        /// Every node, flattened once — the pointer asks of it on every move.
        let nodes: [DeviceNode]
        let byRef: [String: DeviceNode]
        var size: CGSize { CGSize(width: frozen.width, height: frozen.height) }
        var root: DeviceNode? { frozen.tree?.root }

        init(frozen: FrozenScreen, generation: Int, points: CGSize?) {
            self.frozen = frozen
            self.generation = generation
            self.points = points
            let nodes = frozen.tree.map { DeviceTreeQuery.flatten($0.root) } ?? []
            self.nodes = nodes
            self.byRef = Dictionary(nodes.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// The frame a marker keeps: the live picture as it was when the first marker on that screen was made.
    struct Capture {
        let image: CGImage
        let thumbnail: NSImage
        let where_: AnnotateWhere
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
    var diagnostics = false { didSet { diagnosticsChanged() } }
    private(set) var diagnosticLines: [String] = []

    // MARK: Inspector

    /// Inspect is on: the live screen is pointed at, marked and sent from. Nothing pauses.
    private(set) var inspecting = false
    /// The latest reading of the elements, from the background.
    private(set) var latest: Reading?
    private(set) var reading = false
    /// The latest reading is of the screen as it is now. While the picture moves, nothing is drawn from the tree.
    private(set) var treeFresh = false
    private(set) var readProblem = ""
    private(set) var hoverRef: String?
    var focusRef: String?
    /// A row under the pointer in the outline or the checks: highlighted on the screen.
    var listHoverRef: String?
    var expanded: Set<String> = []
    var section: InspectorSection = .element
    private(set) var liveMarkers: [LiveMarker] = []
    /// Marker id → the element it sits on in the latest tree.
    private(set) var markerRefs: [String: String] = [:]
    /// Bumped when a mark by position must disappear because its screen moved on.
    private(set) var overlayTick = 0
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

    @ObservationIgnored private let deviceRail: Bool
    @ObservationIgnored private var deviceRequests = UIGSimulatorRequestFence()
    @ObservationIgnored private var inputTask: Task<Void, Never>?
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
    @ObservationIgnored private var schedule = LiveTreeSchedule()
    @ObservationIgnored private var detector = ScreenChangeDetector()
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// Screen generation → the frame kept for the markers made on it.
    @ObservationIgnored private var captures: [Int: Capture] = [:]
    /// Where the pointer is over the picture, so a new reading highlights what it is on.
    @ObservationIgnored private var pointer: CGPoint?

    private static let lastKey = "simulators.last"
    private var bridge: EngineBridge { EngineBridge.shared }

    init(deviceRail: Bool = false) {
        self.deviceRail = deviceRail
        player.onPictureSize = { [weak self] size in
            self?.videoSize = size
            self?.screenMoved()
        }
        player.onPicture = { [weak self] in self?.lastPictureAt = Date() }
        player.onSignature = { [weak self] signature in
            guard let self, self.detector.observe(signature) else { return }
            self.screenMoved()
        }
        player.needKeyframe = { [weak self] in
            guard let self, self.visible, self.device != nil else { return }
            self.watch(true)
        }
    }

    /// The picture the screen is fitted to: the live one, or the reading's before it arrives.
    var fitSize: CGSize? { videoSize ?? latest?.size }

    var markers: [Annotation] { liveMarkers.map(\.annotation) }

    // MARK: - Appearing

    func appear() {
        guard !appeared else { return }
        appeared = true
        if let device { _ = deviceRequests.begin(device.id) }
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
        deviceRequests.invalidate()
        opening = ""
        inputTask?.cancel()
        inputTask = nil
        inputQueue.removeAll()
        pumping = false
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        listTask?.cancel()
        diagnosticsTask?.cancel()
        if device != nil { watch(false) }
    }

    /// The app came to the front: a simulator started from Xcode meanwhile should simply be there.
    func appBecameActive() {
        guard device == nil || deviceRail else { return }
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
                if self.device == nil || self.deviceRail, first || self.windowsCanBeSeen() {
                    let next = await self.refresh()
                    if first, let next {
                        first = false
                        if !self.deviceRail {
                            let last = UserDefaults.standard.string(forKey: Self.lastKey) ?? ""
                            if !last.isEmpty, next.devices.contains(where: { $0.id == last && $0.available }) {
                                await self.open(last)
                            }
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
        let request = deviceRequests.begin(id)
        opening = id
        problem = ""
        defer { if deviceRequests.accepts(request), opening == id { opening = "" } }
        do {
            let answer = try await bridge.invoke("devices:open", [id])
            guard deviceRequests.accepts(request), !Task.isCancelled else { return }
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
            guard deviceRequests.accepts(request), !Task.isCancelled else { return }
            problem = Self.sentence(error)
        }
    }

    func start(_ entry: DeviceEntry) async {
        let request = deviceRequests.begin(entry.id)
        busy[entry.id] = "Starting…"
        defer { busy[entry.id] = nil }
        problem = ""
        let answer: Any?
        do {
            answer = try await bridge.invoke("devices:boot", [entry.id])
        } catch {
            guard deviceRequests.accepts(request), !Task.isCancelled else { return }
            busy[entry.id] = nil
            problem = Self.sentence(error)
            return
        }
        guard deviceRequests.accepts(request), !Task.isCancelled else { return }
        busy[entry.id] = nil
        switch DeviceOutcome(json: answer, fallback: "It would not start.") {
        case .refused(let message):
            problem = message
        case .ok(let id):
            await refresh()
            guard deviceRequests.accepts(request), !Task.isCancelled else { return }
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
        deviceRequests.invalidate()
        opening = ""
        inputTask?.cancel()
        inputTask = nil
        pumping = false
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
        guard let id = device?.id, let request = deviceRequests.currentTicket else { return }
        inputQueue.push(input)
        player.markInput()
        lastInputAt = Date()
        expectPicture(since: lastInputAt)
        screenMoved()
        guard !pumping else { return }
        pumping = true
        inputTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.deviceRequests.accepts(request), self.device?.id == id,
                  let next = self.inputQueue.next() {
                let call = next.call(device: id)
                _ = try? await self.bridge.invoke(call.channel, call.args)
            }
            if let self, self.deviceRequests.accepts(request) { self.pumping = false; self.inputTask = nil }
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

    /// A steady clock for the read schedule.
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Inspect on: the elements are read in the background and kept current while the
    /// live picture plays on. Off asks first when markers would be lost.
    func toggleInspect() {
        if inspecting {
            leaveInspect()
            return
        }
        guard device != nil else { return }
        inspecting = true
        problem = ""
        said = ""
        readProblem = ""
        detector.reset()
        player.signing = true
        schedule.request(at: Self.now())
        armRead()
        Task { await loadSessions() }
    }

    /// Done: asks first when there are markers that would be lost; a second Done discards.
    func leaveInspect() {
        if !liveMarkers.isEmpty && !confirmingDiscard {
            confirmingDiscard = true
            return
        }
        stopInspecting()
    }

    /// Escape: closes the question if one is open, otherwise it is Done.
    func escapeInspect() {
        guard inspecting else { return }
        if confirmingDiscard { confirmingDiscard = false } else { leaveInspect() }
    }

    /// Leave Inspect. The live picture never stopped, so there is nothing to bring back.
    func stopInspecting() {
        inspecting = false
        player.signing = false
        wakeTask?.cancel()
        wakeTask = nil
        schedule.reset()
        detector.reset()
        liveMarkers = []
        captures = [:]
        markerRefs = [:]
        note = ""
        latest = nil
        treeFresh = false
        reading = false
        findings = []
        hoverRef = nil
        focusRef = nil
        listHoverRef = nil
        pointer = nil
        sendProblem = ""
        readProblem = ""
        confirmingDiscard = false
    }

    /// The picture changed, or input went to the device: the tree is read again once
    /// the screen settles, and nothing is drawn from the old one meanwhile.
    private func screenMoved() {
        guard inspecting else { return }
        let before = schedule.generation
        schedule.change(at: Self.now())
        if treeFresh { treeFresh = false }
        // A mark by position belongs to the screen it was made on.
        if liveMarkers.contains(where: { $0.node == nil && $0.picture == before }) { overlayTick += 1 }
        armRead()
    }

    /// Read the elements again now — the panel's button.
    func readAgain() {
        guard inspecting else { return }
        schedule.request(at: Self.now())
        armRead()
    }

    /// One wake-up at a time, at the moment the next read is due (it moves later while the picture keeps changing).
    private func armRead() {
        guard inspecting, wakeTask == nil, schedule.dueAt != nil else { return }
        wakeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard self.inspecting, let due = self.schedule.dueAt else {
                    self.wakeTask = nil
                    return
                }
                let wait = due - Self.now()
                if wait > 0.001 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
                self.wakeTask = nil
                await self.readTree()
                return
            }
        }
    }

    /// `devices:freeze`, used only for its tree: the stream is never paused and its
    /// picture is never shown. An answer the screen moved on from is let go.
    private func readTree() async {
        guard inspecting, let device, let token = schedule.begin(at: Self.now()) else { return }
        reading = true
        defer {
            reading = schedule.isReading
            armRead()
        }
        let answer: Any?
        do {
            answer = try await bridge.invoke("devices:freeze", [device.id])
        } catch {
            schedule.fail(token)
            if inspecting { readProblem = Self.sentence(error) }
            return
        }
        guard inspecting, self.device?.id == device.id else {
            schedule.fail(token)
            return
        }
        guard let frozen = FrozenScreen(json: answer) else {
            schedule.fail(token)
            readProblem = "The screen's elements could not be read."
            return
        }
        // The screen changed while this was read: a newer read follows.
        guard schedule.finish(token, at: Self.now()) else { return }
        let points = DeviceGeometry.screenPoints(pointWidth: device.pointWidth, pointHeight: device.pointHeight,
                                                 pictureWidth: Double(frozen.width), pictureHeight: Double(frozen.height))
        apply(Reading(frozen: frozen, generation: token.generation, points: points), platform: device.platform)
    }

    private func apply(_ next: Reading, platform: String) {
        let firstTree = latest?.root == nil
        latest = next
        treeFresh = schedule.isFresh
        readProblem = ""
        if let root = next.root {
            findings = DeviceChecks.run(root, points: next.points, minimum: DeviceChecks.minimumTarget(platform: platform))
            let known = Set(next.byRef.keys)
            // What was open stays open; a screen that changed opens as a new one does.
            let initial = DeviceTreeQuery.initiallyExpanded(root)
            expanded = firstTree ? initial : expanded.intersection(known).union(initial)
            if let focusRef, !known.contains(focusRef) { self.focusRef = nil }
            if let listHoverRef, !known.contains(listHoverRef) { self.listHoverRef = nil }
        } else {
            findings = []
            focusRef = nil
        }
        let upgraded = LiveMarkers.upgrading(liveMarkers, nodes: next.nodes, generation: next.generation,
                                             treePicture: next.size, video: videoSize)
        if upgraded != liveMarkers { liveMarkers = upgraded }
        refreshPlacements()
        hover(at: pointer)
    }

    /// The tree's frames hold for the live picture: same shape, not turned since.
    private var shapeMatches: Bool {
        guard let latest else { return false }
        guard let videoSize else { return true }
        return LiveInspect.sameShape(latest.size, videoSize)
    }

    /// The markers drawn over the live picture now, where their elements are now.
    var placements: [LivePlacement] {
        _ = overlayTick
        return LiveMarkers.placements(liveMarkers, nodes: latest?.nodes, fresh: treeFresh && shapeMatches,
                                      generation: schedule.generation)
    }

    /// Highlights are drawn only from a reading of the screen as it is now.
    var highlightsShown: Bool { treeFresh && shapeMatches }

    private func refreshPlacements() {
        var refs: [String: String] = [:]
        if let nodes = latest?.nodes {
            for marker in liveMarkers {
                if let node = LiveMarkers.match(marker, in: nodes) { refs[marker.id] = node.ref }
            }
        }
        if refs != markerRefs { markerRefs = refs }
    }

    /// The element under the pointer, from the latest reading. Only changes what is observed when it changes.
    func hover(at point: CGPoint?) {
        pointer = point
        guard inspecting, let point, let latest,
              let node = LiveInspect.elementAt(point, in: latest.nodes, treePicture: latest.size, video: videoSize) else {
            if hoverRef != nil { hoverRef = nil }
            return
        }
        if hoverRef != node.ref { hoverRef = node.ref }
    }

    /// A click on the live picture: mark the element under it (a click on one already
    /// marked chooses it), keeping the frame on show now. While the screen is moving it
    /// is a mark by position, which becomes the element once that screen has been read.
    func pick(at point: CGPoint) {
        guard inspecting, device != nil else { return }
        if highlightsShown, let latest, latest.root != nil,
           let node = LiveInspect.elementAt(point, in: latest.nodes, treePicture: latest.size, video: videoSize) {
            focus(node.ref, reveal: true)
            if marker(for: node.ref) == nil { mark(node) }
            return
        }
        guard let picture = capture() else { return }
        liveMarkers = LiveMarkers.adding(liveMarkers, id: "a-\(UUID().uuidString)", node: nil,
                                         rect: DeviceGeometry.boxAround(x: point.x, y: point.y), picture: picture,
                                         awaitingElement: !treeFresh)
        sendProblem = ""
    }

    /// The frame on show now, kept once per screen for every marker made on it.
    private func capture() -> Int? {
        let key = schedule.generation
        if captures[key] != nil { return key }
        guard let device else { return nil }
        // The live frame; before the first one is painted, the reading's own picture.
        let image = player.currentPicture()
            ?? latest.flatMap { NSImage(data: $0.frozen.png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard let image else {
            sendProblem = "The live picture has not arrived yet, so nothing was marked."
            return nil
        }
        let where_ = latest?.frozen.where_ ?? AnnotateWhere(place: device.kindWords, name: device.name, deviceId: device.id)
        captures[key] = Capture(image: image, thumbnail: NSImage(cgImage: image, size: .zero), where_: where_)
        return key
    }

    /// The frame a marker keeps, small, for the side list.
    func thumbnail(for marker: LiveMarker) -> NSImage? { captures[marker.picture]?.thumbnail }

    func focus(_ ref: String, reveal: Bool) {
        focusRef = ref
        guard reveal, let root = latest?.root else { return }
        expanded.formUnion(DeviceTreeQuery.ancestors(of: ref, in: root))
        revealTick += 1
    }

    func node(_ ref: String?) -> DeviceNode? {
        guard let ref else { return nil }
        return latest?.byRef[ref]
    }

    /// What the details show: the element under the pointer, or the one chosen.
    var detailNode: DeviceNode? { node(hoverRef) ?? node(focusRef) }

    /// The marker on this element of the latest tree, if any.
    func marker(for ref: String) -> Annotation? {
        liveMarkers.first { markerRefs[$0.id] == ref }?.annotation
    }

    func mark(_ node: DeviceNode) {
        guard marker(for: node.ref) == nil, let picture = capture() else { return }
        liveMarkers = LiveMarkers.adding(liveMarkers, id: "a-\(UUID().uuidString)", node: node,
                                         rect: node.usableFrame ?? DeviceGeometry.boxAround(x: 0.5, y: 0.5), picture: picture)
        refreshPlacements()
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
        liveMarkers = LiveMarkers.removing(liveMarkers, id: id)
        forgetUnusedCaptures()
        refreshPlacements()
        if liveMarkers.isEmpty { sendProblem = "" }
    }

    func clearMarkers() {
        liveMarkers = []
        captures = [:]
        markerRefs = [:]
        sendProblem = ""
    }

    private func forgetUnusedCaptures() {
        let used = Set(liveMarkers.map(\.picture))
        captures = captures.filter { used.contains($0.key) }
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

    /// The marked pictures saved with `annotate:save`, the round's one line typed into the
    /// session and submitted, and `annotate:sent` — the page's Annotate, end to end. Markers
    /// from one screen make one picture, as before; markers from several screens make one
    /// picture per screen, each with its own markers drawn, all named in the one message.
    func sendRound() async {
        guard canSendRound, !sending else { return }
        sending = true
        sendProblem = ""
        defer { sending = false }
        await loadSessions()
        guard let target = AgentSessions.resolve(chosenSessionId, in: sessions) else {
            sendProblem = sessionReason
            return
        }
        var drawn: [(png: Data, width: Int, height: Int, where_: AnnotateWhere)] = []
        var pictures: [RoundPicture] = []
        for group in LiveMarkers.pictureGroups(liveMarkers) {
            guard let capture = captures[group.picture],
                  let picture = MarkedPicture.draw(capture.image, markers: group.markers) else {
                sendProblem = "The picture could not be saved, so nothing was sent."
                return
            }
            drawn.append((picture.png, picture.width, picture.height, capture.where_))
            pictures.append(RoundPicture(path: "", width: picture.width, height: picture.height,
                                         markers: group.markers.map(\.n), screen: capture.where_.screen))
        }
        guard let first = drawn.first else { return }
        let round = AnnotationRound(id: "round-\(UUID().uuidString)", createdAt: (Date().timeIntervalSince1970 * 1000).rounded(),
                                    where_: first.where_, frameWidth: first.width, frameHeight: first.height,
                                    annotations: markers, note: note)
        // Last to first: annotate:save keeps one round per id with the picture it saved, so
        // the kept round ends with the picture carrying #1 — and that save lists the others.
        for index in drawn.indices.reversed() {
            let json = index == 0 ? round.json(pictures: pictures) : round.json
            let saved = try? await bridge.invoke("annotate:save", ["data:image/png;base64,\(drawn[index].png.base64EncodedString())", json])
            guard let path = (saved as? [String: Any])?["path"] as? String, !path.isEmpty else {
                sendProblem = "The picture could not be saved, so nothing was sent."
                return
            }
            pictures[index].path = path
        }
        if let refusal = await write(Handoff.composeRound(round, pictures: pictures), to: target) {
            sendProblem = refusal
            return
        }
        _ = try? await bridge.invoke("annotate:sent", [round.id, ["sessionId": target.id, "label": target.label]])
        // Inspect stays on over the live screen, ready for the next round.
        clearMarkers()
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
