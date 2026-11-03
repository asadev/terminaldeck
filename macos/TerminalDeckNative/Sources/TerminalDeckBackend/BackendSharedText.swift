import Foundation
import TerminalDeckNativeCore

/// Source-compatible primitives from shared byte-size, quote-match, held-window,
/// paste-cap, notify-rule and not-a-page. No global environment or app effects.
public enum BackendSharedBrand {
    public static let name = "Terminal Deck"
    public static let id = "terminaldeck"
    public static let bundleId = "dev.terminaldeck.app"
    public static let projectConfigDir = ".terminaldeck"
    public static let sessionEnvVar = "TERMINALDECK_SESSION_ID"
    public static let tagline = "Run your coding agents on one deck"
    public static let assistant = "Hoot"
}

public enum BackendSharedText {
    /// All TS caps/slices measure UTF-16 code units, rather than Swift graphemes.
    public static func prefix(_ value: String, _ count: Int) -> String {
        String(decoding: value.utf16.prefix(max(0, count)), as: UTF16.self)
    }
    public static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: javascriptPattern(pattern)),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return false }
        // ICU's $ also accepts a final line separator. TS's no-multiline
        // validators and their tests require the end of the actual input.
        return !pattern.hasSuffix("$") || NSMaxRange(match.range) == text.utf16.count
    }
    public static let whitespaceClass = #"[\x09-\x0d\x20\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\uFEFF]"#
    /// ICU's \d/\s/\b use broader Unicode sets than JavaScript's grammar.
    public static func javascriptPattern(_ pattern: String) -> String {
        let boundary = #"(?:(?<![A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<=[A-Za-z0-9_])(?![A-Za-z0-9_]))"#
        let whitespace = String(whitespaceClass.dropFirst().dropLast())
        // A complement pair means every code point; mixing JavaScript's \s
        // with ICU's \S would otherwise drop ICU-only whitespace such as NEL.
        let adjusted = pattern.replacingOccurrences(of: #"[\s\S]"#, with: "(?s:.)").replacingOccurrences(of: #"[\S\s]"#, with: "(?s:.)")
        let scalars = Array(adjusted.unicodeScalars)
        var output = "", index = 0, insideClass = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                let code = scalars[index + 1]
                switch code {
                case "d": output += insideClass ? "0-9" : "[0-9]"
                case "s": output += insideClass ? whitespace : whitespaceClass
                case "S": output += insideClass ? #"\S"# : "[^" + whitespace + "]"
                case "b": output += insideClass ? #"\x08"# : boundary
                default: output.unicodeScalars.append(scalar); output.unicodeScalars.append(code)
                }
                index += 2; continue
            }
            if scalar == "[" { insideClass = true }; if scalar == "]" { insideClass = false }
            output.unicodeScalars.append(scalar); index += 1
        }
        return output
    }
    public static func trim(_ text: String) -> String {
        text.replacingOccurrences(of: "^" + whitespaceClass + "+|" + whitespaceClass + "+$", with: "", options: .regularExpression)
    }
    public static func byteSize(_ bytes: Double) -> String {
        let units = ["bytes", "KB", "MB", "GB"]
        var value = bytes, unit = 0
        while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
        if unit == 0 { return "\(jsNumber(bytes)) bytes" }
        let number = value < 10 ? oneDecimal(value) : jsNumber(floor(value + 0.5))
        return "\(number) \(units[unit])"
    }
    private static func oneDecimal(_ value: Double) -> String {
        // unit > 0 means 1 <= value < 10 here. Round the exact binary
        // rational times ten, ties upward, as ECMAScript toFixed(1) does.
        // Multiplying Double by ten first would erase the 1.15/1.25 distinction.
        let bits = value.bitPattern
        let exponent = Int((bits >> 52) & 0x7ff) - 1023
        let numerator = ((bits & 0x000f_ffff_ffff_ffff) | (1 << 52)) * 10
        let shift = 52 - exponent
        var rounded = numerator >> shift
        let remainder = numerator & ((UInt64(1) << shift) - 1)
        if remainder >= UInt64(1) << (shift - 1) { rounded += 1 }
        return "\(rounded / 10).\(rounded % 10)"
    }
    public static func jsNumber(_ value: Double) -> String {
        if value.isNaN { return "NaN" }; if value == .infinity { return "Infinity" }; if value == -.infinity { return "-Infinity" }
        if value == 0 { return "0" }
        if value.rounded() == value && abs(value) < 1e21 { return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(value)
    }
    public static let maxPasteBytes = 1024 * 1024
    public static func overPasteCap(_ text: String) -> Bool {
        if text.utf16.count > maxPasteBytes { return true }
        var count = 0
        for scalar in text.unicodeScalars {
            let code = scalar.value
            count += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4
            if count > maxPasteBytes { return true }
        }
        return false
    }
    public static let needleChars = 64
    public static func normalizeLine(_ text: String) -> String {
        trim(text.replacingOccurrences(of: #"[\x00-\x08\x0b-\x1f\x7f-\x9f]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
    }
    public static func needleOf(_ quote: String) -> String {
        for line in quote.components(separatedBy: "\n") { let clean = normalizeLine(line); if !clean.isEmpty { return prefix(clean, needleChars) } }
        return ""
    }
    public static func stripAnsi(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\x1b\][\s\S]*?(?:\x07|\x1b\\)"#, #"\x1b\[[0-?]*[ -/]*[@-~]"#, #"\x1b[ -/]*[0-~]"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }
    public static func containsQuote(_ haystack: String, _ quote: String) -> Bool {
        let needle = needleOf(quote)
        guard !needle.isEmpty else { return false }
        return haystack.components(separatedBy: "\n").contains { normalizeLine($0).contains(needle) } || normalizeLine(haystack).contains(needle)
    }
    public static let notADevServer: Set<String> = [
        "rapportd", "sshd", "adb", "sharingd", "launchd", "ControlCe", "Spotify", "Dropbox", "iTunes", "AirPlay", "identityservicesd", "remoted", "Google", "Slack", "Postgres", "postgres", "mysqld", "redis-server", "mongod", "Docker", "System", "System Idle Process", "svchost", "services", "lsass", "wininit", "spoolsv", "sqlservr", "MsMpEng", "vmware-hostd", "com.docker.backend", "systemd-resolve", "systemd-resolved", "chronyd", "ntpd", "named", "dnsmasq", "unbound", "rpcbind", "rpc.statd", "smbd", "nmbd", "cupsd", "dovecot", "mariadbd", "memcached", "postmaster", "slapd",
    ]
    public static func isExcluded(_ name: String) -> Bool {
        if notADevServer.contains(name) { return true }
        let first = name.components(separatedBy: " ").first ?? ""
        if first != name && notADevServer.contains(first) { return true }
        return name.utf16.count > 9 && notADevServer.contains(prefix(name, 9))
    }
}

public struct BackendSharedHeldWindow: Equatable, Sendable {
    public let n: Int
    public let title: String
    public let url: String
    public let host: String
    public init(n: Int, title: String = "", url: String = "", host: String = "") { self.n = n; self.title = title; self.url = url; self.host = host }
    public var wireValue: NativeRPCValue { .object([.init("n", .number(Double(n))), .init("title", .string(title)), .init("url", .string(url)), .init("host", .string(host))]) }
}

public enum BackendSharedHeldWindows {
    public static let maxWindows = 16
    public static let maxLabelChars = 512
    public static func heldLabel(_ value: NativeRPCValue) -> String {
        guard let text = value.string else { return "" }
        let flat = BackendSharedText.trim(text.replacingOccurrences(of: #"[\x00-\x1f\x7f-\x9f\u2028\u2029]+"#, with: " ", options: .regularExpression))
        return BackendSharedText.prefix(flat, maxLabelChars)
    }
    public static func read(_ value: NativeRPCValue) -> [BackendSharedHeldWindow] {
        var windows: [BackendSharedHeldWindow] = []
        for row in value.elements ?? [] {
            if windows.count >= maxWindows { break }
            guard row.fields != nil, let n = row["n"].number, n.rounded() == n, n >= 1, n <= 9999 else { continue }
            windows.append(.init(n: Int(n), title: heldLabel(row["title"]), url: heldLabel(row["url"]), host: heldLabel(row["host"])))
        }
        return windows
    }
    public static func same(_ a: [BackendSharedHeldWindow], _ b: [BackendSharedHeldWindow]) -> Bool { a == b }
}

public enum BackendSharedNotifyRule {
    public static let notifyingStatuses = ["completed", "input"]
    public static let cooldownMilliseconds: Double = 4000
    public enum Verdict: Equatable, Sendable { case fire; case suppressed(String) }
    public static func isNotifyingStatus(_ status: String) -> Bool { notifyingStatuses.contains(status) }
    public static func decide(status: String, previous: String?, enabled: Bool, watching: Bool, lastFiredAt: Double?, now: Double, cooldownMs: Double) -> Verdict {
        if !enabled { return .suppressed("disabled") }
        guard let previous else { return .suppressed("first-sight") }
        if previous == status { return .suppressed("unchanged") }
        if !isNotifyingStatus(status) { return .suppressed("not-notifying") }
        if watching { return .suppressed("watching") }
        if let lastFiredAt, now - lastFiredAt < cooldownMs { return .suppressed("cooldown") }
        return .fire
    }
}
