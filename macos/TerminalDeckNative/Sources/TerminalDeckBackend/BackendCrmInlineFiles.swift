import Foundation
import TerminalDeckNativeCore

/// src/shared/crm/inline-files.ts. Editor positions and the visible-title cap
/// count UTF-16 units, exactly as JavaScript string indices do.
public enum BackendCrmInlineFiles {
    public static let visibleTitleMax = 300, rawTitleMax = 4000
    public static let chipChar = "\u{FFFC}"
    public typealias InlinePart = CrmText.Part
    public struct Edit: Sendable, Equatable {
        public let text: String
        public let caret: Int
        public init(text: String, caret: Int) { self.text = text; self.caret = caret }
    }
    static let tokenPattern = #"\[\[file:((?:draft:)?[A-Za-z0-9_-]+)\]\]"#
    static func matches(_ text: String) -> [NSTextCheckingResult] {
        let re = try! NSRegularExpression(pattern: tokenPattern)
        return re.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }
    static func slice(_ text: String, _ start: Int, _ end: Int? = nil) -> String {
        let units = Array(text.utf16), count = units.count
        let a = max(0, min(start, count)), b = max(a, min(end ?? count, count))
        return String(decoding: units[a..<b], as: UTF16.self)
    }
    static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: template)
    }
    static func replacingTokens(_ text: String, _ transform: (String, String) -> String) -> String {
        let source = text as NSString
        var out = "", last = 0
        for match in matches(text) {
            out += source.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(source.substring(with: match.range), source.substring(with: match.range(at: 1)))
            last = NSMaxRange(match.range)
        }
        out += source.substring(from: last)
        return out
    }
    public static func fileToken(_ id: String) -> String { CrmText.fileToken(id) }
    public static func draftFileId(_ key: String) -> String { "draft:" + key }
    public static func isDraftFileId(_ id: String) -> Bool { id.hasPrefix("draft:") }
    public static func splitInlineFiles(_ text: String) -> [InlinePart] {
        let source = text as NSString
        var out: [InlinePart] = [], last = 0
        for match in matches(text) {
            if match.range.location > last { out.append(.text(source.substring(with: NSRange(location: last, length: match.range.location - last)))) }
            out.append(.file(source.substring(with: match.range(at: 1))))
            last = NSMaxRange(match.range)
        }
        if last < source.length { out.append(.text(source.substring(from: last))) }
        return out
    }
    public static func fileTokenIds(_ text: String) -> [String] {
        splitInlineFiles(text).compactMap { if case .file(let id) = $0 { id } else { nil } }
    }
    public static func countFileTokens(_ text: String) -> Int { fileTokenIds(text).count }
    public static func stripFileTokens(_ text: String) -> String {
        let without = replacingTokens(text) { _, _ in "" }
        let spaces = replace(without, #"[ \t]{2,}"#, " ")
        let lines = replace(spaces, #"\n{3,}"#, "\n\n")
        return replace(lines, #"(?m)^[ \t]+|[ \t]+$"#, "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func visibleLength(_ text: String) -> Int { replacingTokens(text) { _, _ in "" }.utf16.count }
    public static func truncateVisible(_ text: String, max maximum: Int = visibleTitleMax) -> String {
        if visibleLength(text) <= maximum { return text }
        var out = "", seen = 0
        for part in splitInlineFiles(text) {
            switch part {
            case .file(let id): out += fileToken(id)
            case .text(let run):
                let room = maximum - seen
                if room > 0 { let take = slice(run, 0, room); out += take; seen += take.utf16.count }
            }
        }
        return out
    }
    /// Presence of a key with nil means remove that placement.
    public static func rewriteFileTokens(_ text: String, map: [String: String?]) -> String {
        let rewritten = replacingTokens(text) { whole, id in
            guard let entry = map[id] else { return whole }
            return entry.flatMap { $0.isEmpty ? nil : fileToken($0) } ?? ""
        }
        if rewritten == text { return text }
        let folded = replace(rewritten, #"[ \t]{2,}"#, " ")
        return replace(folded, #"(?m)[ \t]+$"#, "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func insertAt(_ text: String, index: Int, snippet: String, spaced: Bool = true) -> Edit {
        let i = max(0, min(index, text.utf16.count)), before = slice(text, 0, i), after = slice(text, i)
        let lead = spaced && !before.isEmpty && before.last?.isWhitespace != true ? " " : ""
        let tail = spaced && !after.isEmpty && after.first?.isWhitespace != true ? " " : ""
        let inserted = lead + snippet + tail
        return Edit(text: before + inserted + after, caret: i + inserted.utf16.count)
    }
    public static func toFlat(_ text: String) -> String { replacingTokens(text) { _, _ in chipChar } }
    public static func fromFlat(_ flat: String, ids: [String]) -> String {
        var out = "", k = 0
        for scalar in flat.unicodeScalars {
            if scalar.value == 0xFFFC {
                if k < ids.count && !ids[k].isEmpty { out += fileToken(ids[k]) }
                k += 1
            } else { out.unicodeScalars.append(scalar) }
        }
        return out
    }
    public static func plainTextForField(_ text: String) -> String {
        let lines = replace(text, #"\r\n?"#, "\n")
        return replacingTokens(lines) { _, _ in "" }.replacingOccurrences(of: chipChar, with: "").replacingOccurrences(of: "\u{200B}", with: "")
    }
    static func countChips(_ text: String) -> Int { text.unicodeScalars.filter { $0.value == 0xFFFC }.count }
    public static func spliceStorage(_ text: String, start: Int, end: Int, insert: String) -> Edit {
        let flat = toFlat(text), ids = fileTokenIds(text), s = max(0, min(start, flat.utf16.count))
        let e = max(s, min(end, flat.utf16.count)), clean = plainTextForField(insert), before = slice(flat, 0, s)
        let kBefore = countChips(before), kGone = countChips(slice(flat, s, e))
        let nextIds = Array(ids.prefix(kBefore)) + Array(ids.dropFirst(kBefore + kGone))
        return Edit(text: fromFlat(before + clean + slice(flat, e), ids: nextIds), caret: s + clean.utf16.count)
    }
    public static func insertFileAt(_ text: String, at: Int, id: String, spaced: Bool = true) -> Edit {
        let flat = toFlat(text), ids = fileTokenIds(text), i = max(0, min(at, flat.utf16.count))
        let kBefore = countChips(slice(flat, 0, i)), placed = insertAt(flat, index: i, snippet: chipChar, spaced: spaced)
        return Edit(text: fromFlat(placed.text, ids: Array(ids.prefix(kBefore)) + [id] + Array(ids.dropFirst(kBefore))), caret: placed.caret)
    }
    public static func visibleInFlatRange(_ text: String, start: Int, end: Int) -> Int {
        let flat = toFlat(text), count = flat.utf16.count
        let s = start < 0 ? max(0, count + start) : min(count, start)
        let e = end < 0 ? max(0, count + end) : min(count, end)
        return slice(flat, s, max(s, e)).replacingOccurrences(of: chipChar, with: "").utf16.count
    }
}
