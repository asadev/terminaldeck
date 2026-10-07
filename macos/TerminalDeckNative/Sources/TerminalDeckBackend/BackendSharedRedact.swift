import Foundation
import TerminalDeckNativeCore

public struct BackendSharedRedactOptions: Sendable {
    public var home: String?
    public var username: String?
    public var extraSecrets: [String]
    public var keepIdentity: Bool
    public init(home: String? = nil, username: String? = nil, extraSecrets: [String] = [], keepIdentity: Bool = false) { self.home = home; self.username = username; self.extraSecrets = extraSecrets; self.keepIdentity = keepIdentity }
}

public struct BackendSharedRedactionResult: Equatable, Sendable { public let text: String; public let count: Int }

/// main/redact.ts. Structure, known shapes, entropy and identity are applied in
/// the source order. Any environment values must be supplied by the caller.
public enum BackendSharedRedact {
    public static let redacted = "[redacted]"
    public static let userPlaceholder = "<user>"
    private static let secretHeaders = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token"
    private static let secretKey = #"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*"#
    private struct Rule { let pattern: String; let insensitive: Bool; let replacement: ([String]) -> String }
    private static func apply(_ text: String, pattern: String, insensitive: Bool = false, replacement: ([String]) -> String) -> BackendSharedRedactionResult {
        // The expressions are fixed source grammar; a port error must never
        // silently turn a redaction layer off.
        guard let regex = try? NSRegularExpression(pattern: BackendSharedText.javascriptPattern(pattern), options: insensitive ? [.caseInsensitive] : []) else { preconditionFailure("Invalid compiled redaction rule") }
        let ns = text as NSString, matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in let range = match.range(at: index); return range.location == NSNotFound ? "" : ns.substring(with: range) }
            result.replaceCharacters(in: match.range, with: replacement(groups))
        }
        return .init(text: result as String, count: matches.count)
    }
    private static var structural: [Rule] { [
        .init(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, insensitive: false, replacement: { _ in "-----BEGIN PRIVATE KEY-----[redacted]-----END PRIVATE KEY-----" }),
        .init(pattern: #"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"#, insensitive: false, replacement: { _ in "-----BEGIN KEY-----[redacted]-----END KEY-----" }),
        .init(pattern: #"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, insensitive: true, replacement: { $0[1] + redacted + "@" }),
        .init(pattern: #"("(?:\#(secretHeaders))"\s*:\s*)"[^"]*""#, insensitive: true, replacement: { $0[1] + "\"" + redacted + "\"" }),
        .init(pattern: #"\b((?:\#(secretHeaders))\s*:\s*)[^\r\n"']+"#, insensitive: true, replacement: { $0[1] + redacted }),
        .init(pattern: #"\b(\#(secretKey))("?\s*[:=]\s*)(["'])(?:\\.|(?!\3)[^\\])*\3"#, insensitive: true, replacement: { $0[1] + $0[2] + $0[3] + redacted + $0[3] }),
        .init(pattern: #"\b(\#(secretKey))(\s*[:=]\s*)(?!\[redacted\])([^\s,;)}\]"']+)"#, insensitive: true, replacement: { $0[1] + $0[2] + redacted }),
        .init(pattern: #"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}"#, insensitive: true, replacement: { $0[1] + " " + redacted }),
        .init(pattern: #"\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)"#, insensitive: false, replacement: { $0[1] + $0[2] + userPlaceholder }),
    ] }
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
    public static func entropy(_ value: String) -> Double {
        guard !value.isEmpty else { return 0 }
        var counts: [Unicode.Scalar: Int] = [:]
        for scalar in value.unicodeScalars { counts[scalar, default: 0] += 1 }
        let length = Double(value.utf16.count)
        return counts.values.reduce(0) { bits, count in let p = Double(count) / length; return bits - p * log2(p) }
    }
    public static func looksSecret(_ candidate: String) -> Bool {
        guard candidate.utf16.count >= 32, !BackendSharedText.matches(candidate, #"(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#),
              BackendSharedText.matches(candidate, "[0-9]"), BackendSharedText.matches(candidate, "[A-Za-z]"), candidate.filter({ $0 == "-" || $0 == "_" }).count <= 2 else { return false }
        return entropy(candidate) >= 3
    }
    public static func foldIdentity(_ text: String, home: String, username: String) -> BackendSharedRedactionResult {
        var output = text, count = 0
        func take(_ result: BackendSharedRedactionResult) { output = result.text; count += result.count }
        if !home.isEmpty { take(apply(output, pattern: NSRegularExpression.escapedPattern(for: home), replacement: { _ in "~" })) }
        take(apply(output, pattern: #"(/Users/|/home/)[A-Za-z0-9._-]+"#, replacement: { $0[1] + userPlaceholder }))
        take(apply(output, pattern: #"([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+"#, insensitive: true, replacement: { $0[1] + userPlaceholder }))
        if username.utf16.count >= 2 {
            // JS permits the source's variable-length lookbehind; ICU does not.
            // Check its two boundary alternatives over literal username matches.
            let ns = output as NSString, result = NSMutableString(string: output)
            let regex = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: username))
            for match in regex.matches(in: output, range: NSRange(location: 0, length: ns.length)).reversed() {
                let start = match.range.location, end = NSMaxRange(match.range)
                let before = start == 0 ? "" : ns.substring(with: NSRange(location: start - 1, length: 1))
                let after = end == ns.length ? "" : ns.substring(with: NSRange(location: end, length: 1))
                let whitespaceBefore = BackendSharedText.matches(before, #"\s"#)
                let whitespaceAfter = BackendSharedText.matches(after, #"\s"#)
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
    public static func isSecretKey(_ key: String) -> Bool { BackendSharedText.matches(key, "(?i)^" + secretKey + "$") }
    public static func redactWithCount(_ text: String, options: BackendSharedRedactOptions = .init()) -> BackendSharedRedactionResult {
        if text.isEmpty { return .init(text: text, count: 0) }
        let home = options.home ?? NSHomeDirectory(), username = options.username ?? home.components(separatedBy: CharacterSet(charactersIn: "/\\")).last(where: { !$0.isEmpty }) ?? ""
        var output = text, count = 0
        func take(_ result: BackendSharedRedactionResult) { output = result.text; count += result.count }
        for literal in options.extraSecrets.filter({ $0.utf16.count >= 6 }).sorted(by: { $0.utf16.count > $1.utf16.count }) {
            take(apply(output, pattern: NSRegularExpression.escapedPattern(for: literal), replacement: { _ in redacted }))
        }
        for rule in structural { take(apply(output, pattern: rule.pattern, insensitive: rule.insensitive, replacement: rule.replacement)) }
        for pattern in tokenPatterns { take(apply(output, pattern: pattern, replacement: { _ in redacted })) }
        let sweep = apply(output, pattern: #"[A-Za-z0-9+=_-]{32,}"#, replacement: { looksSecret($0[0]) ? redacted : $0[0] })
        // apply counts all matches; the source counts only redacted candidates.
        let candidates = try! NSRegularExpression(pattern: #"[A-Za-z0-9+=_-]{32,}"#)
        let ns = output as NSString
        count += candidates.matches(in: output, range: NSRange(location: 0, length: ns.length)).filter { looksSecret(ns.substring(with: $0.range)) }.count
        output = sweep.text
        if !options.keepIdentity { take(foldIdentity(output, home: home, username: username)) }
        return .init(text: output, count: count)
    }
    public static func redact(_ text: String, options: BackendSharedRedactOptions = .init()) -> String { redactWithCount(text, options: options).text }
    public static func redactLines(_ lines: [String], options: BackendSharedRedactOptions = .init()) -> [String] { lines.map { redact($0, options: options) } }
    public static func redactValue(_ value: NativeRPCValue, options: BackendSharedRedactOptions = .init()) -> NativeRPCValue {
        switch value {
        case .string(let text): return .string(redact(text, options: options))
        case .array(let values): return .array(values.map { redactValue($0, options: options) })
        case .object(let fields): return .object(fields.map { .init($0.key, isSecretKey($0.key) ? .string(redacted) : redactValue($0.value, options: options)) })
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
                    output[key] = isSecretKey(key) ? redacted : walk(item)
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
