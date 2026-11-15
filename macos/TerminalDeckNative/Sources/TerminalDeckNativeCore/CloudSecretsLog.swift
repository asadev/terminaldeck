import Foundation

/// One plain line in the app's log for every state change of saved passwords on this Mac (Security, 14 Nov: after the
/// first install nobody could tell from a Mac whether saved passwords had turned on).
///
/// THE RULE: a line carries device NAMES, counts, dates, the service's short refusal codes and plain words ONLY. Never
/// a key, a code (matching or transfer), a token, a password, a challenge, a signature, an id of any kind (device,
/// approval, credential, request, account) or his e-mail. Every line passes `safe` before it is written; a line that
/// fails is replaced by `withheld` and never written as it was. Names go through `name` first. The scan is pinned by
/// `CloudSecretsLogTests`, which runs every flow and checks every line written.
public struct CloudSecretsLog: Sendable {
    public static let prefix = "cloud passwords: "
    public static let withheld = "a line was left out because it looked like it could carry a secret"
    private let write: @Sendable (String) -> Void
    public init(_ write: @escaping @Sendable (String) -> Void) { self.write = write }
    public static let none = CloudSecretsLog { _ in }
    public func say(_ text: String) { write(Self.line(text)) }

    /// The full line as written: the prefix and the words, or the fixed withheld sentence.
    public static func line(_ text: String) -> String {
        let full = prefix + text
        return safe(full) ? full : prefix + withheld
    }
    /// False for anything that could be a secret or an identifier:
    /// - an "@" (an e-mail);
    /// - any word of 24 characters or more (keys, tokens, signatures, challenges, base64 of any kind);
    /// - a run of 12 or more hex characters (ids, hashes; every UUID has one);
    /// - a run of 7 or more digits (times in milliseconds, numeric ids);
    /// - three groups of four hex characters in a row (a matching or transfer code).
    public static func safe(_ line: String) -> Bool {
        if line.contains("@") { return false }
        let words = line.split(whereSeparator: { $0.isWhitespace || ",;()[]{}\"'".contains($0) })
        if words.contains(where: { $0.count >= 24 }) { return false }
        for pattern in ["[0-9A-Fa-f]{12,}", "[0-9]{7,}", "[0-9A-F]{4} [0-9A-F]{4} [0-9A-F]{4}"] {
            if line.range(of: pattern, options: .regularExpression) != nil { return false }
        }
        return true
    }
    /// A device name as a line shows it: one line (breaks and control characters become spaces), ".local" dropped,
    /// no "@", at most 20 characters, never empty.
    public static func name(_ raw: String?) -> String {
        // Line breaks and control characters become a space: a name can never start a line of its own.
        let flat = String(String.UnicodeScalarView((raw ?? "").unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        var text = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".local") { text = String(text.dropLast(6)) }
        text = text.replacingOccurrences(of: "@", with: " ")
        if text.count > 20 { text = String(text.prefix(19)) + "…" }
        return text.isEmpty ? "a device with no name" : text
    }
    /// A date for a line (his Mac's own time zone), e.g. "14 Nov 2026 15:02".
    public static func date(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }
    /// The service's refusal code as a line may show it: lower-case letters and "_" only, at most 22 characters.
    public static func code(_ raw: String) -> String {
        let kept = raw.lowercased().filter { ("a"..."z").contains($0) || $0 == "_" }
        return kept.isEmpty ? "no code" : String(kept.prefix(22))
    }
    /// PASSWORDS-5: a refusal of the spare routes (add, replace) in plain words, each code its own; anything else as `cause`.
    public static func spareCause(_ error: any Error) -> String {
        if error is CloudSecretsPasskeyExcluded { return "the passkey of your spare key is still on this Mac" }
        guard case .remote(let detail)? = error as? CloudFailure else { return cause(error) }
        let words: String?
        switch detail.code {
        case "spare_exists": words = "a spare key is already on file for this key"
        case "no_spare": words = "there is no spare key on file to replace"
        case "spare_changed": words = "the spare key was changed on another device meanwhile"
        case "spare_unchanged": words = "the new passkey is the one already on file"
        case "version_changed": words = "saved passwords changed meanwhile on another device"
        case "approval_expired": words = "the request ran out before the passkey was made"
        case "rate_limited": words = "the spare key was replaced too often this hour; try again later"
        case "not_approved": words = "this Mac may not change the spare key"
        case "spare_signature": words = "the service did not accept this Mac's signature"
        default: words = detail.code.hasPrefix("passkey_") ? "the service did not accept the new passkey" : nil
        }
        guard let words else { return cause(error) }
        return words + " (" + code(detail.code) + ")"
    }
    /// A failure in plain words. Never the error's own text (it may quote ids).
    public static func cause(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let plain = error as? CloudSecretsPlainFailure { return plain.reason }
        if let failure = error as? CloudFailure {
            switch failure {
            case .remote(let detail): return "the service refused (" + code(detail.code) + ")"
            case .invalidRequest: return "it did not pass this Mac's checks"
            case .unsupportedFormat: return "an answer in a form this Mac does not take"
            case .unsafeConfiguration: return "this copy of the app is not set up for it"
            case .unavailable: return "not available just now"
            case .gateClosed: return "Cloud is not open for this account right now"
            case .storageRequired: return "Cloud storage is needed first"
            case .checksumMismatch: return "a check of the answer failed"
            case .idReused: return "a request was used twice"
            case .versionChanged: return "saved passwords changed meanwhile on another device"
            case .secretsLocked: return "this Mac does not hold the key"
            case .deviceRevoked: return "this device was removed from the account"
            case .budgetPaused: return "Cloud is paused for this account"
            }
        }
        let ns = error as NSError
        let domain = ns.domain.split(separator: ".").last.map(String.init) ?? "system"
        return "system error " + String(domain.prefix(20)) + " " + String(ns.code)
    }
}

/// A failure whose plain reason was already worded where it happened (the system's passkey sheet). The reason follows
/// the log rule (no ids, no codes of his).
public struct CloudSecretsPlainFailure: Error, Sendable, Equatable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
}
