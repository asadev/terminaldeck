import Foundation

// The command palette's rules, ported from src/renderer/components/CommandPalette.tsx:
// one query whose prefix is the mode (">" commands, "?" / "??" past sessions, else
// quick open with ":42" for a line), the same list movement, the same words.

public enum PaletteMode: String, Decodable, Sendable { case files, commands, sessions }

public struct PaletteCommand: Decodable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let group: String?
    public let shortcut: String?
    public let keywords: String?

    public init(id: String, title: String, group: String? = nil, shortcut: String? = nil, keywords: String? = nil) {
        self.id = id; self.title = title; self.group = group; self.shortcut = shortcut; self.keywords = keywords
    }

    /// commandSearchText: title, group and keywords (only the title is highlighted).
    public var searchText: String { [title, group, keywords].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
}

/// What the page hands the native palette.
public struct PaletteRequest: Decodable, Equatable, Sendable {
    public let mode: PaletteMode
    public let projectRoot: String?
    public let commands: [PaletteCommand]
}

public struct SessionSnippet: Decodable, Equatable, Sendable {
    public struct Span: Decodable, Equatable, Sendable { public let start: Int; public let length: Int }
    public let text: String
    public let ranges: [Span]
    public let truncatedStart: Bool
    public let truncatedEnd: Bool
}

public struct SessionHit: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let at: Double
    public let role: String
    public let tool: String?
    public let isSidechain: Bool
    public let projectName: String?
    public let snippet: SessionSnippet
}

public enum Palette {
    public static let maxResults = 60
    public static let pageJump = 8
    public static let maxRecents = 12
    public static let maxSessionHits = 40
    public static let sessionDebounce: Duration = .milliseconds(260)
    public static let searchRoles = ["user", "assistant", "thinking", "tool"]

    /// The seed query for how it was opened.
    public static func seed(mode: PaletteMode, projectRoot: String?) -> String {
        projectRoot == nil || mode == .commands ? ">" : (mode == .sessions ? "?" : "")
    }

    /// The mode a query is in (session mode first; no project → commands).
    public static func mode(of query: String, projectRoot: String?) -> PaletteMode {
        if projectRoot != nil && query.hasPrefix("?") { return .sessions }
        if query.hasPrefix(">") || projectRoot == nil { return .commands }
        return .files
    }

    public static func sessionScope(_ query: String) -> String { query.hasPrefix("??") ? "all" : "project" }

    /// sigilLength
    public static func sigilLength(_ query: String, sessionMode: Bool) -> Int {
        if sessionMode { return query.hasPrefix("??") ? 2 : 1 }
        return query.hasPrefix(">") ? 1 : 0
    }

    /// The query without its prefix (and, in files, without ":42").
    public static func term(of query: String, projectRoot: String?) -> (text: String, line: Int?) {
        let mode = mode(of: query, projectRoot: projectRoot)
        let raw = String(query.dropFirst(sigilLength(query, sessionMode: mode == .sessions)))
        return mode == .files ? parseFileQuery(raw) : (raw, nil)
    }

    /// parseFileQuery: "name:42" → ("name", 42); ":0" or an absurd number is part of the name.
    public static func parseFileQuery(_ raw: String) -> (text: String, line: Int?) {
        guard let match = raw.range(of: #"^(.*?):(\d+)\s*$"#, options: .regularExpression) else { return (raw, nil) }
        let whole = String(raw[match])
        guard let colon = whole.lastIndex(of: ":") else { return (raw, nil) }
        let text = String(whole[..<colon])
        let digits = whole[whole.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return (raw, nil) }
        guard let line = Int(digits), line >= 1, line <= 1_000_000_000 else { return (raw, nil) }
        return (text, line)
    }

    /// nextIndex
    public static func nextIndex(_ current: Int, count: Int, delta: Int, wrap: Bool) -> Int {
        if count <= 0 { return 0 }
        let from = max(0, min(current, count - 1))
        let target = from + delta
        if !wrap { return max(0, min(count - 1, target)) }
        return ((target % count) + count) % count
    }

    /// recentsFirst
    public static func recentsFirst(_ files: [String], recents: [String]) -> [String] {
        if recents.isEmpty { return files }
        let known = Set(files)
        let lead = recents.filter { known.contains($0) }
        if lead.isEmpty { return files }
        let leadSet = Set(lead)
        return lead + files.filter { !leadSet.contains($0) }
    }

    /// ROLE_LABEL
    public static func roleLabel(_ role: String) -> String {
        ["user": "You", "assistant": "Reply", "thinking": "Thinking", "tool": "Tool", "system": "System"][role] ?? role
    }

    /// snippetRanges: valid spans, in order, as MatchRanges.
    public static func snippetRanges(_ snippet: SessionSnippet) -> [MatchRange] {
        let length = snippet.text.utf16.count
        return snippet.ranges.filter { $0.length > 0 && $0.start >= 0 && $0.start < length }
            .sorted { $0.start < $1.start }
            .map { MatchRange(start: $0.start, end: $0.start + $0.length) }
    }

    public static func label(_ mode: PaletteMode) -> String {
        switch mode {
        case .sessions: "Past sessions"
        case .commands: "Command palette"
        case .files: "Quick open"
        }
    }

    public static func placeholder(_ mode: PaletteMode, scope: String, projectRoot: String?) -> String {
        switch mode {
        case .sessions: scope == "all" ? "Search every project’s past sessions" : "Search everything past sessions said and did"
        case .commands: "Run a command…"
        case .files: projectRoot != nil ? "Search files by name — add :42 for a line" : "Open a project to search files"
        }
    }

    /// paletteEmptyMessage
    public static func emptyMessage(mode: PaletteMode, term: String, scope: String,
                                    sessionsUnavailable: Bool = false, sessionsError: String? = nil, searching: Bool = false,
                                    filesLoading: Bool = false, filesUnavailable: Bool = false) -> String {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .sessions:
            if sessionsUnavailable { return "Past-session search is not connected to the main process." }
            if let sessionsError { return sessionsError }
            if searching { return "Reading past sessions…" }
            if t.count < 2 { return "Type at least two characters. Quoted “phrases” and -exclusions work." }
            return scope == "all" ? "Nothing on this machine said “\(t)”." : "Nothing in this project’s sessions. Start the query with ?? to search every project."
        case .files:
            if filesUnavailable { return "Could not read this project’s files." }
            if filesLoading { return "Reading project files…" }
            if t.isEmpty { return "No files found." }
            return "No matches for “\(t)”."
        case .commands:
            if t.isEmpty { return "No commands available." }
            return "No matches for “\(t)”."
        }
    }

    /// relativeTime: "just now", "5m ago", "3h ago", else the date.
    public static func relativeTime(_ at: Double, now: Double) -> String {
        if at == 0 { return "" }
        let delta = now - at
        let minute = 60_000.0, hour = 60 * minute, day = 24 * hour
        if delta < minute { return "just now" }
        if delta < hour { return "\(Int((delta / minute).rounded()))m ago" }
        if delta < day { return "\(Int((delta / hour).rounded()))h ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
    }
}
