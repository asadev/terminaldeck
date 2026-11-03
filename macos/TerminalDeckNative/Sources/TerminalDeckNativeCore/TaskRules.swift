import Foundation

public enum TaskStatuses {
    public static let all = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]
    public static let boardOrder = Array(all.filter { $0 != "Done" }) + ["Done"]
    public static func next(_ status: String) -> String? {
        switch status {
        case "To-Do": "Working on it"
        case "Working on it", "Stuck": "In Progress"
        case "In Progress": "Done"
        default: nil
        }
    }
}

/// Name-to-id mechanics shared by agent forms, task configuration, seats and routines.
/// Agents fold accents; role and routine ids retain their existing ASCII-only rule.
public enum TaskNames {
    public static func slug(_ name: String, limit: Int = 64, foldAccents: Bool = false) -> String {
        let text = foldAccents ? name.decomposedStringWithCompatibilityMapping.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) : name
        let words = text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(words.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    public static func agentID(_ name: String, taken: Set<String> = []) -> String {
        let slug = slug(name, limit: 36, foldAccents: true)
        let base = slug.isEmpty ? "agent" : slug
        var id = base, suffix = 2
        while taken.contains(id) { id = base + "-" + String(suffix); suffix += 1 }
        return id
    }
}
