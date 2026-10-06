import Foundation

/// The checks behind "Join a remote session" (src/renderer/components/JoinRemoteDialog.tsx):
/// a session code is 8 characters of Crockford base32 (no I, L, O or U), written in
/// two groups of four; a PIN is 6 digits read out by the host. Nothing connects yet —
/// the dialog says so first — but what a person types is still checked as they type.
public enum JoinCode {
    /// Crockford base32: no I, L, O or U.
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    public static let codeLength = 8
    public static let pinLength = 6
    /// How the code is written down and read out: two groups of four.
    static let group = 4
    /// Session sharing has not shipped: the Join button stays disabled on this, not on the form.
    public static let remoteSessionsAvailable = false

    public enum Problem: String, Sendable { case empty, invalidCharacters = "invalid-characters", tooShort = "too-short", tooLong = "too-long" }

    public enum Check: Equatable, Sendable {
        case ok(String)
        case bad(Problem, String)

        public var isOK: Bool { if case .ok = self { return true } else { return false } }
        public var value: String? { if case .ok(let value) = self { return value } else { return nil } }
        public var problem: Problem? { if case .bad(let problem, _) = self { return problem } else { return nil } }
        public var message: String? { if case .bad(_, let message) = self { return message } else { return nil } }
    }

    /// Upper case, separators gone, and the glyphs the alphabet never uses read as
    /// the ones they look like: O → 0, I and L → 1. U is left to be reported.
    public static func normalizeCode(_ raw: String) -> String {
        var out = ""
        for character in raw.uppercased() {
            guard character.isASCII, character.isLetter || character.isNumber else { continue }
            switch character {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default: out.append(character)
            }
        }
        return out
    }

    /// Grouped for display, so a code on screen matches the one on the invite.
    public static func formatCode(_ code: String) -> String {
        let clean = Array(normalizeCode(code))
        var groups: [String] = []
        var index = 0
        while index < clean.count {
            groups.append(String(clean[index..<min(index + group, clean.count)]))
            index += group
        }
        return groups.joined(separator: "-")
    }

    public static func validateCode(_ raw: String) -> Check {
        let code = normalizeCode(raw)
        if code.isEmpty { return .bad(.empty, "Enter the code you were given.") }
        var bad: [Character] = []
        for character in code where !alphabet.contains(character) && !bad.contains(character) { bad.append(character) }
        if !bad.isEmpty {
            return .bad(.invalidCharacters, "Codes never contain \(bad.map(String.init).joined(separator: ", ")).")
        }
        if code.count > codeLength {
            return .bad(.tooLong, "That is \(code.count) characters — a code is \(codeLength).")
        }
        if code.count < codeLength {
            let missing = codeLength - code.count
            return .bad(.tooShort, "\(missing) more character\(missing == 1 ? "" : "s") to go.")
        }
        return .ok(code)
    }

    /// Digits only: a letter is dropped, never read as a digit.
    public static func normalizePin(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber })
    }

    public static func validatePin(_ raw: String) -> Check {
        let pin = normalizePin(raw)
        if pin.isEmpty { return .bad(.empty, "Enter the PIN the host read out.") }
        if pin.count > pinLength {
            return .bad(.tooLong, "That is \(pin.count) digits — a PIN is \(pinLength).")
        }
        if pin.count < pinLength {
            let missing = pinLength - pin.count
            return .bad(.tooShort, "\(missing) more digit\(missing == 1 ? "" : "s") to go.")
        }
        return .ok(pin)
    }

    public static func validateRequest(code: String, pin: String) -> Bool {
        validateCode(code).isOK && validatePin(pin).isOK
    }

    /// The line under a field: its complaint once touched or typed into, else the quiet hint.
    public static func codeNote(_ code: String, touched: Bool) -> (text: String, complaint: Bool) {
        let check = validateCode(code)
        if let message = check.message, touched || !code.isEmpty { return (message, true) }
        return (check.value.map(formatCode) ?? "\(codeLength) characters.", false)
    }

    public static func pinNote(_ pin: String, touched: Bool) -> (text: String, complaint: Bool) {
        let check = validatePin(pin)
        if let message = check.message, touched || !pin.isEmpty { return (message, true) }
        return (check.isOK ? "Looks right." : "\(pinLength) digits, from the host.", false)
    }

    /// The line under the disabled Join button.
    public static func status(code: String, pin: String) -> String {
        validateRequest(code: code, pin: pin)
            ? "Well formed — but there is still nothing to connect to."
            : "Enabled when session sharing ships."
    }
}
