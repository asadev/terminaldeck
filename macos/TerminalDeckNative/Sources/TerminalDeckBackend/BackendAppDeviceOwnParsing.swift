import Foundation
import TerminalDeckNativeCore

// The pure parts of Terminal Deck's own device engine (28 Oct 2026): what Apple's and Google's tools print, read into
// the shapes the phone panel and the devices_* tools already use. No I/O here, so every rule is tested on its own.

// MARK: - The live picture from `screenrecord --output-format=h264`

/// Cuts a raw H.264 byte stream (Annex B: each NAL unit after a 00 00 01 or 00 00 00 01 start code) into NAL units.
/// A unit ends where the next start code begins; `flush()` ends the last one when the stream has paused, which is how
/// a picture that is followed by nothing (a still screen) still reaches the panel.
public struct BackendAppDeviceAnnexB: Sendable {
    private var pending: [UInt8] = []
    public init() {}

    /// The units completed by `chunk`; the unfinished one stays until more bytes or `flush()`.
    public mutating func push(_ chunk: Data) -> [Data] {
        pending.append(contentsOf: chunk)
        var units: [Data] = [], start: Int? = nil, index = 0, cut = 0
        while index + 3 <= pending.count {
            if pending[index] == 0, pending[index + 1] == 0, pending[index + 2] == 1 {
                let codeStart = index > 0 && pending[index - 1] == 0 ? index - 1 : index
                if let begun = start, codeStart > begun { units.append(Data(pending[begun..<codeStart])) }
                start = index + 3; cut = codeStart; index += 3
            } else { index += 1 }
        }
        guard let begun = start else {
            // No start code yet: keep at most the last three bytes (a code may straddle chunks).
            if pending.count > 3 { pending.removeFirst(pending.count - 3) }
            return units
        }
        // Keep the unfinished unit with its start code, so the next push finds where it begins.
        let keep = cut <= begun ? cut : begun
        pending.removeFirst(keep)
        return units.filter { !$0.isEmpty }
    }

    /// The unit in progress, ended now (the stream paused after it).
    public mutating func flush() -> [Data] {
        var index = 0
        while index + 3 <= pending.count {
            if pending[index] == 0, pending[index + 1] == 0, pending[index + 2] == 1 {
                let unit = Data(pending[(index + 3)...]); pending.removeAll()
                return unit.isEmpty ? [] : [unit]
            }
            index += 1
        }
        return []
    }
}

public enum BackendAppDeviceH264 {
    public static func type(_ unit: Data) -> UInt8 { unit.first.map { $0 & 0x1F } ?? 0 }
    /// A coded slice (1) or an IDR slice (5): a picture.
    public static func isPicture(_ unit: Data) -> Bool { [1, 5].contains(type(unit)) }

    /// The decoder configuration (AVCDecoderConfigurationRecord) for one SPS and one PPS, 4-byte unit lengths.
    public static func avcC(sps: Data, pps: Data) -> Data? {
        let s = [UInt8](sps), p = [UInt8](pps)
        guard s.count >= 4, !p.isEmpty, s.count <= 0xFFFF, p.count <= 0xFFFF else { return nil }
        var out: [UInt8] = [1, s[1], s[2], s[3], 0xFF, 0xE1, UInt8(s.count >> 8), UInt8(s.count & 0xFF)]
        out += s
        out += [1, UInt8(p.count >> 8), UInt8(p.count & 0xFF)]
        out += p
        return Data(out)
    }

    /// The panel's packet for one coded picture (ScreenPacket 0x11): timestamp, keyframe flag, length-prefixed units.
    public static func picture(_ units: [Data], key: Bool, microseconds: UInt64) -> Data {
        var out = Data([0x11])
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((microseconds >> UInt64(shift)) & 0xFF)) }
        out.append(key ? 1 : 0)
        for unit in units {
            let length = UInt32(unit.count)
            out.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
            out.append(unit)
        }
        return out
    }
}

