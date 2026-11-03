import AppKit
import IOSurface
import TerminalDeckDirectMach
import TerminalDeckNativeCore

// Finding 3 (Asad, 22 Oct 2026): "why simulators are not running fast inside ... in native Device Hub app
// working fine but inside terminal deck its slow ... and also i cant type inside" — Option B: do what
// Device Hub does. The device's own screen buffer is shown as layer contents (no video encode, no
// decode), redrawn only when the device draws, and touches and keys go straight in.
//
// Safety: the private iOS work runs in the helper process, never here. Anything failing on the direct
// path (no helper, helper ends, a missing call in a new Xcode, an emulator going away) ends it quietly;
// the panel goes back to the device engine's picture (stills on iOS, screenrecord video on Android) with a
// short note, and the device is not tried directly again for two minutes. Off switch: `defaults write <app> devices.directScreen -bool NO`,
// or TD_DEVICE_DIRECT=0 in the environment.

/// A direct screen-and-input path for one device in one panel.
@MainActor protocol DeviceDirectSource: AnyObject {
    /// The screen surface: first, and again whenever the device replaces it (rotation, a new size).
    var onSurface: ((IOSurfaceRef) -> Void)? { get set }
    /// The device drew a new picture into the surface.
    var onFrame: (() -> Void)? { get set }
    /// The path ended by itself; the words go to the log, never on screen.
    var onEnded: ((String) -> Void)? { get set }
    /// Input can go this way now.
    var inputReady: Bool { get }
    /// Fingers go this way (the screen sends press, move and lift as they happen).
    var canTouch: Bool { get }
    /// Keys go this way, each at once.
    var canType: Bool { get }
    func start()
    func stop()
    /// The panel cannot be seen: no frame notices meanwhile.
    func setPaused(_ paused: Bool)
    /// Sends one input now; false when this path cannot take it (the caller sends it the engine's way).
    func send(_ input: DeviceInput) -> Bool
    /// Two fingers (a pinch made with the mouse and ⌥): false when this path cannot.
    func pinch(phase: String, first: CGPoint, second: CGPoint) -> Bool
}

@MainActor enum DeviceDirect {
    /// After a failure, the device is shown through the device engine's picture for this long before trying again.
    static let retryAfter: TimeInterval = 120
    private static var failures: [String: Date] = [:]

    static var enabled: Bool {
        if ProcessInfo.processInfo.environment[NativeLaunchSwitches.deviceDirect] == "0" { return false }
        return UserDefaults.standard.object(forKey: "devices.directScreen") as? Bool ?? true
    }

    /// The direct path for this device, when there is one and it has not just failed.
    static func source(for device: DeviceDetails, now: Date = Date()) -> (any DeviceDirectSource)? {
        guard enabled, let target = DeviceDirectTarget(id: device.id, platform: device.platform, kind: device.kind) else { return nil }
        if let failed = failures[device.id], now.timeIntervalSince(failed) < retryAfter { return nil }
        switch target {
        case .iosSimulator(let udid): return SimDirectSource(udid: udid)
        case .androidEmulator(let serial): return EmulatorDirectSource(serial: serial)
        }
    }

    static func failed(_ id: String, at now: Date = Date()) { failures[id] = now }

    /// The person asked to try the fast direct path again now: forget the cooldown for this device so the
    /// next `source(for:)` hands back a live source instead of nil (Asad 23 Oct: a visible Retry).
    static func clearFailure(_ id: String) { failures[id] = nil }
}

/// The iOS Simulator's direct path: `TerminalDeckNativeHelper --sim-direct` reads CoreSimulator and
/// sends Indigo input, or CoreDevice's while the simulator's touchscreen is that one (TDSimDirect.h);
/// its surface and frame notices arrive here over Mach. Without a screen (`screen: false`) it is input
/// only, for AI sessions' device tools while no panel shows the simulator (DeviceDirectInputs).
@MainActor final class SimDirectSource: DeviceDirectSource {
    var onSurface: ((IOSurfaceRef) -> Void)?
    var onFrame: (() -> Void)?
    var onEnded: ((String) -> Void)?
    var inputReady: Bool { ready != nil && !stopped }
    /// What the touchscreen the simulator uses now takes through the helper (the helper says when it changes).
    var canTouch: Bool { inputReady && ready?.touchNow == true }
    var canType: Bool { inputReady && ready?.keysNow == true }

