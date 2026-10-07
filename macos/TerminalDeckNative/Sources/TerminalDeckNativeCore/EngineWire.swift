import Foundation

/// The engine bridge's wire rules, for screens drawn in Swift.
///
/// The pages reach the engine through `/__td/invoke`, `/__td/send` and the
/// `/__td/events` stream (src/main/native-shell/bridge-server.ts). A native
/// screen speaks the same API with the same values: JSON, with bytes carried as
/// `{"$bytes": "<base64>"}` (src/main/native-shell/wire.ts). These are the pure
/// parts — where to connect, how values cross, how the event stream is read —
/// so they can be tested without an engine.
public enum EngineWire {
    /// The engine's base address and its per-launch key, from the ready URL
    /// (`http://127.0.0.1:<port>/?t=<token>`). Nil when either is missing.
    public static func endpoint(from readyURL: URL) -> (base: URL, token: String)? {
        guard var parts = URLComponents(url: readyURL, resolvingAgainstBaseURL: false),
              let token = parts.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty,
              parts.host != nil, parts.port != nil else { return nil }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let base = parts.url else { return nil }
        return (base, token)
    }

    /// A Swift value ready for JSONSerialization: `Data` becomes `{"$bytes": …}`.
    public static func encode(_ value: Any?) -> Any {
        switch value {
        case nil: return NSNull()
        case let data as Data: return ["$bytes": data.base64EncodedString()]
        case let array as [Any?]: return array.map { encode($0) }
        case let dict as [String: Any?]: return dict.mapValues { encode($0) }
        case let other?: return other
        }
    }

    /// A JSON value from the engine, with `{"$bytes": …}` turned back into `Data`.
    public static func decode(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            if dict.count == 1, let b64 = dict["$bytes"] as? String, let data = Data(base64Encoded: b64) { return data }
            return dict.mapValues { decode($0) }
        }
        if let array = value as? [Any] { return array.map { decode($0) } }
        return value
    }

    /// The body of an invoke or send.
    public static func requestBody(channel: String, args: [Any?]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["channel": channel, "args": encode(args)])
    }

    /// The answer to an invoke: the value, or the engine's own error sentence.
    public static func invokeResult(_ data: Data) -> Result<Any, EngineWireError> {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let answer = object as? [String: Any] else { return .failure(.malformed) }
        if answer["ok"] as? Bool == true { return .success(decode(answer["value"] ?? NSNull())) }
        return .failure(.refused((answer["error"] as? String) ?? "the engine refused the call"))
    }

    /// One event from the stream: its channel and arguments.
    public struct Event: @unchecked Sendable {
        public let channel: String
        public let args: [Any]
        public init(channel: String, args: [Any]) { self.channel = channel; self.args = args }
    }

    /// Reads the Server-Sent Events stream line by line. Feed it each line
    /// (without the newline); it hands back an event when a blank line ends one.
    /// Comment lines (`:` keep-alives) and unknown fields are ignored.
    public struct EventParser {
        private var data: [String] = []
        public init() {}
        public mutating func feed(_ line: String) -> Event? {
            if line.isEmpty {
                defer { data.removeAll() }
                guard !data.isEmpty,
                      let json = data.joined(separator: "\n").data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                      let channel = object["channel"] as? String else { return nil }
                let args = (decode(object["args"] ?? []) as? [Any]) ?? []
                return Event(channel: channel, args: args)
            }
            if line.hasPrefix(":") { return nil }
            if line.hasPrefix("data:") {
                var value = line.dropFirst(5)
                if value.hasPrefix(" ") { value = value.dropFirst() }
                data.append(String(value))
            }
            return nil
        }
    }
}

public enum EngineWireError: Error, Equatable, CustomStringConvertible {
    case notReady
    case malformed
    case refused(String)
    case http(Int)

    public var description: String {
        switch self {
        case .notReady: return "The engine is not ready yet."
        case .malformed: return "The engine's answer could not be read."
        case .refused(let why): return why
        case .http(let code): return "The engine answered \(code)."
        }
    }
}
