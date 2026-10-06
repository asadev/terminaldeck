import Foundation

// What the island shows when it grows (lane B), as rules a test can ask:
//   - renderer/island/IslandPage.tsx — `linesOf`, the words;
//   - renderer/island/native-island.ts — `hootRunsIn`, `mergeIslandMessages`, `ISLAND_MESSAGES`;
//   - renderer/hoot-panel/HootPanel.tsx — `AllSessions` and `what`;
//   - shared/hoot-panel-model.ts — `allSessionsInOrder`.
// The main page hands the session list over as `{type: 'island-snapshot', snapshot}`,
// the same snapshot it gives the island's own page.

public struct IslandSessionRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let status: String

    public init(id: String, label: String, status: String) {
        self.id = id; self.label = label; self.status = status
    }
}

public struct IslandSnapshot: Equatable, Sendable {
    public let assistant: String
    public let stage: String?
    public let sessions: [IslandSessionRow]
    public let line: String
}

public enum IslandContent {
    public static let messageType = "island-snapshot"
    /// `ISLAND_MESSAGES`: the last few lines, no more.
    public static let maxMessages = 8
    private static let statuses: Set<String> = ["idle", "working", "waiting", "input", "completed", "exited"]

    public static func isSnapshotMessage(_ body: Any) -> Bool {
        (body as? [String: Any])?["type"] as? String == messageType
    }

    /// The snapshot, read the way `readSnapshot` reads sessions: an id is required,
    /// a missing label is "Session", an unknown status is idle.
    public static func snapshot(_ body: Any) -> IslandSnapshot? {
        guard isSnapshotMessage(body), let raw = (body as? [String: Any])?["snapshot"] as? [String: Any] else { return nil }
        let assistant = (raw["assistant"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? CopilotWords.assistant
        var rows: [IslandSessionRow] = []
        for case let entry as [String: Any] in (raw["sessions"] as? [Any]) ?? [] {
            guard let id = entry["id"] as? String else { continue }
            let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Session"
            let status = (entry["status"] as? String).flatMap { statuses.contains($0) ? $0 : nil } ?? "idle"
            rows.append(IslandSessionRow(id: id, label: label, status: status))
        }
        return IslandSnapshot(assistant: assistant, stage: raw["stage"] as? String, sessions: rows,
                              line: (raw["line"] as? String) ?? assistant)
    }

    /// `allSessionsInOrder`: needs you, then working, then the rest, then ended.
    public static func inOrder(_ sessions: [IslandSessionRow]) -> [IslandSessionRow] {
        func rank(_ status: String) -> Int {
            status == "input" ? 0 : status == "working" ? 1 : status == "exited" ? 3 : 2
        }
        return sessions.enumerated()
            .sorted { rank($0.element.status) == rank($1.element.status) ? $0.offset < $1.offset : rank($0.element.status) < rank($1.element.status) }
            .map(\.element)
    }

    /// `what`: the words beside a session's dot.
    public static func what(_ status: String) -> String {
        switch status {
        case "input": return "needs you"
        case "working": return "working"
        case "completed": return "finished"
        case "exited": return "ended"
        default: return "idle"
        }
    }

    /// `linesOf`: Hoot's conversation lines from `chat:load` / `chat:tail`, and whether
    /// the answer starts over.
    public static func lines(_ value: Any) -> (lines: [IntentChatLine], reset: Bool) {
        let reset = (value as? [String: Any])?["reset"] as? Bool ?? false
        return (IntentHoot.lines(value).lines, reset)
    }

    /// `mergeIslandMessages`: a line already held is replaced where it stands, a new one
    /// goes last; only the last `maxMessages` are kept.
    public static func merge(_ held: [IntentChatLine], _ update: [IntentChatLine], reset: Bool) -> [IntentChatLine] {
        var next = reset ? [] : held
        for line in update {
            if let at = next.firstIndex(where: { $0.id == line.id }) { next[at] = line } else { next.append(line) }
        }
        return Array(next.suffix(maxMessages))
    }

    /// `hootRunsIn`: the folder the running Hoot was started in, else the configured one.
    public static func hootRunsIn(_ sessionList: Any, hootId: String?, configured: String?) -> String? {
        guard let hootId else { return configured }
        for case let entry as [String: Any] in (sessionList as? [Any]) ?? [] where entry["id"] as? String == hootId {
            if let cwd = entry["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return configured
    }
}

public enum IslandContentWords {
    public static func quiet(_ name: String, stopped: Bool) -> String { stopped ? "\(name) is not running." : "Ask \(name) anything." }
    public static func ask(_ name: String) -> String { "Ask \(name)" }
    public static func start(_ name: String) -> String { "Start \(name)" }
    public static func couldNotStart(_ name: String) -> String { "\(name) could not be started." }
    public static func conversation(_ name: String) -> String { "\(name)'s conversation" }
    public static let noSessions = "No sessions open."
    public static let allSessions = "All sessions"
    public static func rowTitle(_ row: IslandSessionRow) -> String { "\(row.label): \(IslandContent.what(row.status))" }
}
