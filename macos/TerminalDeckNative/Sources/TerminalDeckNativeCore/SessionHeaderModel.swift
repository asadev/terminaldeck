import Foundation

// The words on a session's bar: its name as somebody types it (`session-title.ts`:
// `userSessionTitle`), and its folder (`FolderChip.tsx`).

public enum SessionTitleRules {
    /// `MAX_TITLE_LENGTH`.
    public static let maxLength = 40

    /// `userSessionTitle`: the typed name cleaned and shortened, or nil for a blank (a cancel).
    public static func typed(_ raw: String, max: Int = maxLength) -> String? {
        let cleaned = clean(raw)
        return cleaned.isEmpty ? nil : truncate(cleaned, max: max)
    }

    /// `cleanTitleText`: no escape sequences, injected blocks or control characters;
    /// runs of whitespace become one space; a leading conversation id goes.
    public static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        for block in [#"<system-reminder>[\s\S]*?</system-reminder>"#, #"<local-command-caveat>[\s\S]*?</local-command-caveat>"#,
                      #"<command-name>[\s\S]*?</command-args>"#] {
            text = text.replacingOccurrences(of: block, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"[\u0000-\u001F\u007F]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b[\s:,-]*"#,
                                         with: "", options: [.regularExpression, .caseInsensitive])
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `truncateOnWordBoundary`: at most `max` characters, breaking between words
    /// when a space falls in the second half, with an ellipsis as the last character.
    public static func truncate(_ text: String, max: Int = maxLength) -> String {
        guard max > 0 else { return "" }
        let chars = Array(text)
        guard chars.count > max else { return text }
        let budget = max - 1
        guard budget > 0 else { return "…" }
        let window = Array(chars.prefix(budget + 1))
        let lastSpace = window.lastIndex(of: " ")
        let head: String
        if let lastSpace, lastSpace >= Int((Double(budget) * 0.5).rounded(.down)) {
            head = String(window[..<lastSpace])
        } else {
            head = String(chars.prefix(budget))
        }
        let trimmed = head.replacingOccurrences(of: #"[\s,.;:!?/\\|—–-]+$"#, with: "", options: .regularExpression)
        return (trimmed.isEmpty ? String(chars.prefix(budget)) : trimmed) + "…"
    }
}

public enum SessionFolder {
    /// `folderLabel`: the last part of the path, either separator.
    public static func label(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// `shownFolderName`: the assistant's own folder is named for it.
    public static func shown(_ path: String, assistant: Bool = false, assistantName: String = "Hoot") -> String {
        let own = label(path)
        return assistant && (own == "hoot" || own == "copilot") ? "\(assistantName)’s folder" : own
    }

    /// The folder chip's hover label.
    public static func help(_ path: String) -> String {
        "\(path)\nA session keeps this folder for its whole life. Start another to work somewhere else."
    }
}
