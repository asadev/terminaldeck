import Foundation

/// What the island says about the app, as the main page reports it.
public enum IslandStatus: String, Equatable, Sendable, CaseIterable {
    case idle
    case working
    case needsYou = "needs-you"
    case offline
}

/// The main page's `{type:'island', state:{status, badge, line}}`.
///
/// The island shows only this. Before the engine is up, or before the page has
/// said anything, there is no state and the island is the plain pill.
public struct IslandState: Equatable, Sendable {
    public var status: IslandStatus
    /// How many things want attention; 0 shows no badge.
    public var badge: Int
    /// One short line (for VoiceOver and the pill's tooltip).
    public var line: String

    public static let messageType = "island"
    public static let maxLine = 200
    public static let maxBadge = 99_999

    public init(status: IslandStatus, badge: Int = 0, line: String = "") {
        self.status = status
        self.badge = min(max(0, badge), Self.maxBadge)
        self.line = line
    }

    /// True for any `{type:'island', …}` body, well-formed or not — so the relay
    /// takes it and it never reaches the other page messages.
    public static func isIslandMessage(_ body: Any) -> Bool {
        (body as? [String: Any])?["type"] as? String == messageType
    }

    /// `body` is what WebKit hands over (NSDictionary of JSON-like values).
    /// nil unless it is an island message with a known status.
    public static func parse(_ body: Any) -> IslandState? {
        guard let dict = body as? [String: Any], dict["type"] as? String == messageType,
              let state = dict["state"] as? [String: Any],
              let raw = state["status"] as? String,
              let status = IslandStatus(rawValue: raw)
        else { return nil }
        return IslandState(status: status, badge: badge(state["badge"]), line: clean(state["line"] as? String ?? ""))
    }

    /// A count: a finite number, rounded down, never negative. Anything else (a
    /// boolean, a string, NaN) is no badge rather than a guess.
    private static func badge(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double > 0 else { return 0 }
        return Int(min(double.rounded(.down), Double(maxBadge)))
    }

    private static func clean(_ raw: String) -> String {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(maxLine))
    }
}

/// Commands into the island's own page.
public enum IslandCommand {
    /// `window.tdNative.run('island-expanded', true|false)` — the panel grew or settled.
    public static func expanded(_ isExpanded: Bool) -> String {
        "window.tdNative && window.tdNative.run('island-expanded', \(isExpanded ? "true" : "false"))"
    }
}

/// Where the island's expanded content lives: `<engine origin>/?island=1`.
/// The bridge token is never repeated here — the main page's first load set the cookie.
public enum IslandLocation {
    public static func url(engineURL: URL) -> URL? {
        guard let origin = EngineOrigin(url: engineURL) else { return nil }
        return URL(string: "\(origin.display)/?island=1")
    }
}
