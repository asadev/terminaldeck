import Foundation
import TerminalDeckNativeCore

public enum BackendOSPopoutRules {
    public struct Rect: Equatable, Codable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
        public var wireValue: NativeRPCValue { .object([.init("x", .number(x)), .init("y", .number(y)), .init("width", .number(width)), .init("height", .number(height))]) }
        public static func parse(_ value: NativeRPCValue) -> Self? {
            guard let x = value["x"].number, let y = value["y"].number, let width = value["width"].number, let height = value["height"].number, width > 0, height > 0 else { return nil }
            return Self(x: BackendOSPopoutRules.round(x), y: BackendOSPopoutRules.round(y), width: BackendOSPopoutRules.round(width), height: BackendOSPopoutRules.round(height))
        }
    }
    public struct Display: Equatable, Sendable {
        public let id: Double, label: String, bounds: Rect, workArea: Rect
        public init(id: Double, label: String, bounds: Rect, workArea: Rect) { self.id = id; self.label = label; self.bounds = bounds; self.workArea = workArea }
    }
    public struct Placement: Equatable, Sendable {
        public let key: String, bounds: Rect, displayID: Double?, fullScreen: Bool
        public init(key: String, bounds: Rect, displayID: Double?, fullScreen: Bool) { self.key = key; self.bounds = bounds; self.displayID = displayID; self.fullScreen = fullScreen }
        public var wireValue: NativeRPCValue { .object([.init("key", .string(key)), .init("bounds", bounds.wireValue), .init("displayId", displayID.map(NativeRPCValue.number) ?? .null), .init("fullScreen", .bool(fullScreen))]) }
    }
    public struct Placed: Equatable, Sendable { public let bounds: Rect, display: Display, outcome: String }
    public static let filename = "popout-windows.json", maximumRemembered = 40, saveDelayMilliseconds = 400
    public static let mainCommands: Set<String> = ["view.mcp", "app.preferences", "session.new", "session.newDialog"]
    public static let notForwarded: Set<String> = ["devices:frame", "machines:output", "servers:shell:output", "browser:progress", "debug:ipc-call"]
    public static func round(_ value: Double) -> Double { floor(value + 0.5) }
    public static func readPlacements(_ raw: NativeRPCValue) -> [Placement] {
        guard raw["v"].number == 1, let rows = raw["windows"].elements else { return [] }
        var result: [Placement] = [], seen = Set<String>()
        for row in rows {
            guard let key = row["key"].string, !key.isEmpty, !seen.contains(key), let bounds = Rect.parse(row["bounds"]) else { continue }
            seen.insert(key); result.append(Placement(key: key, bounds: bounds, displayID: row["displayId"].number, fullScreen: row["fullScreen"].bool == true))
        }
        return result
    }
    public static func file(_ placements: [Placement]) -> NativeRPCValue { .object([.init("v", .number(1)), .init("windows", .array(placements.map(\.wireValue)))]) }
    private static func intersection(_ a: Rect, _ b: Rect) -> Rect { let x = max(a.x, b.x), y = max(a.y, b.y); return Rect(x: x, y: y, width: max(0, min(a.x + a.width, b.x + b.width) - x), height: max(0, min(a.y + a.height, b.y + b.height) - y)) }
    public static func reachable(_ bounds: Rect, on display: Display) -> Bool {
        let title = Rect(x: bounds.x, y: bounds.y, width: bounds.width, height: min(bounds.height, 32)), seen = intersection(title, display.workArea)
        return seen.width >= min(120, bounds.width) && seen.height >= min(32, bounds.height) / 2
    }
    public static func fit(_ bounds: Rect, into area: Rect) -> Rect {
        let width = max(min(bounds.width, area.width), min(480, area.width)), height = max(min(bounds.height, area.height), min(320, area.height))
        return Rect(x: round(min(max(bounds.x, area.x), area.x + area.width - width)), y: round(min(max(bounds.y, area.y), area.y + area.height - height)), width: round(width), height: round(height))
    }
    public static func centre(width: Double, height: Double, area: Rect) -> Rect { fit(Rect(x: area.x + round((area.width - width) / 2), y: area.y + round((area.height - height) / 2), width: width, height: height), into: area) }
    public static func displayAt(x: Double, y: Double, displays: [Display]) -> Display? { displays.first { x >= $0.bounds.x && x < $0.bounds.x + $0.bounds.width && y >= $0.bounds.y && y < $0.bounds.y + $0.bounds.height } }
    public static func mostlyHolding(_ bounds: Rect, displays: [Display]) -> Display? {
        var best: Display?, area = 0.0
        for display in displays { let seen = intersection(bounds, display.bounds), candidate = seen.width * seen.height; if candidate > area { best = display; area = candidate } }
        return best
    }
    public static func restored(_ placement: Placement, displays: [Display], primary: Display) -> Placed {
        if let same = displays.first(where: { $0.id == placement.displayID }), reachable(placement.bounds, on: same) { return Placed(bounds: fit(placement.bounds, into: same.workArea), display: same, outcome: "same-display") }
        if let display = displays.first(where: { reachable(placement.bounds, on: $0) }) { return Placed(bounds: fit(placement.bounds, into: display.workArea), display: display, outcome: display.id == placement.displayID ? "same-display" : "moved-display") }
        return Placed(bounds: centre(width: placement.bounds.width, height: placement.bounds.height, area: primary.workArea), display: primary, outcome: "fallback-primary")
    }
    public static func new(at: (x: Double, y: Double)? = nil, target: Display? = nil, main: Rect?, displays: [Display], primary: Display, open: Int) -> Placed {
        if let at { let display = displayAt(x: at.x, y: at.y, displays: displays) ?? primary; return Placed(bounds: fit(Rect(x: round(at.x - 480), y: round(at.y - 14), width: 960, height: 640), into: display.workArea), display: display, outcome: "drop") }
        if let target { return Placed(bounds: centre(width: 960, height: 640, area: target.workArea), display: target, outcome: "target") }
        let step = Double(28 * (open + 1)), display = main.flatMap { mostlyHolding($0, displays: displays) } ?? primary
        return Placed(bounds: fit(Rect(x: (main?.x ?? primary.workArea.x) + step, y: (main?.y ?? primary.workArea.y) + step, width: 960, height: 640), into: display.workArea), display: display, outcome: "cascade")
    }
    /// Persist Electron's top-left desktop coordinates; convert only at the
    /// AppKit boundary so existing files survive the native cutover.
    public static func fromAppKit(_ bounds: Rect, primaryTop: Double) -> Rect { Rect(x: bounds.x, y: primaryTop - bounds.y - bounds.height, width: bounds.width, height: bounds.height) }
    public static func toAppKit(_ bounds: Rect, primaryTop: Double) -> Rect { fromAppKit(bounds, primaryTop: primaryTop) }
}
