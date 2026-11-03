import Foundation
import TerminalDeckNativeCore

/// Root-level .gitignore + .deckignore semantics from fs-tree.ts, including
/// escaped comments, globstar, bracket classes, last-match negation and the
/// excluded-parent rule. .git/node_modules are always hidden.
public struct BackendFilesystemIgnore: Sendable {
    public struct Rule: Sendable {
        public let source: String; public let negated: Bool; public let directoryOnly: Bool; fileprivate let expression: String
        public func matches(_ path: String, directory: Bool) -> Bool { (!directoryOnly || directory) && path.range(of: expression, options: .regularExpression) != nil }
    }
    public let rules: [Rule]
    public init(texts: [String]) { rules = texts.flatMap { $0.components(separatedBy: .newlines).compactMap(Self.compile) } }
    public func ignored(_ relative: String, directory: Bool) -> Bool {
        let segments = relative.split(separator: "/").map(String.init)
        if segments.contains(".git") || segments.contains("node_modules") { return true }
        for index in segments.indices {
            let final = index == segments.count - 1
            let path = segments[...index].joined(separator: "/")
            var hidden = false
            for rule in rules where !rule.directoryOnly || !final || directory {
                if path.range(of: rule.expression, options: .regularExpression) != nil { hidden = !rule.negated }
            }
            if hidden { return true }
        }
        return false
    }
    public static func compile(_ line: String) -> Rule? {
        var pattern = line.replacingOccurrences(of: #"(?<!\\)\s+$"#, with: "", options: .regularExpression)
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
        let negated = pattern.hasPrefix("!")
        if negated { pattern.removeFirst() }
        else if pattern.hasPrefix("\\#") || pattern.hasPrefix("\\!") { pattern.removeFirst() }
        let directory = pattern.hasSuffix("/")
        if directory { pattern.removeLast() }
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        guard !pattern.isEmpty else { return nil }
        let chars = Array(pattern)
        var result = anchored ? "^" : "(?:^|/)"
        var i = 0
        func escaped(_ character: Character) -> String { NSRegularExpression.escapedPattern(for: String(character)) }
        while i < chars.count {
            let character = chars[i]
            if character == "\\" {
                result += i + 1 < chars.count ? escaped(chars[i + 1]) : "\\\\"; i += 2; continue
            }
            if character == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    var end = i + 2
                    while end < chars.count && chars[end] == "*" { end += 1 }
                    if end < chars.count && chars[end] == "/" { result += "(?:.*/)?"; i = end + 1 }
                    else { result += ".*"; i = end }
                } else { result += "[^/]*"; i += 1 }
                continue
            }
            if character == "?" { result += "[^/]"; i += 1; continue }
            if character == "[" {
                var end = i + 1
                if end < chars.count && (chars[end] == "!" || chars[end] == "^") { end += 1 }
                if end < chars.count && chars[end] == "]" { end += 1 }
                while end < chars.count {
                    if chars[end] == "\\" { end += 2; continue }
                    if chars[end] == "]" { break }; end += 1
                }
                if end < chars.count {
                    var body = Array(chars[(i + 1)..<end]), value = "(?!/)["
                    if body.first == "!" || body.first == "^" { value += "^"; body.removeFirst() }
                    var position = 0
                    while position < body.count {
                        let char = body[position]
                        if char == "\\" {
                            value += "\\" + (position + 1 < body.count ? String(body[position + 1]) : "\\")
                            position += 2
                        } else {
                            value += char == "]" || char == "^" ? "\\" + String(char) : String(char)
                            position += 1
                        }
                    }
                    result += value + "]"; i = end + 1; continue
                }
            }
            result += escaped(character); i += 1
        }
        result += "$"
        guard (try? NSRegularExpression(pattern: result)) != nil else { return nil }
        return Rule(source: line, negated: negated, directoryOnly: directory, expression: result)
    }

    public static func credentialPath(_ relative: String) -> Bool {
        let fragments = [#"\.env(\.[^/]*)?$"#, #"\.envrc$"#, #"(\.npmrc|\.yarnrc\.yml|\.pypirc)$"#,
            #"(\.netrc|_netrc|\.pgpass|\.htpasswd)$"#, #"(\.git-credentials|\.credentials\.json|\.vault-token)$"#,
            #"id_(rsa|dsa|ecdsa|ed25519)(_sk)?$"#, #"[^/]*\.(pem|key|p8|p12|pfx|jks|keystore|asc|ppk)$"#,
            #"[^/]*\.(tfvars(\.json)?|tfstate(\.backup)?)$"#, #"(\.ssh|\.aws|\.gnupg|\.kube|\.azure|\.docker)(/.*)?$"#,
            #"(secrets?\.(json|ya?ml|toml|env)|[^/]*\.secrets?\.(json|ya?ml|toml))$"#, #"service-account[^/]*\.json$"#]
        let prefix = "(?:^|.*/)"
        if [#"\.env\.(example|sample|template|defaults|dist)$"#, #"\.env\.d\.ts$"#].contains(where: { relative.range(of: prefix + $0, options: .regularExpression) != nil }) { return false }
        return fragments.contains { relative.range(of: prefix + $0, options: .regularExpression) != nil }
    }
}
