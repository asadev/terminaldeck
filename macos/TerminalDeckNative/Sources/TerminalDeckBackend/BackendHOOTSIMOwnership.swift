import Foundation

/// Read only the CURRENT saved profile's instructions. Import source paths and
/// model-supplied candidate prose never establish product-file ownership.
public enum BackendHOOTSIMOwnership {
    public enum Claim: Sendable, Equatable { case owns, excludes, contradictory, unknown }
    private enum Section { case none, owned, excluded }

    public static func scopedFile(_ file: String, sourceFolder: String) -> String? {
        guard let sourceRoot = root(sourceFolder) else { return nil }
        return path(file, within: sourceRoot)?.0
    }

    public static func claim(instructions: String, file: String, sourceFolder: String, ownerFolder: String) -> Claim {
        guard instructions.utf16.count <= 32_000,
              let sourceRoot = root(sourceFolder), let ownerRoot = root(ownerFolder),
              let wanted = path(file, within: sourceRoot)?.0 else { return .unknown }
        var section: Section = .none, positive = false, negative = false, declarations = 0
        for original in instructions.components(separatedBy: .newlines) {
            let line = original.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.hasPrefix("#") {
                let heading = lower.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if heading == "scope — i own" || heading == "scope - i own" || heading == "scope: i own" ||
                    ["file ownership", "owned files", "files i own", "owned paths"].contains(heading) {
                    section = .owned
                } else if heading.hasPrefix("not mine") || heading.hasPrefix("not owned") ||
                    heading == "do not touch" || heading == "out of scope" {
                    section = .excluded
                } else { section = .none }
                continue
            }
            let explicit = capture(#"^(?:[-*]\s*)?(?:owns|i own|owned files|owned paths)\s*:?\s+(.+)$"#, line)
            let denied = section == .excluded || unsafeOwnershipLine(lower)
            guard section != .none || explicit != nil || denied else { continue }
            let content = explicit ?? line
            var paths = captures(#"`([^`]+)`"#, content)
            if paths.isEmpty, let explicit {
                paths = explicit.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if paths.isEmpty && denied {
                // Negative prose may be unquoted; it still prevents a positive
                // declaration from winning. A basename is never a suffix guess.
                paths = content.split(whereSeparator: \.isWhitespace).map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'(),;:"))
                }
            }
            for raw in paths {
                declarations += 1
                guard declarations <= 256 else { return .unknown }
                guard let candidate = path(raw, within: ownerRoot) else { continue }
                let matches = wanted == candidate.0 || (candidate.1 && wanted.hasPrefix(candidate.0 + "/"))
                guard matches else { continue }
                if denied { negative = true }
                else if section == .owned || explicit != nil { positive = true }
            }
        }
        if positive && negative { return .contradictory }
        if negative { return .excludes }
        return positive ? .owns : .unknown
    }

    private static func unsafeOwnershipLine(_ line: String) -> Bool {
        line.range(of: #"\b(?:not|never|only|except|borrowed|ruling|after|unless|until)\b|don't|do not|hand off|someone else's|another agent|[a-z0-9_-]+(?:'s|’s) (?:file|layer)|\bonly on\b"#,
                   options: .regularExpression) != nil
    }
    private static func root(_ value: String) -> String? {
        guard value.hasPrefix("/"), value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func path(_ value: String, within root: String) -> (String, Bool)? {
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.contains("://"), !value.contains("\\"), !value.contains("~"),
              !value.contains(where: { "*?[]{}".contains($0) }),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              value.contains("/") || value.contains(".") || ["Makefile", "Dockerfile", "README"].contains(value) else { return nil }
        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(fileURLWithPath: root).appendingPathComponent(value)
        guard let actual = resolved(url) else { return nil }
        let prefix = root == "/" ? "/" : root + "/"
        guard actual.hasPrefix(prefix), actual != root else { return nil }
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: actual, isDirectory: &isDirectory)
        return (actual, value.hasSuffix("/") || (exists && isDirectory.boolValue))
    }
    /// Foundation leaves a path untouched when its last part does not exist yet,
    /// so a symlinked folder could hide behind a missing file name. Resolve the
    /// deepest part that exists (without following it to check), then re-add the rest.
    private static func resolved(_ url: URL) -> String? {
        var existing = url.standardizedFileURL, rest: [String] = []
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil {
            guard existing.path != "/" else { return nil }
            rest.insert(existing.lastPathComponent, at: 0); existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath()
        // A dangling link cannot be resolved, so it can never prove ownership.
        guard FileManager.default.fileExists(atPath: result.path) else { return nil }
        for part in rest { result.appendPathComponent(part) }
        return result.standardizedFileURL.path
    }
    private static func captures(_ pattern: String, _ value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let source = value as NSString
        return expression.matches(in: value, range: NSRange(location: 0, length: source.length)).compactMap {
            $0.numberOfRanges > 1 ? source.substring(with: $0.range(at: 1)) : nil
        }
    }
    private static func capture(_ pattern: String, _ value: String) -> String? { captures(pattern, value).first }
}
