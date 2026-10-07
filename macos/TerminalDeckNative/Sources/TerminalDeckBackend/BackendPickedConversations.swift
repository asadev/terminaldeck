import Foundation
import TerminalDeckNativeCore

/// Port of src/main/picked-conversation.ts: learns which conversation a tab opened
/// on Claude Code's list ended up on, from the SessionStart hook or the CLI's own
/// per-process record. An id counts only when its transcript exists, non-empty,
/// under the watched folder.
public struct BackendPickWatch: Sendable {
    public let cwd: String
    public let configDir: String
    public init(cwd: String, configDir: String) { self.cwd = cwd; self.configDir = configDir }
}

public struct BackendPickHookNote: Sendable {
    public let provider: String
    public let event: String
    public let sessionID: String?
    public let cliSessionID: String?
    public init(provider: String, event: String, sessionID: String?, cliSessionID: String?) {
        self.provider = provider; self.event = event; self.sessionID = sessionID; self.cliSessionID = cliSessionID
    }
}

public enum BackendPickedRules {
    public static let typingGapMilliseconds: Double = 3000

    public static func hasTranscript(_ watch: BackendPickWatch, conversationID: String) async -> Bool {
        guard conversationID.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil else { return false }
        for spelling in NativeTranscriptPaths.projectSpellings(watch.cwd) {
            let file = URL(fileURLWithPath: watch.configDir).appendingPathComponent("projects")
                .appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(spelling)).appendingPathComponent(conversationID + ".jsonl")
            if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true, (values.fileSize ?? 0) > 0 { return true }
        }
        return false
    }

    public static func sessionFileConversation(configDir: String, pid: Int) async -> String? {
        let file = URL(fileURLWithPath: configDir).appendingPathComponent("sessions").appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let owner = object["pid"] as? NSNumber, owner.intValue == pid,
              let session = object["sessionId"] as? String else { return nil }
        return session
    }
}

public actor BackendPickedConversations {
    private struct Watched {
        let watch: BackendPickWatch
        let generation: Int
        var known: String?
        var readAt: Double
    }
    private var watching: [String: Watched] = [:]
    private var generation = 0
    private let pidOf: @Sendable (String) -> Int?
    private let learned: @Sendable (String, String) -> Void
    private let now: @Sendable () -> Double

    public init(pidOf: @escaping @Sendable (String) -> Int?, learned: @escaping @Sendable (String, String) -> Void,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.pidOf = pidOf; self.learned = learned; self.now = now
    }

    public func watch(_ sessionID: String, _ watch: BackendPickWatch) {
        generation += 1
        watching[sessionID] = Watched(watch: watch, generation: generation, known: nil, readAt: -.infinity)
    }

    public func forget(_ sessionID: String) { watching[sessionID] = nil }

    public func noteHook(_ note: BackendPickHookNote) async {
        guard note.provider == "claude", note.event == "SessionStart", let session = note.sessionID, let cli = note.cliSessionID else { return }
        await consider(session, cli)
    }

    public func noteTyping(_ sessionID: String) async {
        guard var entry = watching[sessionID] else { return }
        let current = now()
        if current - entry.readAt < BackendPickedRules.typingGapMilliseconds { return }
        entry.readAt = current
        watching[sessionID] = entry
        guard let pid = pidOf(sessionID) else { return }
        if let candidate = await BackendPickedRules.sessionFileConversation(configDir: entry.watch.configDir, pid: pid) {
            await consider(sessionID, candidate)
        }
    }

    private func consider(_ sessionID: String, _ candidate: String) async {
        guard let entry = watching[sessionID], entry.known != candidate else { return }
        guard await BackendPickedRules.hasTranscript(entry.watch, conversationID: candidate) else { return }
        // Forgotten, or re-watched, while the disk was being asked.
        guard watching[sessionID]?.generation == entry.generation else { return }
        watching[sessionID]?.known = candidate
        learned(sessionID, candidate)
    }
}
