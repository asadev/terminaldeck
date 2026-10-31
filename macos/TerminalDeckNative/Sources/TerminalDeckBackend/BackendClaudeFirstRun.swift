import Foundation

/// L8 (11 Oct, FORK-TASKS / Asad's morning): an app-started Claude Code session must never open on Claude Code's
/// first-run screen (theme, then sign-in steps), where nobody is watching and the brief can never be typed.
///
/// Claude Code shows that screen exactly when its config file says `hasCompletedOnboarding` is not true (read in
/// claude 2.1.x: the onboarding step runs when `!config.hasCompletedOnboarding`; no launch option or environment
/// variable skips it, and a sign-out sets the flag back to false, which is what happened to his file this morning).
/// The config file is `$CLAUDE_CONFIG_DIR/.claude.json` for a session with its own config folder (an app-kept
/// login), else `~/.claude.json`.
///
/// So, right before such a session starts, and only when the flag is not already true:
/// - the ONE key is set to true by a minimal text edit: every other key, its order, spacing and numbers stay
///   byte for byte; the result is parsed and compared with the original minus that key, and nothing is written
///   unless they are equal;
/// - nothing is written while Claude Code holds its own lock on the file (`<file>.lock`), or if the file changed
///   while it was being read; the write is atomic (temporary file + rename) and keeps the file's permissions;
/// - the person's own `~/.claude.json` is never CREATED (a missing one means Claude Code has never run there);
///   an app-kept login's folder belongs to the app, so a missing file there is created with just that key.
/// Every change is returned as one line for the log.
public enum BackendClaudeFirstRun {
    public static let key = "hasCompletedOnboarding"

    public static func configFile(configDirectory: String?, home: String) -> URL {
        if let configDirectory, !configDirectory.isEmpty { return URL(fileURLWithPath: configDirectory).appendingPathComponent(".claude.json") }
        return URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
    }

    /// Nil when nothing had to change; otherwise the log line (done, or why it was left alone).
    @discardableResult
    public static func ensureOnboarded(configDirectory: String?, home: String) -> String? {
        let ownFolder = configDirectory.map { !$0.isEmpty } ?? false
        let file = configFile(configDirectory: configDirectory, home: home)
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else {
            guard ownFolder else { return nil }
            do {
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = Data("{\n  \"\(key)\": true\n}\n".utf8)
                guard manager.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                return "Claude Code first-run screen skipped for a session: created \(file.path) with only \(key)=true (the app's own login folder)."
            } catch { return "Claude Code may show its first-run screen: \(file.path) could not be created (\(error.localizedDescription))." }
        }
        guard let before = try? manager.attributesOfItem(atPath: file.path), let size = (before[.size] as? NSNumber)?.intValue, size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Claude Code may show its first-run screen: \(file.path) could not be read as JSON, so it was left alone."
        }
        if object[key] as? Bool == true { return nil }
        guard !manager.fileExists(atPath: file.path + ".lock") else {
            return "Claude Code may show its first-run screen: \(file.path) is being written by Claude Code right now, so it was left alone."
        }
        guard let edited = edit(text), let changed = try? JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any],
              changed[key] as? Bool == true, NSDictionary(dictionary: changed.filter { $0.key != key }).isEqual(to: object.filter { $0.key != key }) else {
            return "Claude Code may show its first-run screen: \(key) could not be set in \(file.path) without touching anything else, so it was left alone."
        }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).td-\(UUID().uuidString.prefix(8))")
        do {
            let mode = (before[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
            guard manager.createFile(atPath: temporary.path, contents: Data(edited.utf8), attributes: [.posixPermissions: mode]) else { throw CocoaError(.fileWriteUnknown) }
            // Changed while it was being read (Claude Code wrote it)? Then leave it: the next start looks again.
            let now = try manager.attributesOfItem(atPath: file.path)
            guard (now[.modificationDate] as? Date) == (before[.modificationDate] as? Date), (now[.size] as? NSNumber)?.intValue == size,
                  !manager.fileExists(atPath: file.path + ".lock") else {
                try? manager.removeItem(at: temporary)
                return "Claude Code may show its first-run screen: \(file.path) changed while it was being read, so it was left alone."
            }
            guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            return "Claude Code first-run screen skipped for a session: set only \(key)=true in \(file.path) (every other key kept as it was)."
        } catch {
            try? manager.removeItem(at: temporary)
            return "Claude Code may show its first-run screen: \(file.path) could not be updated (\(error.localizedDescription))."
        }
    }

    /// The smallest text change: an existing `"hasCompletedOnboarding": <anything but true>` becomes true; a file
    /// without the key gets it as the first member of the top-level object. Nil when neither fits.
    static func edit(_ text: String) -> String? {
        let existing = #"("hasCompletedOnboarding"\s*:\s*)(false|null|0|"[^"]*")"#
        if let range = text.range(of: existing, options: .regularExpression) {
            let match = String(text[range])
            guard let value = match.range(of: #"(false|null|0|"[^"]*")$"#, options: .regularExpression) else { return nil }
            return text.replacingCharacters(in: range, with: String(match[..<value.lowerBound]) + "true")
        }
        guard text.range(of: "\"" + key + "\"") == nil, let brace = text.firstIndex(of: "{") else { return nil }
        let rest = text[text.index(after: brace)...]
        let empty = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
        return String(text[...brace]) + "\n  \"\(key)\": true" + (empty ? "\n" : ",") + rest
    }
}
