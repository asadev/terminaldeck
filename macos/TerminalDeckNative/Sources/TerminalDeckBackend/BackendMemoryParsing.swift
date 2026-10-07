import Foundation
import TerminalDeckNativeCore

/// Shared flat front matter / Markdown rules from memory/note.ts and links.ts.
public enum BackendMemoryParsing {
    public struct Note: Sendable {
        public let front: [String: String]; public let body: String
        public let name: String?; public let title: String; public let links: [String]
    }
    static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))) ?? []
    }
    static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }; return String(text[range])
    }
    static func replace(_ text: String, _ pattern: String, _ with: String) -> String {
        (try? NSRegularExpression(pattern: pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)) ?? text
    }
    static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func cut(_ text: String, _ length: Int) -> String { cut(text, 0, length) }
    static func cut(_ text: String, _ start: Int, _ length: Int) -> String {
        String(decoding: text.utf16.dropFirst(max(0, start)).prefix(max(0, length)), as: UTF16.self)
    }
    static func unique(_ values: [String]) -> [String] { var seen = Set<String>(); return values.filter { seen.insert($0).inserted } }
    static func object(_ values: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(values.map { .init($0.0, $0.1) }) }
    static func strings(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
    static func optional(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    public static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard text.hasPrefix("---"), trim(lines[0]) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if trim(line) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { continue }
            let key = trim(String(line[..<colon]))
            let value = replace(trim(String(line[line.index(after: colon)...])), #"^["'](.*)["']$"#, "$1")
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }
    public static func bodyOf(_ text: String) -> String {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return text }
        guard let after = text[end.upperBound...].firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: after)...])
    }
    public static func wikiLinks(_ text: String) -> [String] {
        unique(matches(#"\[\[([^\]\n]+?)\]\]"#, text).map {
            trim(group($0, 1, text).components(separatedBy: "|")[0].components(separatedBy: "#")[0])
        }.filter { !$0.isEmpty })
    }
    public static func markdownLinks(_ text: String) -> [String] {
        unique(matches(#"(?<!!)\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#, text).compactMap {
            let raw = trim(group($0, 1, text).components(separatedBy: "#")[0])
            guard !raw.isEmpty, !raw.hasPrefix("/"), matches(#"(?i)^[a-z][a-z0-9+.-]*:"#, raw).isEmpty else { return nil }
            let decoded = raw.removingPercentEncoding ?? raw
            return decoded.lowercased().hasSuffix(".md") ? decoded : nil
        })
    }
    public static func noteLinks(_ text: String) -> [String] { unique(wikiLinks(text) + markdownLinks(text)) }
    public static func parseNote(_ text: String, file: String) -> Note {
        let front = frontMatter(text), body = bodyOf(text)
        let name = front["name"].map(trim).flatMap { $0.isEmpty ? nil : $0 }
        let heading = matches(#"(?m)^#\s+(.+)$"#, body).first.map { trim(group($0, 1, body)) }
        let base = URL(fileURLWithPath: file).lastPathComponent
        return Note(front: front, body: body, name: name, title: name ?? heading ?? replace(base, #"(?i)\.md$"#, ""), links: wikiLinks(body))
    }
    /// POSIX normalization, including leading ../ so escape detection remains visible.
    public static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." { parts.removeLast() }
            else { parts.append(part) }
        }
        let joined = parts.joined(separator: "/")
        return (path.hasPrefix("/") ? "/" : "") + (joined.isEmpty ? "." : joined)
    }
    static func dirname(_ path: String) -> String { path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : "." }
    public struct Linkable: Sendable {
        public let path: String; public let name: String?; public let links: [String]
        public init(path: String, name: String? = nil, links: [String] = []) { self.path = path; self.name = name; self.links = links }
    }
    public struct Resolver: Sendable {
        private var paths: [String: String] = [:], names: [String: String] = [:], bare: [String: [String]] = [:]
        private static func stem(_ path: String) -> String { replace(path, #"(?i)\.md$"#, "").lowercased() }
        public init(_ notes: [Linkable]) {
            for note in notes.sorted(by: { $0.path.localizedCompare($1.path) == .orderedAscending }) {
                paths[Self.stem(note.path)] = note.path
                if let name = note.name, names[name.lowercased()] == nil { names[name.lowercased()] = note.path }
                bare[Self.stem(URL(fileURLWithPath: note.path).lastPathComponent), default: []].append(note.path)
            }
        }
        public func resolve(from: String, target: String) -> String? {
            let written = trim(target).replacingOccurrences(of: "\\", with: "/")
            guard !written.isEmpty else { return nil }
            if written.contains("/") {
                for candidate in [dirname(from) + "/" + written, written] {
                    let normal = normalize(candidate)
                    if normal == ".." || normal.hasPrefix("../") { continue }
                    if let hit = paths[Self.stem(normal)] { return hit }
                }
                return nil
            }
            if !written.lowercased().hasSuffix(".md"), let named = names[written.lowercased()] { return named }
            let candidates = bare[Self.stem(written)] ?? []
            return candidates.first(where: { dirname($0) == dirname(from) }) ?? candidates.first
        }
    }
    public static func graph(_ notes: [Linkable]) -> MemoryGraph {
        let ordered = notes.sorted { $0.path < $1.path }, resolver = Resolver(notes)
        var seen = Set<String>(), edges: [MemoryEdge] = [], dangling: [MemoryDangling] = []
        for note in ordered { for target in note.links {
            guard let to = resolver.resolve(from: note.path, target: target) else { dangling.append(.init(from: note.path, target: target)); continue }
            if to != note.path, seen.insert(note.path + "\n" + to).inserted { edges.append(.init(from: note.path, to: to)) }
        } }
        return .init(nodes: ordered.map(\.path), edges: edges, dangling: dangling)
    }
    static func graphWire(_ graph: MemoryGraph) -> NativeRPCValue {
        object([("nodes", .array(graph.nodes.map { object([("path", .string($0))]) })),
            ("edges", .array(graph.edges.map { object([("from", .string($0.from)), ("to", .string($0.to))]) })),
            ("dangling", .array(graph.dangling.map { object([("from", .string($0.from)), ("target", .string($0.target))]) }))])
    }
}

/// BM25, title weight 3, Unicode terms and last-word prefix matching (text-index.ts).
public struct BackendMemoryTextIndex: Sendable {
    public struct Hit: Sendable { public let id: String; public let score: Double; public let snippet: String }
    private struct Entry: Sendable { let body: String; let frequency: [String: Int]; let length: Int }
    private var docs: [String: Entry] = [:], postings: [String: Set<String>] = [:]
    private var termOrder: [String] = []; private var totalLength = 0
    public init() {}
    public var size: Int { docs.count }
    public func has(_ id: String) -> Bool { docs[id] != nil }
    public static func tokens(_ text: String) -> [String] {
        BackendMemoryParsing.matches(#"[\p{L}\p{N}]+"#, text.lowercased()).map { BackendMemoryParsing.group($0, 0, text.lowercased()) }
    }
    public mutating func put(id: String, title: String, body: String) {
        remove(id)
        var frequency: [String: Int] = [:]
        for term in Self.tokens(title) { frequency[term, default: 0] += 3 }
        for term in Self.tokens(body) { frequency[term, default: 0] += 1 }
        for term in BackendMemoryParsing.unique(Self.tokens(title) + Self.tokens(body)) {
            if postings[term] == nil { termOrder.append(term) }
            postings[term, default: []].insert(id)
        }
        let length = frequency.values.reduce(0, +)
        docs[id] = Entry(body: body, frequency: frequency, length: length); totalLength += length
    }
    public mutating func remove(_ id: String) {
        guard let entry = docs.removeValue(forKey: id) else { return }
        for term in entry.frequency.keys {
            postings[term]?.remove(id)
            if postings[term]?.isEmpty == true { postings[term] = nil; termOrder.removeAll { $0 == term } }
        }
        totalLength -= entry.length
    }
    public func search(_ query: String, limit: Int = 20, filter: (String) -> Bool = { _ in true }) -> [Hit] {
        let words = Self.tokens(query)
        guard !words.isEmpty, !docs.isEmpty else { return [] }
        let average = Double(totalLength) / Double(docs.count); var scores: [String: Double] = [:]
        for (index, word) in words.enumerated() {
            let terms = index == words.count - 1 ? (postings[word] != nil && word.utf16.count < 3 ? [word] : termOrder.filter { $0.hasPrefix(word) }) : (postings[word] == nil ? [] : [word])
            for term in terms { let ids = postings[term] ?? []
                let idf = log(1 + (Double(docs.count - ids.count) + 0.5) / (Double(ids.count) + 0.5))
                for id in ids where filter(id) {
                    guard let entry = docs[id] else { continue }; let f = Double(entry.frequency[term] ?? 0)
                    scores[id, default: 0] += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * Double(entry.length) / average))
                }
            }
        }
        return scores.sorted { $0.value == $1.value ? $0.key.localizedCompare($1.key) == .orderedAscending : $0.value > $1.value }
            .prefix(max(0, limit)).map { .init(id: $0.key, score: $0.value, snippet: Self.snippet(docs[$0.key]?.body ?? "", words: words)) }
    }
    public static func snippet(_ body: String, words: [String]) -> String {
        let flat = BackendMemoryParsing.trim(BackendMemoryParsing.replace(body, #"\s+"#, " ")), lower = flat.lowercased() as NSString
        var at = NSNotFound
        for word in words { at = lower.range(of: word).location; if at != NSNotFound { break } }
        guard at != NSNotFound else { return BackendMemoryParsing.cut(flat, 160) }
        let start = max(0, at - 40)
        return (start > 0 ? "…" : "") + BackendMemoryParsing.cut(flat, start, 160) + (start + 160 < flat.utf16.count ? "…" : "")
    }
}
