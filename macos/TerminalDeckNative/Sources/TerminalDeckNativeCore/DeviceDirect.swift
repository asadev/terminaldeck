import Foundation

// Finding 3 (Asad, 22 Oct 2026: "simulators are not running fast inside ... i cant type inside, and
// android is slow too"; Option B: read the screen directly and send touches and keys directly).
// The pure parts of the direct device path, shared by the iOS helper and the Android emulator:
// which keys a piece of typing is, how a tap or a swipe becomes finger steps, and the helper's
// one-line commands. No I/O here, so every rule is tested on its own.

/// One key press on the device's hardware keyboard: HID usage (keyboard page), with modifiers held.
public struct DeviceDirectKeyStroke: Equatable, Sendable {
    public var usage: UInt16
    public var modifiers: [UInt16]
    public init(_ usage: UInt16, modifiers: [UInt16] = []) {
        self.usage = usage
        self.modifiers = modifiers
    }
}

public enum DeviceDirectKeys {
    public static let leftShift: UInt16 = 225
    public static let leftCommand: UInt16 = 227

    /// The keys that type `text` on a US keyboard, or nil when any character has no key (an emoji,
    /// Urdu, an accent): such typing goes through the simulator's pasteboard instead, which takes any text.
    public static func strokes(_ text: String) -> [DeviceDirectKeyStroke]? {
        var out: [DeviceDirectKeyStroke] = []
        for scalar in text.unicodeScalars {
            guard let stroke = stroke(scalar) else { return nil }
            out.append(stroke)
        }
        return out
    }

    /// A named key from the panel's keyboard ("return", "delete", "arrow-up", "select-all", …).
    public static func named(_ name: String) -> [DeviceDirectKeyStroke]? {
        switch name {
        case "return", "enter": [.init(40)]
        case "escape": [.init(41)]
        case "delete", "backspace": [.init(42)]
        case "tab": [.init(43)]
        case "space": [.init(44)]
        case "forward-delete": [.init(76)]
        case "arrow-right": [.init(79)]
        case "arrow-left": [.init(80)]
        case "arrow-down": [.init(81)]
        case "arrow-up": [.init(82)]
        case "home": [.init(74)]
        case "end": [.init(77)]
        case "page-up": [.init(75)]
        case "page-down": [.init(78)]
        case "select-all": [.init(4, modifiers: [leftCommand])]
        // ⌘V: what the device engine presses after putting text on the simulator's pasteboard (long or non-US typing).
        case "paste": [.init(25, modifiers: [leftCommand])]
        default: nil
        }
    }

    /// The modifiers a device tool may hold around a key (devices.type `modifiers`), as HID usages.
    public static func modifier(_ name: String) -> UInt16? {
        switch name {
        case "control": 224
        case "shift": leftShift
        case "option": 226
        case "command": leftCommand
        default: nil
        }
    }

    /// A named key with the tool's modifiers held around it (each once), or nil when the key or a modifier
    /// has no key here.
    public static func named(_ name: String, modifiers: [String]) -> [DeviceDirectKeyStroke]? {
        guard let strokes = named(name) else { return nil }
        var held: [UInt16] = []
        for name in modifiers {
            guard let usage = modifier(name) else { return nil }
            if !held.contains(usage) { held.append(usage) }
        }
        return strokes.map { .init($0.usage, modifiers: held + $0.modifiers.filter { !held.contains($0) }) }
    }

    private static let unshifted: [Character: UInt16] = [
        "1": 30, "2": 31, "3": 32, "4": 33, "5": 34, "6": 35, "7": 36, "8": 37, "9": 38, "0": 39,
        "\n": 40, "\r": 40, "\t": 43, " ": 44, "-": 45, "=": 46, "[": 47, "]": 48, "\\": 49,
        ";": 51, "'": 52, "`": 53, ",": 54, ".": 55, "/": 56,
    ]
    private static let shifted: [Character: UInt16] = [
        "!": 30, "@": 31, "#": 32, "$": 33, "%": 34, "^": 35, "&": 36, "*": 37, "(": 38, ")": 39,
        "_": 45, "+": 46, "{": 47, "}": 48, "|": 49, ":": 51, "\"": 52, "~": 53, "<": 54, ">": 55, "?": 56,
    ]

