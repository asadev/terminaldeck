import AppKit
import ApplicationServices
import CoreImage
import CoreMedia
import Foundation
import IOKit.pwr_mgt
import IOSurface
import ScreenCaptureKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// Asad, 31 Oct 2026: see and control THIS Mac from the phone ("can we make something like macky" → "build"), built
// fresh on the phone's Devices page: "This Mac" is listed first, one row per display, and opens in the same
// full-screen viewer as a simulator. Pictures come from ScreenCaptureKit (only when the screen changed, at most 20 a
// second, at the display's own pixel size up to 1920 wide), input goes in as ordinary mouse, scroll and key events.
//
// macOS asks for two permissions, once, at the Mac: Screen Recording (to see) and Accessibility (to click and type).
// Nothing here ever asks macOS for them on its own: the phone is told in words, and the Mac shows the same words with
// buttons that open the right Settings page — only when a phone tries.

/// This Mac's displays, permissions, pictures and input for the phone.
@MainActor enum NativeMacScreen {
    nonisolated static let permissionLine = "This Mac needs a one-time permission: System Settings → Privacy & Security → Screen Recording and Accessibility → Terminal Deck."
    nonisolated static let recordingLine = "This Mac needs a one-time permission to show its screen: System Settings → Privacy & Security → Screen Recording → Terminal Deck."
    nonisolated static let controlLine = "This Mac needs a one-time permission to be clicked and typed on: System Settings → Privacy & Security → Accessibility → Terminal Deck."
    nonisolated static let recordingSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    nonisolated static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Screen Recording is granted (checked without asking).
    nonisolated static var canRecord: Bool { CGPreflightScreenCaptureAccess() }
    /// Accessibility is granted (checked without asking).
    nonisolated static var canControl: Bool { AXIsProcessTrusted() }

    /// The words for what is missing, or "" when both are granted.
    nonisolated static func missingLine(record: Bool = canRecord, control: Bool = canControl) -> String {
        switch (record, control) {
        case (true, true): return ""
        case (false, false): return permissionLine
        case (false, true): return recordingLine
        case (true, false): return controlLine
        }
    }

    nonisolated static var macName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "This Mac" : name
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// One row per display, the main display first, as the phone's Devices page lists them.
    static func rows() -> [NativeRPCValue] {
        let screens = NSScreen.screens
        let record = canRecord, control = canControl
        return screens.compactMap { screen -> NativeRPCValue? in
            guard let id = displayID(screen) else { return nil }
            let bounds = CGDisplayBounds(id)
            let name = screens.count > 1 ? "\(macName) · \(screen.localizedName)" : macName
            let pixels = CGDisplayCopyDisplayMode(id).map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "\(Int(bounds.width)) × \(Int(bounds.height))"
            return .object([.init("id", .string("mac:\(id)")), .init("name", .string(name)), .init("platform", .string("mac")),
                            .init("kind", .string("display")), .init("state", .string("ready")), .init("runtime", .string(pixels)),
                            .init("canStart", .bool(false)), .init("canStop", .bool(false)), .init("canRotate", .bool(false)),
                            .init("buttons", .array([])), .init("main", .bool(CGDisplayIsMain(id) != 0)),
                            .init("canWatch", .bool(record)), .init("canControl", .bool(control)),
                            .init("note", .string(missingLine(record: record, control: control)))])
        }
    }

    static func display(_ id: String) throws -> CGDirectDisplayID {
        guard id.hasPrefix("mac:"), let number = UInt32(id.dropFirst(4)) else { throw NativeRPCError.invalidArguments("That is not one of this Mac's displays.") }
        return CGDirectDisplayID(number)
    }

    // MARK: Pictures

    /// A live stream of one display, or a refusal in words (the Mac shows the permission card too).
    static func stream(_ id: String) async throws -> any BackendPhoneDeviceStream {
        let display = try display(id)
        guard canRecord else {
            NativeMacScreenIndicator.shared.needsPermission(record: false, control: canControl)
            throw NativeRPCError(code: "unavailable", message: recordingLine)
        }
        let capture = try await NativeMacScreenCaptures.shared.open(display)
        return NativeMacScreenStream(capture: capture)
    }

