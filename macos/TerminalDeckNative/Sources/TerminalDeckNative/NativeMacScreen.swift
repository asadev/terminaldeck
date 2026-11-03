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
    }

    /// Round 3 (1 Nov, Asad: "the cursor starts the instant the finger starts… lagging on the PC side also"): one input
    /// posted now, on the caller's thread (the phone's input lane), never through the main thread; a click lets the
    /// keyboard follow the field it landed in. Answers a refusal in words, or nil.
    nonisolated static func postNow(_ id: String, _ input: BackendPhoneDeviceInput) -> String? {
        guard id.hasPrefix("mac:"), let number = UInt32(id.dropFirst(4)) else { return "That is not one of this Mac's displays." }
        guard NativeMacScreenInput.trusted() else {
            let record = canRecord
            Task { @MainActor in NativeMacScreenIndicator.shared.needsPermission(record: record, control: false) }
            return controlLine
        }
        NativeMacScreenInput.postNow(input, bounds: CGDisplayBounds(CGDirectDisplayID(number)))
        switch input {
        case let .click(button, phase) where button == "left" && phase != "down": NativeMacScreenFocus.recheck()
        case .tap: NativeMacScreenFocus.recheck()
        default: break
        }
        return nil
    }
}

/// Posting the phone's input as CoreGraphics events, in global display points (top-left origin).
enum NativeMacScreenInput {
    private static let clickLock = NSLock()
    nonisolated(unsafe) private static var lastClick: (at: CGPoint, time: Date, count: Int64)?

