import Foundation

/// The engine's own origin: `http://<loopback>:<port>`. Nothing else may load in the view.
public struct EngineOrigin: Equatable, Sendable {
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    public let host: String
    public let port: Int

    /// Only a plain http address on this machine, with an explicit port, qualifies.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              Self.loopbackHosts.contains(host),
              let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil
        else { return nil }
        self.host = host
        self.port = port
    }

    /// True when `url` is on exactly this origin (scheme, host and port).
    public func contains(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http",
              url.host?.lowercased() == host
        else { return false }
        return (url.port ?? 80) == port
    }

    /// `http://127.0.0.1:1234` — for comparing with a WebKit security origin.
    public func matches(scheme: String, host: String, port: Int) -> Bool {
        let effectivePort = port == 0 ? 80 : port
        return scheme.lowercased() == "http" && host.lowercased() == self.host && effectivePort == self.port
    }

    public var display: String {
        host.contains(":") ? "http://[\(host)]:\(port)" : "http://\(host):\(port)"
    }
}

public enum NavigationDecision: Equatable, Sendable {
    /// Load it in the view.
    case allow
    /// Cancel, and hand it to the default browser / mail app.
    case openExternally
    /// Cancel silently.
    case block
}

public enum NavigationPolicy {
    /// Schemes we are willing to hand to another app. Anything else (file:, custom app
    /// schemes, javascript:, data:) is never passed on from the page.
    public static let externalSchemes: Set<String> = ["http", "https", "mailto"]

    /// - Parameters:
    ///   - url: where the navigation is going.
    ///   - isMainFrame: true for the top-level page or a new-window request.
    ///   - origin: the engine origin.
    public static func decide(url: URL?, isMainFrame: Bool, origin: EngineOrigin) -> NavigationDecision {
        guard let url, let scheme = url.scheme?.lowercased() else { return .block }

        if origin.contains(url) { return .allow }

        switch scheme {
        case "about":
            // Empty documents: about:blank anywhere (it loads nothing), about:srcdoc
            // only for frames the page builds for itself.
            let page = url.absoluteString.lowercased()
            if page == "about:blank" { return .allow }
            if page == "about:srcdoc", !isMainFrame { return .allow }
            return .block
        case "blob":
            // A blob URL carries its creator's origin: blob:http://127.0.0.1:1234/<uuid>.
            let inner = String(url.absoluteString.dropFirst("blob:".count))
            if let innerURL = URL(string: inner), origin.contains(innerURL) { return .allow }
            return .block
        default:
            if isMainFrame, externalSchemes.contains(scheme) { return .openExternally }
            return .block
        }
    }
}