    let udid: String
    /// Shows the screen (a panel); false: input only, no screen port and no frame notices.
    let screen: Bool
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var writeFD: Int32 = -1
    private var receiver: SimDirectReceiver?
    private var ready: SimDirectLine.Ready?
    private var gotSurface = false
    private var stopped = false
    private var watchdog: Task<Void, Never>?
    private var pending = Data()
    /// The finger(s) now down went to the helper: the rest of that gesture goes there too, even if the
    /// touchscreen changes hands meanwhile (the helper keeps a gesture on one touchscreen as well).
    private var touchDirect = false
    /// Callers waiting for the helper's ready line (DeviceDirectInputs), answered once each.
    private var readyWaiters: [UUID: CheckedContinuation<SimDirectLine.Ready?, Never>] = [:]
    /// Callers waiting for the helper's echo (long AI typing), by token, answered once each.
    private var echoWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var lastEcho = 0

    init(udid: String, screen: Bool = true) {
        self.udid = udid
        self.screen = screen
    }

    /// What the helper said it can do, once it is ready and while it runs.
    var current: SimDirectLine.Ready? { stopped ? nil : ready }
    var isStopped: Bool { stopped }

    /// The helper's ready line, waited for at most `seconds`; nil when it ends or takes longer. No polling:
    /// the line (or the end) answers every waiter.
    func whenReady(within seconds: Double) async -> SimDirectLine.Ready? {
        if stopped { return nil }
        if let ready { return ready }
        let key = UUID()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.answerWaiter(key, nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { readyWaiters[key] = $0 }
    }

    private func answerWaiter(_ key: UUID, _ answer: SimDirectLine.Ready?) {
        readyWaiters.removeValue(forKey: key)?.resume(returning: answer)
    }

    private func answerWaiters(_ answer: SimDirectLine.Ready?) {
        let waiting = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiting.values { waiter.resume(returning: answer) }
    }

    /// True once the helper has taken every line written before this call (its echo, SimDirectLine.echo);
    /// false when it ends, cannot be written to, or takes longer than `seconds`. Long AI typing writes its next
    /// piece only after this, so the helper's input pipe never fills (review 22 Oct 2026).
    func settled(within seconds: Double) async -> Bool {
        guard !stopped else { return false }
        lastEcho += 1
        let token = lastEcho
        guard write(SimDirectLine.echo(token)) else { return false }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.answerEcho(token, false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { echoWaiters[token] = $0 }
    }

    private func answerEcho(_ token: Int, _ answer: Bool) {
        echoWaiters.removeValue(forKey: token)?.resume(returning: answer)
    }

    /// Tests only (the live phone-devices check): the helper as `swift build` made it, beside no app bundle.
    nonisolated(unsafe) static var helperOverride: URL?

    static func helperURL() -> URL? {
        if let helperOverride { return helperOverride }
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/TerminalDeckNativeHelper"),
                          Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("TerminalDeckNativeHelper")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start() {
        guard process == nil, !stopped else { return }
        // One helper per simulator: a panel showing it takes over from an input-only one.
        if screen { DeviceDirectInputs.shared.panelStarted(self) }
        guard let helper = Self.helperURL() else { end("The screen helper is not in this build."); return }
        let name = screen ? "dev.terminaldeck.simdirect.\(getpid()).\(UUID().uuidString)" : SimDirectLine.inputOnly
        var port: mach_port_t = 0
        if screen {
            guard td_direct_listen(name, &port) == KERN_SUCCESS, port != 0 else { end("The screen port could not be made."); return }
        }
        let child = Process()
        child.executableURL = helper
        child.arguments = ["--sim-direct", udid, name]
        let inPipe = Pipe(), outPipe = Pipe()
        child.standardInput = inPipe
        child.standardOutput = outPipe
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.helperEnded(status) } }
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.read(data) } }
        }
        do { try child.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            if screen { td_direct_close(port) }
            end("The screen helper could not start: \(error.localizedDescription)")
            return
        }
        process = child
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        writeFD = inPipe.fileHandleForWriting.fileDescriptor
        // Never a signal, never a wait: a helper that stops reading ends the direct path instead.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        guard screen else {
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled, !self.stopped, self.ready == nil else { return }
                self.end("The input helper did not get ready in time.")
            }
            return
        }
        let receiver = SimDirectReceiver(port: port, sender: child.processIdentifier,
            surface: { [weak self] box in DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(box.surface) } } },
            frame: { [weak self] in self?.onFrame?() },
            failed: { [weak self] in self?.end("The screen port stopped working.") })
        self.receiver = receiver
        receiver.start()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, !self.stopped, self.ready == nil || !self.gotSurface else { return }
            self.end("The screen helper did not show the screen in time.")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        answerWaiters(nil)
        let echoes = echoWaiters
        echoWaiters.removeAll()
        for waiter in echoes.values { waiter.resume(returning: false) }
        if screen { DeviceDirectInputs.shared.panelStopped(self) }
        watchdog?.cancel()
        watchdog = nil
        if writeFD >= 0 { raw(SimDirectLine.quit) }
        try? input?.close()
        input = nil
        writeFD = -1
        output?.readabilityHandler = nil
        output = nil
        receiver?.stop()
        receiver = nil
        if let child = process {
            child.terminationHandler = nil
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) { if child.isRunning { child.terminate() } }
        }
        process = nil
    }

    func setPaused(_ paused: Bool) { write(SimDirectLine.pause(paused)) }

    func send(_ input: DeviceInput) -> Bool {
        guard let ready, !stopped else { return false }
        switch input {
        case let .touch(phase, x, y):
            guard fingers(phase, ready) else { return false }
            // A finger put down right at the screen's edge (the panel's mouse) starts an edge swipe.
            if phase == "down", let edge = SimDirectLine.edge(fromX: x, fromY: y, band: 0.015) { write(edge) }
            return write(SimDirectLine.touch(down: phase != "up", [(x, y)]))
        case let .tap(x, y, hold):
            guard ready.touchNow else { return false }
            play(DeviceDirectGesture.tap(x: x, y: y, holdMs: hold))
            return true
        case let .swipe(fromX, fromY, toX, toY, ms):
            guard ready.touchNow else { return false }
            if let edge = SimDirectLine.edge(fromX: fromX, fromY: fromY, toX: toX, toY: toY) { write(edge) }
            play(DeviceDirectGesture.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms))
            return true
        case .type(let text):
            // On CoreDevice's touchscreen the engine's typing is dropped too, so a paste goes as keys there.
            guard ready.keysNow, let lines = SimDirectLine.typing(text, coreDevice: ready.coreDevice) else { return false }
            return write(lines)
        case .key(let name):
            return sendKey(name, modifiers: [])
        case .button(let name):
            guard ready.buttonsNow, let down = SimDirectLine.button(name, down: true, coreDevice: ready.coreDevice, side: ready.side),
                  let up = SimDirectLine.button(name, down: false, coreDevice: ready.coreDevice, side: ready.side),
                  write(down) else { return false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { MainActor.assumeIsolated { _ = self.write(up) } }
            return true
        }
    }

    /// AI device tools' input: taps and swipes are in the frame of the app on screen (devices.tree), which the
    /// helper turns onto the upright touchscreen; everything else as `send`.
    func sendFromTool(_ input: DeviceInput) -> Bool {
        guard let ready, !stopped else { return false }
        switch input {
        case let .tap(x, y, hold):
            guard ready.touchNow else { return false }
            play(DeviceDirectGesture.tap(x: x, y: y, holdMs: hold), appFrame: true)
            return true
        case let .swipe(fromX, fromY, toX, toY, ms):
            guard ready.touchNow else { return false }
            if let edge = SimDirectLine.edge(fromX: fromX, fromY: fromY, toX: toX, toY: toY) { write(edge) }
            play(DeviceDirectGesture.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms), appFrame: true)
            return true
        default:
            return send(input)
        }
    }

    /// A named key with modifiers held around it (AI device tools); false when this path cannot take it.
    func sendKey(_ name: String, modifiers: [String]) -> Bool {
        guard let ready, !stopped, ready.keysNow, let strokes = DeviceDirectKeys.named(name, modifiers: modifiers) else { return false }
        return write(strokes.map(SimDirectLine.press).joined())
    }

    func pinch(phase: String, first: CGPoint, second: CGPoint) -> Bool {
        guard let ready, !stopped, fingers(phase, ready) else { return false }
        return write(SimDirectLine.touch(down: phase != "up", [(Double(first.x), Double(first.y)), (Double(second.x), Double(second.y))]))
    }

    // MARK: Inside

    /// Whether this finger step goes to the helper: decided when the finger goes down, kept until it lifts.
    private func fingers(_ phase: String, _ ready: SimDirectLine.Ready) -> Bool {
        if phase == "down" { touchDirect = ready.touchNow }
        let direct = touchDirect
        if phase == "up" { touchDirect = false }
        return direct
    }

    private func play(_ steps: [DeviceDirectTouchStep], appFrame: Bool = false) {
        for step in steps {
            let line = SimDirectLine.touch(down: !step.up, [(step.x, step.y)], appFrame: appFrame)
            if step.atMs <= 0 { write(line); continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.atMs / 1000) { MainActor.assumeIsolated { _ = self.write(line) } }
        }
    }

    @discardableResult private func write(_ text: String?) -> Bool {
        guard let text, writeFD >= 0, !stopped else { return false }
        if raw(text) { return true }
        end("The screen helper stopped taking input.")
        return false
    }

    @discardableResult private func raw(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        return written == bytes.count
    }

    private func received(_ surface: IOSurfaceRef) {
        guard !stopped else { return }
        gotSurface = true
        if ready != nil { watchdog?.cancel() }
        onSurface?(surface)
    }

    private func read(_ data: Data) {
        guard !stopped else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if let ready = SimDirectLine.ready(line) {
                self.ready = ready
                NativeCompositionRoot.note("device direct: \(udid) \(screen ? "live" : "input only") \(ready.width)x\(ready.height) touch=\(ready.touch) keys=\(ready.keys) buttons=\(ready.buttons) core=\(ready.core) hid=\(ready.coreDevice ? "coredevice" : "indigo")")
                if !screen { watchdog?.cancel() }
                DeviceDirectInputs.shared.heard(udid, coreDevice: ready.coreDevice)
                answerWaiters(ready)
                // The panel learns at once that fingers and keys can go this way now.
                if gotSurface { watchdog?.cancel(); onFrame?() }
            } else if let coreDevice = SimDirectLine.hid(line) {
                ready?.coreDevice = coreDevice
                DeviceDirectInputs.shared.heard(udid, coreDevice: coreDevice)
                NativeCompositionRoot.note("device direct: \(udid) touchscreen now \(coreDevice ? "CoreDevice's" : "Indigo's")")
                // What fingers and keys can do may have changed with it: the panel hears at once, so input
                // the new touchscreen cannot take here goes the engine's way from the next one.
                if gotSurface { onFrame?() }
            } else if let token = SimDirectLine.echoed(line) {
                answerEcho(token, true)
            } else if line.hasPrefix("note ") {
                NativeCompositionRoot.note("device direct: \(udid) \(line.dropFirst(5))")
            } else if line == "gone" {
                // Starting again brings the simulator's own touchscreen back.
                DeviceDirectInputs.shared.heard(udid, coreDevice: nil)
                end("The simulator shut down.")
                return
            } else if line.hasPrefix("error ") {
                end(String(line.dropFirst(6)))
                return
            }
        }
        if pending.count > 4_096 { pending.removeAll() }
    }

    private func helperEnded(_ status: Int32) {
        guard !stopped else { return }
        end("The screen helper ended (\(status)).")
    }

    private func end(_ reason: String) {
        guard !stopped else { return }
        // engine.log, not NSLog: the system log keeps NSLog text as <private> (22 Oct, finding 3).
        NativeCompositionRoot.note("device direct: \(udid): \(reason)")
        stop()
        onEnded?(reason)
    }
}