    /// A full-size still of one display, as PNG.
    static func shot(_ id: String) async throws -> BackendAppDeviceScreenshot {
        let display = try display(id)
        guard canRecord else {
            NativeMacScreenIndicator.shared.needsPermission(record: false, control: canControl)
            throw NativeRPCError(code: "unavailable", message: recordingLine)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let screen = content.displays.first(where: { $0.displayID == display }) else {
            throw NativeRPCError(code: "unavailable", message: "That display is no longer connected to this Mac.")
        }
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display)
        configuration.width = mode?.pixelWidth ?? screen.width * 2
        configuration.height = mode?.pixelHeight ?? screen.height * 2
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: screen, excludingWindows: []), configuration: configuration)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw NativeRPCError(code: "unavailable", message: "The screenshot could not be made.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NativeRPCError(code: "unavailable", message: "The screenshot could not be made.") }
        return .init(png: data as Data, width: Double(image.width), height: Double(image.height))
    }

    // MARK: Input

    /// Clicks, scrolls and keys from the phone, as ordinary events on this Mac (posted off the main thread: a drag
    /// takes its time). Refused in words without Accessibility.
    nonisolated static func input(_ id: String, _ input: BackendPhoneDeviceInput) async throws {
        guard id.hasPrefix("mac:"), let number = UInt32(id.dropFirst(4)) else { throw NativeRPCError.invalidArguments("That is not one of this Mac's displays.") }
        guard canControl else {
            let record = canRecord
            await MainActor.run { NativeMacScreenIndicator.shared.needsPermission(record: record, control: false) }
            throw NativeRPCError(code: "unavailable", message: controlLine)
        }
        await NativeMacScreenInput.post(input, bounds: CGDisplayBounds(CGDirectDisplayID(number)))
        // The Mac's card blinks at each remote click or key (learning 8), so the person at the Mac sees it happen.
        // A pointer move or a release is not worth a blink; a press, a key or text is.
        let blink: Bool
        switch input {
        case let .mouse(phase, _, _, _, _): blink = phase == "down"
        case let .keyCode(_, down, _): blink = down
        default: blink = true
        }
        if blink { await MainActor.run { NativeMacScreenIndicator.shared.flash() } }
    }
}

/// Posting the phone's input as CoreGraphics events, in global display points (top-left origin).
enum NativeMacScreenInput {
    private static let clickLock = NSLock()
    nonisolated(unsafe) private static var lastClick: (at: CGPoint, time: Date, count: Int64)?

