import Foundation

/// Which environment values live Docker output must hide. Real secrets only:
/// values under secret-looking names, credentials inside URLs, and long random
/// strings. Dates, times, versions, numbers, words and paths stay readable.
public enum BackendDockerSecretFilter {
    static let secretNameParts = ["PASS", "SECRET", "TOKEN", "KEY", "PRIVATE", "CREDENTIAL", "AUTH", "DSN", "SALT",
                                  "COOKIE", "SESSION", "SIGNATURE", "CERT", "CONNECTION", "WEBHOOK", "BEARER", "JWT"]
    static let plainWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "none", "enabled", "disabled"]

    public static func isSecret(name: String, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !plainWords.contains(trimmed.lowercased()) else { return false }
        if trimmed.contains("://"), trimmed.contains("@") { return true }   // user:password@host
        let upper = name.uppercased()
        if secretNameParts.contains(where: { upper.contains($0) }) { return trimmed.count >= 4 && !isPlainNumber(trimmed) }
        return looksRandom(trimmed)
    }

    static func isPlainNumber(_ text: String) -> Bool { text.allSatisfy { $0.isNumber || ".,:-_ ".contains($0) } }

    /// Long, mixed, high-entropy, no spaces, not a path, URL, date or version.
    static func looksRandom(_ text: String) -> Bool {
        guard text.count >= 20, !text.contains(where: \.isWhitespace), !text.hasPrefix("/"), !text.contains("://"),
              !isPlainNumber(text) else { return false }
        let classes = [text.contains(where: \.isLowercase), text.contains(where: \.isUppercase), text.contains(where: \.isNumber)].filter { $0 }.count
        // Timestamps and versions are mostly digits with a letter or two.
        guard classes >= 2, text.filter(\.isLetter).count >= 6 else { return false }
        var counts: [Character: Int] = [:]
        for char in text { counts[char, default: 0] += 1 }
        let length = Double(text.count)
        let entropy = counts.values.reduce(0.0) { sum, n in let p = Double(n) / length; return sum - p * log2(p) }
        return entropy >= 3.5
    }
}
