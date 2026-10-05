import Foundation

/// One screen shown in its own window: a panel (Hoot, Tasks, Memory, …), a session,
/// or one of the native browser's tabs.
/// It is the window's identity, so opening the same screen again focuses that window;
/// it is Codable so open windows can be reopened on the next launch.
public struct ScreenRef: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case panel, session
        /// A native browser tab: drawn in Swift, no page behind it.
        case browser
    }

    /// The kind as the page and NativeScreens name it.
    public var screenKind: String {
        switch kind {
        case .session: "session"
        case .browser: "browser"
        case .panel: isHoot ? "hoot" : "panel"
        }
    }

    /// Worth reopening at the next launch (a browser tab's window is not: its tab may be gone).
    public var isRemembered: Bool { kind != .browser }

    public let kind: Kind
    public let id: String
    /// Drawn with Hoot's owl in its window's toolbar.
    public let isHoot: Bool

    public init(kind: Kind, id: String, isHoot: Bool = false) {
        self.kind = kind
        self.id = id
        self.isHoot = isHoot
    }

    enum CodingKeys: String, CodingKey { case kind, id, isHoot }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        isHoot = try c.decodeIfPresent(Bool.self, forKey: .isHoot) ?? false
    }

    /// A sidebar row: sessions are sessions; Hoot and every other row is a panel.
    public static func forSidebarItem(_ item: SidebarItem) -> ScreenRef {
        ScreenRef(kind: item.kind == .session ? .session : .panel, id: item.id, isHoot: item.isHoot)
    }

    /// A tab: panel and Hoot tabs are panels; terminal, browser and session tabs are sessions.
    public static func forTab(_ tab: TabItem) -> ScreenRef {
        let isPanel = tab.isHoot || tab.kind == "panel"
        return ScreenRef(kind: isPanel ? .panel : .session, id: tab.id, isHoot: tab.isHoot)
    }

    /// `<engine origin>/?screen=<kind>&id=<id>` — keeping the engine's own query
    /// (its token) so the page is let in, and escaping the id completely.
    public func url(engineURL: URL) -> URL? {
        guard kind != .browser, EngineOrigin(url: engineURL) != nil,
              var components = URLComponents(url: engineURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/"
        components.fragment = nil
        var items = (components.percentEncodedQueryItems ?? []).filter { $0.name != "screen" && $0.name != "id" }
        items.append(URLQueryItem(name: "screen", value: kind.rawValue))
        items.append(URLQueryItem(name: "id", value: Self.escape(id)))
        components.percentEncodedQueryItems = items
        return components.url
    }

    /// Percent-encodes everything but unreserved ASCII, so `&`, `=`, `+`, `#`, `/`,
    /// spaces and non-ASCII can never change the query's meaning.
    public static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    // MARK: Remembering open windows across launches

    public static func encodeList(_ refs: [ScreenRef]) -> Data {
        (try? JSONEncoder().encode(refs)) ?? Data("[]".utf8)
    }

    /// Unreadable data → nothing to reopen (never a crash).
    public static func decodeList(_ data: Data?) -> [ScreenRef] {
        guard let data, let refs = try? JSONDecoder().decode([ScreenRef].self, from: data) else { return [] }
        var seen = Set<ScreenRef>()
        return refs.filter { seen.insert($0).inserted }
    }
}
