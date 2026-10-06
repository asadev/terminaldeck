import Foundation

// The fuzzy matcher, ported from src/renderer/fuzzy.ts: the same scores, bonuses,
// gap rules and tie-breaks, so the native palette ranks exactly as the page's did.
// Like JavaScript it works in UTF-16 code units, so match ranges are the same numbers.

public struct MatchRange: Equatable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) { self.start = start; self.end = end }
}

public struct FuzzyResult: Equatable, Sendable {
    public let score: Int
    public let ranges: [MatchRange]
}

public struct Ranked<T> {
    public let item: T
    public let score: Int
    public let ranges: [MatchRange]
}

public enum Fuzzy {
    public enum Scores {
        public static let match = 16, boundary = 8, pathBoundary = 10, camel = 7, digit = 6
        public static let consecutive = 5, caseMatch = 1, firstCharMultiplier = 2, basename = 4
        public static let gapStart = -3, gapExtension = -1
    }

    static let noMatch = -1_000_000
    static let maxTextLength = 320
    static let maxQueryLength = 64
    static let maxTerms = 16

    // MARK: Public API (same names as fuzzy.ts)

    public static func match(_ text: String, _ query: String, smartCase: Bool = true, splitTerms: Bool = true) -> FuzzyResult? {
        let units = Array(text.utf16)
        let (clipped, offset) = clip(units)
        return shift(run(clipped, query, smartCase: smartCase, splitTerms: splitTerms, basenameFrom: clipped.count), offset)
    }

    public static func matchPath(_ path: String, _ query: String, smartCase: Bool = true, splitTerms: Bool = true) -> FuzzyResult? {
        let units = Array(path.utf16)
        let (clipped, offset) = clip(units)
        return shift(run(clipped, query, smartCase: smartCase, splitTerms: splitTerms, basenameFrom: basenameStart(clipped)), offset)
    }

    public static func basenameStart(_ path: String) -> Int { basenameStart(Array(path.utf16)) }

    static func basenameStart(_ units: [UInt16]) -> Int {
        let slash = units.lastIndex(of: 0x2F) ?? -1, backslash = units.lastIndex(of: 0x5C) ?? -1
        return max(slash, backslash) + 1
    }