    private static func stroke(_ scalar: Unicode.Scalar) -> DeviceDirectKeyStroke? {
        let value = scalar.value
        if (0x61...0x7A).contains(value) { return .init(UInt16(4 + value - 0x61)) }
        if (0x41...0x5A).contains(value) { return .init(UInt16(4 + value - 0x41), modifiers: [leftShift]) }
        let character = Character(scalar)
        if let usage = unshifted[character] { return .init(usage) }
        if let usage = shifted[character] { return .init(usage, modifiers: [leftShift]) }
        return nil
    }
}

/// One step of a finger on the screen: where (0…1 from the top left), when, and whether it lifts.
public struct DeviceDirectTouchStep: Equatable, Sendable {
    public var atMs: Double
    public var x: Double
    public var y: Double
    public var up: Bool
}

/// Taps and swipes as finger steps, for a device driven finger by finger. A finger that is down and
/// moves is sent as "down here now"; about sixty steps a second, as a real drag.
public enum DeviceDirectGesture {
    public static let stepMs = 16.0

    public static func tap(x: Double, y: Double, holdMs: Double?) -> [DeviceDirectTouchStep] {
        let hold = max(holdMs ?? 70, 40)
        return [.init(atMs: 0, x: x, y: y, up: false), .init(atMs: hold, x: x, y: y, up: true)]
    }

    public static func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, ms: Double) -> [DeviceDirectTouchStep] {
        let duration = min(max(ms, 60), 3_000)
        let count = max(6, Int((duration / stepMs).rounded()))
        var steps: [DeviceDirectTouchStep] = []
        for index in 0...count {
            let fraction = Double(index) / Double(count)
            let last = index == count   // exactly where it was asked to end, whatever the rounding
            steps.append(.init(atMs: duration * fraction, x: last ? toX : fromX + (toX - fromX) * fraction,
                               y: last ? toY : fromY + (toY - fromY) * fraction, up: false))
        }
        steps.append(.init(atMs: duration + stepMs, x: toX, y: toY, up: true))
        return steps
    }

    /// The second finger of a pinch made with the mouse: mirrored through the screen's middle.
    public static func mirrored(x: Double, y: Double) -> (x: Double, y: Double) { (1 - x, 1 - y) }
}

/// The iOS helper's commands (`TerminalDeckNativeHelper --sim-direct`, TDSimDirect.h): one line each.
public enum SimDirectLine {
    /// `appFrame`: the points are in the frame of the app on screen, as devices.tree gives them (AI device tools);
    /// the helper turns them onto the upright touchscreen by how the app is turned, read at the gesture's first
    /// finger (t/u). Otherwise they are on the upright screen the panel shows (T/U). Review 22 Oct 2026: on a turned
    /// app, AI taps from the tree landed elsewhere (the engine's way too).
    public static func touch(down: Bool, _ points: [(x: Double, y: Double)], appFrame: Bool = false) -> String? {
        guard points.count == 1 || points.count == 2 else { return nil }
        let places = points.map { String(format: "%.5f %.5f", clamp($0.x), clamp($0.y)) }.joined(separator: " ")
        let verb = appFrame ? (down ? "t" : "u") : (down ? "T" : "U")
        return "\(verb) \(points.count) \(places)\n"
    }