    static func point(_ x: Double, _ y: Double, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width, y: bounds.minY + min(max(y, 0), 1) * bounds.height)
    }

    /// Async (Reviewer, 31 Oct): a drag's steps wait with `Task.sleep`, never a `usleep` that would hold a thread of the
    /// shared cooperative pool for the whole drag.
    static func post(_ input: BackendPhoneDeviceInput, bounds: CGRect) async {
        let source = CGEventSource(stateID: .hidSystemState)
        func mouse(_ type: CGEventType, _ at: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: clicks)
            event.post(tap: .cghidEventTap)
        }
        switch input {
        case let .tap(x, y, hold):
            let at = point(x, y, in: bounds)
            if let hold, hold >= 450 { click(at, button: .right, mouse: mouse); return }
            click(at, button: .left, mouse: mouse)
        case let .secondaryTap(x, y):
            click(point(x, y, in: bounds), button: .right, mouse: mouse)
        case let .swipe(fromX, fromY, toX, toY, ms):
            // A drag with the button held: press, move in small steps, release.
            let from = point(fromX, fromY, in: bounds), to = point(toX, toY, in: bounds)
            mouse(.mouseMoved, from)
            mouse(.leftMouseDown, from)
            let steps = max(6, min(60, Int(ms / 16)))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                try? await Task.sleep(for: .milliseconds(max(4, min(25, ms / Double(steps)))))
            }
            mouse(.leftMouseUp, to)
        case let .scroll(x, y, dx, dy):
            mouse(.mouseMoved, point(x, y, in: bounds))
            // A share of the picture becomes points on this display: a finger moving the content down scrolls up.
            let wheelY = Int32((dy * bounds.height).rounded()), wheelX = Int32((dx * bounds.width).rounded())
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheelY, wheel2: wheelX, wheel3: 0)?
                .post(tap: .cghidEventTap)
        case .type(let text):
            for chunk in chunks(text) {
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    let units = Array(chunk.utf16)
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.post(tap: .cghidEventTap)
                }
            }
        case .key(let name):
            key(name, modifiers: [], source: source)
        case let .shortcut(name, modifiers):
            key(name, modifiers: modifiers, source: source)
        case let .mouse(phase, button, x, y, clicks):
            // Another Mac's real mouse: where the pointer is, with its own press, release and drag (Mac to Mac).
            let at = point(x, y, in: bounds)
            let which: CGMouseButton = button == "right" ? .right : button == "middle" ? .center : .left
            let type: CGEventType
            switch (phase, which) {
            case ("down", .left): type = .leftMouseDown
            case ("down", .right): type = .rightMouseDown
            case ("down", _): type = .otherMouseDown
            case ("up", .left): type = .leftMouseUp
            case ("up", .right): type = .rightMouseUp
            case ("up", _): type = .otherMouseUp
            case ("drag", .left): type = .leftMouseDragged
            case ("drag", .right): type = .rightMouseDragged
            case ("drag", _): type = .otherMouseDragged
            default: type = .mouseMoved
            }
            mouse(type, at, which, clicks: Int64(clicks))
        case let .keyCode(code, down, modifiers):
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { break }
            event.flags = Self.flags(modifiers)
            event.post(tap: .cghidEventTap)
        case .button, .rotate:
            break
        }
    }

    /// A click, counted as a double click when it lands near the last one within half a second.
    private static func click(_ at: CGPoint, button: CGMouseButton, mouse: (CGEventType, CGPoint, CGMouseButton, Int64) -> Void) {
        let count: Int64 = clickLock.withLock {
            var count: Int64 = 1
            if button == .left, let last = lastClick, Date().timeIntervalSince(last.time) < 0.5, hypot(last.at.x - at.x, last.at.y - at.y) < 8 {
                count = min(last.count + 1, 3)
            }
            lastClick = button == .left ? (at, Date(), count) : nil
            return count
        }
        mouse(.mouseMoved, at, button, count)
        mouse(button == .left ? .leftMouseDown : .rightMouseDown, at, button, count)
        mouse(button == .left ? .leftMouseUp : .rightMouseUp, at, button, count)
    }

    private static func chunks(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        for character in text {
            if current.utf16.count + character.utf16.count > 16 { out.append(current); current = "" }
            current.append(character)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// US-layout key codes for the named keys and for letters and digits (a shortcut such as ⌘C).
    static let codes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = ["return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forward-delete": 117,
            "home": 115, "end": 119, "page-up": 116, "page-down": 121, "arrow-left": 123, "arrow-right": 124, "arrow-down": 125, "arrow-up": 126,
            "select-all": 0]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
            ("5", 23), ("9", 25), ("7", 26), ("8", 28), ("0", 29), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40),
            ("n", 45), ("m", 46)]
        for (name, code) in letters { map[name] = code }
        return map
    }()

    static func flags(_ modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    private static func key(_ name: String, modifiers: [String], source: CGEventSource?) {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        if name == "select-all" { flags.insert(.maskCommand) }
        guard let code = codes[name] else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
}

/// One display's ScreenCaptureKit stream, shared by every phone watching it.
final class NativeMacScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let display: CGDirectDisplayID
    private let lock = NSLock()
    private var stream: SCStream?
    /// The newest picture's pixel buffer, retained (Reviewer, 31 Oct): its IOSurface stays valid only while the buffer
    /// it came from is held, so the buffer is kept, not the bare surface.
    private var pixels: CVPixelBuffer?
    private var generation = 0
    private var ended: String?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let queue = DispatchQueue(label: "dev.terminaldeck.mac-screen", qos: .userInteractive)
    var users = 0

    init(display: CGDirectDisplayID) { self.display = display }

    /// The display's own pixels (Retina, not points: Macky study, learning 1 — capturing at points is why remote text
    /// looks soft), the longest side at most 2560. The phone zooms into the picture for small text.
    static func size(of display: CGDirectDisplayID) -> (Int, Int) {
        let bounds = CGDisplayBounds(display)
        let mode = CGDisplayCopyDisplayMode(display)
        var width = Double(mode?.pixelWidth ?? Int(bounds.width * 2)), height = Double(mode?.pixelHeight ?? Int(bounds.height * 2))
        let longest = max(width, height)
        if longest > 2560 { width *= 2560 / longest; height *= 2560 / longest }
        return (max(2, Int(width) / 2 * 2), max(2, Int(height) / 2 * 2))
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let screen = content.displays.first(where: { $0.displayID == display }) else {
            throw NativeRPCError(code: "unavailable", message: "That display is no longer connected to this Mac.")
        }
        let configuration = SCStreamConfiguration()
        let (width, height) = Self.size(of: display)
        configuration.width = width
        configuration.height = height
        // At most 30 a second (learning 2), in 4:2:0 (learning 4: half the memory of BGRA per picture).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 4
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: SCContentFilter(display: screen, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
    }

    func stop() {
        let stream = lock.withLock { () -> SCStream? in
            let stream = self.stream; self.stream = nil
            if ended == nil { ended = "Stopped." }
            return stream
        }
        wakeAll()
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only pictures that show something new (ScreenCaptureKit also reports idle and blank frames).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), CVPixelBufferGetIOSurface(pixels) != nil else { return }
        lock.withLock { self.pixels = pixels; generation += 1 }
        wakeAll()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        // Screen Recording taken away while a phone watched (learning 7): say so on the phone and on the Mac.
        let revoked = !NativeMacScreen.canRecord
        lock.withLock { ended = revoked ? NativeMacScreen.recordingLine : "The Mac stopped sharing its screen (\(error.localizedDescription))." }
        wakeAll()
        if revoked { Task { @MainActor in NativeMacScreenIndicator.shared.needsPermission(record: false, control: NativeMacScreen.canControl) } }
    }

    private func wakeAll() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let all = Array(waiters.values); waiters.removeAll(); return all
        }
        for waiter in waiting { waiter.resume() }
    }

    /// The newest picture if it is newer than `seen`, the reason it ended, or nil when there is nothing new yet.
    func latest(after seen: Int) -> (pixels: CVPixelBuffer?, generation: Int, ended: String?) {
        lock.withLock { (generation != seen ? pixels : nil, generation, ended) }
    }

    /// Waits for the next picture (or the end), at most `seconds`; a cancelled caller stops waiting at once.
    func wait(after seen: Int, seconds: Double = 2) async {
        let key = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.answer(key)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                let now = lock.withLock { () -> Bool in
                    if generation != seen || ended != nil || Task.isCancelled { return true }
                    waiters[key] = resume
                    return false
                }
                if now { resume.resume() }
            }
        } onCancel: { [weak self] in self?.answer(key) }
    }

    private func answer(_ key: UUID) {
        lock.withLock { waiters.removeValue(forKey: key) }?.resume()
    }
}

