import Foundation

// Bookmarks of the built-in browser (owner, 18 Nov 2026: "We can have bookmarks over here"). The smallest store:
// one flat list per browser profile, newest last (the bar reads left to right in the order they were added), one row
// per address. Only web addresses, as the history keeps them. The file sits beside `browser-history.json`.
// The site's small icon is kept with the bookmark, so the bar shows it before any page is loaded.

public struct BrowserBookmark: Equatable, Sendable, Identifiable {
    public var profileID: String
    public var url: String
    public var title: String
    /// The site's icon as PNG bytes (small; nil when the page had none).
    public var icon: Data?
    /// Milliseconds since 1970.
    public var addedAt: Double

    public init(profileID: String, url: String, title: String, icon: Data? = nil, addedAt: Double = 0) {
        self.profileID = profileID
        self.url = url
        self.title = title
        self.icon = icon
        self.addedAt = addedAt
    }

    public var id: String { profileID + "\u{1F}" + url }

    /// What the bar shows: the name, else the host without `www.`.
    public var label: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }

    public var host: String {
        guard let host = URLComponents(string: url)?.host else { return url }
        let port = URLComponents(string: url)?.port.map { ":\($0)" } ?? ""
        return (host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host) + port
    }
}

public enum BrowserBookmarks {
    public static let maxPerProfile = 500
    public static let maxTitle = 120
    /// A site icon larger than this is not kept (the bar then draws the site's letter).
    public static let maxIconBytes = 24 * 1024
    /// The switch "Always show the bookmarks bar" (off: the bar shows on the New Tab page only).
    public static let alwaysShowKey = "browser.bookmarksBar.always"

    /// The key bookmarks are kept under: the same as the history's ("" is the default profile).
    public static func profileKey(_ profile: String) -> String { BrowserHistory.profileKey(profile) }

    public static func cleanTitle(_ raw: String) -> String {
        let flat = BrowserText.oneLine(raw)
        return flat.count > maxTitle ? String(flat.prefix(maxTitle)) : flat
    }

    /// This profile's bookmarks, in the order they were added.
    public static func list(_ all: [BrowserBookmark], profileID: String) -> [BrowserBookmark] {
        all.filter { $0.profileID == profileID }
    }

    public static func contains(_ all: [BrowserBookmark], profileID: String, url: String) -> Bool {
        guard let url = BrowserHistory.visitable(url) else { return false }
        return all.contains { $0.profileID == profileID && $0.url == url }
    }

    /// Adds the page (once: a second add renames it and refreshes its icon). Not a web address: nothing changes.
    public static func add(_ all: [BrowserBookmark], profileID: String, url: String, title: String, icon: Data? = nil,
                           at: Double, limit: Int = maxPerProfile) -> [BrowserBookmark] {
        guard !profileID.isEmpty, let url = BrowserHistory.visitable(url) else { return all }
        let kept = icon.flatMap { $0.count <= maxIconBytes ? $0 : nil }
        let clean = cleanTitle(title)
        if let index = all.firstIndex(where: { $0.profileID == profileID && $0.url == url }) {
            var next = all
            if !clean.isEmpty { next[index].title = clean }
            if let kept { next[index].icon = kept }
            return next
        }
        guard list(all, profileID: profileID).count < limit else { return all }
        return all + [BrowserBookmark(profileID: profileID, url: url, title: clean, icon: kept, addedAt: at)]
    }

    public static func remove(_ all: [BrowserBookmark], profileID: String, url: String) -> [BrowserBookmark] {
        let target = BrowserHistory.visitable(url) ?? url
        return all.filter { !($0.profileID == profileID && $0.url == target) }
    }

    /// The star: on a saved page it removes, else it adds. `added` says which happened (nil: nothing, not a web page).
    public static func toggle(_ all: [BrowserBookmark], profileID: String, url: String, title: String, icon: Data? = nil,
                              at: Double) -> (list: [BrowserBookmark], added: Bool?) {
        guard !profileID.isEmpty, BrowserHistory.visitable(url) != nil else { return (all, nil) }
        if contains(all, profileID: profileID, url: url) { return (remove(all, profileID: profileID, url: url), false) }
        let next = add(all, profileID: profileID, url: url, title: title, icon: icon, at: at)
        return (next, next.count > all.count ? true : nil)
    }

    /// A deleted profile's bookmarks go with it.
    public static func dropProfile(_ all: [BrowserBookmark], profileID: String) -> [BrowserBookmark] {
        all.filter { $0.profileID != profileID }
    }

    /// How many of the bar's items fit, left to right, when each needs `widths[i]` and `gap` between them; the rest go
    /// behind "»" (`overflowWidth` is kept free for it as soon as one item does not fit).
    public static func fitting(widths: [Double], available: Double, gap: Double, overflowWidth: Double) -> Int {
        let total = widths.reduce(0, +) + gap * Double(max(0, widths.count - 1))
        if total <= available { return widths.count }
        var used = 0.0, shown = 0
        for width in widths {
            let next = used + (shown == 0 ? 0 : gap) + width
            if next + gap + overflowWidth > available { break }
            used = next
            shown += 1
        }
        return shown
    }

    public static func encode(_ list: [BrowserBookmark]) -> Data {
        let rows: [[String: Any]] = list.map { mark in
            var row: [String: Any] = ["profileID": mark.profileID, "url": mark.url, "title": mark.title, "addedAt": mark.addedAt]
            if let icon = mark.icon { row["icon"] = icon.base64EncodedString() }
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: ["version": 1, "entries": rows], options: [.sortedKeys])) ?? Data()
    }

    /// Forgiving: an unreadable row is dropped, never the whole list.
    public static func decode(_ data: Data?) -> [BrowserBookmark] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["entries"] as? [Any] else { return [] }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let fields = row as? [String: Any],
                  let profileID = fields["profileID"] as? String, !profileID.isEmpty,
                  let url = BrowserHistory.visitable((fields["url"] as? String) ?? "") else { return nil }
            let mark = BrowserBookmark(profileID: profileID, url: url, title: cleanTitle((fields["title"] as? String) ?? ""),
                                       icon: (fields["icon"] as? String).flatMap { Data(base64Encoded: $0) },
                                       addedAt: (fields["addedAt"] as? NSNumber)?.doubleValue ?? 0)
            return seen.insert(mark.id).inserted ? mark : nil
        }
    }
}