    /// `G <edge>`: the next gesture begins at an edge of the screen. On CoreDevice's touchscreen an edge swipe must say
    /// so, or it is only a drag on the screen: the swipe up that unlocks and goes home, down for the notifications,
    /// in from the left for Back (Asad, 31 Oct: "swipe up does nothing" on the lock screen, watched from his phone).
    /// Measured 31 Oct 2026 on an iPhone Air, iOS 27: 1 top, 3 bottom, 4 left; 2 (right) by the same order.
    /// A gesture counts as an edge one when it starts within `band` of an edge and (when its end is known) goes inward.
    public static func edge(fromX: Double, fromY: Double, toX: Double? = nil, toY: Double? = nil, band: Double = 0.03) -> String? {
        let edge: Int
        if fromY >= 1 - band, toY.map({ $0 < fromY }) ?? true { edge = 3 }
        else if fromY <= band, toY.map({ $0 > fromY }) ?? true { edge = 1 }
        else if fromX <= band, toX.map({ $0 > fromX }) ?? true { edge = 4 }
        else if fromX >= 1 - band, toX.map({ $0 < fromX }) ?? true { edge = 2 }
        else { return nil }
        return "G \(edge)\n"
    }

    public static func key(_ usage: UInt16, down: Bool) -> String { "K \(usage) \(down ? "d" : "u")\n" }

    /// Every line of a key press: modifiers down, the key down and up, modifiers up.
    public static func press(_ stroke: DeviceDirectKeyStroke) -> String {
        stroke.modifiers.map { key($0, down: true) }.joined()
            + key(stroke.usage, down: true) + key(stroke.usage, down: false)
            + stroke.modifiers.reversed().map { key($0, down: false) }.joined()
    }

    /// The hardware buttons the helper presses: home and lock on the simulator's own (Indigo) touchscreen, the volume
    /// and Action buttons too when the helper has SimulatorKit's arbitrary button message (`side=1`, 28 Oct 2026), and
    /// every iPhone button on Apple's CoreDevice one (`hid=coredevice`: Device Hub or Xcode attached).
    public static let buttons: Set<String> = ["home", "lock"]
    public static let coreDeviceButtons: Set<String> = ["home", "lock", "volume-up", "volume-down", "action"]

    public static func button(_ name: String, down: Bool, coreDevice: Bool = false, side: Bool = false) -> String? {
        (coreDevice || side ? coreDeviceButtons : buttons).contains(name) ? "B \(name) \(down ? "d" : "u")\n" : nil
    }

    /// Typing up to this many characters goes key by key; longer (a paste) goes through the simulator's
    /// pasteboard, which puts it in as one piece.
    public static let longestTyped = 64
    /// On CoreDevice's touchscreen a paste is typed key by key as long as its key lines stay within this many
    /// bytes: one write, well inside the helper's pipe.
    public static let longestCoreDeviceTyping = 8 * 1024

    /// The key lines that type `text` through the helper, or nil when it goes through the pasteboard (a character
    /// with no key, or more than the helper should take at once).
    public static func typing(_ text: String, coreDevice: Bool) -> String? {
        if coreDevice {
            // Every character is at least two 6-byte lines: a text too long for that never gets mapped.
            guard text.unicodeScalars.count <= longestCoreDeviceTyping / 12 else { return nil }
        } else if text.count > longestTyped {
            return nil
        }
        guard let strokes = DeviceDirectKeys.strokes(text) else { return nil }
        let lines = strokes.map(press).joined()
        return !coreDevice || lines.utf8.count <= longestCoreDeviceTyping ? lines : nil
    }

    /// Asks the helper to answer `echo <n>` once it has taken every line written before this one. Long AI typing
    /// writes its next piece only then, so the helper's input pipe never fills (a short write ends the helper).
    public static func echo(_ token: Int) -> String { "E \(token)\n" }
    /// The helper's answer to `echo(_:)`; nil for any other line.
    public static func echoed(_ line: String) -> Int? {
        guard line.hasPrefix("echo ") else { return nil }
        return Int(line.dropFirst(5))
    }

    public static func pause(_ paused: Bool) -> String { "P \(paused ? 1 : 0)\n" }
    public static let quit = "Q\n"
    /// The helper's screen-port argument for input only (AI device tools with no panel showing the
    /// simulator): it then sends no screen and no frame notices.
    public static let inputOnly = "-"

