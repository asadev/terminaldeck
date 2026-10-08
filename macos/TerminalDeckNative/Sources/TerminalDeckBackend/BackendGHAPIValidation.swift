import Foundation
import TerminalDeckNativeCore

/// Input rules shared by the native GitHub operation implementations.
enum BackendGHAPIValidation {
    static let maximumJSONBytes = 4 * 1024 * 1024
    static let maximumLogBytes = 2 * 1024 * 1024
    static let maximumTextBytes = 65_536
    static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(fields.map { .init($0.0, $0.1) })
    }
    static func matches(_ value: String, _ expression: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: expression) else { return false }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range.length == value.utf16.count
    }
    static func host(_ host: String) throws -> String {
        guard host.utf8.count <= 253, matches(host, #"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?"#),
              !host.contains(".."), !host.hasSuffix("."), host.contains("."),
              host.split(separator: ".").allSatisfy({ !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.utf8.count <= 63 }) else {
            throw NativeRPCError.invalidArguments("The connected GitHub host is not a valid host name.")
        }
        return host.lowercased()
    }
    static func repo(_ args: NativeRPCValue, required: Bool = true) throws -> String? {
        let raw: String
        if let value = args["repo"].string { raw = value }
        else if let owner = args["owner"].string, let name = args["name"].string { raw = owner + "/" + name }
        else if !required, args["repo"].isNullish { return nil }
        else { throw NativeRPCError.invalidArguments("Choose a repository as owner/name.") }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, matches(String(parts[0]), #"[A-Za-z0-9][A-Za-z0-9-]{0,99}"#),
              matches(String(parts[1]), #"[A-Za-z0-9_.-]{1,100}"#), parts[1] != ".", parts[1] != ".." else {
            throw NativeRPCError.invalidArguments("The repository must be owner/name, with no web address or extra path.")
        }
        return raw
    }
    static func integer(_ args: NativeRPCValue, _ key: String, alias: String? = nil, default fallback: Int? = nil, range: ClosedRange<Int> = 1...Int.max) throws -> Int {
        let raw = args[key].isNullish ? alias.map { args[$0] } ?? .missing : args[key]
        if raw.isNullish, let fallback { return fallback }
        guard let number = raw.number, number.rounded(.towardZero) == number, number >= Double(range.lowerBound), number <= Double(min(range.upperBound, 9_007_199_254_740_991)) else {
            throw NativeRPCError.invalidArguments("\(key) must be a whole number between \(range.lowerBound) and \(min(range.upperBound, 9_007_199_254_740_991)).")
        }
        return Int(number)
    }
    static func text(_ args: NativeRPCValue, _ key: String, required: Bool = false, maximum: Int = maximumTextBytes, alias: String? = nil) throws -> String? {
        let raw = args[key].isNullish ? alias.map { args[$0] } ?? .missing : args[key]
        if raw.isNullish, !required { return nil }
        guard let value = raw.string, value.utf8.count <= maximum, !value.contains("\0"), !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeRPCError.invalidArguments("\(key) must be \(required ? "nonempty " : "")text of at most \(maximum) bytes.")
        }
        return value
    }
    static func choice(_ args: NativeRPCValue, _ key: String, values: [String], default fallback: String? = nil, alias: String? = nil) throws -> String? {
        let value = try text(args, key, alias: alias) ?? fallback
        guard value == nil || values.contains(value!) else { throw NativeRPCError.invalidArguments("\(key) must be \(values.joined(separator: ", ")).") }
        return value
    }
    static func boolean(_ args: NativeRPCValue, _ key: String, default fallback: Bool = false) throws -> Bool {
        if args[key].isNullish { return fallback }
        guard let value = args[key].bool else { throw NativeRPCError.invalidArguments("\(key) must be true or false.") }; return value
    }
    static func identifier(_ args: NativeRPCValue, _ key: String, alias: String? = nil) throws -> String {
        let raw = args[key].isNullish ? alias.map { args[$0] } ?? .missing : args[key]
        if let text = raw.string {
            guard matches(text, #"[1-9][0-9]{0,19}"#), UInt64(text) != nil else { throw NativeRPCError.invalidArguments("\(key) must be a positive GitHub ID.") }; return text
        }
        return String(try integer(args, key, alias: alias))
    }
    static func date(_ args: NativeRPCValue, _ key: String) throws -> String? {
        guard let text = try self.text(args, key, maximum: 64) else { return nil }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: text) == nil {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard formatter.date(from: text) != nil else { throw NativeRPCError.invalidArguments("\(key) must be an ISO date such as 2026-10-08T00:00:00Z.") }
        }
        return text
    }
    static func names(_ args: NativeRPCValue, _ key: String, maximum: Int = 100, logins: Bool = false) throws -> [String] {
        guard let values = args[key].elements, values.count <= maximum else { throw NativeRPCError.invalidArguments("\(key) must be a list of at most \(maximum) names.") }
        return try values.map {
            guard let value = $0.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 100,
                  !value.contains("\0"), !value.contains("\n"), !value.contains("\r"), !logins || matches(value, #"[A-Za-z0-9][A-Za-z0-9-]{0,99}"#) else {
                throw NativeRPCError.invalidArguments("\(key) contains an invalid name.")
            }; return value
        }
    }
    static func ref(_ value: String, allowOwner: Bool = false) throws -> String {
        let candidate = allowOwner && value.contains(":") ? String(value.split(separator: ":", maxSplits: 1).last ?? "") : value
        guard !value.isEmpty, value.utf8.count <= 1024, !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.contains(".."), !value.contains("@{"), !value.contains("\\"),
              !value.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              !value.contains(where: { "~^?*[".contains($0) }), !candidate.isEmpty,
              !candidate.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock") || $0.hasSuffix(".") }),
              (!allowOwner && !value.contains(":")) || (allowOwner && value.filter({ $0 == ":" }).count <= 1) else {
            throw NativeRPCError.invalidArguments("Choose a valid Git branch or commit reference.")
        }
        if allowOwner, value.contains(":"), let owner = value.split(separator: ":").first, !matches(String(owner), #"[A-Za-z0-9][A-Za-z0-9-]{0,99}"#) { throw NativeRPCError.invalidArguments("The source branch owner is invalid.") }
        return value
    }
    static func sha(_ value: String) throws -> String {
        guard matches(value, #"[A-Fa-f0-9]{7,64}"#) else { throw NativeRPCError.invalidArguments("Choose a valid commit ID.") }; return value
    }
    static func relativePath(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 4096, !value.hasPrefix("/"), !value.contains("\\"),
              !value.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NativeRPCError.invalidArguments("A review file must be a relative path inside the repository.")
        }; return value
    }
    /// Keeps ordinary commit IDs intact while removing credential literals and recognizable tokens.
    static func scrub(_ value: String, secrets: [String]) -> String {
        var result = value
        for secret in secrets where !secret.isEmpty { result = result.replacingOccurrences(of: secret, with: "[redacted]") }
        for pattern in [#"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\bsk-(?:ant-|proj-|svcacct-)?[A-Za-z0-9_-]{16,}"#, #"(?i)(?:Bearer|Basic|Token)\s+[A-Za-z0-9._~+/=-]{8,}"#, #"(?i)https?://[^/\s:@]+(?::[^/\s@]+)?@"#, #"(?i)(?<=[?&])(?:sig|signature|x-amz-signature|access_token|token)=[^&\s\"<>]+"#] {
            if let regex = try? NSRegularExpression(pattern: pattern) { result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]") }
        }
        return result
    }
    static func scrub(_ value: NativeRPCValue, secrets: [String]) -> NativeRPCValue {
        switch value {
        case .string(let text): return .string(scrub(text, secrets: secrets))
        case .array(let values): return .array(values.map { scrub($0, secrets: secrets) })
        case .object(let fields): return .object(fields.map { field in
            let sensitive = ["token", "access_token", "refresh_token", "password", "authorization", "client_secret"].contains(field.key.lowercased())
            return .init(field.key, sensitive ? .string("[redacted]") : scrub(field.value, secrets: secrets))
        })
        default: return value
        }
    }
}