    static func point(_ x: Double, _ y: Double, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width, y: bounds.minY + min(max(y, 0), 1) * bounds.height)
    }

    /// Accessibility granted (asked of macOS at most once a second: the trackpad posts up to 120 moves a second).
    private static let trustLock = NSLock()
    nonisolated(unsafe) private static var trust: (at: Date, granted: Bool) = (.distantPast, false)
    static func trusted() -> Bool {
        if let cached = trustLock.withLock({ Date().timeIntervalSince(trust.at) < 1 ? trust.granted : nil }) { return cached }
        let granted = AXIsProcessTrusted()
        trustLock.withLock { trust = (Date(), granted) }
        return granted
    }

    /// Async (Reviewer, 31 Oct): a drag's steps wait with `Task.sleep`, never a `usleep` that would hold a thread of the
    /// shared cooperative pool for the whole drag. Everything but a drag-swipe is posted at once (`postNow`).
    static func post(_ input: BackendPhoneDeviceInput, bounds: CGRect) async {
        let source = CGEventSource(stateID: .hidSystemState)
        func mouse(_ type: CGEventType, _ at: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: at, mouseButton: button) else { return }
            event.setIntegerValueField(.mouseEventClickState, value: clicks)
            event.post(tap: .cghidEventTap)
        }
        guard case let .swipe(fromX, fromY, toX, toY, ms) = input else { postNow(input, bounds: bounds); return }
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
    }

    /// One input as events, now, on the caller's thread (round 3: the phone's input lane). A drag-swipe goes through
    /// `post` (it takes its time).
    static func postNow(_ input: BackendPhoneDeviceInput, bounds: CGRect) {
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
        case let .swipe(fromX, fromY, toX, toY, _):
            // Only through `post`; here (never expected) at once, without the steps.
            let from = point(fromX, fromY, in: bounds), to = point(toX, toY, in: bounds)
            mouse(.mouseMoved, from); mouse(.leftMouseDown, from); mouse(.leftMouseDragged, to); mouse(.leftMouseUp, to)
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
        case let .pointer(dx, dy, held):
            // The trackpad (older phones): from where this Mac last put the pointer while that is fresh, else where it
            // is (item 60: the system's reading lags a posted move by a few ms; read back, moves were lost).
            mouse(held ? .leftMouseDragged : .mouseMoved, pointerModel.move(dx: dx, dy: dy, real: CGEvent(source: nil)?.location, bounds: bounds, now: now()))
        case let .pointerTo(x, y, held):
            // Item 60: exactly where the phone draws it.
            mouse(held ? .leftMouseDragged : .mouseMoved, pointerModel.moveTo(x: x, y: y, bounds: bounds, now: now()))
        case let .click(button, phase):
            let at = pointer(in: bounds)
            let which: CGMouseButton = button == "right" ? .right : button == "middle" ? .center : .left
            switch phase {
            case "down": mouse(which == .left ? .leftMouseDown : which == .right ? .rightMouseDown : .otherMouseDown, at, which, clicks: 1)
            case "up": mouse(which == .left ? .leftMouseUp : which == .right ? .rightMouseUp : .otherMouseUp, at, which, clicks: 1)
            default:
                if which == .center {
                    mouse(.otherMouseDown, at, .center); mouse(.otherMouseUp, at, .center)
                } else {
                    click(at, button: which, mouse: mouse)
                }
            }
        case let .wheel(dx, dy):
            // Where the pointer is; a finger moving the content down scrolls up, as on a trackpad.
            let wheelY = Int32((dy * bounds.height).rounded()), wheelX = Int32((dx * bounds.width).rounded())
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wheelY, wheel2: wheelX, wheel3: 0)?
                .post(tap: .cghidEventTap)
        case .button, .rotate:
            break
        }
    }

    /// Where this Mac's pointer is (on this display; its middle when it is on another), moved by a share of the display
    /// and kept inside it.
    static func pointer(in bounds: CGRect, dx: Double = 0, dy: Double = 0) -> CGPoint {
        let at = pointerModel.current(real: CGEvent(source: nil)?.location, bounds: bounds, now: now())
        return clamp(CGPoint(x: at.x + dx * bounds.width, y: at.y + dy * bounds.height), to: bounds)
    }

    /// Where the phone's moves last put the pointer (item 60; MacPointerModel). One for the Mac: the pointer is one.
    static let pointerModel = MacPointerModel()
    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1), y: min(max(point.y, bounds.minY), bounds.maxY - 1))
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
    /// Round 3: the viewers that draw the pointer themselves; while every viewer does, the pictures leave it out (a
    /// phone moves its own pointer at once instead of waiting for a picture of it).
    private var hiders = 0
    private var configuration: SCStreamConfiguration?

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
        // At most 60 a second (1 Nov: a change waits at most 17 ms to be captured; the phone still gets only what its
        // link carries), in 4:2:0 (learning 4: half the memory of BGRA per picture).
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 4
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: SCContentFilter(display: screen, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream; self.configuration = configuration }
    }

    /// One more (+1) or one fewer (-1) viewer draws the pointer itself (0: the number of viewers changed); the pictures
    /// show the pointer unless every viewer draws it.
    func pointer(hiddenBy change: Int) {
        let update = lock.withLock { () -> (SCStream, SCStreamConfiguration)? in
            hiders = max(0, hiders + change)
            let shows = hiders < max(1, users)
            guard let stream, let configuration, configuration.showsCursor != shows else { return nil }
            configuration.showsCursor = shows
            return (stream, configuration)
        }
        if let (stream, configuration) = update { stream.updateConfiguration(configuration) { _ in } }
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
        if let capture = captures[display], capture.latest(after: -1).ended == nil { capture.users += 1; capture.pointer(hiddenBy: 0); return capture }
        let capture = NativeMacScreenCapture(display: display)
        try await capture.start()
        capture.users = 1
        captures[display] = capture
        return capture
    }

    func release(_ capture: NativeMacScreenCapture) {
        capture.users -= 1
        guard capture.users <= 0 else { capture.pointer(hiddenBy: 0); return }
        if captures[capture.display] === capture { captures[capture.display] = nil }
        capture.stop()
    }

    func stopAll() {
        for capture in captures.values { capture.stop() }
        captures.removeAll()
    }
}

/// One phone viewer's video source from a shared display capture.
final class NativeMacScreenStream: BackendPhoneDeviceStream, @unchecked Sendable {
    private let capture: NativeMacScreenCapture
    private let lock = NSLock()
    private var seen = 0
    private var stopped = false
    private var hiding = false

    init(capture: NativeMacScreenCapture) { self.capture = capture }

    /// Round 3: this viewer draws the pointer itself.
    func drawsPointer(_ phone: Bool) async {
        let change = lock.withLock { () -> Bool in
            guard !stopped, hiding != phone else { return false }
            hiding = phone
            return true
        }
        if change { capture.pointer(hiddenBy: phone ? 1 : -1) }
    }

