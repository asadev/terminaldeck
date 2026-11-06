import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Runs in the GUI bootstrap session selected by launchd, never inside the system daemon. No password UI is drawn
/// here: events go to macOS's own password field, using the same event posting code as ordinary phone control.
@MainActor final class MacReachAgent {
    private var client: BackendMacReachClient?
    private var captures: [CGDirectDisplayID: MacReachAgentCapture] = [:]
    private var observers: [NSObjectProtocol] = []
    private var users: [CGDirectDisplayID: Int] = [:]

    func run() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let requirement = try BackendMacReachSigning.requirements().helper
        let connection = NSXPCConnection(machServiceName: MacReach.daemonLabel, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: BackendMacReachRPC.self)
        connection.exportedInterface = NSXPCInterface(with: BackendMacReachRPC.self)
        connection.exportedObject = BackendMacReachRequest { [weak self] command, payload in
            guard let self else { throw Self.unavailable }
            return try await self.handle(command, payload)
        }
        connection.invalidationHandler = { exit(0) }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume()
        let client = BackendMacReachClient(connection: connection)
        self.client = client
        Task {
            do { _ = try await client.value("agent", .object([.init("loginWindow", .bool(geteuid() == 0))])) }
            catch { exit(0) }
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.changedSession() }
            })
        }
    }
    private func changedSession() async {
        // Keep each source object available while its capture is replaced. Empty frames mean “starting”, not “ended”.
        // Clear first so no pre-lock desktop can be presented as a current lock-screen frame.
        let previous = captures
        for capture in previous.values { capture.clear() }
        for (id, capture) in previous {
            await capture.stop()
            guard captures[id] === capture else { continue }
            do {
                try await capture.start()
                if captures[id] !== capture { await capture.stop() }
            } catch { capture.failed() }
        }
    }
    private func handle(_ command: String, _ payload: Data) async throws -> Data {
        guard payload.count <= 65_536 else { throw Self.unavailable }
        if command == "stop-all" {
            let previous = captures; captures = [:]; users = [:]
            for capture in previous.values { await capture.stop() }
            return Data()
        }
        if command == "rows" { return try NativeRPCValue.object([.init("devices", .array(rows()))]).encodedJSON() }
        if command == "wake" { try await wake(); return try NativeRPCValue.object([.init("ok", .bool(true))]).encodedJSON() }
        let value = try NativeRPCValue.parseJSON(payload)
        let id = try display(value["id"].string ?? "")
        switch command {
        case "open":
            guard CGPreflightScreenCaptureAccess() else {
                throw NativeRPCError(code: "unavailable", message: "Allow Terminal Deck in System Settings → Privacy & Security → Screen Recording on your Mac.")
            }
            if captures[id] == nil {
                let capture = MacReachAgentCapture(display: id)
                try await capture.start()
                captures[id] = capture
            }
            users[id, default: 0] += 1
            return Data()
        case "cursor":
            guard let capture = captures[id] else { throw Self.unavailable }
            try await capture.showsCursor(value["phone"].bool != true)
            return Data()
        case "frame":
            guard let capture = captures[id] else { throw Self.unavailable }
            return try capture.frame()
        case "close":
            users[id] = max(0, (users[id] ?? 0) - 1)
            if users[id] == 0 { users[id] = nil; let capture = captures.removeValue(forKey: id); await capture?.stop() }
            return Data()
        case "password":
            try BackendMacReachPassword.send(value["password"].string, state: { Self.state })
            return Data()
        case "input":
            guard AXIsProcessTrusted() else {
                throw NativeRPCError(code: "unavailable", message: "Allow Terminal Deck in System Settings → Privacy & Security → Accessibility on your Mac.")
            }
            let input = try BackendMacReachInput.decode(value)
            // The signed caller checks control permission; capture may remain local while locked.
            guard captures[id] != nil || [.locked, .signingIn].contains(Self.state) || macReachIsRelease(input) else { throw Self.unavailable }
            await BackendMacReachInput.post(input, bounds: CGDisplayBounds(id))
            return Data()
        default: throw Self.unavailable
        }
    }
    static var state: MacReach.State {
        // A LoginWindow agent is root and may have no authenticated-user dictionary yet. Its connected GUI session
        // is the sign-in screen; absence of a signed-in account is not loss of the machine.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return geteuid() == 0 ? .signingIn : .unreachable }
        return MacReach.state(reachable: true, loginDone: session[kCGSessionLoginDoneKey as String] as? Bool == true,
            locked: session["CGSSessionScreenIsLocked"] as? Bool == true,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }
    static func inventory() -> [MacDisplaySelection.Display] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count <= 64 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { $0.takeRetainedValue() }.flatMap { CFUUIDCreateString(nil, $0) as String? }.flatMap(UUID.init(uuidString:))
            return .init(number: id, uuid: uuid, main: CGDisplayIsMain(id) != 0)
        }
    }
    private func display(_ id: String) throws -> CGDirectDisplayID {
        try MacDisplaySelection.resolve(id, displays: Self.inventory()).number
    }
    private func rows() -> [NativeRPCValue] {
        let state = Self.state
        return Self.inventory().sorted { $0.main && !$1.main }.map { display in
            let bounds = CGDisplayBounds(display.number)
            let at = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let x = min(max((at.x - bounds.minX) / max(1, bounds.width), 0), 1)
            let y = min(max((at.y - bounds.minY) / max(1, bounds.height), 0), 1)
            return .object([.init("pointer", .object([.init("x", .number(x)), .init("y", .number(y)),
                .init("onDisplay", .bool(bounds.contains(at))), .init("width", .number(bounds.width))])),.init("id", .string(display.wireID)), .init("name", .string(display.main ? "This Mac" : "Mac display")),
                .init("platform", .string("mac")), .init("kind", .string("display")), .init("state", .string("ready")),
                .init("screenState", .string(state.rawValue)), .init("runtime", .string("\(Int(bounds.width)) × \(Int(bounds.height))")),
                .init("main", .bool(display.main)), .init("canStart", .bool(false)), .init("canStop", .bool(false)),
                .init("canRotate", .bool(false)), .init("buttons", .array([])), .init("canWatch", .bool(CGPreflightScreenCaptureAccess())),
                .init("canControl", .bool(AXIsProcessTrusted())), .init("note", .string(state == .desktop ? "" : state.words))])
        }
    }
    private func wake() async throws {
        var assertion = IOPMAssertionID(0)
        guard IOPMAssertionDeclareUserActivity("Phone sign-in screen" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess else { throw Self.unavailable }
        defer { IOPMAssertionRelease(assertion) }
        try await Task.sleep(for: .seconds(1))
    }
    nonisolated private static var unavailable: NativeRPCError {
        .init(code: "unavailable", message: "Your Mac's sign-in screen is unavailable right now. Try again.")
    }
}

