import Foundation

// The native sidebar is drawn from what the page posts as `{type:'sidebar', state}`.
// Decoding is forgiving: one malformed row is dropped, never the whole sidebar.

public struct SidebarItem: Equatable, Identifiable, Sendable, Decodable {
    public enum Kind: Equatable, Sendable {
        case hoot, panel, session
        case other(String)

        init(_ raw: String?) {
            switch raw {
            case "hoot": self = .hoot
            case "panel": self = .panel
            case "session": self = .session
            default: self = .other(raw ?? "")
            }
        }

        /// The page's own word for it ('hoot', 'panel', 'session', or whatever it sent).
        public var name: String {
            switch self {
            case .hoot: "hoot"
            case .panel: "panel"
            case .session: "session"
            case .other(let raw): raw
            }
        }

        /// Used when the page's symbol name is missing (or not a real SF Symbol).
        public var defaultSymbol: String {
            switch self {
            case .hoot: "bird"
            case .panel: "square.grid.2x2"
            case .session: "terminal"
            case .other: "circle"
            }
        }
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let kind: Kind
    public let unread: Bool
    public let status: String?
    public let subtitle: String?

    public init(id: String, title: String, symbol: String? = nil, kind: Kind, unread: Bool = false, status: String? = nil, subtitle: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.symbol = symbol.flatMap(\.nonEmpty) ?? kind.defaultSymbol
        self.unread = unread
        self.status = status.flatMap(\.nonEmpty)
        self.subtitle = subtitle.flatMap(\.nonEmpty)
    }

    enum CodingKeys: String, CodingKey { case id, title, symbol, kind, unread, status, subtitle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "item without id")
        }
        self.init(
            id: id,
            title: c.lossyString(.title) ?? "",
            symbol: c.lossyString(.symbol),
            kind: Kind(c.lossyString(.kind)),
            unread: c.lossyFlag(.unread) ?? false,
            status: c.lossyString(.status),
            subtitle: c.lossyString(.subtitle))
    }
}

public struct SidebarGroup: Equatable, Identifiable, Sendable, Decodable {
    public let id: String
    /// nil → a section without a header.
    public let title: String?
    public let items: [SidebarItem]

    public init(id: String, title: String?, items: [SidebarItem]) {
        self.id = id
        self.title = title.flatMap(\.nonEmpty)
        self.items = items
    }

    enum CodingKeys: String, CodingKey { case id, title, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "group without id")
        }
        self.init(id: id, title: c.lossyString(.title), items: c.lossyArray(.items))
    }
}

public struct SidebarProject: Equatable, Identifiable, Sendable, Decodable {
    /// The project's folder path.
    public let id: String
    public let title: String
    public var expanded: Bool
    public let sessions: [SidebarItem]

    public init(id: String, title: String, expanded: Bool, sessions: [SidebarItem]) {
        self.id = id
        self.title = title
        self.expanded = expanded
        self.sessions = sessions
    }

    enum CodingKeys: String, CodingKey { case id, title, expanded, sessions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "project without path")
        }
        let fallbackTitle = URL(fileURLWithPath: id).lastPathComponent
        self.init(
            id: id,
            title: c.lossyString(.title).flatMap(\.nonEmpty) ?? fallbackTitle,
            expanded: c.lossyFlag(.expanded) ?? false,
            sessions: c.lossyArray(.sessions))
    }
}

public struct SidebarState: Equatable, Sendable, Decodable {
    public var groups: [SidebarGroup]
    public var projects: [SidebarProject]
    public var selectedId: String?

    public init(groups: [SidebarGroup], projects: [SidebarProject], selectedId: String?) {
        self.groups = groups
        self.projects = projects
        self.selectedId = selectedId.flatMap(\.nonEmpty)
    }

    enum CodingKeys: String, CodingKey { case groups, projects, selectedId }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(groups: c.lossyArray(.groups), projects: c.lossyArray(.projects), selectedId: c.lossyString(.selectedId))
    }

    /// Every row the page sent: group items and project sessions.
    public var allItems: [SidebarItem] {
        groups.flatMap(\.items) + projects.flatMap(\.sessions)
    }

    public func item(id: String) -> SidebarItem? {
        allItems.first { $0.id == id }
    }
}

public struct SettingsSection: Equatable, Identifiable, Sendable, Decodable {
    public let id: String
    public let title: String
    public let symbol: String
    public let kind: String?

    public init(id: String, title: String, symbol: String?, kind: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol.flatMap(\.nonEmpty) ?? "gearshape"
        self.kind = kind.flatMap(\.nonEmpty)
    }

    /// Hoot's section shows the owl, never an SF Symbol.
    public var isHoot: Bool { id == "hoot" || kind == "hoot" }

    enum CodingKeys: String, CodingKey { case id, title, symbol, kind }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "section without id")
        }
        self.init(id: id, title: c.lossyString(.title).flatMap(\.nonEmpty) ?? id,
                  symbol: c.lossyString(.symbol), kind: c.lossyString(.kind))
    }
}

// MARK: Forgiving decoding helpers

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// A string, or a number written as a string; nil for null/missing/other.
    func lossyString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        return nil
    }

    /// true/false, or a count (> 0 means true).
    func lossyFlag(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let n = try? decodeIfPresent(Double.self, forKey: key) { return n > 0 }
        return nil
    }

    /// Every element that decodes; malformed ones are skipped. Missing → [].
    func lossyArray<T: Decodable>(_ key: Key) -> [T] {
        ((try? decodeIfPresent([Lossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