    /// Item 61: the newest capture as it is (4:2:0, the display's pixels up to 2560) for the hardware video encoder.
    func pixels(within seconds: Double) async -> BackendPhoneDevicePixelsAnswer {
        let deadline = Date().addingTimeInterval(seconds)
        while !Task.isCancelled, !lock.withLock({ stopped }) {
            let now = capture.latest(after: lock.withLock { seen })
            if now.ended != nil { return .ended }
            if let pixels = now.pixels {
                lock.withLock { seen = now.generation }
                return .pixels(BackendPhoneDevicePixels(pixels, capturedAt: Date().timeIntervalSince1970 * 1_000))
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return .unchanged }
            await capture.wait(after: lock.withLock { seen }, seconds: left)
        }
        return .ended
    }

    func endReason() async -> String { capture.latest(after: -1).ended ?? "The Mac stopped sharing its screen." }

    func stop() async {
        let (first, hid) = lock.withLock { () -> (Bool, Bool) in defer { stopped = true; hiding = false }; return (!stopped, hiding) }
        guard first else { return }
        if hid { capture.pointer(hiddenBy: -1) }
        await NativeMacScreenCaptures.shared.release(capture)
    }
}

// MARK: - What the Mac does while a phone sees it

/// While a phone sees this Mac (round 3, Asad 1 Nov: no "Controlled from iPhone" card — "I don't want it at all
/// completely"): nothing is shown on the Mac. The display stays awake and the keyboard focus is followed only while a
/// phone watches; who watches is in the log and in `mac_screen.status`; whether phones may at all is the switch in
/// Settings → Devices (`NativeMacScreenSetting`). A missing permission is said to the phone in words, and logged here.
@MainActor final class NativeMacScreenIndicator {
    static let shared = NativeMacScreenIndicator()
    private(set) var viewers: [BackendPhoneMacViewer] = []
    /// Keeps the display awake only while a phone watches (learning 12): released when the last one leaves. Never
    /// `pmset`, never a global setting; a closed lid on battery still sleeps.
    private var awake: IOPMAssertionID = 0

    func update(_ viewers: [BackendPhoneMacViewer]) {
        let before = self.viewers
        self.viewers = viewers
        if before.isEmpty, !viewers.isEmpty { NativeCompositionRoot.note("mac screen: \(viewers.map(\.phone).joined(separator: ", ")) started watching") }
        if !before.contains(where: \.controlling), viewers.contains(where: \.controlling) { NativeCompositionRoot.note("mac screen: \(viewers.first { $0.controlling }?.phone ?? "a phone") is controlling") }
        if !before.isEmpty, viewers.isEmpty { NativeCompositionRoot.note("mac screen: no phone is watching any more") }
        keepAwake(!viewers.isEmpty)
        NativeMacScreenFocus.shared.watch(!viewers.isEmpty)
    }

    /// A phone asked for something a missing permission blocks: the phone was told in words; noted here once.
    func needsPermission(record: Bool, control: Bool) {
        NativeCompositionRoot.note("mac screen: a phone asked, but \(NativeMacScreen.missingLine(record: record, control: control))")
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
}

// MARK: - The pointer for a phone that draws it itself (round 3)

/// Where this Mac's pointer is on a display, and its shape, for `sims.pointer`. Read from any thread (the pointer
/// reporter); the shape (`NSCursor.currentSystem`, AppKit) is looked at on the main thread, at most ten times a second
/// and only while the pointer moves.
enum NativeMacScreenPointer {
    private struct Shape { var token = 0; var key = 0; var png = Data(); var hot = CGPoint.zero; var points = CGSize.zero }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shape = Shape()
    nonisolated(unsafe) private static var asked = Date.distantPast
    nonisolated(unsafe) private static var lastAt = CGPoint(x: -1, y: -1)