    /// What the helper said it can do: `ready <w> <h> touch=1 keys=1 buttons=1 side=1 core=1 hid=indigo|coredevice`.
    /// Each touchscreen has its own: a simulator's own (Indigo) input can fail the helper's shape check
    /// while CoreDevice's is there, and the other way round. Input goes to the helper only when the
    /// touchscreen in use now takes it, and to the device engine otherwise, never into nothing.
    public struct Ready: Equatable, Sendable {
        public var width: Int
        public var height: Int
        /// What the simulator's own (Indigo) input takes through the helper.
        public var touch: Bool
        public var keys: Bool
        public var buttons: Bool
        /// The volume and Action buttons on the simulator's own touchscreen too.
        public var side: Bool = false
        /// The helper can reach CoreDevice's touchscreen (fingers, keys and every iPhone button).
        public var core: Bool = false
        /// The simulator takes input from CoreDevice's touchscreen now (its `dtuhidd` runs).
        public var coreDevice: Bool = false

        /// What the helper can take now, on the touchscreen the simulator uses.
        public var touchNow: Bool { coreDevice ? core : touch }
        public var keysNow: Bool { coreDevice ? core : keys }
        public var buttonsNow: Bool { coreDevice ? core : buttons }
    }

    public static func ready(_ line: String) -> Ready? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "ready", let width = Int(parts[1]), let height = Int(parts[2]),
              width > 0, height > 0 else { return nil }
        let flags = Set(parts.dropFirst(3).map(String.init))
        return Ready(width: width, height: height, touch: flags.contains("touch=1"), keys: flags.contains("keys=1"),
                     buttons: flags.contains("buttons=1"), side: flags.contains("side=1"), core: flags.contains("core=1"),
                     coreDevice: flags.contains("hid=coredevice"))
    }

    /// `hid coredevice` / `hid indigo`: the simulator's touchscreen changed hands (Device Hub or Xcode
    /// started or ended CoreDevice's `dtuhidd`). Nil for any other line.
    public static func hid(_ line: String) -> Bool? {
        switch line {
        case "hid coredevice": true
        case "hid indigo": false
        default: nil
        }
    }

    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }
}

/// AI sessions' device tools (devices_tap, devices_swipe, devices_type, devices_button) on an iOS Simulator
/// (Asad, 22 Oct 2026: "fix ai taps"). Once something such as Device Hub has started a simulator's CoreDevice
/// touchscreen, it stays in use until the simulator shuts down. Tool input goes the phone panel's way: the direct
/// helper when the touchscreen in use takes it there, the device engine otherwise (typing through the pasteboard),
/// and a refusal the AI can read when neither can deliver it, never nothing.
public enum DeviceToolDirect {
    public enum Answer: Equatable, Sendable {
        /// Delivered the direct way.
        case sent
        /// Hand it to the device engine (typing through the pasteboard; anything else it answers in words).
        case engine
        /// Neither way can deliver it; the words go back to the AI.
        case refused(String)
    }

    /// Input the helper could not take. Typing goes to the device engine on either touchscreen (it pastes the text and
    /// presses ⌘V through the helper); anything else goes to the engine on the simulator's own touchscreen and is refused
    /// in words on CoreDevice's.
    public static func untaken(_ input: DeviceInput, coreDevice: Bool) -> Answer {
        if case .type = input { return .engine }
        guard coreDevice else { return .engine }
        let lead = "This simulator takes input only from Apple's newer CoreDevice touchscreen now (Device Hub or Xcode turned it on; it stays on until the simulator shuts down)"
        switch input {
        case .type:
            return .engine
        case .key(let name):
            return .refused("\(lead), and \(name) with those modifiers has no key there. Nothing was pressed.")
        case .button(let name):
            return .refused("\(lead), and its \(name) button cannot be pressed from here. Nothing was pressed.")
        case .tap, .touch, .swipe:
            return .refused("\(lead), and Terminal Deck could not reach that touchscreen on this Mac. Nothing was touched. Shutting the simulator down and starting it again brings its own touchscreen back.")
        }
    }

