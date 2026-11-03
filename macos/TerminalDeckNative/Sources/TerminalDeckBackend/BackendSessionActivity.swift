import Foundation
import TerminalDeckNativeCore

/// What `lastActivityAt` means (Asad, 1 Nov, item 58: an idle session must not say "Just now"): the last time
/// something really happened INSIDE the session, in ms since 1970.
/// - An AI session (Claude, Codex, Gemini in a terminal): its hooks only: a turn starting (the person's message),
///   a tool used, an approval asked, the turn ending, the session starting. Its screen's own repaints, a status
///   read off the screen, opening it, resizing it or listing it are not activity.
/// - A plain shell: its output, except its redraw for a new size or for a terminal joining it.
/// - A chat: its engine's turn changes.
/// - Any session: a person typing (not the mouse, focus or answers a terminal sends by itself), and its exit.
/// Kept in the app's session ledger (`activityAt`) so it survives an app restart; before anything is known, the
/// time the session started.
public enum BackendSessionActivity {
    static let redrawQuietMilliseconds = 2_000.0
    /// The hook events that are a real step of an AI's turn (every provider's names).
    public static let hookEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
        "Notification", "Stop", "StopFailure", "SubagentStop", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool",
    ]
    public static func hookCounts(_ event: String) -> Bool { hookEvents.contains(event) }
    /// Output counts only for a plain shell's terminal, and not while it redraws for a size change or a join.
    static func outputCounts(provider: String?, chat: Bool, at: Double, redrawUntil: Double?) -> Bool {
        guard !chat, provider == "shell" else { return false }
        return at > (redrawUntil ?? 0)
    }
    /// 2 Nov (item 65): when a Claude session last had a real turn, read from its own transcript (the newest
    /// `user` or `assistant` entry's `timestamp` in its last 512 KB), for a session whose activity was never kept
    /// (its work came before 1 Nov's install, or the app missed it). The file's modified time is not used: Claude
    /// touches the file on resume without a turn. Nil when not a Claude session or nothing is found.
    /// Every Claude home this app gives its sessions, for `transcriptActivity` (2 Nov, install-24 final check F2:
    /// a dev or scratch copy runs Claude with CLAUDE_CONFIG_DIR=<data>/agent-homes/claude, which was never read, so
    /// a restored chat said its start time). `sessionEnvironment` is the environment sessions are started with (the
    /// configuration's inheritedEnvironment, which carries BackendScratchAgentHomes); then the Mac's own ~/.claude and
    /// each saved account login's folder.
    public static func claudeHomes(home: URL, dataRoot: URL, sessionEnvironment: [String: String]) -> [String] {
        var out: [String] = []
        func add(_ path: String) {
            let path = (path as NSString).standardizingPath
            if !path.isEmpty, !out.contains(path) { out.append(path) }
        }
        if let configured = sessionEnvironment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            add(configured)
        }
        add(home.appendingPathComponent(".claude").path)
        let logins = dataRoot.appendingPathComponent("account-logins")
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: logins.path)) ?? []).sorted() where !name.hasPrefix(".") {
            add(logins.appendingPathComponent(name).path)
        }
        return out
    }
    public static func transcriptActivity(saved: NativeRPCValue, configDirectories: [String]) -> Double? {
        guard (saved["provider"].string ?? "claude") == "claude", let cwd = saved["cwd"].string, !cwd.isEmpty,
              let id = saved["agentSessionId"].string, id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return nil }
        let folder = String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        var latest: Double?
        for directory in configDirectories {
            let path = (directory as NSString).appendingPathComponent("projects/\(folder)/\(id).jsonl")
            guard let at = lastTurn(path) else { continue }
            latest = max(latest ?? 0, at)
        }
        return latest
    }
    static func lastTurn(_ path: String, tail: Int = 512 * 1024) -> Double? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var latest: Double?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  let stamp = object["timestamp"] as? String,
                  let date = iso.date(from: stamp) ?? plain.date(from: stamp) else { continue }
            latest = max(latest ?? 0, date.timeIntervalSince1970 * 1000)
        }
        return latest
    }
    /// The time a phone is sent: what this app saw, what the ledger kept from before a restart, else the start.
    public static func lastActivityAt(createdAt: Double, live: Double?, kept: Double?) -> Double {
        max(live ?? 0, kept ?? 0, createdAt)
    }
}
