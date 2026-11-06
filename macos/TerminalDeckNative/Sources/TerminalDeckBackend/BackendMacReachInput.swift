import AppKit
import ApplicationServices
import Foundation
import TerminalDeckNativeCore

public enum BackendMacReachInput {
    private static let clickLock = NSLock()
    nonisolated(unsafe) private static var lastClick: (at: CGPoint, time: Date, count: Int64)?

    public static func point(_ x: Double, _ y: Double, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width, y: bounds.minY + min(max(y, 0), 1) * bounds.height)
    }

    /// Accessibility granted (asked of macOS at most once a second: the trackpad posts up to 120 moves a second).
    private static let trustLock = NSLock()
    nonisolated(unsafe) private static var trust: (at: Date, granted: Bool) = (.distantPast, false)
    public static func trusted() -> Bool {
        if let cached = trustLock.withLock({ Date().timeIntervalSince(trust.at) < 1 ? trust.granted : nil }) { return cached }
        let granted = AXIsProcessTrusted()
        trustLock.withLock { trust = (Date(), granted) }
        return granted
    }

    /// Async (Reviewer, 31 Oct): a drag's steps wait with `Task.sleep`, never a `usleep` that would hold a thread of the
    /// shared cooperative pool for the whole drag. Everything but a drag-swipe is posted at once (`postNow`).
    public static func post(_ input: BackendPhoneDeviceInput, bounds: CGRect) async {
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
    public static func postNow(_ input: BackendPhoneDeviceInput, bounds: CGRect) {
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
    public static func pointer(in bounds: CGRect, dx: Double = 0, dy: Double = 0) -> CGPoint {
        let at = pointerModel.current(real: CGEvent(source: nil)?.location, bounds: bounds, now: now())
        return clamp(CGPoint(x: at.x + dx * bounds.width, y: at.y + dy * bounds.height), to: bounds)
    }

    /// Where the phone's moves last put the pointer (item 60; MacPointerModel). One for the Mac: the pointer is one.
    public static let pointerModel = MacPointerModel()
    public static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    public static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
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


extension BackendMacReachInput {
    /// Only the ordinary sims input vocabulary crosses XPC. The payload is transient; callers never log it.
    public static func wire(_ input: BackendPhoneDeviceInput, display: String) -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(display))]
        func add(_ key: String, _ value: NativeRPCValue) { fields.append(.init(key, value)) }
        func at(_ x: Double, _ y: Double) { add("x", .number(x)); add("y", .number(y)) }
        switch input {
        case let .tap(x, y, hold): add("do", .string("tap")); at(x, y); if let hold { add("hold", .number(hold)) }
        case let .secondaryTap(x, y): add("do", .string("tap")); at(x, y); add("right", .bool(true))
        case let .swipe(x, y, x2, y2, ms): add("do", .string("swipe")); at(x, y); add("x2", .number(x2)); add("y2", .number(y2)); add("ms", .number(ms))
        case let .scroll(x, y, dx, dy): add("do", .string("scroll")); at(x, y); add("dx", .number(dx)); add("dy", .number(dy))
        case .type(let text): add("do", .string("type")); add("text", .string(text))
        case .key(let key): add("do", .string("key")); add("key", .string(key))
        case let .shortcut(key, modifiers): add("do", .string("key")); add("key", .string(key)); add("mods", .array(modifiers.map(NativeRPCValue.string)))
        case let .mouse(phase, button, x, y, clicks):
            add("do", .string("mouse")); at(x, y); add("phase", .string(phase)); add("button", .string(button)); add("clicks", .number(Double(clicks)))
        case let .keyCode(code, down, modifiers):
            add("do", .string("keycode")); add("code", .number(Double(code))); add("down", .bool(down)); add("mods", .array(modifiers.map(NativeRPCValue.string)))
        case let .pointer(dx, dy, held): add("do", .string("pointer")); add("dx", .number(dx)); add("dy", .number(dy)); add("held", .bool(held))
        case let .pointerTo(x, y, held): add("do", .string("pointer")); at(x, y); add("held", .bool(held))
        case let .click(button, phase): add("do", .string("click")); add("button", .string(button)); if let phase { add("phase", .string(phase)) }
        case let .wheel(dx, dy): add("do", .string("wheel")); add("dx", .number(dx)); add("dy", .number(dy))
        case .button(let button): add("do", .string("button")); add("button", .string(button))
        case .rotate: add("do", .string("rotate"))
        }
        return .object(fields)
    }
    public static func decode(_ value: NativeRPCValue) throws -> BackendPhoneDeviceInput {
        try BackendPhoneDevices.input(BackendRemoteClientMessage(value), mac: true)
    }
}