/// Carries a surface from the receiving thread to the main one; not touched on the way.
struct DirectSurfaceBox: @unchecked Sendable { let surface: IOSurfaceRef }

/// Waits on the app's screen port on its own thread. Only the helper it started may send to it.
/// Frame notices are folded: while one is on its way to the main thread, more are not queued.
/// A port that fails ends the direct path (the panel goes back to the video) instead of a frozen picture.
final class SimDirectReceiver: @unchecked Sendable {
    private let port: mach_port_t
    private let sender: pid_t
    private let surface: @Sendable (DirectSurfaceBox) -> Void
    private let frame: @MainActor () -> Void
    private let failed: @MainActor () -> Void
    private let lock = NSLock()
    private var stopped = false
    private var framePending = false

    init(port: mach_port_t, sender: pid_t, surface: @escaping @Sendable (DirectSurfaceBox) -> Void, frame: @escaping @MainActor () -> Void,
         failed: @escaping @MainActor () -> Void) {
        self.port = port
        self.sender = sender
        self.surface = surface
        self.frame = frame
        self.failed = failed
    }

    func start() {
        let thread = Thread { [self] in loop() }
        thread.name = "terminaldeck.device-direct"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The thread notices within a quarter of a second and gives the port up itself, so its name is
    /// never reused under a receive still waiting on it.
    func stop() { lock.withLock { stopped = true } }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func loop() {
        while !isStopped {
            let message = td_direct_receive(port, 250, sender)
            if message.kind == TDDirectSurface {
                if let found = IOSurfaceLookupFromMachPort(message.surface), !isStopped { surface(DirectSurfaceBox(surface: found)) }
                mach_port_deallocate(mach_task_self_, message.surface)
            } else if message.kind == TDDirectFrame {
                let first = lock.withLock { () -> Bool in
                    if framePending || stopped { return false }
                    framePending = true
                    return true
                }
                guard first else { continue }
                DispatchQueue.main.async { [self] in
                    lock.withLock { framePending = false }
                    MainActor.assumeIsolated { if !isStopped { frame() } }
                }
            } else if message.kind == TDDirectFailed {
                if !isStopped { DispatchQueue.main.async { [self] in MainActor.assumeIsolated { if !isStopped { failed() } } } }
                break
            }
        }
        td_direct_close(port)
    }
}
