import Foundation

/// The Simulators page's data, read from the engine's answers — the Swift
/// reading of `renderer/devices/devices-bridge.ts`. Channels and shapes are
/// `src/main/devices/ipc.ts`'s.

public struct DeviceEntry: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    /// `ios` or `android`.
    public var platform: String
    /// `simulator`, `emulator` or `physical`.
    public var kind: String
    /// `ready`, `booting`, `offline`, `unauthorized`, `shutdown` or `unknown`.
    public var state: String
    public var available: Bool
    public var name: String
    public var runtime: String
    public var canBoot: Bool
    public var canShutDown: Bool
    public var note: String
    /// Not confirmed by the engine this time — shown from the simulator's own record, being checked again.
    public var checking: Bool

    public init(id: String, platform: String = "ios", kind: String = "simulator", state: String = "ready",
                available: Bool = true, name: String, runtime: String = "", canBoot: Bool = false,
                canShutDown: Bool = false, note: String = "", checking: Bool = false) {
        self.id = id
        self.platform = platform
        self.kind = kind
        self.state = state
        self.available = available
        self.name = name
        self.runtime = runtime
        self.canBoot = canBoot
        self.canShutDown = canShutDown
        self.note = note
        self.checking = checking
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        platform = row["platform"] as? String == "android" ? "android" : "ios"
        kind = row["kind"] as? String ?? "simulator"
        state = row["state"] as? String ?? "unknown"
        available = row["available"] as? Bool ?? false
        name = row["name"] as? String ?? id
        runtime = row["runtime"] as? String ?? ""
        canBoot = row["canBoot"] as? Bool ?? false
        canShutDown = row["canShutDown"] as? Bool ?? false
        note = row["note"] as? String ?? ""
        checking = row["checking"] as? Bool ?? false
    }

    /// What sort of thing a row is, in the words a person uses.
    public static func kindWords(platform: String, kind: String) -> String {
        if platform == "ios" { return "iOS Simulator" }
        return kind == "physical" ? "Android phone" : "Android emulator"
    }

    public var kindWords: String { Self.kindWords(platform: platform, kind: kind) }

    /// The state, in words.
    public var stateLine: String {
        if !note.isEmpty { return note }
        switch state {
        case "ready": return "Running"
        case "booting": return "Starting…"
        case "shutdown": return "Off"
        case "offline": return "Not answering"
        case "unauthorized": return "Waiting for permission on the phone"
        default: return ""
        }
    }

    /// The line under a device's name: `Simulator · iOS 27.0`, its state only where the group does not say it.
    public var subLine: String {
        let what = !runtime.isEmpty && platform == "ios" ? "Simulator" : kindWords
        let stateWords = available || canBoot ? "" : stateLine
        return [what, runtime, stateWords, checking ? "checking…" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

public struct DeviceList: Equatable, Sendable {
    public var available: Bool
    public var reason: String
    public var devices: [DeviceEntry]

    public init(available: Bool, reason: String = "", devices: [DeviceEntry]) {
        self.available = available
        self.reason = reason
        self.devices = devices
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        available = row["available"] as? Bool ?? false
        reason = row["reason"] as? String ?? ""
        devices = (row["devices"] as? [Any] ?? []).compactMap(DeviceEntry.init(json:))
    }

    /// Running first, then what can be started, then what cannot be used at all.
    public var groups: [(title: String, rows: [DeviceEntry])] {
        let running = devices.filter(\.available)
        let off = devices.filter { !$0.available && $0.canBoot }
        let other = devices.filter { !$0.available && !$0.canBoot }
        return [("Running", running), ("Off", off), ("Not available", other)].filter { !$0.1.isEmpty }
    }

    /// Whether a row is changing, so the list is asked again soon rather than now and then.
    public var isChanging: Bool { devices.contains { $0.checking || $0.state == "booting" } }
}

/// An open device, from `devices:open`.
public struct DeviceDetails: Equatable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var kind: String
    public var pointWidth: Double
    public var pointHeight: Double
    public var buttons: [String]
    public var keys: [String]
    public var text: String
    public var canRotate: Bool
    /// A finger can be held and moved, rather than only tapped or swiped.
    public var rawTouch: Bool

    public init(id: String, name: String, platform: String = "ios", kind: String = "simulator",
                pointWidth: Double = 0, pointHeight: Double = 0, buttons: [String] = [], keys: [String] = [],
                text: String = "none", canRotate: Bool = false, rawTouch: Bool = false) {
        self.id = id
        self.name = name
        self.platform = platform
        self.kind = kind
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.buttons = buttons
        self.keys = keys
        self.text = text
        self.canRotate = canRotate
        self.rawTouch = rawTouch
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = row["name"] as? String ?? id
        platform = row["platform"] as? String == "android" ? "android" : "ios"
        kind = row["kind"] as? String ?? ""
        pointWidth = DeviceJSON.number(row["pointWidth"])
        pointHeight = DeviceJSON.number(row["pointHeight"])
        buttons = DeviceJSON.strings(row["buttons"])
        keys = DeviceJSON.strings(row["keys"])
        text = row["text"] as? String ?? "none"
        canRotate = row["canRotate"] as? Bool ?? false
        rawTouch = row["rawTouch"] as? Bool ?? false
    }

    public var isPhysical: Bool { kind == "physical" }
    public var kindWords: String { DeviceEntry.kindWords(platform: platform, kind: isPhysical ? "physical" : "simulator") }
}

/// The exact picture, the tree read against it and where, from `devices:freeze`.
public struct FrozenScreen: Sendable {
    public var png: Data
    public var width: Int
    public var height: Int
    public var tree: DeviceTree?
    public var treeError: String
    public var where_: AnnotateWhere

    public init(png: Data, width: Int, height: Int, tree: DeviceTree?, treeError: String = "", where_: AnnotateWhere) {
        self.png = png
        self.width = width
        self.height = height
        self.tree = tree
        self.treeError = treeError
        self.where_ = where_
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let png = DeviceJSON.dataURL(row["image"]) else { return nil }
        self.png = png
        width = Int(DeviceJSON.number(row["width"]))
        height = Int(DeviceJSON.number(row["height"]))
        tree = DeviceTree(json: row["tree"])
        treeError = row["treeError"] as? String ?? ""
        where_ = AnnotateWhere(json: row["where"]) ?? AnnotateWhere(place: "", name: "")
    }
}

/// A screenshot saved to Pictures, from `devices:screenshot`.
public struct DeviceShot: Sendable {
    public var path: String
    public var width: Int
    public var height: Int
    /// A PNG preview, when the engine could make one.
    public var preview: Data?

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let path = row["path"] as? String, !path.isEmpty else { return nil }
        self.path = path
        width = Int(DeviceJSON.number(row["width"]))
        height = Int(DeviceJSON.number(row["height"]))
        preview = DeviceJSON.dataURL(row["preview"])
    }
}