/// The displays being captured, one stream each.
actor NativeMacScreenCaptures {
    static let shared = NativeMacScreenCaptures()
    private var captures: [CGDirectDisplayID: NativeMacScreenCapture] = [:]

    func open(_ display: CGDirectDisplayID) async throws -> NativeMacScreenCapture {
        if let capture = captures[display], capture.latest(after: -1).ended == nil { capture.users += 1; return capture }
        let capture = NativeMacScreenCapture(display: display)
        try await capture.start()
        capture.users = 1
        captures[display] = capture
        return capture
    }

    func release(_ capture: NativeMacScreenCapture) {
        capture.users -= 1
        guard capture.users <= 0 else { return }
        if captures[capture.display] === capture { captures[capture.display] = nil }
        capture.stop()
    }

    func stopAll() {
        for capture in captures.values { capture.stop() }
        captures.removeAll()
    }
}

/// One phone viewer's pictures from a shared display capture.
final class NativeMacScreenStream: BackendPhoneDeviceStream, @unchecked Sendable {
    private let capture: NativeMacScreenCapture
    private let lock = NSLock()
    private var seen = 0
    private var stopped = false

    init(capture: NativeMacScreenCapture) { self.capture = capture }

    func next(maxWidth: Int, quality: Int, maxBytes: Int) async -> BackendPhoneDeviceFrame? {
        while !Task.isCancelled, !lock.withLock({ stopped }) {
            let now = capture.latest(after: lock.withLock { seen })
            if now.ended != nil { return nil }
            if let pixels = now.pixels, let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() {
                lock.withLock { seen = now.generation }
                // The buffer is held until the picture is encoded, so its surface cannot be reused under us.
                let frame = withExtendedLifetime(pixels) {
                    NativePhoneDeviceScreens.encode(DirectSurfaceBox(surface: surface), maxWidth: maxWidth, quality: quality, maxBytes: maxBytes)
                }
                if let frame { return frame }
            }
            await capture.wait(after: lock.withLock { seen })
        }
        return nil
    }

    func endReason() async -> String { capture.latest(after: -1).ended ?? "The Mac stopped sharing its screen." }

    func stop() async {
        guard lock.withLock({ () -> Bool in defer { stopped = true }; return !stopped }) else { return }
        await NativeMacScreenCaptures.shared.release(capture)
    }
}

// MARK: - What the Mac shows

/// The Mac's own sign while a phone sees it: a small card at the top right of the main screen naming who watches or
/// controls, with Stop; or, when a phone asked and a permission is missing, the same words the phone was given and a
/// button for each Settings page. It appears only because of a phone, never on its own.
@MainActor @Observable final class NativeMacScreenIndicator {
    static let shared = NativeMacScreenIndicator()
    private(set) var viewers: [BackendPhoneMacViewer] = []
    private(set) var missingRecord = false
    private(set) var missingControl = false
    /// Goes up at each remote click or key; the card's mark blinks.
    private(set) var flashes = 0
    var stop: (() -> Void)?
    @ObservationIgnored private var panel: NSPanel?
    /// Keeps the display awake only while a phone watches (learning 12): released when the last one leaves. Never
    /// `pmset`, never a global setting; a closed lid on battery still sleeps.
    @ObservationIgnored private var awake: IOPMAssertionID = 0

