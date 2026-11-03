import Foundation

extension TaskFields {
    // MARK: Small helpers

    /// An id for an option or a draft — unique, never empty.
    public static func newKey() -> String { UUID().uuidString.lowercased() }

    public static func isUuidLike(_ v: String?) -> Bool {
        guard let v, v.utf8.count == 36 else { return false }
        for (i, c) in v.utf8.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != UInt8(ascii: "-") { return false }
            } else if !((48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c)) {
                return false
            }
        }
        return true
    }

    static func isHex(_ v: String?) -> Bool {
        guard let v, v.utf8.count == 7, v.hasPrefix("#") else { return false }
        return v.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// JavaScript's Math.round: halves go up.
    public static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    public static func roundTo(_ n: Double, _ decimals: Int) -> Double {
        let f = pow(10, Double(decimals))
        return jsRound((n + Double.ulpOfOne) * f) / f
    }

    /// A number as JavaScript writes it ("25", "25.5").
    public static func js(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == n.rounded(), abs(n) < 1e21 { return String(format: "%.0f", n) }
        return "\(n)"
    }

    static func jsString(_ v: CrmValue?) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): js(n)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case nil: "undefined"
        case .array(let a): a.map { jsString($0) }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func clampInt(_ v: CrmValue?, _ lo: Int, _ hi: Int, _ dflt: Int) -> Int {
        var n = Double.nan
        if case .number(let d) = v { n = d }
        if case .string(let s) = v, !s.trimmingCharacters(in: .whitespaces).isEmpty { n = Double(s.trimmingCharacters(in: .whitespaces)) ?? .nan }
        guard n.isFinite else { return dflt }
        return Swift.min(hi, Swift.max(lo, Int(jsRound(n))))
    }

    public enum Parsed: Equatable, Sendable {
        case empty
        case bad
        case value(Double)
    }

    /// A number from what a person typed: "1,200", "AED 1200.5", 3.
    public static func toNumber(_ raw: CrmValue?) -> Parsed {
        switch raw {
        case nil, .null: return .empty
        case .number(let n): return n.isFinite ? .value(n) : .bad
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var body = raw
            // Only a REAL currency code in front of a number is dropped ("AED 1,200").
            if let m = trimmed.firstMatch(of: #/^([A-Za-z]{3})\s*(?=[-+.\d])/#), currencies.contains(String(m.1).uppercased()) {
                body = String(trimmed[m.range.upperBound...])
            }
            let s = body.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "," && !$0.isWhitespace }
            if s.isEmpty { return .empty }
            guard s.wholeMatch(of: #/[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?/#) != nil, let n = Double(s) else { return .bad }
            return n.isFinite ? .value(n) : .bad
        default:
            return .bad
        }
    }

}