    /// rankMatches: best first; an empty query keeps the caller's order.
    public static func rank<T>(_ items: [T], _ query: String, limit: Int = 50, path: Bool = false,
                               smartCase: Bool = true, text: (T) -> String) -> [Ranked<T>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return items.prefix(limit).map { Ranked(item: $0, score: 0, ranges: []) } }
        var scored: [Scored] = []
        for (i, item) in items.enumerated() {
            let t = text(item)
            let result = path ? matchPath(t, trimmed, smartCase: smartCase) : match(t, trimmed, smartCase: smartCase)
            if let result { scored.append(Scored(index: i, score: result.score, ranges: result.ranges, length: t.utf16.count)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.ranges.count != b.ranges.count { return a.ranges.count < b.ranges.count }
            let aStart = a.ranges.first?.start ?? 0, bStart = b.ranges.first?.start ?? 0
            if aStart != bStart { return aStart < bStart }
            if a.length != b.length { return a.length < b.length }
            return a.index < b.index
        }
        return scored.prefix(limit).map { Ranked(item: items[$0.index], score: $0.score, ranges: $0.ranges) }
    }

    /// segmentByRanges: the text cut into matched / unmatched runs (UTF-16 offsets).
    public static func segments(_ text: String, _ ranges: [MatchRange]) -> [(text: String, matched: Bool)] {
        let units = Array(text.utf16)
        func slice(_ a: Int, _ b: Int) -> String { String(decoding: units[a..<b], as: UTF16.self) }
        var out: [(String, Bool)] = []
        var cursor = 0
        for range in ranges {
            let start = max(range.start, cursor), end = min(range.end, units.count)
            if end <= start { continue }
            if start > cursor { out.append((slice(cursor, start), false)) }
            out.append((slice(start, end), true))
            cursor = end
        }
        if cursor < units.count { out.append((slice(cursor, units.count), false)) }
        return out
    }

    /// clampRanges: the ranges inside [from, to), rebased to `from`.
    public static func clamp(_ ranges: [MatchRange], from: Int, to: Int) -> [MatchRange] {
        ranges.compactMap { r in
            let start = max(r.start, from), end = min(r.end, to)
            return end > start ? MatchRange(start: start - from, end: end - from) : nil
        }
    }

    // MARK: The matcher

    static let classOther = 0, classLower = 1, classUpper = 2, classDigit = 3

    static func charClass(_ c: UInt16) -> Int {
        if c >= 0x61 && c <= 0x7A { return classLower }
        if c >= 0x41 && c <= 0x5A { return classUpper }
        if c >= 0x30 && c <= 0x39 { return classDigit }
        if c > 127 { return classLower } // é, ü, 名 behave like word characters
        return classOther
    }

    static func lower(_ units: [UInt16]) -> [UInt16] {
        units.map { u in
            if u >= 0x41 && u <= 0x5A { return u + 32 }
            if u < 128 { return u }
            guard let scalar = Unicode.Scalar(u) else { return u }
            let l = Array(String(Character(scalar)).lowercased().utf16)
            return l.count == 1 ? l[0] : u // length-changing lowercasing keeps the unit, keeping offsets aligned
        }
    }

    static func bonuses(_ text: [UInt16], basenameFrom: Int) -> [Int] {
        var out = [Int](repeating: 0, count: text.count)
        var previousClass = classOther
        var previousChar: UInt16 = 0
        for i in 0..<text.count {
            let ch = text[i]
            let cls = charClass(ch)
            var bonus = 0
            if cls != classOther && previousClass == classOther {
                bonus = (previousChar == 0x2F || previousChar == 0x5C) ? Scores.pathBoundary : Scores.boundary
            } else if previousClass == classLower && cls == classUpper {
                bonus = Scores.camel
            } else if previousClass != classDigit && cls == classDigit {
                bonus = Scores.digit
            }
            out[i] = i >= basenameFrom ? bonus + Scores.basename : bonus
            previousClass = cls
            previousChar = ch
        }
        return out
    }

    static func isSubsequence(_ haystack: [UInt16], _ needle: [UInt16], from: Int) -> Bool {
        var j = from
        for c in needle {
            guard let k = haystack[j...].firstIndex(of: c) else { return false }
            j = k + 1
        }
        return true
    }

    static func toRanges(_ indices: [Int]) -> [MatchRange] {
        var ranges: [MatchRange] = []
        for index in indices {
            if let last = ranges.last, last.end == index { ranges[ranges.count - 1].end = index + 1 }
            else { ranges.append(MatchRange(start: index, end: index + 1)) }
        }
        return ranges
    }

    static func matchTerm(_ text: [UInt16], _ lowerText: [UInt16], _ query: [UInt16], _ lowerQuery: [UInt16],
                          _ bonus: [Int], caseSensitive: Bool) -> FuzzyResult? {
        let n = text.count, m = query.count
        if m == 0 { return FuzzyResult(score: 0, ranges: []) }
        if m > n { return nil }
        let haystack = caseSensitive ? text : lowerText
        let needle = caseSensitive ? query : lowerQuery
        guard let start = haystack.firstIndex(of: needle[0]), let lastIndex = haystack.lastIndex(of: needle[m - 1]) else { return nil }
        let end = lastIndex + 1
        if end - start < m { return nil }
        if !isSubsequence(haystack, needle, from: start) { return nil }

        var previous = [Int](repeating: noMatch, count: n), current = [Int](repeating: noMatch, count: n)
        var previousRun = [Int](repeating: 0, count: n), currentRun = [Int](repeating: 0, count: n)
        var from = [Int](repeating: -1, count: m * n)

        for i in 0..<m {
            let qc = needle[i], qcRaw = query[i]
            for j in start..<end { current[j] = noMatch; currentRun[j] = 0 }
            var gap = noMatch
            var gapFrom = -1
            for j in start..<end {
                if i > 0 && j >= start + 2 {
                    let opening = previous[j - 2] + Scores.gapStart
                    let extending = gap + Scores.gapExtension
                    if opening >= extending { gap = opening; gapFrom = j - 2 } else { gap = extending }
                }
                if haystack[j] != qc { continue }
                let matchScore = Scores.match + (text[j] == qcRaw ? Scores.caseMatch : 0)
                if i == 0 {
                    current[j] = matchScore + bonus[j] * Scores.firstCharMultiplier
                    currentRun[j] = bonus[j]
                    continue
                }
                let adjacent = j > start ? previous[j - 1] : noMatch
                let runStartBonus = j > start ? previousRun[j - 1] : 0
                let runBonus = max(bonus[j], Scores.consecutive, runStartBonus)
                let viaRun = adjacent + matchScore + runBonus
                let viaGap = gap + matchScore + bonus[j]
                if viaRun >= viaGap {
                    current[j] = viaRun
                    currentRun[j] = j > start ? previousRun[j - 1] : bonus[j]
                    from[i * n + j] = j - 1
                } else {
                    current[j] = viaGap
                    currentRun[j] = bonus[j]
                    from[i * n + j] = gapFrom
                }
            }
            swap(&previous, &current)
            swap(&previousRun, &currentRun)
        }
        var best = noMatch, bestColumn = -1
        for j in start..<end where previous[j] > best { best = previous[j]; bestColumn = j }
        if bestColumn < 0 || best < noMatch / 2 { return nil }
        var indices = [Int](repeating: 0, count: m)
        var column = bestColumn
        for i in stride(from: m - 1, through: 0, by: -1) {
            indices[i] = column
            if i > 0 { column = from[i * n + column] }
        }
        return FuzzyResult(score: best, ranges: toRanges(indices))
    }

    static func mergeRanges(_ ranges: [MatchRange]) -> [MatchRange] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { $0.start < $1.start }
        var merged = [sorted[0]]
        for next in sorted.dropFirst() {
            if next.start <= merged[merged.count - 1].end { merged[merged.count - 1].end = max(merged[merged.count - 1].end, next.end) }
            else { merged.append(next) }
        }
        return merged
    }

