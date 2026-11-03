import Foundation

/// The page address the native bridge reports when it is ready.
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
}

public enum EngineWireError: Error, Equatable, CustomStringConvertible {
    case notReady
    case malformed
    case refused(String)

    public var description: String {
        switch self {
        case .notReady: return "The engine is not ready yet."
        case .malformed: return "The engine's answer could not be read."
        case .refused(let why): return why
        }
    }
}