/// Turns NAL units into the panel's packets: the configuration (0x10) whenever it is new, then one packet per
/// picture with the units that came with it (SEI and the like).
public struct BackendAppDeviceH264Packets: Sendable {
    private var sps: Data?, pps: Data?, sentConfig: Data?
    private var extras: [Data] = []
    public init() {}

    /// Forget what was sent: the next picture is preceded by the configuration again (a new viewer, a restart).
    public mutating func resend() { sentConfig = nil }

    public mutating func push(_ unit: Data, microseconds: UInt64) -> [Data] {
        switch BackendAppDeviceH264.type(unit) {
        case 7: sps = unit; return []
        case 8: pps = unit; return []
        case 1, 5:
            var out: [Data] = []
            if let sps, let pps, let config = BackendAppDeviceH264.avcC(sps: sps, pps: pps), config != sentConfig {
                var packet = Data([0x10]); packet.append(config); out.append(packet); sentConfig = config
            }
            guard sentConfig != nil else { extras.removeAll(); return out }
            let key = BackendAppDeviceH264.type(unit) == 5
            out.append(BackendAppDeviceH264.picture(extras + [unit], key: key, microseconds: microseconds))
            extras.removeAll()
            return out
        case 9: return []                          // access unit delimiter: carries nothing the decoder needs
        default: if extras.count < 8 { extras.append(unit) }; return []
        }
    }
}

// MARK: - Android, from adb

public struct BackendAppDeviceAdbRow: Sendable, Equatable {
    public let serial: String
    public let state: String
    public let model: String
    public init(serial: String, state: String, model: String) { self.serial = serial; self.state = state; self.model = model }
}

