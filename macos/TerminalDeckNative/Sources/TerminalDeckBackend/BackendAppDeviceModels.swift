import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendAppDeviceFrame: Sendable, Equatable {
    public let kind: UInt8
    public let payload: Data
    public init(kind: UInt8, payload: Data) { self.kind = kind; self.payload = payload }
}
public enum BackendAppDeviceFrames {
    public static let request: UInt8 = 0x01, response: UInt8 = 0x02, h264Config: UInt8 = 0x10,
                      h264Data: UInt8 = 0x11, jpeg: UInt8 = 0x12, png: UInt8 = 0x20
    public static let maximumPayloadBytes = 64 * 1024 * 1024
    public static func encode(kind: UInt8, payload: Data) throws -> Data {
        guard payload.count <= Int(UInt32.max) else { throw BackendAppSessionError("The device frame payload cannot fit in its four-byte length.") }
        let length = UInt32(payload.count)
        var result = Data([kind, UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        result.append(payload); return result
    }
}
public struct BackendAppDeviceFrameReader: Sendable {
    private var pending: [UInt8] = []
    public init() {}
    public mutating func push(_ chunk: Data) throws -> [BackendAppDeviceFrame] {
        pending.append(contentsOf: chunk)
        var frames: [BackendAppDeviceFrame] = [], offset = 0
        while pending.count - offset >= 5 {
            let length = Int(pending[offset + 1]) << 24 | Int(pending[offset + 2]) << 16 | Int(pending[offset + 3]) << 8 | Int(pending[offset + 4])
            guard length <= BackendAppDeviceFrames.maximumPayloadBytes else {
                pending.removeAll(); throw BackendAppSessionError("The device engine sent a frame of \(length) bytes, which it never should.")
            }
            guard pending.count - offset >= 5 + length else { break }
            frames.append(.init(kind: pending[offset], payload: Data(pending[(offset + 5)..<(offset + 5 + length)])))
            offset += 5 + length
        }
        if offset > 0 { pending.removeFirst(offset) }
        return frames
    }
}
public struct BackendAppDeviceEngine: Sendable, Equatable {
    public let bin: String
    public let core: String
    public let cli: String
    public let environment: [String: String]
    public init(bin: String, core: String, cli: String, environment: [String: String]) {
        self.bin = bin; self.core = core; self.cli = cli; self.environment = environment
    }
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
    public static func candidates(resourcesPath: String?, appPath: String, cwd: String, override: String? = nil) -> [String] {
        let package = "node_modules/@toolingtools/simview/bin"
        var out: [String] = []
        if let override, !override.isEmpty { out.append(override) }
        if let resourcesPath { out.append(URL(fileURLWithPath: resourcesPath).appendingPathComponent("app.asar.unpacked/" + package).path) }
        let unpacked = appPath.hasSuffix("app.asar") ? String(appPath.dropLast("app.asar".count)) + "app.asar.unpacked" : appPath
        out += [unpacked, appPath, cwd].map { URL(fileURLWithPath: $0).appendingPathComponent(package).path }
        var seen = Set<String>(); return out.filter { seen.insert($0).inserted }
    }
    public static func locate(resourcesPath: String?, appPath: String, cwd: String, environment: [String: String],
                              platform: String = "darwin", arch: String = BackendAppDeviceEngineLocator.architecture, nativeBin: String? = nil,
                              exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                              executable: @Sendable (String) -> Bool = { access($0, X_OK) == 0 }) -> BackendAppDeviceEngineAnswer {
        guard platform == "darwin" else { return .unavailable("Simulators open on a Mac. This computer is not one.") }
        guard arch == "arm64" else { return .unavailable("Simulators need a Mac with Apple silicon.") }
        // Native packaging may place the same engine in Resources/simview/bin.
        // Caller supplies that exact directory, followed by source candidates.
        let bins = nativeBin.map { [$0] } ?? []
        for bin in bins + candidates(resourcesPath: resourcesPath, appPath: appPath, cwd: cwd, override: environment["TD_DEVICE_ENGINE_BIN"]) {
            let root = URL(fileURLWithPath: bin), core = root.appendingPathComponent("simview-core").path
            guard exists(core), executable(core) else { continue }
            var env: [String: String] = [:]
            for (name, file) in [("SIMVIEW_ANDROID_AGENT_PATH", "simview-android-agent.jar"), ("SIMVIEW_PROBE_DYLIB", "libSimViewProbe.dylib"), ("SIMVIEW_XCTEST_PROVIDER_XCTESTRUN", "xctest-provider/SimViewXCTestProvider.xctestrun")] {
                let path = root.appendingPathComponent(file).path
                if exists(path) { env[name] = path }
            }
            return .available(.init(bin: bin, core: core, cli: root.appendingPathComponent("simview").path, environment: env))
        }
        return .unavailable("This copy of the app is missing its simulator engine. Reinstall the app to get it back.")
    }
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
        for key in ["enabled", "hidden", "focused"] { if let value = row[key].bool { node = node.setting(key, .bool(value)) } }
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
