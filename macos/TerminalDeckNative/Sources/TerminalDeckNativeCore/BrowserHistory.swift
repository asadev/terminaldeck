import Foundation

// The address field's suggestions: the pages this browser has visited, kept per
// profile. A port of the web browser's history rules (`main/browser-history.ts`,
// `renderer/browser/history-view.ts`): only web addresses, one row per address
// with a visit count, at most 3000 rows, and suggestions ranked by how well the
// address or title starts with what was typed, then how often and how lately.
// Isolated tabs keep nothing, so they never add a row.

public struct BrowserVisit: Equatable, Sendable, Codable {
    public var profileID: String
    public var url: String
    public var title: String
    /// Milliseconds since 1970.
    public var visitedAt: Double
    public var visits: Int

    public init(profileID: String, url: String, title: String, visitedAt: Double, visits: Int = 1) {
        self.profileID = profileID
        self.url = url
        self.title = title
        self.visitedAt = visitedAt
        self.visits = visits
    }

    /// The row's two halves: the title (else the address) and the host without `www.`.
    public var label: String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? url : trimmed
    }

    public var host: String {
        guard let host = URLComponents(string: url)?.host else { return url }
        let port = URLComponents(string: url)?.port.map { ":\($0)" } ?? ""
        return (host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host) + port
    }
}

public enum BrowserHistory {
    public static let maxEntries = 3000
    public static let maxURL = 2048
    public static let maxTitle = 300

    /// The profile key for a tab's profile ("" is the default profile).
    public static func profileKey(_ profile: String) -> String { profile.isEmpty ? "default" : profile }

    public static func visitable(_ url: String) -> String? {
        guard !url.trimmingCharacters(in: .whitespaces).isEmpty, url.count <= maxURL,
              let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", !(parts.host ?? "").isEmpty else { return nil }
        return parts.url?.absoluteString
    }

    public static func cleanTitle(_ raw: String) -> String {
        let flat = BrowserText.oneLine(raw)
        return flat.count > maxTitle ? String(flat.prefix(maxTitle)) : flat
    }

    /// A visit, folded into the row for that address (count up, title kept if
    /// the new one is empty), newest first, capped.
    public static func note(_ list: [BrowserVisit], profileID: String, url: String, title: String, at: Double,
                            limit: Int = maxEntries) -> [BrowserVisit] {
        guard !profileID.isEmpty, let url = visitable(url) else { return list }
        let existing = list.first { $0.profileID == profileID && $0.url == url }
        let rest = list.filter { !($0.profileID == profileID && $0.url == url) }
        let clean = cleanTitle(title)
        let next = BrowserVisit(profileID: profileID, url: url,
                                title: clean.isEmpty ? (existing?.title ?? "") : clean,
                                visitedAt: at, visits: (existing?.visits ?? 0) + 1)
        let all = [next] + rest
        if all.count <= limit { return all }
        return Array(all.sorted { $0.visitedAt > $1.visitedAt }.prefix(limit))
    }

    /// Only the title changed (it usually arrives after the address).
    public static func retitle(_ list: [BrowserVisit], profileID: String, url: String, title: String) -> [BrowserVisit] {
        let clean = cleanTitle(title)
        guard !clean.isEmpty, let url = visitable(url) else { return list }
        return list.map { visit in
            guard visit.profileID == profileID && visit.url == url else { return visit }
            var copy = visit
            copy.title = clean
            return copy
        }
    }

    static func typedForms(_ url: String) -> [String] {
        let bare = url.replacingOccurrences(of: #"^https?://"#, with: "", options: [.regularExpression, .caseInsensitive])
        let noWww = bare.replacingOccurrences(of: #"^www\."#, with: "", options: [.regularExpression, .caseInsensitive])
        return noWww == bare ? [url, bare] : [url, bare, noWww]
    }

    public static func score(_ visit: BrowserVisit, typed: String) -> Int {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return 0 }
        let url = visit.url.lowercased(), title = visit.title.lowercased()
        if typedForms(url).dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 4 }
        if url.hasPrefix(needle) { return 3 }
        if title.hasPrefix(needle) { return 2 }
        if url.contains(needle) || title.contains(needle) { return 1 }
        return 0
    }

    public static func suggest(_ list: [BrowserVisit], profileID: String, typed: String, limit: Int = 8) -> [BrowserVisit] {
        let scored = list.compactMap { visit -> (BrowserVisit, Int)? in
            guard visit.profileID == profileID else { return nil }
            let s = score(visit, typed: typed)
            return s > 0 ? (visit, s) : nil
        }
        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.visits != b.0.visits { return a.0.visits > b.0.visits }
            return a.0.visitedAt > b.0.visitedAt
        }.prefix(limit).map(\.0)
    }

    public static func forget(_ list: [BrowserVisit], profileID: String, url: String) -> [BrowserVisit] {
        list.filter { !($0.profileID == profileID && $0.url == url) }
    }

    public static func clear(_ list: [BrowserVisit], profileID: String) -> [BrowserVisit] {
        list.filter { $0.profileID != profileID }
    }

    public static func encode(_ list: [BrowserVisit]) -> Data {
        (try? JSONEncoder().encode(Saved(version: 1, entries: list))) ?? Data()
    }

    /// Forgiving: an unreadable row is dropped, never the whole history.
    public static func decode(_ data: Data?) -> [BrowserVisit] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["entries"] as? [Any] else { return [] }
        return rows.compactMap { row in
            guard let fields = row as? [String: Any],
                  let profileID = fields["profileID"] as? String, !profileID.isEmpty,
                  let url = visitable((fields["url"] as? String) ?? "") else { return nil }
            let visits = (fields["visits"] as? NSNumber)?.intValue ?? 1
            return BrowserVisit(profileID: profileID, url: url, title: cleanTitle((fields["title"] as? String) ?? ""),
                                visitedAt: (fields["visitedAt"] as? NSNumber)?.doubleValue ?? 0, visits: max(1, visits))
        }
    }

    private struct Saved: Codable {
        var version: Int
        var entries: [BrowserVisit]
    }
}

extension BrowserHistory {
    /// The address field's inline completion (`completionFor` in history-view.ts):
    /// what was typed, finished from a visited address — or nil. Never for a
    /// search (spaces) and never when nothing would be added.
    public static func completion(typed: String, url: String) -> String? {
        if typed.trimmingCharacters(in: .whitespaces).isEmpty || typed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return nil
        }
        let bare = url.replacingOccurrences(of: #"^https?://"#, with: "", options: [.regularExpression, .caseInsensitive])
        let noWww = bare.replacingOccurrences(of: #"^www\."#, with: "", options: [.regularExpression, .caseInsensitive])
        let lower = typed.lowercased()
        for candidate in [noWww, bare, url] {
            // `example.com/` reads as `example.com`: a bare host's own slash is not part of what anyone types.
            let trimmed = candidate.hasSuffix("/") && candidate.firstIndex(of: "/") == candidate.index(before: candidate.endIndex)
                ? String(candidate.dropLast()) : candidate
            if trimmed.lowercased().hasPrefix(lower) && trimmed.count > typed.count {
                return typed + trimmed.dropFirst(typed.count)
            }
        }
        return nil
    }
}
