import Foundation

// The tab strip in the toolbar is drawn from `{type:'tabs', state}`.
// Same forgiving decoding as the sidebar: a malformed tab is dropped, not the strip.

public struct TabItem: Equatable, Identifiable, Sendable, Decodable {
    public let id: String
    public let title: String
    public let symbol: String
    /// The page's word for it ('session', 'terminal', 'browser', 'panel', 'hoot', …).
    public let kind: String
    public let active: Bool
    public let unread: Bool
    public let status: String?
    /// Missing means not closable: closing is never assumed.
    public let closable: Bool

    public init(id: String, title: String, symbol: String? = nil, kind: String, active: Bool = false,
                unread: Bool = false, status: String? = nil, closable: Bool = false) {
        self.id = id
        self.title = title
        self.kind = kind
        self.symbol = symbol.flatMap(\.nonEmpty) ?? Self.defaultSymbol(kind: kind)
        self.active = active
        self.unread = unread
        self.status = status.flatMap(\.nonEmpty)
        self.closable = closable
    }

    public static func defaultSymbol(kind: String) -> String {
        switch kind {
        case "browser": "globe"
        case "hoot": "bird"
        case "panel": "square.grid.2x2"
        default: "terminal"
        }
    }

    /// Hoot gets its own owl, never an SF Symbol.
    public var isHoot: Bool { kind == "hoot" || id == "hoot" }

    /// The same tab, shown as selected or not (only one tab in the strip is).
    public func with(active: Bool) -> TabItem {
        TabItem(id: id, title: title, symbol: symbol, kind: kind, active: active,
                unread: unread, status: status, closable: closable)
    }

    enum CodingKeys: String, CodingKey { case id, title, symbol, kind, active, unread, status, closable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "tab without id")
        }
        self.init(
            id: id,
            title: c.lossyString(.title) ?? "",
            symbol: c.lossyString(.symbol),
            kind: c.lossyString(.kind)?.nonEmpty ?? "session",
            active: c.lossyFlag(.active) ?? false,
            unread: c.lossyFlag(.unread) ?? false,
            status: c.lossyString(.status),
            closable: c.lossyFlag(.closable) ?? false)
    }
}

public struct TabsState: Equatable, Sendable, Decodable {
    public var tabs: [TabItem]
    public var canNewTerminal: Bool
    public var canNewBrowser: Bool

    public init(tabs: [TabItem], canNewTerminal: Bool, canNewBrowser: Bool) {
        self.tabs = tabs
        self.canNewTerminal = canNewTerminal
        self.canNewBrowser = canNewBrowser
    }

    public var activeID: String? { tabs.first(where: \.active)?.id }

    enum CodingKeys: String, CodingKey { case tabs, canNewTerminal, canNewBrowser }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tabs: c.lossyArray(.tabs),
                  canNewTerminal: c.lossyFlag(.canNewTerminal) ?? false,
                  canNewBrowser: c.lossyFlag(.canNewBrowser) ?? false)
    }
}

extension SidebarItem {
    /// Hoot gets its own owl, never an SF Symbol.
    public var isHoot: Bool { kind == .hoot || id == "hoot" }
}

/// How wide each tab is: share the room equally, never narrower than `minimum`
/// (then the strip scrolls) nor wider than `maximum` (then tabs stay left-aligned).
public enum TabStripMetrics {
    public static let minimumTab: Double = 112
    public static let maximumTab: Double = 220
    public static let spacing: Double = 2

    public static func tabWidth(count: Int, available: Double) -> Double {
        guard count > 0 else { return 0 }
        let share = (available - spacing * Double(count - 1)) / Double(count)
        return min(maximumTab, max(minimumTab, share.rounded(.down)))
    }

    public static func contentWidth(count: Int, tabWidth: Double) -> Double {
        guard count > 0 else { return 0 }
        return tabWidth * Double(count) + spacing * Double(count - 1)
    }
}