    static func read(_ id: String) -> BackendPhoneDevicePointer? {
        guard id.hasPrefix("mac:"), let number = UInt32(id.dropFirst(4)) else { return nil }
        let bounds = CGDisplayBounds(CGDirectDisplayID(number))
        guard bounds.width > 0, bounds.height > 0, let real = CGEvent(source: nil)?.location else { return nil }
        // Item 60: while the phone's moves are fresh, where this Mac put the pointer (the system's own reading lags a
        // posted move and would pull the phone's drawn pointer back); otherwise where it really is.
        let placed = NativeMacScreenInput.pointerModel.placedIfFresh(bounds: bounds, now: NativeMacScreenInput.now())
        let at = placed ?? real
        let (moved, ask) = lock.withLock { () -> (Bool, Bool) in
            let moved = at != lastAt
            lastAt = at
            let ask = (moved || shape.token == 0) && Date().timeIntervalSince(asked) > 0.1
            if ask { asked = Date() }
            return (moved, ask)
        }
        _ = moved
        if ask { DispatchQueue.main.async { MainActor.assumeIsolated { refreshShape() } } }
        let current = lock.withLock { shape }
        let picture: BackendPhoneDevicePointer.Shape? = current.token == 0 ? nil : .init(
            token: current.token, png: current.png,
            hotX: current.points.width > 0 ? Double(current.hot.x / current.points.width) : 0,
            hotY: current.points.height > 0 ? Double(current.hot.y / current.points.height) : 0,
            width: Double(current.points.width / bounds.width), height: Double(current.points.height / bounds.height))
        let on = placed != nil || bounds.insetBy(dx: -0.5, dy: -0.5).contains(real)
        return .init(x: Double((at.x - bounds.minX) / bounds.width), y: Double((at.y - bounds.minY) / bounds.height), onDisplay: on, shape: picture,
                     displayWidth: Double(bounds.width))
    }

    @MainActor private static func refreshShape() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard image.size.width > 0, image.size.height > 0, let tiff = image.tiffRepresentation else { return }
        let key = tiff.hashValue ^ Int(cursor.hotSpot.x * 1_000) ^ (Int(cursor.hotSpot.y * 1_000) << 16)
        guard key != lock.withLock({ shape.key }) else { return }
        // At twice its size in points (the phone draws it at the picture's scale).
        let width = Int(image.size.width * 2), height = Int(image.size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        lock.withLock {
            shape = Shape(token: shape.token + 1, key: key, png: png, hot: cursor.hotSpot, points: image.size)
        }
    }
}


/// Which element on this Mac has the keyboard focus, while a phone watches (1 Nov, trackpad model; Asad: "keyboard will
/// come wherever we click"): a text field taking the focus brings the phone's keyboard up. Accessibility's own focus
/// notification for the app in front (followed when another app comes forward); nothing polls, and nothing is
/// observed while no phone watches. Needs Accessibility (the same permission clicking needs).
///
/// Round 3 (#22, #23): every Accessibility question is asked OFF the main thread with a short timeout. Asked on the main
/// thread, a question to Terminal Deck itself (in front, as in Asad's screenshot) waits for the main thread that is
/// asking it: the app froze for seconds ("lagging on the PC side also") and the phone's input behind it timed out
/// ("Sending to the device did not answer in time"). And after every click from the phone the focus is looked at again
/// and a text field is reported even when it is the same one, so the keyboard comes back every time.
@MainActor final class NativeMacScreenFocus {
    static let shared = NativeMacScreenFocus()
    /// Told when the focus moves into (true) or out of (false) a place that takes text, or again after a phone's click.
    var changed: ((Bool) -> Void)?
    private var observer: AXObserver?
    private var activation: NSObjectProtocol?
    private var text: Bool?
    private var watching = false
    nonisolated static let queue = DispatchQueue(label: "dev.terminaldeck.mac-focus", qos: .userInitiated)

    nonisolated static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    func watch(_ on: Bool) {
        if on, activation == nil {
            guard AXIsProcessTrusted() else { return }
            watching = true
            activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated { if let pid { NativeMacScreenFocus.shared.follow(pid) } }
            }
            // What has the focus when a phone starts watching is not news: only a change from here on is said.
            quiet = true
            if let app = NSWorkspace.shared.frontmostApplication { follow(app.processIdentifier) }
        } else if !on, let activation {
            watching = false
            NSWorkspace.shared.notificationCenter.removeObserver(activation)
            self.activation = nil
            detach()
            text = nil
        }
    }

