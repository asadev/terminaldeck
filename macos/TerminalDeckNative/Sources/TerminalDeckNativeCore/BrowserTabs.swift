import Foundation

// The native browser's tabs as plain data: their order, which one is chosen,
// and how they are kept across a relaunch (addresses, titles, profile and the
// Isolated flag, in UserDefaults). Each browser tab is a tab in the main
// window's strip; `NativeBrowserTabs` owns the live pages, this owns the rules.

/// One tab, as remembered.
public struct BrowserTabRecord: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    /// The page's address — empty for a tab still on the "Open a page" view.
    public var url: String
    public var title: String
    /// The browser profile (the engine's `browser-profile` id) whose cookies the tab uses;
    /// empty for the default profile.
    public var profile: String
    /// "Isolated": the tab keeps its own cookies and storage, in memory only,
    /// thrown away when it closes. The web browser's Shared/Isolated toggle.
    public var isolated: Bool

    public init(id: String = UUID().uuidString, url: String = "", title: String = "",
                profile: String = "", isolated: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.profile = profile
        self.isolated = isolated
    }
}

/// The tabs in order, and the chosen one.
public struct BrowserTabList: Equatable, Sendable {
    public private(set) var tabs: [BrowserTabRecord]
    public private(set) var selectedID: String?

    public init(tabs: [BrowserTabRecord] = [], selectedID: String? = nil) {
        var seen = Set<String>()
        self.tabs = tabs.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        self.selectedID = selectedID.flatMap { id in self.tabs.contains { $0.id == id } ? id : nil } ?? self.tabs.first?.id
    }

    public var selected: BrowserTabRecord? { selectedID.flatMap { record($0) } }

    public func index(of id: String) -> Int? { tabs.firstIndex { $0.id == id } }
    public func record(_ id: String) -> BrowserTabRecord? { tabs.first { $0.id == id } }

    /// Add a tab right after `after` (or at the end), and choose it if asked.
    public mutating func insert(_ tab: BrowserTabRecord, after: String? = nil, select: Bool = true) {
        guard index(of: tab.id) == nil, !tab.id.isEmpty else { return }
        if let after, let at = index(of: after) {
            tabs.insert(tab, at: at + 1)
        } else {
            tabs.append(tab)
        }
        if select || selectedID == nil { selectedID = tab.id }
    }

    public mutating func select(_ id: String) {
        if index(of: id) != nil { selectedID = id }
    }

    /// Close a tab. Closing the chosen one chooses its right-hand neighbour, else its left.
    public mutating func close(_ id: String) {
        guard let at = index(of: id) else { return }
        tabs.remove(at: at)
        guard selectedID == id else { return }
        selectedID = tabs.isEmpty ? nil : tabs[min(at, tabs.count - 1)].id
    }

    /// Move a tab to `destination` (an index into the list as it is after the move).
    public mutating func move(_ id: String, to destination: Int) {
        guard let from = index(of: id) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(destination, tabs.count)))
    }

    /// Move a tab one place left (-1) or right (+1).
    public mutating func move(_ id: String, by offset: Int) {
        guard let from = index(of: id) else { return }
        move(id, to: from + offset)
    }

    /// The tab after (+1) or before (-1) the chosen one, wrapping round.
    public func neighbour(_ offset: Int) -> String? {
        guard !tabs.isEmpty else { return nil }
        let at = selectedID.flatMap { index(of: $0) } ?? 0
        let next = ((at + offset) % tabs.count + tabs.count) % tabs.count
        return tabs[next].id
    }

    public mutating func update(_ id: String, url: String? = nil, title: String? = nil,
                                profile: String? = nil, isolated: Bool? = nil) {
        guard let at = index(of: id) else { return }
        if let url { tabs[at].url = url }
        if let title { tabs[at].title = title }
        if let profile { tabs[at].profile = profile }
        if let isolated { tabs[at].isolated = isolated }
    }
}

/// How the tabs are kept across a relaunch.
public enum BrowserTabsStore {
    public static let defaultsKey = "nativeBrowser.tabs.v1"

    private struct Saved: Codable {
        var version: Int
        var tabs: [BrowserTabRecord]
        var selected: String?
    }

    /// The tabs to keep, in order, with the chosen one.
    public static func encode(_ list: BrowserTabList) -> Data {
        let saved = Saved(version: 1, tabs: list.tabs, selected: list.selectedID)
        return (try? JSONEncoder().encode(saved)) ?? Data()
    }

    /// The tabs as they were kept. Anything unreadable is dropped, never the whole
    /// list; only web addresses (or none, for the start view) come back.
    public static func decode(_ data: Data?) -> BrowserTabList {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["tabs"] as? [Any] else { return BrowserTabList() }
        var tabs: [BrowserTabRecord] = []
        for row in rows {
            guard let fields = row as? [String: Any],
                  let id = fields["id"] as? String, !id.isEmpty else { continue }
            let url = (fields["url"] as? String) ?? ""
            guard url.isEmpty || isWebAddress(url) else { continue }
            tabs.append(BrowserTabRecord(id: id, url: url,
                                         title: (fields["title"] as? String) ?? "",
                                         profile: (fields["profile"] as? String) ?? "",
                                         isolated: (fields["isolated"] as? Bool) ?? false))
        }
        return BrowserTabList(tabs: tabs, selectedID: object["selected"] as? String)
    }

    static func isWebAddress(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && !(parts.host ?? "").isEmpty
    }
}