final class MacReachAgentCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let display: CGDirectDisplayID
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mac-reach.screen", qos: .userInteractive)
    private var stream: SCStream?
    private var packet = Data()
    private var configuration: SCStreamConfiguration?
    private var problem = false
    init(display: CGDirectDisplayID) { self.display = display }
    @MainActor func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw NativeRPCError(code: "unavailable", message: "Screen Recording must be allowed on your Mac.") }
        var assertion: IOPMAssertionID = 0
        let woke = IOPMAssertionDeclareUserActivity("Phone sign-in screen" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess
        defer { if woke { IOPMAssertionRelease(assertion) } }
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if content.displays.isEmpty, woke {
            try await Task.sleep(for: .seconds(1))
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        guard let screen = content.displays.first(where: { $0.displayID == display }) else {
            throw NativeRPCError(code: "unavailable", message: "macOS isn't making its sign-in screen available. Check the access helper on your Mac, then try again.")
        }
        let configuration = SCStreamConfiguration()
        let factor = min(1, 1920.0 / Double(max(screen.width, screen.height)))
        configuration.width = max(2, Int(Double(screen.width) * factor) / 2 * 2)
        configuration.height = max(2, Int(Double(screen.height) * factor) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: SCContentFilter(display: screen, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock { self.stream = stream; self.configuration = configuration; packet = Data(); problem = false }
        do { try await stream.startCapture() } catch { failed(); throw error }
    }
    func showsCursor(_ visible: Bool) async throws {
        guard let pair = lock.withLock({ () -> (SCStream, SCStreamConfiguration)? in
            guard let stream, let configuration else { return nil }
            configuration.showsCursor = visible
            return (stream, configuration)
        }) else { return }
        try await pair.0.updateConfiguration(pair.1)
    }
    func frame() throws -> Data {
        try lock.withLock {
            if problem { throw NativeRPCError(code: "unavailable", message: "The Mac sign-in screen stopped. Try again.") }
            return packet
        }
    }
    func clear() { lock.withLock { packet = Data() } }
    func failed() { lock.withLock { packet = Data(); problem = true } }
    func stop() async {
        let stream = lock.withLock { let value = stream; stream = nil; packet = Data(); return value }
        try? await stream?.stopCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { failed() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, lock.withLock({ self.stream === stream }),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sample),
              let bytes = try? BackendMacReachPixels.encode(buffer, capturedAt: Date().timeIntervalSince1970 * 1000) else { return }
        lock.withLock { if self.stream === stream { packet = bytes } }
    }
}

/// Cleanup must still release a drag or held key after its last screen viewer has gone away.
func macReachIsRelease(_ input: BackendPhoneDeviceInput) -> Bool {
    switch input {
    case .keyCode(_, down: false, modifiers: _), .mouse(phase: "up", button: _, x: _, y: _, clicks: _), .click(button: _, phase: "up"): return true
    default: return false
    }
}