public enum BackendAppDeviceAndroidParsing {
    /// `adb devices -l`: each device's serial, state and model.
    public static func devices(_ text: String) -> [BackendAppDeviceAdbRow] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*"),
                  parts[0].range(of: #"^[A-Za-z0-9._:\-]+$"#, options: .regularExpression) != nil else { return nil }
            let model = parts.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? ""
            return .init(serial: parts[0], state: parts[1], model: model)
        }
    }

    /// The device row the inventory reads (the shape `BackendAppDeviceInventoryParsing.engineDevice` takes).
    public static func row(_ found: BackendAppDeviceAdbRow) -> NativeRPCValue {
        let emulator = found.serial.hasPrefix("emulator-")
        let state: String
        switch found.state {
        case "device": state = "ready"
        case "unauthorized": state = "unauthorized"
        case "offline": state = "offline"
        case "authorizing", "connecting": state = "booting"
        default: state = "unknown"
        }
        let name = found.model.isEmpty ? found.serial : found.model.replacingOccurrences(of: "_", with: " ")
        return BackendAppDeviceParsing.object([("id", .string("android:" + found.serial)), ("platform", .string("android")),
            ("kind", .string(emulator ? "emulator" : "physical")), ("state", .string(state)), ("available", .bool(state == "ready")),
            ("name", .string(name)), ("runtime", .string("")),
            ("capabilities", BackendAppDeviceParsing.object([("orientation", .bool(true)), ("input", BackendAppDeviceParsing.object([
                ("buttons", .array(buttons.map(NativeRPCValue.string))), ("keys", .array(keyNames.map(NativeRPCValue.string))),
                ("text", .string("ascii")), ("rawTouch", .bool(false))]))]))])
    }

    public static let buttons = ["home", "back", "overview", "lock", "volume-up", "volume-down"]
    public static let keyNames = ["return", "delete", "tab", "escape", "space", "arrow-up", "arrow-down", "arrow-left", "arrow-right", "select-all"]

    /// `wm size`: the size apps draw at (an override wins over the physical size).
    public static func size(_ text: String) -> (width: Int, height: Int)? {
        func read(_ label: String) -> (Int, Int)? {
            guard let line = text.components(separatedBy: "\n").first(where: { $0.contains(label) }),
                  let match = line.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else { return nil }
            let parts = line[match].split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
        }
        return read("Override size") ?? read("Physical size")
    }

    /// `wm density`: dots per inch (an override wins).
    public static func density(_ text: String) -> Int? {
        func read(_ label: String) -> Int? {
            guard let line = text.components(separatedBy: "\n").first(where: { $0.contains(label) }),
                  let match = line.range(of: #"\d+"#, options: .regularExpression) else { return nil }
            return Int(line[match]).flatMap { $0 > 0 ? $0 : nil }
        }
        return read("Override density") ?? read("Physical density")
    }

    /// The display's quarter turns now, from `dumpsys input` (SurfaceOrientation) or `dumpsys window` (mCurrentRotation).
    public static func rotation(_ text: String) -> Int? {
        if let match = text.range(of: #"SurfaceOrientation:\s*(\d)"#, options: .regularExpression),
           let digit = text[match].last.flatMap({ Int(String($0)) }), (0...3).contains(digit) { return digit }
        if let match = text.range(of: #"mCurrentRotation=(ROTATION_)?(\d+)"#, options: .regularExpression) {
            let value = Int(text[match].split(whereSeparator: { !$0.isNumber }).last.map(String.init) ?? "") ?? -1
            switch value { case 0, 1, 2, 3: return value; case 90: return 1; case 180: return 2; case 270: return 3; default: return nil }
        }
        return nil
    }

    /// The app in front, from `dumpsys activity activities` (or `dumpsys window`): package and activity.
    public static func foreground(_ text: String) -> (package: String, activity: String)? {
        for key in ["topResumedActivity", "mResumedActivity", "ResumedActivity", "mCurrentFocus", "mFocusedApp"] {
            for line in text.components(separatedBy: "\n") where line.contains(key) {
                guard let match = line.range(of: #"[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+"#, options: .regularExpression) else { continue }
                let parts = line[match].split(separator: "/", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].contains(".") else { continue }
                let activity = parts[1].hasPrefix(".") ? parts[0] + parts[1] : parts[1]
                return (parts[0], activity)
            }
        }
        return nil
    }

    /// Android key codes for the panel's named keys (KeyEvent constants).
    public static func keycode(_ name: String) -> Int? {
        switch name {
        case "return", "enter": 66
        case "delete", "backspace": 67
        case "tab": 61
        case "escape": 111
        case "space": 62
        case "forward-delete": 112
        case "arrow-up": 19
        case "arrow-down": 20
        case "arrow-left": 21
        case "arrow-right": 22
        case "home": 122
        case "end": 123
        case "page-up": 92
        case "page-down": 93
        default: nil
        }
    }

    public static func modifierKeycode(_ name: String) -> Int? {
        switch name { case "shift": 59; case "control": 113; case "option": 57; case "command": 117; default: nil }
    }

    /// The `adb shell input` arguments that press a named key with modifiers held, or nil when there is no such key.
    public static func keyArguments(_ name: String, modifiers: [String]) -> [String]? {
        var held: [Int] = []
        for modifier in modifiers {
            guard let code = modifierKeycode(modifier) else { return nil }
            if !held.contains(code) { held.append(code) }
        }
        if name == "select-all" { if !held.contains(113) { held.append(113) }; return ["keycombination"] + held.map(String.init) + ["29"] }
        guard let code = keycode(name) else { return nil }
        return held.isEmpty ? ["keyevent", String(code)] : ["keycombination"] + held.map(String.init) + [String(code)]
    }

    public static func buttonKeycode(_ name: String) -> Int? {
        switch name {
        case "home": 3
        case "back": 4
        case "overview": 187
        case "lock": 26
        case "volume-up": 24
        case "volume-down": 25
        default: nil
        }
    }

    /// `input text` takes printable ASCII, with a space written as %s. The whole is quoted for the phone's shell.
    /// Nil when the text has anything else (Android's input tool cannot type it).
    public static func typedText(_ text: String) -> String? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return nil }
        let spaced = text.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: " ", with: "%s")
        return "'" + spaced.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The screen's quarter turn for an orientation name (Settings.System.USER_ROTATION).
    public static func userRotation(_ orientation: String) -> Int? {
        switch orientation {
        case "portrait": 0
        case "landscape-left": 1
        case "portrait-upside-down": 2
        case "landscape-right": 3
        default: nil
        }
    }

    /// `uiautomator dump`'s XML as the panel's snapshot (the shape `BackendAppDeviceParsing.snapshot` reads), or nil.
    public static func snapshot(_ xml: String, now: String = Date().ISO8601Format(), maximum: Int = 1500) -> NativeRPCValue? {
        guard let start = xml.range(of: "<?xml") ?? xml.range(of: "<hierarchy"),
              let end = xml.range(of: "</hierarchy>", options: .backwards) else { return nil }
        let reader = UIAutomatorReader(maximum: maximum)
        let parser = XMLParser(data: Data(xml[start.lowerBound..<end.upperBound].utf8))
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else { return nil }
        let screen = reader.screen
        func value(_ node: UIAutomatorReader.Node, ref: inout Int) -> NativeRPCValue {
            ref += 1
            var fields: [(String, NativeRPCValue)] = [("ref", .string("a\(ref)"))]
            let a = node.attributes
            if let role = a["class"], !role.isEmpty { fields.append(("role", .string(role))) }
            if let label = a["content-desc"], !label.isEmpty { fields.append(("label", .string(label))) }
            let secret = a["password"] == "true"
            if let text = a["text"], !text.isEmpty {
                if secret { fields.append(("valueRedacted", .bool(true))) } else { fields.append(("text", .string(text))); fields.append(("value", .string(text))) }
            }
            if let id = a["resource-id"], !id.isEmpty { fields.append(("identifier", .string(id))) }
            if let enabled = a["enabled"] { fields.append(("enabled", .bool(enabled == "true"))) }
            if a["focused"] == "true" { fields.append(("focused", .bool(true))) }
            let acts = ["clickable", "checkable", "scrollable", "long-clickable"].contains { a[$0] == "true" } || (a["class"] ?? "").hasSuffix("EditText")
            fields.append(("actionable", .bool(acts)))
            if let rect = bounds(a["bounds"] ?? ""), screen.width > 0, screen.height > 0 {
                fields.append(("frame", BackendAppDeviceParsing.object([("normalized", BackendAppDeviceParsing.object([
                    ("x", .number(rect.x / screen.width)), ("y", .number(rect.y / screen.height)),
                    ("width", .number(rect.width / screen.width)), ("height", .number(rect.height / screen.height))]))])))
            }
            let children = node.children.map { value($0, ref: &ref) }
            if !children.isEmpty { fields.append(("children", .array(children))) }
            return BackendAppDeviceParsing.object(fields)
        }
        var ref = 0
        let top = BackendAppDeviceParsing.object([("ref", .string("a0")), ("role", .string("hierarchy")),
            ("frame", BackendAppDeviceParsing.object([("normalized", BackendAppDeviceParsing.object([("x", .number(0)), ("y", .number(0)), ("width", .number(1)), ("height", .number(1))]))])),
            ("children", .array(root.children.map { value($0, ref: &ref) }))])
        return BackendAppDeviceParsing.object([("source", .string("android-uiautomator")), ("capturedAt", .string(now)), ("root", top),
            ("stats", BackendAppDeviceParsing.object([("nodeCount", .number(Double(reader.count))), ("truncated", .bool(reader.truncated)),
                ("quality", .string(reader.count > 1 ? "full" : "degraded"))]))])
    }

    /// `[x1,y1][x2,y2]` as a rectangle.
    public static func bounds(_ text: String) -> (x: Double, y: Double, width: Double, height: Double)? {
        let numbers = text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
        return (numbers[0], numbers[1], numbers[2] - numbers[0], numbers[3] - numbers[1])
    }

    private final class UIAutomatorReader: NSObject, XMLParserDelegate {
        final class Node { var attributes: [String: String]; var children: [Node] = []; init(_ a: [String: String]) { attributes = a } }
        let maximum: Int
        var root: Node?
        var stack: [Node] = []
        var count = 0
        var truncated = false
        var screen: (width: Double, height: Double) = (0, 0)
        init(maximum: Int) { self.maximum = maximum }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "hierarchy" { let node = Node(attributes); root = node; stack = [node]; return }
            guard name == "node", let parent = stack.last else { return }
            let node = Node(attributes)
            if count < maximum, stack.count < 200 { parent.children.append(node); count += 1 } else { truncated = true }
            if let rect = BackendAppDeviceAndroidParsing.bounds(attributes["bounds"] ?? "") {
                screen = (max(screen.width, rect.x + rect.width), max(screen.height, rect.y + rect.height))
            }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "node", stack.count > 1 { stack.removeLast() }
        }
    }

    /// The deepest node under a point (0...1), preferring one a finger acts on, with its children left out.
    public static func element(at x: Double, _ y: Double, in snapshot: NativeRPCValue) -> NativeRPCValue? {
        var best: (node: NativeRPCValue, depth: Int, area: Double)?
        func visit(_ node: NativeRPCValue, depth: Int) {
            let f = node["frame"]["normalized"]
            if let fx = f["x"].number, let fy = f["y"].number, let fw = f["width"].number, let fh = f["height"].number,
               x >= fx, x <= fx + fw, y >= fy, y <= fy + fh, node["role"].string != "hierarchy" {
                let area = fw * fh
                if best == nil || depth > best!.depth || (depth == best!.depth && area < best!.area) { best = (node, depth, area) }
            }
            for child in node["children"].elements ?? [] { visit(child, depth: depth + 1) }
        }
        visit(snapshot["root"], depth: 0)
        return best.map { $0.node.setting("children", .missing) }
    }
}

