import Foundation

/// `{type:'open-link', url, disposition:'tab'|'external'}` from an engine page.
public struct LinkRequest: Equatable, Sendable {
    public enum Disposition: String, Equatable, Sendable {
        case tab
        case external
    }

    public var url: String
    public var disposition: Disposition

    public static let messageType = "open-link"
    public static let maxURL = 8192

    public static func isLinkMessage(_ body: Any) -> Bool {
        (body as? [String: Any])?["type"] as? String == messageType
    }

    /// nil unless it is an open-link message with a url. A missing or unknown
    /// disposition is "external" — never a tab the page did not ask for.
    public static func parse(_ body: Any) -> LinkRequest? {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType,
              let url = PageBody.string(dict["url"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty, url.count <= maxURL
        else { return nil }
        let disposition = (dict["disposition"] as? String).flatMap(Disposition.init(rawValue:)) ?? .external
        return LinkRequest(url: url, disposition: disposition)
    }
}

/// What happens to a link a page asked to open.
public enum LinkAction: Equatable, Sendable {
    /// A native browser tab.
    case tab(URL)
    /// The default browser (or mail app for mailto:).
    case external(URL)
    /// A file on this Mac: only after asking, and then shown in Finder, never run.
    case askFile(URL)
    /// Another app's link (`vscode:`, `slack:` …): only after asking.
    case askApp(URL)
    /// Never: script and data addresses, the engine's own pages, nonsense.
    case refuse(String)
}

public enum LinkPolicy {
    /// Schemes that can carry script or content of the page's own making.
    public static let neverSchemes: Set<String> = ["javascript", "data", "blob", "about", "vbscript", "filesystem"]

    public static func decide(_ request: LinkRequest, engineOrigin: EngineOrigin?) -> LinkAction {
        guard let url = URL(string: request.url), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .refuse("not an address")
        }
        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return .refuse("no host") }
            // The engine's pages live only in the app's own windows, never in a tab or browser.
            if let engineOrigin, engineOrigin.contains(url) { return .refuse("the engine's own address") }
            return request.disposition == .tab ? .tab(url) : .external(url)
        case "mailto":
            return .external(url)
        case "file":
            return url.isFileURL && !url.path.isEmpty ? .askFile(url) : .refuse("not a file address")
        default:
            if neverSchemes.contains(scheme) { return .refuse("\(scheme): links are never opened") }
            // A plausible URL scheme: letters first, then letters, digits, + - .
            let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "+-."))
            guard let first = scheme.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first),
                  scheme.unicodeScalars.allSatisfy({ allowed.contains($0) })
            else { return .refuse("not an address") }
            return .askApp(url)
        }
    }
}

/// Camera and microphone for an engine page.
public enum MediaCapturePolicy {
    public enum Kind: Equatable, Sendable {
        case microphone
        case camera
        case cameraAndMicrophone
    }

    public enum Decision: Equatable, Sendable {
        case grant
        case deny
    }

    /// The microphone (dictation) for the engine's own origin only; never the camera
    /// (the app declares no camera use, and asking for it would end the app).
    public static func decide(kind: Kind, scheme: String, host: String, port: Int,
                              engineOrigin: EngineOrigin?) -> Decision {
        guard kind == .microphone, let engineOrigin,
              engineOrigin.matches(scheme: scheme, host: host, port: port)
        else { return .deny }
        return .grant
    }
}
