import Foundation

// Siri / Shortcuts (lane R): the pure half of the App Intents.
// Everything here is plain Foundation so the test target can pin every sentence
// Siri says; the intents themselves live in the app target (`Intents*.swift`).

/// What an intent says: a short line Siri speaks, and every line behind it
/// (shown under Siri's answer, and handed to Shortcuts as the intent's output).
public struct IntentAnswer: Equatable, Sendable {
    public var spoken: String
    public var detail: [String]

    public init(spoken: String, detail: [String] = []) {
        self.spoken = spoken
        self.detail = detail
    }

    /// The detail as one text, or the spoken line when there is no detail.
    public var detailText: String {
        detail.isEmpty ? spoken : detail.joined(separator: "\n")
    }
}

/// A plain sentence for anything that went wrong. Siri reads it out as it is.
public enum IntentProblem: Error, Equatable, Sendable, CustomStringConvertible {
    /// The engine is not up and did not come up in time.
    case starting
    /// The engine stopped or could not start; its own reason.
    case down(String)
    /// The engine answered with a refusal; its own sentence.
    case refused(String)
    /// Anything else, already worded.
    case plain(String)

    public var sentence: String {
        switch self {
        case .starting:
            return "Terminal Deck is still starting. Try again in a moment."
        case .down(let why):
            let reason = IntentSpeech.sentenceCase(IntentSpeech.cleanError(why))
            return reason.isEmpty ? "Terminal Deck isn't running." : "Terminal Deck isn't running. \(IntentSpeech.ending(reason))"
        case .refused(let why):
            let reason = IntentSpeech.cleanError(why)
            return reason.isEmpty ? "Terminal Deck said no to that." : IntentSpeech.ending(IntentSpeech.sentenceCase(reason))
        case .plain(let text):
            return text
        }
    }

    public var description: String { sentence }

    /// The engine bridge's own errors, in the same plain voice.
    public static func from(_ error: EngineWireError) -> IntentProblem {
        switch error {
        case .notReady: return .starting
        case .malformed: return .plain("Terminal Deck gave an answer I couldn't read.")
        case .refused(let why): return .refused(why)
        case .http(let code): return .plain("Terminal Deck didn't answer (error \(code)).")
        }
    }
}

/// Turning the app's text into something worth hearing.
public enum IntentSpeech {
    /// About two spoken sentences.
    public static let spokenLimit = 240

    /// Markdown and terminal text as plain sentences: code blocks dropped, links
    /// to their words, list markers and emphasis gone, one line.
    public static func plain(_ text: String) -> String {
        var lines: [String] = []
        var inFence = false
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            var line = trimmed
            // Headings, quotes, bullets and numbered items.
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^>\s?"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^([-*+•]|\d{1,3}[.)])\s+"#, with: "", options: .regularExpression)
            // Links and images: [words](url) → words.
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            // Emphasis and inline code markers (never a lone underscore inside a word).
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "`", with: "")
            // Table rules and horizontal rules say nothing aloud.
            if line.range(of: #"^[|\-:\s=*_]+$"#, options: .regularExpression) != nil { continue }
            line = line.replacingOccurrences(of: "|", with: " ")
            line = collapse(line)
            if line.isEmpty { continue }
            lines.append(ending(line))
        }
        return collapse(lines.joined(separator: " "))
    }

    /// At most `limit` characters, ending on a sentence when one ends late enough,
    /// otherwise on a word with an ellipsis.
    public static func shorten(_ text: String, limit: Int = spokenLimit) -> String {
        let flat = collapse(text)
        guard flat.count > limit, limit > 1 else { return flat }
        let window = String(flat.prefix(limit))
        // The last sentence end inside the window, if it keeps at least a third of it.
        var lastEnd: String.Index?
        var index = window.startIndex
        while index < window.endIndex {
            let next = window.index(after: index)
            if ".!?".contains(window[index]), next == window.endIndex || window[next] == " " {
                lastEnd = next
            }
            index = next
        }
        if let lastEnd, window.distance(from: window.startIndex, to: lastEnd) >= limit / 3 {
            return String(window[..<lastEnd])
        }
        let cut = String(flat.prefix(limit - 1))
        let atWord = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—")) + "…"
    }

    /// "A", "A and B", "A, B and C", "A, B, C and 2 more".
    public static func list(_ names: [String], max: Int = 3) -> String {
        let shown = Array(names.prefix(Swift.max(1, max)))
        let rest = names.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        switch shown.count {
        case 0: return ""
        case 1: return shown[0]
        default: return shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        }
    }

    /// "1 task", "3 tasks".
    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// Ends with a full stop unless it already ends a sentence.
    public static func ending(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…:".contains(last) ? trimmed : trimmed + "."
    }

    /// First letter upper-cased, the rest left alone.
    public static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// An engine error without the plumbing around it ("Error invoking remote
    /// method 'x': Error: tasks: …" → "…").
    public static func cleanError(_ raw: String) -> String {
        var text = collapse(raw)
        if let range = text.range(of: #"^Error invoking remote method '[^']*':\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        while let range = text.range(of: #"^(Error|TypeError|RangeError):\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        // A channel's own prefix ("tasks: ", "chat: ") is not part of the sentence.
        if let range = text.range(of: #"^[a-z][a-z-]{1,20}:\s+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
    }

    /// Runs of whitespace (newlines included) as one space, trimmed.
    public static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
