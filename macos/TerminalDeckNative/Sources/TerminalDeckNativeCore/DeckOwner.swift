import Foundation

/// U33, the person this copy of the app belongs to: read from the Mac account, never built in. Every
/// "Message from …" label on what the person typed, and every line that names them to an AI, comes from here.
public enum DeckOwner {
    /// The Mac account's full name, or its short name when the account has none.
    public static var name: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }
    /// The source title on a message the person typed.
    public static var messageTitle: String { title(name) }
    public static func title(_ sender: String) -> String { "Message from " + sender }

    /// Whether a saved message's source title, or a sender name, is the person's own. Chats saved by builds
    /// before 18 Oct 2026 carry the developer's name; on his Mac they still read as his own.
    public static func isOwn(title: String? = nil, sender: String? = nil) -> Bool {
        if let title, title == messageTitle || title == Self.title(earlierBuildsName) { return true }
        if let sender, sender == name || sender == earlierBuildsName { return true }
        return false
    }
    static let earlierBuildsName = "Asad Iqbal"
}