    private func detach() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
    }

    private func follow(_ pid: pid_t) {
        detach()
        // Terminal Deck itself in front: registered here, on the main thread (AppKit answers it in this process and
        // touches our own views, which are main-thread only — 1 Nov hotfix, the install #18 crash).
        if MacFocusProbe.mustAskOnMain(focusedPID: pid, ownPID: getpid()) {
            var made: AXObserver?
            let callback: AXObserverCallback = { _, _, _, _ in
                Task { @MainActor in NativeMacScreenFocus.shared.evaluate() }
            }
            guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
            AXObserverAddNotification(made, AXUIElementCreateApplication(pid), kAXFocusedUIElementChangedNotification as CFString, nil)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
            observer = made
            evaluate()
            return
        }
        // Another app: made and registered off the main thread (it may be slow to answer).
        Self.queue.async {
            var made: AXObserver?
            let callback: AXObserverCallback = { _, _, _, _ in
                Task { @MainActor in NativeMacScreenFocus.shared.evaluate() }
            }
            guard AXObserverCreate(pid, callback, &made) == .success, let made else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            AXObserverAddNotification(made, app, kAXFocusedUIElementChangedNotification as CFString, nil)
            let box = ObserverBox(made)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let focus = NativeMacScreenFocus.shared
                    guard focus.watching else { return }
                    focus.detach()
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(box.observer), .defaultMode)
                    focus.observer = box.observer
                    focus.evaluate()
                }
            }
        }
    }

    /// Reads the focused element (off the main thread) and says so when it changed between "takes text" and not; with
    /// `again`, a text field is said even when it already had the focus (a phone just clicked into it).
    func evaluate(again: Bool = false) {
        // Which app is in front is read HERE, from AppKit, never from Accessibility's system-wide element: asked for the
        // focused application, the system-wide element is answered by the app in front — when that is Terminal Deck,
        // by AppKit in this very process, walking our own views on the asking thread (the 11:18 crash, after #18a).
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if MacFocusProbe.mustAskOnMain(focusedPID: front, ownPID: getpid()) {
            // Terminal Deck itself (or unknown): on the main thread, where AppKit answers in-process at once.
            report(Self.focusTakesText(of: AXUIElementCreateApplication(getpid())), again: again)
            return
        }
        // Another app: asked by its own pid, off the main thread (it may be slow to answer).
        Self.queue.async {
            let takesText = Self.otherAppFocusTakesText(pid: front)
            DispatchQueue.main.async { MainActor.assumeIsolated { NativeMacScreenFocus.shared.report(takesText, again: again) } }
        }
    }

    /// A phone clicked: the focus is looked at again shortly after (the click has to land first), twice.
    nonisolated static func recheck() {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard NativeMacScreenFocus.shared.watching else { return }
                    NativeMacScreenFocus.shared.evaluate(again: true)
                }
            }
        }
    }

    /// The focus in ANOTHER app, asked by its pid (off the main thread, short timeouts). Never this process: its own
    /// elements are only ever asked on the main thread, and nothing here touches the system-wide element.
    nonisolated static func otherAppFocusTakesText(pid: pid_t) -> Bool {
        guard !MacFocusProbe.mustAskOnMain(focusedPID: pid, ownPID: getpid()) else { return false }
        return focusTakesText(of: AXUIElementCreateApplication(pid))
    }

    /// Whether the focused element of `app` takes text. For this process, only ever called on the main thread.
    nonisolated static func focusTakesText(of app: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        let roleName = role as? String ?? ""
        // A text role (a terminal's text view is an AXTextArea; web text boxes report AXTextField/AXTextArea too).
        return textRoles.contains(roleName) || (subrole as? String) == "AXSecureTextField"
    }

    private var quiet = false

    private func report(_ value: Bool, again: Bool = false) {
        if quiet, !again { quiet = false; text = value; return }
        quiet = false
        if again, value { text = value; changed?(true); return }
        guard value != text else { return }
        text = value
        changed?(value)
    }
}

/// An AXObserver handed from the Accessibility queue to the main thread.
private final class ObserverBox: @unchecked Sendable {
    let observer: AXObserver
    init(_ observer: AXObserver) { self.observer = observer }
}
