import Foundation
import TerminalDeckNativeCore

/// The keepIdentity:true redaction path from redact.ts, used for MCP config
/// that an agent may send back to edit. Real folder paths must remain usable.
public enum BackendDeckCoreEventsRedaction {
    private static let secretKey = #"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*"#
    private static let headers = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token"
    public static func value(_ value: NativeRPCValue) -> NativeRPCValue {
        switch value {
        case .string(let text): return .string(redact(text))
        case .array(let values): return .array(values.map(Self.value))
        case .object(let fields): return .object(fields.map { .init($0.key, matches("^" + secretKey + "$", $0.key, insensitive:true) ? .string("[redacted]") : Self.value($0.value)) })
        default: return value
        }
    }
    public static func withoutSecrets(_ value: NativeRPCValue, depth: Int = 0) -> NativeRPCValue {
        guard depth <= 8 else { return value }
        switch value {
        case .array(let values): return .array(values.map { withoutSecrets($0,depth:depth+1) })
        case .object(let fields): return .object(fields.map { field in
            .init(field.key,field.value.string != nil && matches(#"^key$|token|secret|password|passwd|api[-_]?key|credential|cookie|authorization|bearer|private"#,field.key,insensitive:true) ? .string("[withheld]") : withoutSecrets(field.value,depth:depth+1))
        })
        default: return value
        }
    }
    public static func redact(_ text: String, extraSecrets: [String] = []) -> String {
        var out = text
        for literal in extraSecrets.filter({ $0.utf16.count >= 6 }).sorted(by:{ $0.utf16.count > $1.utf16.count }) { out = out.replacingOccurrences(of:literal,with:"[redacted]") }
        let structural: [(String,String,Bool)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,"-----BEGIN PRIVATE KEY-----[redacted]-----END PRIVATE KEY-----",false),
            (#"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"#,"-----BEGIN KEY-----[redacted]-----END KEY-----",false),
            (#"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#,"$1[redacted]@",true),
            ("(\"(?:" + headers + ")\"\\s*:\\s*)\"[^\"]*\"","$1\"[redacted]\"",true),
            (#"\b((?:"# + headers + #")\s*:\s*)[^\r\n"']+"#,"$1[redacted]",true),
            (#"\b("# + secretKey + #")("?\s*[:=]\s*)(["'])(?:\\.|(?!\3)[^\\])*\3"#,"$1$2$3[redacted]$3",true),
            (#"\b("# + secretKey + #")(\s*[:=]\s*)(?!\[redacted\])([^\s,;)}\]"']+)"#,"$1$2[redacted]",true),
            (#"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}"#,"$1 [redacted]",true),
            (#"\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)"#,"$1$2<user>",false)
        ]
        for (pattern,replacement,insensitive) in structural { out = replace(pattern,out,replacement,insensitive:insensitive) }
        let tokens = [#"\bsk-ant-[A-Za-z0-9_-]{10,}"#,#"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}"#,#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#,#"\bgithub_pat_[A-Za-z0-9_]{20,}"#,#"\bglpat-[A-Za-z0-9_-]{16,}"#,#"\bxox[abprse]-[A-Za-z0-9-]{10,}"#,#"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#,#"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"#,#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b"#,#"\bAIza[A-Za-z0-9_-]{30,}"#,#"\bya29\.[A-Za-z0-9_-]{10,}"#,#"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}"#,#"\bnpm_[A-Za-z0-9]{30,}"#,#"\bdop_v1_[a-f0-9]{40,}"#,#"\bhf_[A-Za-z0-9]{20,}"#,#"\bsbp_[a-f0-9]{20,}"#,#"\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}"#,#"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#,#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#]
        for pattern in tokens { out = replace(pattern,out,"[redacted]") }
        guard let regex = try? NSRegularExpression(pattern:#"[A-Za-z0-9+=_-]{32,}"#) else { return out }
        for match in regex.matches(in:out,range:NSRange(out.startIndex...,in:out)).reversed() {
            guard let range = Range(match.range,in:out), looksSecret(String(out[range])) else { continue }; out.replaceSubrange(range,with:"[redacted]")
        }
        return out
    }
    public static func looksSecret(_ value: String) -> Bool {
        guard value.utf16.count >= 32, !matches(#"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,value,insensitive:true),
              matches("[0-9]",value), matches("[A-Za-z]",value), value.filter({ $0 == "-" || $0 == "_" }).count <= 2 else { return false }
        var counts: [Character:Int] = [:]; for char in value { counts[char,default:0] += 1 }
        let entropy = counts.values.reduce(0.0) { result,count in let p = Double(count)/Double(value.count); return result - p*log2(p) }
        return entropy >= 3
    }
    private static func matches(_ pattern: String, _ text: String, insensitive: Bool = false) -> Bool { (try? NSRegularExpression(pattern:pattern,options:insensitive ? [.caseInsensitive] : []).firstMatch(in:text,range:NSRange(text.startIndex...,in:text))) != nil }
    private static func replace(_ pattern: String, _ text: String, _ replacement: String, insensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern:pattern,options:insensitive ? [.caseInsensitive] : []) else { return text }
        return regex.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:replacement)
    }
}
