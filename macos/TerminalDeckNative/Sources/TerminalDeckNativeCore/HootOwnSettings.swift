import Foundation

/// Hoot's own settings, in one place: only the person changes them, never Hoot itself (Asad, 11 Oct: "Hoot should be
/// able to do all of it other than its own"). Every tool that writes settings for Hoot checks this list.
/// Explicit keys first; the prefixes and the name rule are only a second net.
public enum HootOwnSettings {
    public static let providers = ["claude", "codex", "gemini"]
    /// Each key, named: Hoot's permission mode, its AI and account, its folder. (The four "What Hoot may do" switches
    /// were retired on 12 Oct: Hoot can always do those things, and their saved values are removed at start.)
    public static let keys: Set<String> = {
        var keys: Set<String> = [
            "hoot.provider",                      // which Coding AI Hoot runs on
            "hoot.home",                          // Hoot's own folder
        ]
        for provider in providers {
            for field in ["permission", "account", "model", "effort", "context", "fast"] { keys.insert("hoot.\(field).\(provider)") }
        }
        return keys
    }()
    /// The settings groups that also hold app-wide settings Hoot MAY change (remote access, deck-control, security,
    /// confinement): inside them, a setting about Hoot itself (which devices may reach it, its own box) is its own.
    public static let sharedGroups = ["remote.", "deckControl.", "security.", "confine."]
    public static let prefixes = ["hoot.", "copilot."]

    public static func isOwn(_ key: String) -> Bool {
        if keys.contains(key) { return true }
        if prefixes.contains(where: key.hasPrefix) { return true }
        // Second net: a shared-group setting whose name is about Hoot.
        let low = key.lowercased()
        return sharedGroups.contains(where: key.hasPrefix) && (low.contains("hoot") || low.contains("copilot"))
    }
    /// For the check: does this setting's own description say it is about Hoot?
    public static func describesHoot(id: String, label: String, help: String, more: String?) -> Bool {
        let text = (id + " " + label + " " + help + " " + (more ?? "")).lowercased()
        return text.contains("hoot") || text.contains("copilot") || text.contains("your assistant")
    }
}
