import Foundation

// HelpPanel's rules (src/renderer/components/HelpPanel.tsx). Its words come from the
// page (`window.tdHelp`, native-help.ts), so they are never written twice.

public struct HelpSection: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let hint: String
}

public enum HelpBlock: Decodable, Equatable, Sendable {
    case text(String), note(String), code(String), steps([String]), bullets([String])

    enum CodingKeys: String, CodingKey { case kind, text, code, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "note": self = .note(try c.decode(String.self, forKey: .text))
        case "code": self = .code(try c.decode(String.self, forKey: .code))
        case "steps": self = .steps(try c.decode([String].self, forKey: .items))
        case "bullets": self = .bullets(try c.decode([String].self, forKey: .items))
        default: self = .text((try? c.decode(String.self, forKey: .text)) ?? "")
        }
    }

    var searchText: String {
        switch self {
        case .text(let t), .note(let t), .code(let t): t
        case .steps(let items), .bullets(let items): items.joined(separator: " ")
        }
    }
}

public struct HelpTopic: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let section: String
    public let title: String
    public let blocks: [HelpBlock]
    public let keywords: [String]?

    public init(id: String, section: String, title: String, blocks: [HelpBlock], keywords: [String]? = nil) {
        self.id = id; self.section = section; self.title = title; self.blocks = blocks; self.keywords = keywords
    }

    /// topicText
    var searchText: String {
        "\(title) \(blocks.map(\.searchText).joined(separator: " ")) \((keywords ?? []).joined(separator: " "))".lowercased()
    }
}

public struct HelpContent: Decodable, Equatable, Sendable {
    public let sections: [HelpSection]
    public let topics: [HelpTopic]
}

/// settings:about
public struct AboutInfo: Decodable, Equatable, Sendable {
    public let name: String
    public let tagline: String
    public let version: String
    public let electron: String
    public let chrome: String
    public let node: String
    public let v8: String
    public let platform: String
    public let arch: String
    public let packaged: Bool

    enum CodingKeys: String, CodingKey { case name, tagline, version, electron, chrome, chromium, node, v8, platform, arch, packaged }

    /// Lenient, as the page is: `settings:about` sends `chromium` (not `chrome`) and
    /// no `v8` or `packaged`; the page shows what it gets, so a missing field is empty
    /// (and a missing `packaged` reads as a development build, as on the page).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil ?? "" }
        name = text(.name)
        tagline = text(.tagline)
        version = text(.version)
        electron = text(.electron)
        let chrome = text(.chrome)
        self.chrome = chrome.isEmpty ? text(.chromium) : chrome
        node = text(.node)
        v8 = text(.v8)
        platform = text(.platform)
        arch = text(.arch)
        packaged = ((try? c.decodeIfPresent(Bool.self, forKey: .packaged)) ?? nil) ?? false
    }

    /// The card's rows.
    public var rows: [(String, String)] {
        [("Version", version + (packaged ? "" : " (development build)")), ("Electron", electron), ("Chromium", chrome),
         ("Node", node), ("V8", v8), ("Platform", "\(platform) \(arch)")]
    }

    /// "Copy version details".
    public var copyText: String {
        ["\(name) \(version)\(packaged ? "" : " (dev)")", "Electron \(electron) · Chromium \(chrome) · Node \(node)", "\(platform) \(arch)"]
            .joined(separator: "\n")
    }
}

public enum Help {
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// searchHelp: every term in the topic's title, words or keywords.
    public static func search(_ query: String, in topics: [HelpTopic]) -> [HelpTopic] {
        let terms = terms(query)
        if terms.isEmpty { return topics }
        return topics.filter { topic in terms.allSatisfy { topic.searchText.contains($0) } }
    }

    static let aboutKeywords = ["about", "version", "build", "electron", "chromium", "chrome", "node", "v8", "platform",
                                "arch", "release", "runtime", "bug", "report"]

    /// matchesAbout: the version card is a result only for its own words (or 3+ letter starts of them).
    public static func matchesAbout(_ query: String) -> Bool {
        let terms = terms(query)
        if terms.isEmpty { return false }
        return terms.allSatisfy { term in aboutKeywords.contains { $0 == term || (term.count >= 3 && $0.hasPrefix(term)) } }
    }

    /// fill: "{app}" → the app's name; `backticks` → inline code. (text, isCode) runs.
    public static func fill(_ text: String, appName: String) -> [(text: String, code: Bool)] {
        let parts = text.replacingOccurrences(of: "{app}", with: appName).components(separatedBy: "`")
        // An odd count of backticks leaves the last piece open: the page's regex keeps it as text.
        return parts.enumerated().compactMap { index, part in
            let code = index % 2 == 1 && (index < parts.count - 1)
            if part.isEmpty { return nil }
            return (code || index % 2 == 0 ? part : "`" + part, code)
        }
    }

    public static func resultLabel(_ count: Int) -> String { "\(count) \(count == 1 ? "result" : "results")" }
}
