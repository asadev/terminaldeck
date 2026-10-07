import Foundation
import TerminalDeckNativeCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// Port of src/main/browser-asset-coverage.ts: reading the page's own stated
/// total, comparing it to what was captured, and the append-only coverage log.
/// The digit-group reader is the existing BackendBrowserScrapingRegex.total
/// (same grouped-separator rules); this adds the match metadata and the
/// "more than one total" refusal it did not carry.
enum BackendS4AssetsCoverage {
    static let genericPatterns: [String] = [
        #"\bof\s+([\d][\d.,   ]*\d|\d)\b"#,
        #"\b([\d][\d.,   ]*\d|\d)\s+(?:results?|items?|listings?|records?|entries)\b"#,
        #"\b([\d][\d.,   ]*\d|\d)\s+total\b"#,
    ]
    static let maximumPatternCharacters = 300

    /// new RegExp(pattern, flags).exec(text) through the system JavaScript engine.
    /// nil = no match; throws the engine's message for a bad expression.
    struct Match { let whole: String; let group: String? }
    struct PatternError: Error { let message: String }
    static func exec(_ text: String, pattern: String, flags: String) throws -> Match? {
        #if canImport(JavaScriptCore)
        guard let context = JSContext(), let function = context.evaluateScript("""
          (function(text, pattern, flags) {
            const found = new RegExp(pattern, flags).exec(text);
            return found === null ? null : [found[0], found[1] === undefined ? null : found[1]];
          })
          """) else { throw PatternError(message: "the system JavaScript engine is unavailable") }
        context.exception = nil
        let value = function.call(withArguments: [text, pattern, flags])
        if let exception = context.exception { throw PatternError(message: exception.toString() ?? "unknown reason") }
        guard let value, !value.isNull, !value.isUndefined, let parts = value.toArray(), parts.count == 2, let whole = parts[0] as? String else { return nil }
        return Match(whole: whole, group: parts[1] as? String)
        #else
        throw PatternError(message: "the system JavaScript engine is unavailable")
        #endif
    }

    private static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > 80 ? String(flat.prefix(80)) + "…" : flat
    }
    private static func whole(_ number: Double) -> String { String(Int64(number)) }

    static func statedTotal(text: String, pattern: String?, flags: String?) -> NativeRPCValue {
        func none(_ reason: String) -> NativeRPCValue {
            BackendS4AssetsObject.make([("total", .null), ("pattern", .string("")), ("matched", .string("")), ("reason", .string(reason))])
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return none("there was no text to read") }
        let flags = flags ?? ""
        if flags.range(of: #"^[imsuy]*$"#, options: .regularExpression) == nil { return none("those are not flags a total pattern may carry") }
        if let pattern, !pattern.isEmpty {
            if pattern.utf16.count > maximumPatternCharacters { return none("the pattern is longer than \(maximumPatternCharacters) characters") }
            let found: Match?
            do { found = try exec(text, pattern: pattern, flags: flags) }
            catch let error as PatternError { return none("the pattern is not a valid expression: \(error.message)") }
            catch { return none("the pattern is not a valid expression: unknown reason") }
            guard let found else { return none("the pattern matched nothing in that text") }
            let captured = found.group ?? found.whole
            guard let total = BackendBrowserScrapingRegex.total(captured) else {
                return none("the pattern matched \"\(clip(captured))\", which is not a number this can read")
            }
            return BackendS4AssetsObject.make([("total", .number(total)), ("pattern", .string(pattern)), ("matched", .string(clip(found.whole))), ("reason", .string(""))])
        }
        var readings: [(total: Double, pattern: String, matched: String)] = []
        for source in genericPatterns {
            guard let found = try? exec(text, pattern: source, flags: "i"), let total = BackendBrowserScrapingRegex.total(found.group ?? "") else { continue }
            readings.append((total, source, clip(found.whole)))
        }
        guard let first = readings.first else {
            return none("nothing in that text reads as a stated total. Give a pattern, or a selector’s text, that does.")
        }
        var distinct: [Double] = []
        for reading in readings where !distinct.contains(reading.total) { distinct.append(reading.total) }
        if distinct.count > 1 {
            return none("that text states more than one total — \(distinct.map(whole).joined(separator: " and ")) — so which one bounds this run has to be said with a pattern.")
        }
        return BackendS4AssetsObject.make([("total", .number(first.total)), ("pattern", .string(first.pattern)), ("matched", .string(first.matched)), ("reason", .string(""))])
    }

    /// compareCoverage(): the verdict, the loud flag and the sentence.
    static func compare(_ input: NativeRPCValue, defaultNow: Double) -> NativeRPCValue {
        let rawCaptured = input["captured"].number ?? 0
        let captured = rawCaptured > 0 ? Int64(rawCaptured) : 0
        let tolerance = Int64(max(0, (input["tolerance"].number ?? 0).rounded(.towardZero)))
        let what = (input["what"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = input["url"].string ?? ""
        let at = input["now"].number ?? defaultNow
        let subject = what.isEmpty ? "this page" : what
        func check(_ verdict: String, stated: Int64?, missing: Int64?, ratio: Double?, loud: Bool, _ line: String) -> NativeRPCValue {
            BackendS4AssetsObject.make([("verdict", .string(verdict)), ("stated", stated.map { .number(Double($0)) } ?? .null), ("captured", .number(Double(captured))),
                                        ("missing", missing.map { .number(Double($0)) } ?? .null), ("ratio", ratio.map(NativeRPCValue.number) ?? .null),
                                        ("loud", .bool(loud)), ("line", .string(line)), ("at", .number(at)), ("what", .string(what)), ("url", .string(url))])
        }
        guard let rawStated = input["stated"].number else {
            return check("unknown", stated: nil, missing: nil, ratio: nil, loud: true,
                         "\(captured) captured from \(subject), and nothing on the page said how many there should be. This run cannot be called complete — read the page for its own total, or say so explicitly.")
        }
        let stated = Int64(rawStated), missing = stated - captured
        let ratio: Double? = stated == 0 ? nil : Double(captured) / Double(stated)
        if missing > tolerance {
            let percent = ratio.map { " — \(Int64(($0 * 100).rounded(.toNearestOrAwayFromZero)))% of what the page states" } ?? ""
            return check("short", stated: stated, missing: missing, ratio: ratio, loud: true,
                         "\(captured) of \(stated) captured from \(subject)\(percent). \(missing) are missing. This is not complete.")
        }
        if missing < -tolerance {
            return check("over", stated: stated, missing: missing, ratio: ratio, loud: true,
                         "\(captured) captured from \(subject) against a stated \(stated). More than the page says exist, which usually means the same items were counted twice — check before treating this as a win.")
        }
        return check("complete", stated: stated, missing: missing, ratio: ratio, loud: false, "\(captured) of \(stated) captured from \(subject).")
    }

    /// recordCoverage(): one appended line; false when it would not write.
    static func record(path: String, check: NativeRPCValue) -> Bool {
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) { try Data().write(to: URL(fileURLWithPath: path)) }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: try check.encodedJSON() + Data([10]))
            return true
        } catch { return false }
    }

    /// readCoverage(): unreadable lines and rows with no string verdict are dropped.
    static func read(path: String) -> [NativeRPCValue] {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { return [] }
        var checks: [NativeRPCValue] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let parsed = try? NativeRPCValue.parseJSON(Data(trimmed.utf8)), parsed.fields != nil, parsed["verdict"].string != nil { checks.append(parsed) }
        }
        return checks
    }
}