    func update(_ viewers: [BackendPhoneMacViewer]) {
        let before = self.viewers
        self.viewers = viewers
        if before.isEmpty, !viewers.isEmpty { NativeCompositionRoot.note("mac screen: \(viewers.map(\.phone).joined(separator: ", ")) started watching") }
        if !before.contains(where: \.controlling), viewers.contains(where: \.controlling) { NativeCompositionRoot.note("mac screen: \(viewers.first { $0.controlling }?.phone ?? "a phone") is controlling") }
        if !before.isEmpty, viewers.isEmpty { NativeCompositionRoot.note("mac screen: no phone is watching any more") }
        keepAwake(!viewers.isEmpty)
        refresh()
    }

    func flash() { flashes += 1 }

    /// A phone asked for something a missing permission blocks.
    func needsPermission(record: Bool, control: Bool) {
        missingRecord = !record
        missingControl = !control
        NativeCompositionRoot.note("mac screen: a phone asked, but \(NativeMacScreen.missingLine(record: record, control: control))")
        refresh()
    }

    /// The person pressed Turn on: macOS's own question (shown once per app), then its Settings page (learning 7:
    /// preflight → prompt → deep link → recheck). Only ever from this button, never by itself.
    func turnOn(recording: Bool) {
        if recording {
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(NativeMacScreen.recordingSettings) }
        } else {
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(prompt) { NSWorkspace.shared.open(NativeMacScreen.accessibilitySettings) }
        }
    }

    /// Recheck: what is granted now. Both granted: the card says so and goes away by itself.
    func recheck() {
        missingRecord = !NativeMacScreen.canRecord
        missingControl = missingControl && !NativeMacScreen.canControl
        refresh()
    }

    func dismissPermission() {
        missingRecord = false; missingControl = false
        refresh()
    }

    private func keepAwake(_ on: Bool) {
        if on, awake == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "A phone is showing this Mac's screen (Terminal Deck)" as CFString, &id) == kIOReturnSuccess { awake = id }
        } else if !on, awake != 0 {
            IOPMAssertionRelease(awake); awake = 0
        }
    }

    private var showing: Bool { !viewers.isEmpty || missingRecord || missingControl }

    private func refresh() {
        guard showing else { panel?.orderOut(nil); return }
        let panel = self.panel ?? make()
        self.panel = panel
        let size = panel.contentView?.fittingSize ?? CGSize(width: 340, height: 80)
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrame(CGRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 80), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: NativeMacScreenCard(indicator: self))
        return panel
    }
}

struct NativeMacScreenCard: View {
    let indicator: NativeMacScreenIndicator
    @State private var blink = false

    private var controlling: Bool { indicator.viewers.contains(where: \.controlling) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !indicator.viewers.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: controlling ? "hand.tap.fill" : "eye.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(controlling ? Color.orange : Color.accentColor))
                        .scaleEffect(blink ? 1.25 : 1)
                        .animation(.spring(response: 0.18, dampingFraction: 0.5), value: blink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(indicator.viewers.map(\.display).uniqued().joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Stop") { indicator.stop?() }
                        .controlSize(.small)
                }
                .onChange(of: indicator.flashes) { _, _ in
                    blink = true
                    Task { try? await Task.sleep(for: .milliseconds(160)); blink = false }
                }
            }
            if indicator.missingRecord || indicator.missingControl {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NativeMacScreen.missingLine(record: !indicator.missingRecord, control: !indicator.missingControl))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if indicator.missingRecord {
                            Button("Turn on Screen Recording") { indicator.turnOn(recording: true) }.controlSize(.small)
                        }
                        if indicator.missingControl {
                            Button("Turn on Accessibility") { indicator.turnOn(recording: false) }.controlSize(.small)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Recheck") { indicator.recheck() }.controlSize(.small)
                        Spacer(minLength: 0)
                        Button("Not now") { indicator.dismissPermission() }.controlSize(.small).buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    /// "Controlled from Asad's iPhone" / "Watched from Asad's iPhone" (learning 8).
    private var title: String {
        let phones = indicator.viewers.map(\.phone).uniqued()
        let who = phones.count == 1 ? phones[0] : "\(phones.count) phones"
        return controlling ? "Controlled from \(who)" : "Watched from \(who)"
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
