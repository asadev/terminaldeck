import Foundation
import TerminalDeckNativeCore

/// Asad (12 Oct): Hoot's live job flow shows "what rule of ours is applied during the job and with green tick … specific
/// skill has been applied and flow of the skill as well … including the other agents". Nothing is guessed: Hoot and every
/// agent report a rule or a skill step with the `flow.applied` tool at the moment it happens. Hoot's own reports are in its
/// chat (the tool call itself); an agent's are kept here, with the task the app knows that session works on, so Hoot's
/// flow can show each agent's rules and skill steps under that agent.
public struct JobFlowEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case rule, skill }
    public var id: String
    /// Milliseconds since 1970.
    public var at: Double
    /// The session that reported it.
    public var session: String
    /// The task that session was working on, when the app knows it.
    public var task: String?
    /// The agent's name, as the person knows it.
    public var who: String
    public var seat: String
    public var kind: Kind
    /// A rule: its note id when it is a note.
    public var ruleID: String?
    /// A rule's short title, or the skill's name.
    public var title: String
    /// The whole rule, for the table's detail.
    public var full: String?
    public var step: Int?
    public var stepTitle: String?
    public var detail: String?
    public init(id: String = UUID().uuidString.lowercased(), at: Double, session: String, task: String? = nil, who: String, seat: String, kind: Kind,
                ruleID: String? = nil, title: String, full: String? = nil, step: Int? = nil, stepTitle: String? = nil, detail: String? = nil) {
        self.id = id; self.at = at; self.session = session; self.task = task; self.who = who; self.seat = seat; self.kind = kind
        self.ruleID = ruleID; self.title = title; self.full = full; self.step = step; self.stepTitle = stepTitle; self.detail = detail
    }
    /// One plain line: "Rule applied: Short title" / "Skill resume · step 2: Read the handoff".
    public var line: String { JobFlowWords.line(kind: kind, title: title, step: step, stepTitle: stepTitle) }
}

/// The words the tool answers with and the chat reads back (one place, so both always agree).
public enum JobFlowWords {
    public static let toolID = "flow.applied"
    public static let toolWire = "flow_applied"
    public static let rulePrefix = "Rule applied: "
    public static let skillPrefix = "Skill "
    public static func line(kind: JobFlowEntry.Kind, title: String, step: Int?, stepTitle: String?) -> String {
        switch kind {
        case .rule: return rulePrefix + title
        case .skill:
            var text = skillPrefix + title
            if let step { text += " · step \(step)" }
            if let words = stepTitle, !words.isEmpty { text += (step == nil ? " · " : ": ") + words }
            return text
        }
    }
    /// Is this chat tool call a flow report (called directly, or through tools_run)?
    public static func isReport(name: String, input: NativeRPCValue) -> Bool {
        let bare = name.components(separatedBy: "__").last ?? name
        if bare == toolWire || bare == toolID { return true }
        guard bare == "tools_run" || bare == "tools.run" else { return false }
        let inner = (input["name"].string ?? "").replacingOccurrences(of: ".", with: "_")
        return inner == toolWire
    }
    /// The report's own arguments, whichever way it was called.
    public static func arguments(_ input: NativeRPCValue) -> NativeRPCValue {
        input["arguments"].fields != nil ? input["arguments"] : input
    }
    /// The plain text of a tool's answer (a string, or MCP content blocks).
    public static func text(_ output: NativeRPCValue) -> String {
        if let text = output.string { return text }
        if let blocks = output.elements { return blocks.compactMap { $0["text"].string ?? $0.string }.joined(separator: "\n") }
        if let text = output["content"].elements { return text.compactMap { $0["text"].string }.joined(separator: "\n") }
        return ""
    }
}

public extension Notification.Name {
    /// Posted on the main thread when an agent reported a rule or a skill step.
    static let jobFlowChanged = Notification.Name("dev.terminaldeck.job-flow.changed")
}

/// The agents' reports, newest kept (2,000), saved in the app's data folder.
public actor BackendJobFlowLog {
    public static let shared = BackendJobFlowLog()
    public static let limit = 2_000
    private var file: URL?
    private var entries: [JobFlowEntry] = []
    private var persistedLines = 0
    /// Which task each running session works on, from the app's own task list (session → task id, title, agent).
    private var taskOf: [String: (task: String, agent: String)] = [:]

    private let events: BackendMemoryEvents
    public init(events: BackendMemoryEvents = .shared) { self.events = events }

    /// Where the log is kept; reads what is there.
    public func configure(file: URL) {
        self.file = file; entries = []; taskOf = [:]; persistedLines = 0
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        persistedLines = lines.count
        entries = lines.suffix(Self.limit).compactMap { try? decoder.decode(JobFlowEntry.self, from: Data($0.utf8)) }
    }

    /// The app's task list changed: remember which session works on which task (a task keeps its id after its session ends).
    public func noteTasks(_ views: [NativeRPCValue], activeSessions: Set<String>? = nil) {
        taskOf = [:]
        for view in views {
            guard let session = view["sessionId"].string, !session.isEmpty, activeSessions?.contains(session) != false, let id = view["id"].string else { continue }
            taskOf[session] = (id, view["agent"].string ?? view["assignee"]["name"].string ?? "")
        }
    }
    public func sessionEnded(_ session: String) { taskOf[session] = nil }
    public func task(forSession session: String) -> (task: String, agent: String)? { taskOf[session] }

    public func record(_ entry: JobFlowEntry) async {
        var entry = entry
        if entry.task == nil, let known = taskOf[entry.session] {
            entry.task = known.task
            if entry.who.isEmpty, !known.agent.isEmpty { entry.who = known.agent }
        }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        if let file, let line = try? JSONEncoder().encode(entry) {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if persistedLines >= Self.limit * 2 || !FileManager.default.fileExists(atPath: file.path) {
                    // Compact only after another full window has been appended.
                    let encoder = JSONEncoder()
                    let all = entries.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
                    try Data(all.utf8).write(to: file, options: .atomic)
                    persistedLines = entries.count
                } else {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: line + Data("\n".utf8))
                    persistedLines += 1
                }
            } catch {}
        }
        await events.publish("job-flow:changed")
    }

    /// The reports of these sessions or tasks, oldest first.
    public func entries(sessions: Set<String> = [], tasks: Set<String> = []) -> [JobFlowEntry] {
        entries.filter { sessions.contains($0.session) || ($0.task.map(tasks.contains) ?? false) }
    }
    /// For checks.
    public func all() -> [JobFlowEntry] { entries }
    public func clear() { entries = []; taskOf = [:] }
}