    /// Typing on CoreDevice's touchscreen goes as keys, in pieces of this many characters: each piece's key
    /// lines stay inside one helper write (at most four lines of up to 8 bytes a character).
    public static let typingPiece = 200
    /// Each piece waits for the helper's echo (SimDirectLine.echo) before the next is written, at most this many
    /// seconds; a helper that has not taken it by then is not written to again for this text. A fixed pause
    /// (40 ms before 22 Oct) let a slow helper's pipe fill, and the short write ended the helper (review 22 Oct).
    public static let pieceWithin = 10.0

    public static func pieces(_ text: String, size: Int = typingPiece) -> [String] {
        guard size > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        var result: [String] = [], current = ""
        var count = 0
        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            count += 1
            if count == size { result.append(current); current = ""; count = 0 }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// How long input sent the direct way takes on the device, in milliseconds: the tool answers after
    /// it, so a screenshot taken next shows it done.
    public static func duration(_ input: DeviceInput) -> Double {
        let settle = 30.0
        switch input {
        case let .tap(_, _, hold): return (DeviceDirectGesture.tap(x: 0, y: 0, holdMs: hold).last?.atMs ?? 70) + settle
        case let .swipe(fromX, fromY, toX, toY, ms):
            return (DeviceDirectGesture.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms).last?.atMs ?? ms) + settle
        case .button: return 80 + settle
        // Typing answers once the helper has taken its last piece (its echo), then this.
        case .type: return 50
        case .key, .touch: return settle
        }
    }
}

/// Which device ids the direct path is for: an iOS Simulator (`ios:<UDID>`) or an Android emulator
/// (`android:emulator-<port>`). Physical phones and anything unknown use the device engine's picture and input.
public enum DeviceDirectTarget: Equatable, Sendable {
    case iosSimulator(udid: String)
    case androidEmulator(serial: String)

    public init?(id: String, platform: String, kind: String) {
        if platform == "ios", kind != "physical", id.hasPrefix("ios:") {
            let udid = String(id.dropFirst(4))
            guard UUID(uuidString: udid) != nil else { return nil }
            self = .iosSimulator(udid: udid)
        } else if platform == "android", kind != "physical", id.hasPrefix("android:emulator-") {
            let serial = String(id.dropFirst("android:".count))
            guard let port = Int(serial.dropFirst("emulator-".count)), port > 0, port < 65_536 else { return nil }
            self = .androidEmulator(serial: serial)
        } else {
            return nil
        }
    }
}

/// Who moved the keyboard away from a phone screen that has it (finding 3, "i cant type inside"): the
/// person only when the event is fresh (taken off the app's queue at most 150 ms ago) and the phone did
/// not act on it itself. A box that grabs the keyboard right after typing into the phone is refused; a
/// shortcut such as ⌘F that focuses a field a moment later still moves it.
public enum DeviceKeyboardClaim {
    public static let freshFor: TimeInterval = 0.15

    public static func isPersons(age: TimeInterval, phoneTookIt: Bool) -> Bool {
        !phoneTookIt && age.isFinite && age <= freshFor
    }
}

/// The environment a device tool runs with (`adb`, `simctl pbcopy`/`pbpaste`, the device engine). `simctl pbcopy`
/// reads its input in the locale's encoding, and an app started from Finder or the Dock has no locale, so
/// non-English text typed or pasted into a phone arrived mangled ("café" as "caf√©", Urdu unreadable;
/// 22 Oct 2026, finding 3). A UTF-8 character type is added when none is set; a set locale is never replaced.
public enum DeviceToolEnvironment {
    public static func utf8(_ environment: [String: String]) -> [String: String] {
        guard ["LC_ALL", "LC_CTYPE", "LANG"].allSatisfy({ (environment[$0] ?? "").isEmpty }) else { return environment }
        var result = environment
        result["LC_CTYPE"] = "UTF-8"
        return result
    }
}