    static func splitQuery(_ query: String, splitTerms: Bool) -> [[UInt16]] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if !splitTerms { return [Array(Array(trimmed.utf16).prefix(maxQueryLength))] }
        return trimmed.split(whereSeparator: \.isWhitespace).prefix(maxTerms).map { Array(Array(String($0).utf16).prefix(maxQueryLength)) }
    }

    static func run(_ text: [UInt16], _ query: String, smartCase: Bool, splitTerms: Bool, basenameFrom: Int) -> FuzzyResult? {
        let terms = splitQuery(query, splitTerms: splitTerms)
        if terms.isEmpty { return FuzzyResult(score: 0, ranges: []) }
        let bonus = bonuses(text, basenameFrom: basenameFrom)
        let lowerText = lower(text)
        var score = 0
        var ranges: [MatchRange] = []
        for term in terms {
            let caseSensitive = smartCase && term.contains { $0 >= 0x41 && $0 <= 0x5A }
            guard let result = matchTerm(text, lowerText, term, lower(term), bonus, caseSensitive: caseSensitive) else { return nil }
            score += result.score
            ranges += result.ranges
        }
        return FuzzyResult(score: score, ranges: mergeRanges(ranges))
    }

    static func clip(_ units: [UInt16]) -> ([UInt16], Int) {
        if units.count <= maxTextLength { return (units, 0) }
        let offset = units.count - maxTextLength
        return (Array(units[offset...]), offset)
    }

    static func shift(_ result: FuzzyResult?, _ offset: Int) -> FuzzyResult? {
        guard let result, offset != 0 else { return result }
        return FuzzyResult(score: result.score, ranges: result.ranges.map { MatchRange(start: $0.start + offset, end: $0.end + offset) })
    }
}

/// One match while ranking (`Fuzzy.rank`); kept outside it because a generic function can't nest a type.
private struct Scored { let index: Int; let score: Int; let ranges: [MatchRange]; let length: Int }
