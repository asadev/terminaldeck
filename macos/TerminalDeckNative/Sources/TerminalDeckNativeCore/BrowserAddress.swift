import Foundation

// What the native browser's address field does with whatever was typed into it.
//
// A port of `src/renderer/browser/omnibox.ts` (the web browser's URL bar), rule
// for rule, so the two browsers agree: `localhost:3000` opens the dev server,
// `example.com` opens the site, `cats` and `how do I center a div` search.
// The search engine is the web browser's own (`src/shared/search.ts`).
//
// Like the web version this is a convenience, not a security boundary: what
// comes out is always http(s) or a search URL, and the page view refuses
// anything else on its own.

/// What typing something into the address field means.
public enum BrowserAddressResolution: Equatable, Sendable {
    /// Nothing was typed.
    case empty
    /// Open this address.
    case url(URL)
    /// Search for `query` at `url`.
    case search(url: URL, query: String)

    /// The address to load, if any.
    public var target: URL? {
        switch self {
        case .empty: return nil
        case .url(let url): return url
        case .search(let url, _): return url
        }
    }
}

/// Where a search term goes — the web browser's `DEFAULT_SEARCH`.
public enum BrowserSearch {
    /// `%s` is replaced with the encoded query (`src/shared/search.ts`).
    public static let defaultTemplate = "https://duckduckgo.com/?q=%s"

    /// The URL that searches for `query`. A template without `%s` gets the query appended.
    public static func url(for query: String, template: String = defaultTemplate) -> URL? {
        let encoded = encodeURIComponent(query)
        let text: String
        if let range = template.range(of: "%s") {
            text = template.replacingCharacters(in: range, with: encoded)
        } else {
            text = template + encoded
        }
        return URL(string: text)
    }

    /// JavaScript's `encodeURIComponent`: everything but `A-Z a-z 0-9 - _ . ! ~ * ' ( )`.
    public static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

public enum BrowserAddress {
    /// Decide what to do with the contents of the address field.
    public static func resolve(_ input: String, searchTemplate: String = BrowserSearch.defaultTemplate) -> BrowserAddressResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        if matches(trimmed, #"^[a-zA-Z][a-zA-Z0-9+.\-]*:"#) {
            let scheme = trimmed[..<trimmed.firstIndex(of: ":")!].lowercased()
            if scheme == "http" || scheme == "https" {
                if let url = webURL(trimmed) { return .url(url) }
                return search(trimmed, searchTemplate)
            }
            // `localhost:3000` and `127.0.0.1:8080` look like schemes and are not.
            if matches(trimmed, hostPortPattern), let url = webURL("http://" + trimmed) { return .url(url) }
            // `mailto:`, `javascript:`, `file:` — never opened from here; searched as text.
            return search(trimmed, searchTemplate)
        }

        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return search(trimmed, searchTemplate) }

        // Protocol-relative and bare hosts both become http: a dev server is
        // what is opened here most, and https on localhost is rare.
        if trimmed.hasPrefix("//") {
            if let url = webURL("http:" + trimmed) { return .url(url) }
            return search(trimmed, searchTemplate)
        }

        if looksLikeHost(trimmed), let url = webURL("http://" + trimmed) { return .url(url) }

        return search(trimmed, searchTemplate)
    }

    /// The address as the field shows it while the page is not being edited.
    public static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        return url.absoluteString
    }

    // MARK: - inside

    /// `host:port` with an optional path — the shape that fools a URL parser.
    static let hostPortPattern = #"^(?:[a-zA-Z0-9\-]+(?:\.[a-zA-Z0-9\-]+)*|\[[0-9a-fA-F:]+\]):[0-9]{1,5}(?:[/?#].*)?$"#

    private static let localHosts: Set<String> = ["localhost", "localhost.", "[::1]", "0.0.0.0"]

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func search(_ query: String, _ template: String) -> BrowserAddressResolution {
        guard let url = BrowserSearch.url(for: query, template: template) else { return .empty }
        return .search(url: url, query: query)
    }

    /// The host part of something typed without a scheme, port removed.
    static func hostOf(_ candidate: String) -> String? {
        let authority = String(candidate.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        if authority.isEmpty { return nil }

        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return nil }
            let after = String(authority[authority.index(after: end)...])
            if !after.isEmpty && !matches(after, "^:[0-9]{1,5}$") { return nil }
            return String(authority[...end])
        }

        guard let colon = authority.firstIndex(of: ":") else { return authority }
        let port = String(authority[authority.index(after: colon)...])
        return matches(port, "^[0-9]{1,5}$") ? String(authority[..<colon]) : nil
    }

    static func looksLikeHost(_ candidate: String) -> Bool {
        guard let host = hostOf(candidate) else { return false }
        let bare = host.lowercased()
        if localHosts.contains(bare) { return true }
        if matches(bare, #"^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$"#) { return true }
        if matches(bare, #"^\[[0-9a-fA-F:]+\]$"#) { return true }
        var labels = bare.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // `example.com.` is a fully-qualified host; its empty last label is not a label.
        if labels.count > 1, labels.last == "" { labels.removeLast() }
        if labels.count < 2 { return false }
        if labels.contains("") { return false }
        // Letters only, two or more: separates `example.com` from `1.5` and `v2.0`.
        return matches(labels[labels.count - 1], #"^[a-zA-Z]{2,}\.?$"#)
    }

    /// An http(s) URL with a host, normalised the way a browser shows it, or nil.
    static func webURL(_ candidate: String) -> URL? {
        guard var parts = URLComponents(string: candidate),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty else { return nil }
        parts.scheme = scheme
        // Hosts are case-insensitive. Only the plain-ASCII spelling is touched,
        // so an IPv6 literal or an international name keeps the form it parsed to.
        if let encoded = parts.percentEncodedHost, encoded.allSatisfy(\.isASCII), encoded != encoded.lowercased() {
            parts.percentEncodedHost = encoded.lowercased()
        }
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.url
    }
}
