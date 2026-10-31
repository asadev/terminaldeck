import Foundation
import Darwin
import TerminalDeckNativeCore

/// Terminal Deck's own device engine (28 Oct 2026: the bundled third-party engine was removed; Asad: "remove it
/// completely and build our setup instead"). Nothing outside the app is bundled for it: iOS Simulators are driven with
/// Apple's tools (`xcrun simctl`, `xcodebuild`) and the app's own helper, Android devices with Google's (`adb`).
public struct BackendAppDeviceEngine: Sendable, Equatable {
    /// The app's own helper (`TerminalDeckNativeHelper`): an iOS Simulator's accessibility and rotation run there, so
    /// Apple's private frameworks never load in the app. Nil when this copy has none (tests, a bare build).
    public let helper: String?
    /// Where the engine keeps what it builds on this Mac (the iOS tree runner), inside the app's data folder.
    public let dataFolder: String?
    public init(helper: String?, dataFolder: String?) { self.helper = helper; self.dataFolder = dataFolder }
}
public enum BackendAppDeviceEngineAnswer: Sendable, Equatable {
    case available(BackendAppDeviceEngine)
    case unavailable(String)
}
public enum BackendAppDeviceEngineLocator {
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }
    /// The helper beside the running app's executable: Contents/MacOS in the app, the build folder in development.
    public static func helper(executable: URL? = Bundle.main.executableURL,
                              exists: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard let folder = executable?.deletingLastPathComponent() else { return nil }
        let path = folder.appendingPathComponent("TerminalDeckNativeHelper").path
        return exists(path) ? path : nil
    }
    public static func locate(platform: String = "darwin", arch: String = BackendAppDeviceEngineLocator.architecture,
                              helper: String?, dataFolder: String?) -> BackendAppDeviceEngineAnswer {
        guard platform == "darwin" else { return .unavailable("Simulators open on a Mac. This computer is not one.") }
        guard arch == "arm64" else { return .unavailable("Simulators need a Mac with Apple silicon.") }
        return .available(.init(helper: helper, dataFolder: dataFolder))
    }
}
public struct BackendAppDeviceScreenshot: Sendable {
    public let png: Data
    public let width: Double
    public let height: Double
    public init(png: Data, width: Double, height: Double) { self.png = png; self.width = width; self.height = height }
}

/// JSON adapters copy only source fields. NativeRPCValue preserves a bounded,
/// Sendable wire tree while avoiding a second copy of the UI's DeviceNode type.
public enum BackendAppDeviceParsing {
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func number(_ value: NativeRPCValue) -> Double { value.number.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    public static func strings(_ value: NativeRPCValue) -> [String] { (value.elements ?? []).compactMap(\.string) }
    public static func text(_ value: NativeRPCValue, maximum: Int = 2000) -> String { String(decoding: Array((value.string ?? "").utf16.prefix(maximum)), as: UTF16.self) }
    private static func objectLike(_ value: NativeRPCValue) -> Bool { value.fields != nil || value.elements != nil }
    public static func readNode(_ row: NativeRPCValue, depth: Int = 0) -> NativeRPCValue? {
        guard objectLike(row), depth <= 200 else { return nil }
        var node = object([("ref", .string(row["ref"].string ?? ""))])
        for key in ["role", "label", "value", "identifier", "title", "placeholder", "component", "testID", "text"] {
            if let value = row[key].string, !value.isEmpty { node = node.setting(key, .string(value)) }
        }
        if row["valueRedacted"].bool == true { node = node.setting("valueRedacted", .bool(true)).setting("value", .missing) }
        for key in ["enabled", "hidden", "focused", "actionable"] { if let value = row[key].bool { node = node.setting(key, .bool(value)) } }
        if row["componentPath"].elements != nil { node = node.setting("componentPath", .array(strings(row["componentPath"]).suffix(12).map(NativeRPCValue.string))) }
        let source = row["sourceLocation"]
        if let file = source["file"].string {
            var location = object([("file", .string(file))])
            for key in ["line", "column"] { if let value = source[key].number { location = location.setting(key, .number(value)) } }
            node = node.setting("sourceLocation", location)
        }
        let frame = row["frame"]["normalized"]
        if frame.fields != nil { node = node.setting("frame", object([("normalized", object(["x", "y", "width", "height"].map { ($0, .number(number(frame[$0]))) }))])) }
        let children = (row["children"].elements ?? []).compactMap { readNode($0, depth: depth + 1) }
        if !children.isEmpty { node = node.setting("children", .array(children)) }
        return node
    }
    public static func snapshot(_ raw: NativeRPCValue, now: String = Date().ISO8601Format()) -> NativeRPCValue? {
        guard objectLike(raw), let root = readNode(raw["root"]) else { return nil }
        return object([("source", .string(raw["source"].string ?? "unknown")), ("capturedAt", .string(raw["capturedAt"].string ?? now)),
            ("root", root), ("nodeCount", .number(number(raw["stats"]["nodeCount"]))), ("truncated", .bool(raw["stats"]["truncated"].bool == true))])
    }
    public static func round(_ raw: NativeRPCValue, now: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue {
        let w = raw["where"]
        var whereValue = object([("kind", .string(w["kind"].string == "browser" ? "browser" : "device")), ("place", .string(text(w["place"], maximum: 60))), ("name", .string(text(w["name"], maximum: 200)))])
        for (key, limit) in [("deviceId", 200), ("app", 200), ("screen", 200), ("url", 2000)] {
            let value = text(w[key], maximum: limit); if !value.isEmpty { whereValue = whereValue.setting(key, .string(value)) }
        }
        let annotations = Array((raw["annotations"].elements ?? []).prefix(50)).enumerated().map { index, a in
            let rect = object(["x", "y", "width", "height"].map { ($0, .number(min(max(number(a["rect"][$0]), 0), 1))) })
            var element: NativeRPCValue = .null
            if objectLike(a["element"]) {
                element = object([])
                for (key, limit) in [("role", 60), ("name", 300), ("identifier", 300), ("selector", 500), ("component", 200)] {
                    let value = text(a["element"][key], maximum: limit); if !value.isEmpty { element = element.setting(key, .string(value)) }
                }
                let source = a["element"]["source"], file = text(source["file"], maximum: 500)
                if !file.isEmpty {
                    var location = object([("file", .string(file))])
                    for key in ["line", "column"] { if number(source[key]) > 0 { location = location.setting(key, .number(floor(number(source[key]) + 0.5))) } }
                    element = element.setting("source", location)
                }
            }
            let id = text(a["id"], maximum: 80)
            return object([("id", .string(id.isEmpty ? "a-\(index)" : id)), ("n", .number(Double(index + 1))), ("rect", rect), ("element", element)])
        }
        let id = text(raw["id"], maximum: 80), created = number(raw["createdAt"])
        return object([("id", .string(id.isEmpty ? "round-\(Int64(now))" : id)), ("createdAt", .number(created == 0 ? now : created)), ("where", whereValue),
            ("frame", object(["width", "height"].map { ($0, .number(max(0, floor(number(raw["frame"][$0]) + 0.5)))) })),
            ("note", .string(text(raw["note"], maximum: 4000))), ("annotations", .array(annotations))])
    }
}
