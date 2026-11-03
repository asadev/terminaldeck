import Foundation

/// Claude Code renews its sign-in under a lock in its config folder: it sends the old renewal token
/// (the server retires it at once), then saves the new pair (on a Mac through `security`, a child in
/// Claude Code's own process group). Ending Claude Code, or that `security` child, in between loses the
/// only valid token, or makes Claude Code move the login to a plain file and delete its Keychain item;
/// the next start is refused and the person must sign in again (saba-pc, 1 Nov; this Mac, 28 Oct: the
/// Keychain item was deleted while two new Claude Code processes ran). So a process that may be Claude
/// Code is never stopped while a renewal is under way in its folder.
public enum NativeSignInRenewal {
    /// Claude Code touches its lock every 5 s and treats it as abandoned after 60 s.
    public static let abandoned: TimeInterval = 60
    /// A renewal is one server call and one save; every stop waits at most this long for one.
    public static let patience: TimeInterval = 30

    /// Claude Code's folder for a process: CLAUDE_CONFIG_DIR, else the user's ~/.claude (a terminal can
    /// also start `claude` by hand). nil environment: this process's own.
    public static func folder(environment: [String: String]?) -> String? {
        let values = environment ?? ProcessInfo.processInfo.environment
        if let configured = values["CLAUDE_CONFIG_DIR"] { return configured.hasPrefix("/") ? configured : nil }
        guard let home = values["HOME"], home.hasPrefix("/") else { return nil }
        return (home as NSString).appendingPathComponent(".claude")
    }

    /// The folder when the program is Claude Code (by its path or its script's) or is given its own
    /// CLAUDE_CONFIG_DIR; nil for any other program.
    public static func folder(command: String, arguments: [String] = [], environment: [String: String]?) -> String? {
        let named = ([command] + arguments.prefix(1)).contains { $0.lowercased().contains("claude") }
        guard named || environment?["CLAUDE_CONFIG_DIR"] != nil else { return nil }
        return folder(environment: environment)
    }

    /// `<folder>/.oauth_refresh.lock`, and the older `<folder>.lock` beside the folder.
    public static func locks(_ folder: String) -> [String] {
        var trimmed = folder
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return [(trimmed as NSString).appendingPathComponent(".oauth_refresh.lock"), trimmed + ".lock"]
    }

    public static func inProgress(_ folder: String?, now: Date = Date()) -> Bool {
        guard let folder else { return false }
        for path in locks(folder) {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(modified) < abandoned { return true }
        }
        return false
    }

    /// Runs `then` on `queue` once no renewal is under way in `folder`, after `patience` at the latest,
    /// or at once when `stillNeeded` turns false (the process already ended).
    public static func whenSettled(_ folder: String?, on queue: DispatchQueue, patience: TimeInterval = patience,
                                   stillNeeded: @escaping @Sendable () -> Bool = { true },
                                   then: @escaping @Sendable () -> Void) {
        let until = Date().addingTimeInterval(patience)
        @Sendable func check() {
            if !stillNeeded() || !inProgress(folder) || Date() >= until { then(); return }
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { check() }
        }
        queue.async { check() }
    }
}
