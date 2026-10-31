import Foundation
import TerminalDeckNativeCore

/// FORK-TASKS → M2 (11 Oct, real-app test row 113: "a brief typed by the app is shown as written by
/// Hoot"). The task engine types into agents' sessions: the line that points a new worker at its brief,
/// a comment someone wrote on the task, a notice that its parts are finished. Those words are the APP's,
/// written for whoever gave the task. The diary showed them as Hoot's, because the "user" side of a
/// session the task engine starts is taken to be the orchestrator unless the app says who typed.
///
/// The engine reports each thing it types (`note`). Two things happen:
/// 1. `DeckMemoryFlowInbox.typed(sessionID:text:by: .app)`, the memory flow's own door: the diary row's
///    author is the app.
/// 2. who gave the task is kept beside the typed text, for the memory flow to read with
///    `givenBy(sessionID:text:)` when it writes that row ("App, given by the owner"). Reading is free of
///    side effects. Nothing else reads it.
public struct BackendTaskTypedBrief: Sendable, Equatable {
    public enum Giver: String, Sendable { case person, hoot, agent, crm, app }
    public var sessionID: String
    public var taskID: String
    /// What was typed. For a new worker's first line: its fixed part, without the brief file's path.
    public var text: String
    public var givenByKind: Giver
    /// "the owner", "Hoot", an agent's name, an AI app's name, the CRM's sender.
    public var givenBy: String
    public var at: Double
    public init(sessionID: String, taskID: String, text: String, givenByKind: Giver, givenBy: String, at: Double) {
        self.sessionID = sessionID; self.taskID = taskID; self.text = text; self.givenByKind = givenByKind; self.givenBy = givenBy; self.at = at
    }
}

public enum BackendTaskTypedBriefs {
    private final class Box: @unchecked Sendable { let lock = NSLock(); var rows: [String: [BackendTaskTypedBrief]] = [:] }
    private static let box = Box()
    static let lifetime = 3_600_000.0, maximum = 32

    /// The fixed part of the first line a new worker is typed ("Read <file> and do exactly what it says. …").
    /// The file's path is made by the session driver, so the part after it is what can be recognised.
    public static let firstLine: String = {
        let mark = "\u{1}"
        return (BackendDeckCoreBrief.deliveryLine(mark).components(separatedBy: mark).last ?? "").trimmingCharacters(in: .whitespaces)
    }()
    /// The brief file a new session is pointed at. T17: a brief that opens with its own title and names its
    /// task id is not given them a second time on top ("# <title>" stood twice in the file).
    public static func fileBody(title: String?, folder: String, provider: String?, taskID: String, brief: String) -> String {
        let titled = brief.hasPrefix("# "), named = brief.contains("Task id: " + taskID)
        return (titled ? "" : "# \(title ?? "Task")\n\n") + "repo: \(folder)\nagent: \(provider ?? "the default")\n"
            + (named ? "" : "from-turn: \(taskID)\n") + "\n---\n\n\(brief)\n"
    }
    /// Text longer than this is not typed into a session: it goes whole into a file and one line points at it.
    public static let inlineLimit = 600
    /// The line that points at such a file, and the part of it that does not change with the file's path.
    public static func pointerLine(_ path: String) -> String { "Read " + path + pointerTail }
    public static let pointerTail = " and do what it says. It is new text on your task, too long to type here."
    /// What a kept-open session is told before the next task's brief.
    public static let reusedLine = "A new scoped task has been assigned to this existing session. Keep the project context; the following brief replaces the finished task."

    /// U144 (#363, #524): a brief or a long reply is read once, when its session starts or is handed the text, so after
    /// a week it goes, unless a task still waits on it (its `briefFile`). A definition file the launch used to write
    /// per start (now one per agent) can still be named by a session that restarts, so it is kept a month.
    public static let briefKeptSeconds = 7.0 * 24 * 3_600, oldDefinitionKeptSeconds = 30.0 * 24 * 3_600
    public static func sweep(_ specs: BackendTaskPersistence, keeping: Set<String>, now: Date = Date()) {
        guard specs.ownership == .exclusive else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: specs.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !keeping.contains(file.lastPathComponent) {
            let kept: Double
            if file.lastPathComponent.hasSuffix("-agent-definition.json") { kept = oldDefinitionKeptSeconds }
            else if file.pathExtension == "md" { kept = briefKeptSeconds }
            else { continue }
            guard let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(changed) > kept else { continue }
            try? specs.remove(file.lastPathComponent)
        }
    }

    /// The engine typed `text` into this session for this task. Returns at once.
    public static func note(_ typed: BackendTaskTypedBrief) {
        var row = typed; row.text = squeeze(typed.text)
        guard !row.sessionID.isEmpty, !row.text.isEmpty else { return }
        box.lock.withLock {
            var list = (box.rows[row.sessionID] ?? []).filter { row.at - $0.at < lifetime }
            list.append(row)
            if list.count > maximum { list.removeFirst(list.count - maximum) }
            box.rows[row.sessionID] = list
        }
        DeckMemoryFlowInbox.typed(sessionID: row.sessionID, text: row.text, by: .app)
    }
    /// Who gave the task these typed words were for (the newest match); nil when the task engine did not
    /// type them. The same matching as the memory flow's own: the same words, or one inside the other
    /// when long enough not to be a coincidence.
    public static func givenBy(sessionID: String, text: String) -> BackendTaskTypedBrief? {
        let said = squeeze(text)
        guard !said.isEmpty else { return nil }
        return box.lock.withLock { (box.rows[sessionID] ?? []).last { matches($0.text, said) } }
    }
    /// The session closed: what was typed into it is forgotten.
    public static func forget(sessionID: String) { box.lock.withLock { box.rows[sessionID] = nil } }

    static func squeeze(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ") }
    static func matches(_ typed: String, _ said: String) -> Bool {
        if typed == said { return true }
        let short = typed.count <= said.count ? typed : said, long = typed.count <= said.count ? said : typed
        return short.count >= 40 && long.contains(short)
    }
}
