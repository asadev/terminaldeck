import Foundation

/// Files, the native screen's pure half — the Swift reading of
/// `components/FileTree.tsx`, `components/FileViewer.tsx` and the Files page in
/// `shell/PanelView.tsx`, rule for rule. A folder is listed with `fs:list`, a
/// file read with `fs:read`.

public struct FsEntry: Equatable, Sendable, Identifiable {
    public var name: String
    public var relPath: String
    public var isDir: Bool
    public var symlink: Bool
    /// A link that leaves the project, or loops: shown, never opened.
    public var blocked: Bool
    public var id: String { relPath }

    public init(name: String, relPath: String, isDir: Bool, symlink: Bool = false, blocked: Bool = false) {
        self.name = name
        self.relPath = relPath
        self.isDir = isDir
        self.symlink = symlink
        self.blocked = blocked
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any], let relPath = row["relPath"] as? String, !relPath.isEmpty else { return nil }
        self.init(name: row["name"] as? String ?? relPath, relPath: relPath, isDir: row["kind"] as? String == "dir",
                  symlink: row["symlink"] as? Bool ?? false, blocked: row["blocked"] as? Bool ?? false)
    }
}

public struct DirListing: Equatable, Sendable {
    public var relPath: String
    public var entries: [FsEntry]
    public var truncated: Bool
    /// The file the engine suggests opening first in this folder (a README), at the root only.
    public var defaultFile: String?