/// `{ ok, id }` or `{ ok: false, message }`, from booting or shutting down.
public enum DeviceOutcome: Equatable, Sendable {
    case ok(id: String?)
    case refused(String)

    public init(json: Any?, fallback: String) {
        guard let row = json as? [String: Any] else { self = .refused(fallback); return }
        if row["ok"] as? Bool == true {
            self = .ok(id: row["id"] as? String)
        } else {
            let message = row["message"] as? String ?? ""
            self = .refused(message.isEmpty ? fallback : message)
        }
    }
}

// MARK: - Input

/// One thing sent to a device, in the page's channels.
public enum DeviceInput: Equatable, Sendable {
    case touch(phase: String, x: Double, y: Double)
    case tap(x: Double, y: Double, holdMs: Double?)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, ms: Double)
    case type(String)
    case key(String)
    case button(String)

    /// The channel and arguments, as `src/main/devices/ipc.ts` takes them.
    public func call(device id: String) -> (channel: String, args: [Any?]) {
        switch self {
        case let .touch(phase, x, y): ("devices:touch", [id, phase, x, y])
        case let .tap(x, y, hold): ("devices:tap", [id, x, y, hold])
        case let .swipe(fx, fy, tx, ty, ms): ("devices:swipe", [id, ["x": fx, "y": fy], ["x": tx, "y": ty], ms])
        case let .type(text): ("devices:type", [id, text])
        case let .key(key): ("devices:key", [id, key])
        case let .button(button): ("devices:button", [id, button])
        }
    }

    var isMove: Bool {
        if case .touch("move", _, _) = self { return true }
        return false
    }
}

/// Input in the order it happened, one call at a time.
///
/// The web page relies on IPC keeping a window's messages in order. Over the
/// bridge each call is its own HTTP request, which can overtake another, so the
/// native screen sends one at a time instead. A finger moving faster than the
/// calls complete must not fall behind the pointer, so a move still waiting to
/// go is replaced by the newer one — never a down, an up, a tap or a key.
public struct DeviceInputQueue: Sendable {
    private var items: [DeviceInput] = []

    public init() {}

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public mutating func push(_ input: DeviceInput) {
        if input.isMove, let last = items.last, last.isMove {
            items[items.count - 1] = input
        } else {
            items.append(input)
        }
    }

    public mutating func next() -> DeviceInput? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func removeAll() { items.removeAll() }
}

/// How a press on the screen becomes input, for a device that cannot hold a finger down.
public enum DeviceGesture {
    /// A press shorter and smaller than this is a tap, not a drag.
    public static let tapTravel = 0.015
    public static let longPressMs = 500.0

    /// What a released press means: a swipe if it moved, a long press if held, a tap otherwise.
    public static func release(fromX: Double, fromY: Double, toX: Double, toY: Double, moved: Bool, heldMs: Double) -> DeviceInput {
        if moved {
            return .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: min(max(heldMs, 150), 1_500))
        }
        return .tap(x: fromX, y: fromY, holdMs: heldMs >= longPressMs ? heldMs : nil)
    }

    /// A wheel's gathered movement (page convention: positive is further down) as a short swipe
    /// against it, or nil when it is too small to mean anything.
    public static func wheel(dx: Double, dy: Double) -> DeviceInput? {
        let y = max(-0.45, min(0.45, dy / 900))
        let x = max(-0.45, min(0.45, dx / 900))
        if abs(y) < 0.02 && abs(x) < 0.02 { return nil }
        return .swipe(fromX: 0.5, fromY: 0.5, toX: 0.5 - x, toY: 0.5 - y, ms: 220)
    }
}
