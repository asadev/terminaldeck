import Foundation
import TerminalDeckNativeCore

public struct BackendSharedRedactOptions: Sendable {
    public var home: String?
    public var username: String?
    public var extraSecrets: [String]
    public var keepIdentity: Bool
    /// What a hidden value becomes; Deck Memory writes its own visible marker.
    public var marker: String
    public init(home: String? = nil, username: String? = nil, extraSecrets: [String] = [], keepIdentity: Bool = false, marker: String = BackendSharedRedact.redacted) { self.home = home; self.username = username; self.extraSecrets = extraSecrets; self.keepIdentity = keepIdentity; self.marker = marker }
}

public struct BackendSharedRedactionResult: Equatable, Sendable { public let text: String; public let count: Int }

/// main/redact.ts. Structure, known shapes, entropy and identity are applied in
/// the source order. Any environment values must be supplied by the caller.
/// The one secret-hiding rule: memory, tool results, events and logs all use it.
public enum BackendSharedRedact {
    public static let redacted = "[redacted]"
    public static let userPlaceholder = "<user>"
    public static let withheld = "[withheld]"
    private static let secretHeaders = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token"
    private static let secretKey = #"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*"#
    /// A value already hidden by either marker is left as it is.
    private static let hiddenAlready = [redacted, DeckMemoryRedaction.marker].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    private struct Rule { let regex: NSRegularExpression; let replacement: ([String], String) -> String }
    private static func compile(_ pattern: String, insensitive: Bool = false) -> NSRegularExpression {
        // The expressions are fixed source grammar; a port error must never
        // silently turn a redaction layer off.
        guard let regex = try? NSRegularExpression(pattern: BackendSharedText.javascriptPattern(pattern), options: insensitive ? [.caseInsensitive] : []) else { preconditionFailure("Invalid compiled redaction rule") }
        return regex
    }
    private static func apply(_ text: String, _ regex: NSRegularExpression, replacement: ([String]) -> String) -> BackendSharedRedactionResult {
        let ns = text as NSString, matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in let range = match.range(at: index); return range.location == NSNotFound ? "" : ns.substring(with: range) }
            result.replaceCharacters(in: match.range, with: replacement(groups))
        }
        return .init(text: result as String, count: matches.count)
    }
    /// ICU's $ also accepts a final line separator; `toEnd` asks for the end of the actual input (BackendSharedText.matches).
    private static func found(_ regex: NSRegularExpression, in text: String, toEnd: Bool = false) -> Bool {
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else { return false }
        return !toEnd || NSMaxRange(match.range) == text.utf16.count
    }
    // Every fixed expression is compiled once and shared: diagnostics run each
    // log line through all of them. NSRegularExpression is immutable.
    nonisolated(unsafe) private static let structural: [Rule] = [
        .init(regex: compile(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#), replacement: { _, marker in "-----BEGIN PRIVATE KEY-----" + marker + "-----END PRIVATE KEY-----" }),
        .init(regex: compile(#"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"#), replacement: { _, marker in "-----BEGIN KEY-----" + marker + "-----END KEY-----" }),
        .init(regex: compile(#"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, insensitive: true), replacement: { $0[1] + $1 + "@" }),
        .init(regex: compile(#"("(?:\#(secretHeaders))"\s*:\s*)"[^"]*""#, insensitive: true), replacement: { $0[1] + "\"" + $1 + "\"" }),
        .init(regex: compile(#"\b((?:\#(secretHeaders))\s*:\s*)[^\r\n"']+"#, insensitive: true), replacement: { $0[1] + $1 }),
        .init(regex: compile(#"\b(\#(secretKey))("?\s*[:=]\s*)(["'])(?:\\.|(?!\3)[^\\])*\3"#, insensitive: true), replacement: { $0[1] + $0[2] + $0[3] + $1 + $0[3] }),
        .init(regex: compile(#"\b(\#(secretKey))(\s*[:=]\s*)(?!\#(hiddenAlready))([^\s,;)}\]"']+)"#, insensitive: true), replacement: { $0[1] + $0[2] + $1 }),
        .init(regex: compile(#"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}"#, insensitive: true), replacement: { $0[1] + " " + $1 }),
        .init(regex: compile(#"\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)"#), replacement: { groups, _ in groups[1] + groups[2] + userPlaceholder }),
        // Deck Memory's pair rule: also names written with a space ("api key: …"); the value must hold a digit.
        .init(regex: compile(#"\b(password|passwd|pwd|secret|api[_\- ]?key|access[_\- ]?token|auth[_\- ]?token|token)\b(\s*[:=]\s*["']?)(?=[^\s"',;]*\d)[^\s"',;]{6,}"#, insensitive: true), replacement: { $0[1] + $0[2] + $1 }),
    ]
    private static let tokenPatterns = [
        #"\bsk-ant-[A-Za-z0-9_-]{10,}"#, #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bglpat-[A-Za-z0-9_-]{16,}"#, #"\bxox[abprse]-[A-Za-z0-9-]{10,}"#, #"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#,
        #"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"#, #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b"#,
        #"\bAIza[A-Za-z0-9_-]{30,}"#, #"\bya29\.[A-Za-z0-9_-]{10,}"#, #"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}"#,
        #"\bnpm_[A-Za-z0-9]{30,}"#, #"\bdop_v1_[a-f0-9]{40,}"#, #"\bhf_[A-Za-z0-9]{20,}"#, #"\bsbp_[a-f0-9]{20,}"#,
        #"\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}"#, #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#,
    ]
    nonisolated(unsafe) private static let tokens = tokenPatterns.map { compile($0) }
    nonisolated(unsafe) private static let sweep = compile(#"[A-Za-z0-9+=_-]{32,}"#)
    nonisolated(unsafe) private static let usersPath = compile(#"(/Users/|/home/)[A-Za-z0-9._-]+"#)
    nonisolated(unsafe) private static let windowsUsers = compile(#"([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+"#, insensitive: true)
    nonisolated(unsafe) private static let uuid = compile(#"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#)
    nonisolated(unsafe) private static let digit = compile("[0-9]")
    nonisolated(unsafe) private static let letter = compile("[A-Za-z]")
    nonisolated(unsafe) private static let whitespace = compile(#"\s"#)
    nonisolated(unsafe) private static let wholeSecretKey = compile("(?i)^" + secretKey + "$")
    nonisolated(unsafe) private static let withheldKey = compile(#"^key$|token|secret|password|passwd|api[-_]?key|credential|cookie|authorization|bearer|private"#, insensitive: true)
    /// Every fixed expression above, the same objects on every call.
    static var compiledRules: [NSRegularExpression] {
        structural.map(\.regex) + tokens + [sweep, usersPath, windowsUsers, uuid, digit, letter, whitespace, wholeSecretKey, withheldKey]
    }
    public static func entropy(_ value: String) -> Double {
        guard !value.isEmpty else { return 0 }
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in value.unicodeScalars { counts[scalar, default: 0] += 1 }
        let length = Double(value.utf16.count)
        return counts.values.reduce(0) { bits, count in let p = Double(count) / length; return bits - p * log2(p) }
    }
    public static func looksSecret(_ candidate: String) -> Bool {
        guard candidate.utf16.count >= 32, !found(uuid, in: candidate, toEnd: true),
              found(digit, in: candidate), found(letter, in: candidate), candidate.filter({ $0 == "-" || $0 == "_" }).count <= 2 else { return false }
        return entropy(candidate) >= 3
    }
    public static func foldIdentity(_ text: String, home: String, username: String) -> BackendSharedRedactionResult {
        var output = text, count = 0
        func take(_ result: BackendSharedRedactionResult) { output = result.text; count += result.count }
        if !home.isEmpty { take(apply(output, compile(NSRegularExpression.escapedPattern(for: home)), replacement: { _ in "~" })) }
        take(apply(output, usersPath, replacement: { $0[1] + userPlaceholder }))
        take(apply(output, windowsUsers, replacement: { $0[1] + userPlaceholder }))
        if username.utf16.count >= 2 {
            // JS permits the source's variable-length lookbehind; ICU does not.
            // Check its two boundary alternatives over literal username matches.
            let ns = output as NSString, result = NSMutableString(string: output)
            let regex = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: username))
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).reversed() {
                let start = match.range.location, end = NSMaxRange(match.range)
                let before = start == 0 ? "" : ns.substring(with: NSRange(location: start - 1, length: 1))
                let after = end == ns.length ? "" : ns.substring(with: NSRange(location: end, length: 1))
                let whitespaceBefore = found(whitespace, in: before)
                let whitespaceAfter = found(whitespace, in: after)
                let left = start == 0 || whitespaceBefore || ["/", "\\", ":", "~", "@"].contains(before)
                let right = ["/", "\\", "@"].contains(after)
                let second = ["/", "\\", "~", "@"].contains(before) && (end == ns.length || whitespaceAfter || ["/", "\\", "@", "'", "\""].contains(after))
                if left && right || second { result.replaceCharacters(in: match.range, with: userPlaceholder); count += 1 }
            }
            output = result as String
        }
        return .init(text: output, count: count)
    }
    public static func secretsFromEnv(_ environment: [String: String]) -> [String] {
        environment.filter { name, value in value.utf16.count >= 8 && value.utf16.count <= 4096 && isSecretKey(name) }.map(\.value)
    }
    public static func secretEnvNames(_ environment: [String: String]) -> [String] { environment.keys.filter(isSecretKey).sorted() }
    public static func isSecretKey(_ key: String) -> Bool { found(wholeSecretKey, in: key, toEnd: true) }
    public static func redactWithCount(_ text: String, options: BackendSharedRedactOptions = .init()) -> BackendSharedRedactionResult {
        if text.isEmpty { return .init(text: text, count: 0) }
        let home = options.home ?? NSHomeDirectory(), username = options.username ?? home.components(separatedBy: CharacterSet(charactersIn: "/\\")).last(where: { !$0.isEmpty }) ?? ""
        var output = text, count = 0
        func take(_ result: BackendSharedRedactionResult) { output = result.text; count += result.count }
        let marker = options.marker
        for literal in options.extraSecrets.filter({ $0.utf16.count >= 6 }).sorted(by: { $0.utf16.count > $1.utf16.count }) {
            take(apply(output, compile(NSRegularExpression.escapedPattern(for: literal)), replacement: { _ in marker }))
        }
        for rule in structural { take(apply(output, rule.regex, replacement: { rule.replacement($0, marker) })) }
        for regex in tokens { take(apply(output, regex, replacement: { _ in marker })) }
        // apply counts all matches; the source counts only redacted candidates.
        var swept = 0
        output = apply(output, sweep, replacement: { groups in
            guard looksSecret(groups[0]) else { return groups[0] }
            swept += 1; return marker
        }).text
        count += swept
        if !options.keepIdentity { take(foldIdentity(output, home: home, username: username)) }
        return .init(text: output, count: count)
    }
    public static func redact(_ text: String, options: BackendSharedRedactOptions = .init()) -> String { redactWithCount(text, options: options).text }
    public static func redactLines(_ lines: [String], options: BackendSharedRedactOptions = .init()) -> [String] { lines.map { redact($0, options: options) } }
    public static func redactValue(_ value: NativeRPCValue, options: BackendSharedRedactOptions = .init()) -> NativeRPCValue {
        switch value {
        case .string(let text): return .string(redact(text, options: options))
        case .array(let values): return .array(values.map { redactValue($0, options: options) })
        case .object(let fields): return .object(fields.map { .init($0.key, isSecretKey($0.key) ? .string(options.marker) : redactValue($0.value, options: options)) })
        default: return value
        }
    }
    /// Tool results (accounts, MCP drafts): a text value under a secret-sounding
    /// field name is withheld whole; everything else is kept as it is.
    public static func withoutSecrets(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue {
        guard depth <= 8 else { return value }
        switch value {
        case .array(let values): return .array(values.map { withoutSecrets($0, depth: depth + 1) })
        case .object(let fields): return .object(fields.map { field in
            .init(field.key, field.value.string != nil && found(withheldKey, in: field.key) ? .string(withheld) : withoutSecrets(field.value, depth: depth + 1))
        })
        default: return value
        }
    }
    /// Foundation support for diagnostics assembled outside the RPC value tree.
    /// Track only the current walk, so two references to one object both survive.
    public static func redactFoundation(_ value: Any, options: BackendSharedRedactOptions = .init()) -> Any {
        var seen = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> Any {
            if let text = value as? String { return redact(text, options: options) }
            if let dictionary = value as? NSDictionary {
                let id = ObjectIdentifier(dictionary)
                if seen.contains(id) { return "[circular]" }
                seen.insert(id); defer { seen.remove(id) }
                var output: [String: Any] = [:]
                for rawKey in dictionary.allKeys {
                    guard let key = rawKey as? String, let item = dictionary.object(forKey: rawKey) else { continue }
                    output[key] = isSecretKey(key) ? options.marker : walk(item)
                }
                return output
            }
            if let array = value as? NSArray {
                let id = ObjectIdentifier(array)
                if seen.contains(id) { return "[circular]" }
                seen.insert(id); defer { seen.remove(id) }
                return array.map { walk($0) }
            }
            return value
        }
        return walk(value)
    }
}