    public init(relPath: String = "", entries: [FsEntry], truncated: Bool = false, defaultFile: String? = nil) {
        self.relPath = relPath
        self.entries = entries
        self.truncated = truncated
        self.defaultFile = defaultFile
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let entries = row["entries"] as? [Any] else { return nil }
        self.init(relPath: row["relPath"] as? String ?? "", entries: entries.compactMap(FsEntry.init(json:)),
                  truncated: row["truncated"] as? Bool ?? false,
                  defaultFile: (row["defaultFile"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// What the tree says about its root: still listing, listed, empty, or failed.
public enum TreeRootState: Equatable, Sendable {
    case loading
    case ready(count: Int)
    case empty
    case error(String)
}

/// The tree's state, as `FileTree.tsx`'s reducer keeps it. A value: the screen
/// holds one and calls these as the reducer's actions.
public struct FileTreeState: Equatable, Sendable {
    public static let root = ""

    public var children: [String: [FsEntry]] = [:]
    public var expanded: Set<String> = []
    public var loading: Set<String> = []
    public var errors: [String: String] = [:]
    public var truncated: Set<String> = []
    public var focused: String?

    public init() {}

    public mutating func expand(_ dir: String) { expanded.insert(dir) }
    public mutating func collapse(_ dir: String) { expanded.remove(dir) }
    public mutating func focus(_ relPath: String?) { focused = relPath }

    public mutating func loadStarted(_ dir: String) {
        errors[dir] = nil
        if dir != Self.root { expanded.insert(dir) }
        loading.insert(dir)
    }

    public mutating func loaded(_ dir: String, _ listing: DirListing) {
        children[dir] = listing.entries
        loading.remove(dir)
        if listing.truncated { truncated.insert(dir) } else { truncated.remove(dir) }
        if focused == nil, dir == Self.root { focused = listing.entries.first?.relPath }
    }

    public mutating func failed(_ dir: String, _ message: String) {
        errors[dir] = message
        loading.remove(dir)
        expanded.remove(dir)
    }

    /// Loading until the root has actually been listed; empty only when it came back with nothing.
    public var rootState: TreeRootState {
        if let message = errors[Self.root] { return .error(message) }
        guard let entries = children[Self.root] else { return .loading }
        return entries.isEmpty ? .empty : .ready(count: entries.count)
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let entry: FsEntry
        public let depth: Int
        public var id: String { entry.relPath }
    }

    /// Every row on screen: each folder's entries, and an open folder's below it.
    public var rows: [Row] {
        var out: [Row] = []
        func walk(_ dir: String, _ depth: Int) {
            for entry in children[dir] ?? [] {
                out.append(Row(entry: entry, depth: depth))
                if entry.isDir && expanded.contains(entry.relPath) { walk(entry.relPath, depth + 1) }
            }
        }
        walk(Self.root, 0)
        return out
    }

    public static func parent(of relPath: String) -> String {
        guard let cut = relPath.lastIndex(of: "/") else { return root }
        return String(relPath[..<cut])
    }

    /// What pressing a folder (or →) does: close it, open it from what is held, or list it.
    public enum Toggle: Equatable, Sendable { case none, collapse, expand, load }

    public func toggle(_ entry: FsEntry) -> Toggle {
        guard entry.isDir, !entry.blocked else { return .none }
        if expanded.contains(entry.relPath) { return .collapse }
        return children[entry.relPath] != nil ? .expand : .load
    }

    /// The tree's keyboard, as `onKeyDown` handles it.
    public enum Key: Sendable { case down, up, right, left, home, end, activate }
    public enum KeyEffect: Equatable, Sendable { case none, focus(String), toggle(FsEntry), collapse(String), activate(FsEntry) }

    public func effect(of key: Key) -> KeyEffect {
        let rows = self.rows
        guard !rows.isEmpty else { return .none }
        let index = rows.firstIndex { $0.entry.relPath == focused } ?? -1
        let entry = index >= 0 ? rows[index].entry : nil
        func at(_ i: Int) -> KeyEffect { .focus(rows[max(0, min(i, rows.count - 1))].entry.relPath) }
        switch key {
        case .down: return at(index + 1)
        case .up: return at(index == -1 ? 0 : index - 1)
        case .right:
            guard let entry, entry.isDir, !entry.blocked else { return .none }
            return expanded.contains(entry.relPath) ? at(index + 1) : .toggle(entry)
        case .left:
            guard let entry else { return .none }
            if entry.isDir && expanded.contains(entry.relPath) { return .collapse(entry.relPath) }
            let parent = Self.parent(of: entry.relPath)
            return parent == Self.root ? .none : .focus(parent)
        case .home: return at(0)
        case .end: return at(rows.count - 1)
        case .activate: return entry.map(KeyEffect.activate) ?? .none
        }
    }
}

/// A read file, from `fs:read`.
public enum FileRead: Equatable, Sendable {
    case text(relPath: String, text: String, bytes: Int)
    case binary(relPath: String, bytes: Int)
    case tooLarge(relPath: String, bytes: Int, limit: Int)

    public init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        let relPath = row["relPath"] as? String ?? ""
        let bytes = Int(DeviceJSON.number(row["bytes"]))
        switch row["kind"] as? String {
        case "text": self = .text(relPath: relPath, text: row["text"] as? String ?? "", bytes: bytes)
        case "binary": self = .binary(relPath: relPath, bytes: bytes)
        case "too-large": self = .tooLarge(relPath: relPath, bytes: bytes, limit: Int(DeviceJSON.number(row["limit"])))
        default: return nil
        }
    }

    public var bytes: Int {
        switch self {
        case let .text(_, _, bytes), let .binary(_, bytes), let .tooLarge(_, bytes, _): bytes
        }
    }
}

public enum FilesPageLayout: Equatable, Sendable { case treeAndViewer, treeOnly, blank }

public enum FilesRules {
    public static let listDeadlineSeconds = 10.0
    public static let readDeadlineSeconds = 10.0
    /// A tree read this recently is shown without asking again.
    public static let treeFreshSeconds = 10.0
    /// A file read this recently is shown without reading it again.
    public static let readFreshSeconds = 5.0
    public static let maxCachedBytes = 256 * 1024
    public static let highlightMaxChars = 200_000
    public static let maxViewLines = 50_000
    /// The viewer's "Nothing to open" waits this long, so it never flashes before the tree opens a file.
    public static let emptyGraceSeconds = 0.3

    /// Loading keeps the viewer (it has its own loading state); an empty root is the blank page; a failed root is the tree alone.
    public static func layout(_ tree: TreeRootState) -> FilesPageLayout {
        switch tree {
        case .empty: .blank
        case .error: .treeOnly
        default: .treeAndViewer
        }
    }

    public static func blankReason(root: String, showIgnored: Bool) -> String {
        showIgnored ? "Nothing at all in \(root), ignored files included." : "Nothing in \(root) that your .gitignore does not exclude."
    }

    /// "Reading this folder", or "Reading src/lib".
    public static func listWhat(_ dir: String) -> String { dir.isEmpty ? "Reading this folder" : "Reading \(dir)" }

    /// "Reading a.ts".
    public static func readWhat(_ relPath: String) -> String { "Reading \(name(of: relPath))" }

    /// Open the root's suggested file once per project, only when nothing is open and the caller wants it.
    public static func shouldAutoOpen(autoSelect: Bool, dir: String, root: String, openedFor: String?, selected: String?) -> Bool {
        guard autoSelect, dir == FileTreeState.root, openedFor != root else { return false }
        return selected == nil || selected!.isEmpty
    }

    /// The row's hover: the path, or why a link cannot be followed.
    public static func rowTitle(_ entry: FsEntry) -> String {
        entry.blocked ? "\(entry.name) — link leaves the project, or loops" : entry.relPath
    }

    public static let truncatedLine = "Too many entries — list shortened."

    // MARK: The viewer

    public static func name(of relPath: String) -> String {
        relPath.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? relPath
    }

    public static func extensionOf(_ relPath: String) -> String {
        let name = name(of: relPath)
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    /// `512 B`, `2.0 KB`, `5.0 MB`.
    public static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// `3 lines · 24 B`, only once the file is read as text.
    public static func viewerMeta(lines: Int?, read: FileRead?) -> String {
        guard let lines, case let .text(_, _, bytes)? = read else { return "" }
        return "\(grouped(lines)) lines · \(formatBytes(bytes))"
    }

    public static func tooLargeLine(bytes: Int, limit: Int) -> String {
        "This file is \(formatBytes(bytes)), over the \(formatBytes(limit)) viewer limit. Open it in your editor instead."
    }

    public static func binaryLine(bytes: Int) -> String {
        "Binary file — \(formatBytes(bytes)). Nothing readable to show."
    }

    public static func errorLine(_ message: String) -> String { "Could not open this file — \(message)" }

    public static func shownLine(shown: Int, count: Int) -> String {
        "Showing the first \(grouped(shown)) of \(grouped(count)) lines. Open it in your editor to see the rest."
    }

    /// The text as shown: the final newline dropped, at most `maxViewLines` lines, and how many there were.
    public static func document(_ text: String) -> (source: String, count: Int, shown: Int) {
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        var count = 1
        var cut: String.Index?
        for scalarIndex in trimmed.unicodeScalars.indices where trimmed.unicodeScalars[scalarIndex] == "\n" {
            count += 1
            if count == maxViewLines + 1 { cut = scalarIndex }
        }
        let shown = min(count, maxViewLines)
        return (cut.map { String(trimmed[..<$0]) } ?? trimmed, count, shown)
    }

    /// `1\n2\n3` for the gutter.
    public static func gutter(_ count: Int) -> String {
        (1...max(1, count)).map(String.init).joined(separator: "\n")
    }
}

// MARK: - Colouring

public enum TokenKind: String, Sendable, Equatable { case plain, comment, string, number, keyword, meta }

public struct Token: Equatable, Sendable {
    public var kind: TokenKind
    public var text: String
}

public enum Language: String, Sendable, Equatable { case js, json, css, shell, yaml, markdown }

public enum Highlighter {
    static let extensions: [String: Language] = [
        "ts": .js, "tsx": .js, "mts": .js, "cts": .js, "js": .js, "jsx": .js, "mjs": .js, "cjs": .js,
        "json": .json, "jsonc": .json, "css": .css, "sh": .shell, "bash": .shell, "zsh": .shell,
        "yml": .yaml, "yaml": .yaml, "md": .markdown, "markdown": .markdown,
    ]

    /// The language a file is coloured as, or nil — an unknown extension is left uncoloured rather than guessed.
    public static func language(of relPath: String) -> Language? {
        extensions[FilesRules.extensionOf(relPath).lowercased()]
    }

    struct Grammar {
        var keywords: Set<String>
        var lineComment: [String]
        var blockComment: Bool
        var quotes: [Unicode.Scalar]
        var hashNeedsBoundary = false
        var rawSingleQuote = false
        var atRules = false
        var yamlKeys = false
    }

    static let jsKeywords: Set<String> = Set(("await break case catch class const continue debugger default delete do else enum export " +
        "extends false finally for from function if implements import in instanceof interface let " +
        "new null of private protected public readonly return satisfies static super switch this " +
        "throw true try type typeof undefined var void while with yield as async declare abstract " +
        "keyof infer namespace override").split(separator: " ").map(String.init))

    static let shellKeywords: Set<String> = Set(("if then elif else fi for while until do done case esac function return export local readonly " +
        "set unset shift source exit trap in select time").split(separator: " ").map(String.init))

    static func grammar(_ language: Language) -> Grammar {
        switch language {
        case .js: Grammar(keywords: jsKeywords, lineComment: ["//"], blockComment: true, quotes: ["'", "\"", "`"])
        case .json: Grammar(keywords: ["true", "false", "null"], lineComment: ["//"], blockComment: true, quotes: ["\""])
        case .css: Grammar(keywords: [], lineComment: [], blockComment: true, quotes: ["'", "\""], atRules: true)
        case .shell: Grammar(keywords: shellKeywords, lineComment: ["#"], blockComment: false, quotes: ["'", "\""],
                             hashNeedsBoundary: true, rawSingleQuote: true)
        case .yaml, .markdown: Grammar(keywords: ["true", "false", "null", "yes", "no"], lineComment: ["#"], blockComment: false,
                                       quotes: ["'", "\""], hashNeedsBoundary: true, yamlKeys: true)
        }
    }

    public static func tokenize(_ source: String, _ language: Language) -> [Token] {
        language == .markdown ? markdown(source) : code(source, grammar(language))
    }

    static func isWord(_ c: Unicode.Scalar) -> Bool { isIdent(c) || c == "-" }
    static func isIdentStart(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.letters.contains(c) || c == "_" || c == "$") }
    static func isIdent(_ c: Unicode.Scalar) -> Bool { c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "$") }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
    static func isSpace(_ c: Unicode.Scalar) -> Bool { CharacterSet.whitespacesAndNewlines.contains(c) }

    static func code(_ source: String, _ grammar: Grammar) -> [Token] {
        let s = Array(source.unicodeScalars)
        var out: [Token] = []
        var plainFrom = 0
        var i = 0
        var lineHead = true
        func text(_ a: Int, _ b: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: s[a..<b])
            return String(view)
        }
        func flush(_ end: Int) { if end > plainFrom { out.append(Token(kind: .plain, text: text(plainFrom, end))) } }
        func emit(_ kind: TokenKind, _ end: Int) {
            flush(i)
            out.append(Token(kind: kind, text: text(i, end)))
            i = end
            plainFrom = end
        }
        func starts(_ prefix: String, at index: Int) -> Bool {
            let p = Array(prefix.unicodeScalars)
            guard index + p.count <= s.count else { return false }
            return Array(s[index..<index + p.count]) == p
        }
        func find(_ needle: String, from: Int) -> Int? {
            var k = from
            while k < s.count { if starts(needle, at: k) { return k }; k += 1 }
            return nil
        }
        func endOfString(_ start: Int) -> Int {
            let quote = s[start]
            let multiline = quote == "`"
            let escapes = !(grammar.rawSingleQuote && quote == "'")
            var k = start + 1
            while k < s.count {
                let ch = s[k]
                if escapes && ch == "\\" { k += 2; continue }
                if ch == quote { return k + 1 }
                if ch == "\n" && !multiline { return k }
                k += 1
            }
            return s.count
        }
        while i < s.count {
            let ch = s[i]
            if ch == "\n" { lineHead = true; i += 1; continue }
            if grammar.blockComment && ch == "/" && i + 1 < s.count && s[i + 1] == "*" {
                emit(.comment, find("*/", from: i + 2).map { $0 + 2 } ?? s.count)
                continue
            }
            let marker = grammar.lineComment.first { starts($0, at: i) }
            let boundary = marker != "#" || !grammar.hashNeedsBoundary || i == 0 || s[i - 1] == "\n" || isSpace(s[i - 1])
            if marker != nil && boundary {
                emit(.comment, find("\n", from: i) ?? s.count)
                continue
            }
            if grammar.quotes.contains(ch) {
                emit(.string, endOfString(i))
                lineHead = false
                continue
            }
            if grammar.atRules && ch == "@" && i + 1 < s.count && isIdentStart(s[i + 1]) {
                var end = i + 1
                while end < s.count && isIdent(s[end]) { end += 1 }
                emit(.keyword, end)
                continue
            }
            if isDigit(ch) && !(i > 0 && isIdent(s[i - 1])) {
                var end = i
                while end < s.count && (isIdent(s[end]) && s[end] != "$" || s[end] == ".") { end += 1 }
                emit(.number, end)
                lineHead = false
                continue
            }
            if isIdentStart(ch) {
                var end = i
                while end < s.count && isWord(s[end]) { end += 1 }
                let word = text(i, end)
                if grammar.yamlKeys && lineHead && end < s.count && s[end] == ":" {
                    emit(.meta, end)
                    lineHead = false
                    continue
                }
                if grammar.keywords.contains(word) { emit(.keyword, end) } else { i = end }
                lineHead = false
                continue
            }
            if grammar.yamlKeys && ch == "-" { i += 1; continue }
            if !isSpace(ch) { lineHead = false }
            i += 1
        }
        flush(s.count)
        return out
    }

    static func markdown(_ source: String) -> [Token] {
        var out: [Token] = []
        var fenced = false
        var rest = Substring(source)
        while !rest.isEmpty {
            let line: Substring
            let body: Substring
            if let nl = rest.firstIndex(of: "\n") {
                line = rest[...nl]
                body = rest[..<nl]
            } else {
                line = rest
                body = rest
            }
            let lead = body.prefix { $0 == " " || $0 == "\t" }
            let afterLead = lead.count <= 3 ? body.dropFirst(lead.count) : body
            let indentOK = lead.count <= 3
            if indentOK && (afterLead.hasPrefix("```") || afterLead.hasPrefix("~~~")) {
                fenced.toggle()
                out.append(Token(kind: .comment, text: String(line)))
            } else if fenced {
                out.append(Token(kind: .string, text: String(line)))
            } else if indentOK && isHeading(afterLead) {
                out.append(Token(kind: .meta, text: String(line)))
            } else if indentOK && afterLead.hasPrefix(">") {
                out.append(Token(kind: .comment, text: String(line)))
            } else {
                out.append(Token(kind: .plain, text: String(line)))
            }
            rest = rest[line.endIndex...]
        }
        return out
    }

    static func isHeading(_ text: Substring) -> Bool {
        let hashes = text.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return false }
        let next = text.dropFirst(hashes).first
        return next.map { $0 == " " || $0 == "\t" } ?? false
    }
}