// MARK: - iOS, from the helper and simctl

public enum BackendAppDeviceIOSParsing {
    /// The helper's `--sim-ax tree` answer: the snapshot, whether it is thin, the reason when there is none, the app in front.
    public static func tree(_ text: String) -> (snapshot: NativeRPCValue?, degraded: Bool, error: String, app: NativeRPCValue) {
        guard let raw = try? NativeRPCValue.parseJSON(Data(text.utf8)), raw.fields != nil else {
            return (nil, true, "The simulator's helper gave no answer.", .null)
        }
        if let error = raw["error"].string { return (nil, true, error, raw["app"]) }
        let snapshot = BackendAppDeviceParsing.snapshot(raw)
        let thin = raw["stats"]["quality"].string == "degraded" || BackendAppDeviceParsing.number(snapshot?["nodeCount"] ?? .null) <= 1
        return (snapshot, thin, "", raw["app"])
    }

    /// The width and height a PNG says it has (its IHDR), or nil when it is not a PNG.
    public static func pngSize(_ data: Data) -> (width: Double, height: Double)? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 else { return nil }
        func word(_ at: Int) -> Double { Double(UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])) }
        return (word(16), word(20))
    }

    /// A simulator's screen in points, from its device type's profile (mainScreenWidth/Height in pixels, mainScreenScale;
    /// Xcode 26 and earlier).
    public static func points(profile: [String: Any]) -> (width: Double, height: Double)? {
        guard let width = (profile["mainScreenWidth"] as? NSNumber)?.doubleValue, let height = (profile["mainScreenHeight"] as? NSNumber)?.doubleValue,
              let scale = (profile["mainScreenScale"] as? NSNumber)?.doubleValue, width > 0, height > 0, scale > 0 else { return nil }
        return (width / scale, height / scale)
    }

    /// The same from the device type's capabilities (Xcode 27: `capabilities.displays`, the main screen is screenID 1).
    public static func points(capabilities: [String: Any]) -> (width: Double, height: Double)? {
        let displays = ((capabilities["capabilities"] as? [String: Any])?["displays"] as? [[String: Any]]) ?? []
        guard let main = displays.first(where: { ($0["screenID"] as? NSNumber)?.intValue == 1 }) ?? displays.first,
              let width = (main["width"] as? NSNumber)?.doubleValue, let height = (main["height"] as? NSNumber)?.doubleValue,
              let scale = (main["scale"] as? NSNumber)?.doubleValue, width > 0, height > 0, scale > 0 else { return nil }
        return (width / scale, height / scale)
    }
}
