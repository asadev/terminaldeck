import Foundation

// Siri / Shortcuts (lane R): "What needs me", tasks and goals — the pure parts.
//
// Sessions come from the same sidebar the window draws (the page's `sidebar`
// message: each session row's status, its unread dot, the held rows and the
// Alerts row's "N new"); tasks and goals from `tasks:state`, the Tasks page's
// own read (src/main/tasks/tasks-ipc.ts).

// MARK: - Tasks and goals

public struct IntentTaskSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let project: String
    /// `none`, `me`, `hoot`, or an agent's id.
    public let assignee: String
    /// The agent's name as the board shows it.
    public let agent: String
    public let status: String
    public let done: Bool
    /// In the Trash or archived: not on the board.
    public let isGone: Bool
    /// Its worker went quiet or ended without finishing: the sentence the app wrote.
    public let stalled: String?
    /// The agent that handed it to you, while you have it.
    public let handedFrom: String?
    public let goalId: String?
    public let createdAt: Double
    public let local: Bool

    public var isOpen: Bool { !done && !isGone }
}

public struct IntentGoalSummary: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let status: String
    public let project: String?
    public let total: Int
    public let done: Int
    public let verified: Int
    public let unverified: Int
    public let stalled: Int
    public let blocked: Int
}

public enum IntentTasks {
    /// `tasks:state` → the board's tasks (newest change first, as sent) and goals.
    public static func parse(_ value: Any) -> (tasks: [IntentTaskSummary], goals: [IntentGoalSummary])? {
        guard let state = value as? [String: Any] else { return nil }
        var tasks: [IntentTaskSummary] = []
        for case let raw as [String: Any] in (state["tasks"] as? [Any]) ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let stall = raw["stalled"] as? [String: Any]
            tasks.append(IntentTaskSummary(
                id: id,
                title: (raw["title"] as? String).map(IntentSpeech.collapse) ?? "",
                project: raw["project"] as? String ?? "",
                assignee: raw["assignee"] as? String ?? "none",
                agent: raw["agent"] as? String ?? "",
                status: raw["crmStatus"] as? String ?? "",
                done: isSet(raw["completedAt"]),
                isGone: isSet(raw["deletedAt"]) || isSet(raw["archivedAt"]),
                stalled: stall.map { ($0["text"] as? String).map(IntentSpeech.collapse) ?? "It stopped without finishing." },
                handedFrom: (raw["handedFrom"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                goalId: (raw["goalId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: (raw["createdAt"] as? NSNumber)?.doubleValue ?? 0,
                local: raw["local"] as? Bool ?? false))
        }
        var goals: [IntentGoalSummary] = []
        for case let raw as [String: Any] in (state["goals"] as? [Any]) ?? [] {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            let progress = raw["progress"] as? [String: Any] ?? [:]
            func number(_ key: String) -> Int { max(0, (progress[key] as? NSNumber)?.intValue ?? 0) }
            goals.append(IntentGoalSummary(
                id: id,
                title: (raw["title"] as? String).map(IntentSpeech.collapse) ?? "",
                status: raw["status"] as? String ?? "active",
                project: (raw["project"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                total: number("total"), done: number("done"), verified: number("verified"),
                unverified: number("unverified"), stalled: number("stalled"), blocked: number("blocked")))
        }
        return (tasks, goals)
    }

    /// What `tasks:local-create` is sent for "Add a task": the Tasks page's own
    /// defaults (nobody assigned, the first status), a title, and a project folder
    /// only when one was named.
    public static func newTask(title raw: String, projectPath: String?) -> Result<[String: String], IntentProblem> {
        let title = IntentSpeech.collapse(raw)
        guard !title.isEmpty else { return .failure(.plain("The task needs a title.")) }
        var payload = ["title": title, "instructions": "", "project": "", "assignee": "none"]
        if let projectPath, !projectPath.isEmpty {
            guard projectPath.hasPrefix("/") else { return .failure(.plain("\(projectPath) isn't a full folder path.")) }
            payload["project"] = projectPath
        }
        return .success(payload)
    }

    /// `{ok, message, state}` from a task change: the engine's refusal, or nil when it saved.
    public static func refusal(_ value: Any) -> IntentProblem? {
        guard let dict = value as? [String: Any] else { return .plain("Terminal Deck gave an answer I couldn't read.") }
        if dict["ok"] as? Bool == true { return nil }
        return .refused(dict["message"] as? String ?? "")
    }

    /// The task just made: the newest local task with that title in the state that came back.
    public static func created(title raw: String, in value: Any) -> IntentTaskSummary? {
        guard let state = (value as? [String: Any])?["state"], let parsed = parse(state) else { return nil }
        let title = IntentSpeech.collapse(raw)
        return parsed.tasks.filter { $0.title == title && !$0.isGone }.max { $0.createdAt < $1.createdAt }
    }

    public static func added(_ title: String, projectName: String?) -> IntentAnswer {
        let name = IntentSpeech.collapse(title)
        let spoken = projectName.map { "Added “\(name)” to your tasks in \($0)." } ?? "Added “\(name)” to your tasks."
        return IntentAnswer(spoken: spoken, detail: [spoken])
    }

    /// "Ship 0.18: 3 of 7 tasks done. 1 stalled, 2 blocked."
    public static func goalAnswer(_ goal: IntentGoalSummary, tasks: [IntentTaskSummary]) -> IntentAnswer {
        let name = goal.title.isEmpty ? "That goal" : goal.title
        let state = goal.status == "active" || goal.status.isEmpty ? "" : " (\(goal.status))"
        var parts: [String] = []
        if goal.total == 0 {
            parts.append("\(name)\(state) has no tasks yet.")
        } else if goal.done >= goal.total {
            parts.append("\(name)\(state): all \(IntentSpeech.count(goal.total, "task")) done.")
        } else {
            parts.append("\(name)\(state): \(goal.done) of \(IntentSpeech.count(goal.total, "task")) done.")
        }
        var trouble: [String] = []
        if goal.stalled > 0 { trouble.append("\(goal.stalled) stalled") }
        if goal.blocked > 0 { trouble.append("\(goal.blocked) blocked") }
        if !trouble.isEmpty { parts.append(IntentSpeech.sentenceCase(IntentSpeech.list(trouble)) + ".") }
        if goal.unverified > 0 { parts.append("\(IntentSpeech.count(goal.unverified, "finished task")) not verified yet.") }

        var detail = parts
        let open = tasks.filter { $0.goalId == goal.id && $0.isOpen }
        for task in open.prefix(12) {
            let who = task.agent.isEmpty ? "" : " — \(task.agent)"
            let flag = task.stalled != nil ? " (stalled)" : ""
            detail.append("• \(task.title)\(who)\(flag)")
        }
        if open.count > 12 { detail.append("…and \(open.count - 12) more open.") }
        return IntentAnswer(spoken: IntentSpeech.shorten(parts.joined(separator: " ")), detail: detail)
    }
}

// MARK: - What needs me

public struct IntentNeeds: Equatable, Sendable {
    public struct Session: Equatable, Sendable {
        public let id: String
        public let title: String
        /// The project heading it sits under, when it has one.
        public let project: String?
        public let status: String?
        public let unread: Bool

        public init(id: String, title: String, project: String?, status: String?, unread: Bool) {
            self.id = id
            self.title = title
            self.project = project
            self.status = status
            self.unread = unread
        }
    }

    /// Nil when the window had not drawn its sidebar yet: sessions unknown, not none.
    public var sessions: [Session]?
    public var held: [String]
    public var newAlerts: Int
    public var tasks: [IntentTaskSummary]?

    public init(sessions: [Session]?, held: [String] = [], newAlerts: Int = 0, tasks: [IntentTaskSummary]? = nil) {
        self.sessions = sessions
        self.held = held
        self.newAlerts = newAlerts
        self.tasks = tasks
    }

    /// The sidebar as the window draws it: session rows (with status and unread),
    /// held rows ("Not reopened") and the bell's "N new".
    public static func from(sidebar: SidebarState) -> IntentNeeds {
        var sessions: [Session] = []
        var held: [String] = []
        var alerts = 0
        for group in sidebar.groups {
            for item in group.items {
                if item.id == "alerts" { alerts = leadingNumber(item.subtitle) }
                // Hoot's own row: only when it is the one asking.
                if item.kind == .hoot, item.status == "input" {
                    sessions.append(Session(id: item.id, title: item.title.isEmpty ? "Hoot" : item.title, project: nil, status: "input", unread: false))
                }
            }
        }
        for project in sidebar.projects {
            // Paired machines, servers and app groups have ids that are not paths.
            let heading = project.title.isEmpty ? nil : project.title
            for item in project.sessions {
                if item.status == "held" {
                    held.append(item.title)
                    continue
                }
                guard item.kind == .session else { continue }
                sessions.append(Session(id: item.id, title: item.title.isEmpty ? "A session" : item.title,
                                        project: heading, status: item.status, unread: item.unread))
            }
        }
        return IntentNeeds(sessions: sessions, held: held, newAlerts: alerts)
    }

    /// The spoken line puts first what a person is blocking; the detail lists everything.
    public func answer() -> IntentAnswer {
        var spoken: [String] = []
        var detail: [String] = []
        func named(_ session: Session) -> String {
            guard let project = session.project, project != session.title else { return session.title }
            return "\(session.title) in \(project)"
        }

        if let sessions {
            let asking = sessions.filter { $0.status == "input" }
            let fresh = sessions.filter { $0.unread && $0.status != "input" }
            if asking.count == 1 {
                spoken.append("\(named(asking[0])) is asking you something.")
            } else if asking.count > 1 {
                spoken.append("\(asking.count) sessions are waiting for your answer: \(IntentSpeech.list(asking.map(named))).")
            }
            if !fresh.isEmpty {
                spoken.append(fresh.count == 1
                              ? "\(named(fresh[0])) has something new."
                              : "\(fresh.count) sessions have something new.")
            }
            detail += asking.map { "Waiting for your answer: \(named($0))" }
            detail += fresh.map { "Something new: \(named($0))" }
        }
        if let tasks {
            let stalled = tasks.filter { $0.isOpen && $0.stalled != nil }
            let handed = tasks.filter { $0.isOpen && $0.assignee == "me" && $0.handedFrom != nil }
            if !stalled.isEmpty {
                spoken.append(stalled.count == 1
                              ? "The task “\(stalled[0].title)” stalled."
                              : "\(stalled.count) tasks stalled: \(IntentSpeech.list(stalled.map(\.title), max: 2)).")
            }
            if !handed.isEmpty {
                spoken.append(handed.count == 1
                              ? "\(handed[0].handedFrom ?? "An agent") handed you “\(handed[0].title)”."
                              : "\(handed.count) tasks were handed to you.")
            }
            detail += stalled.map { "Stalled task: \($0.title) — \($0.stalled ?? "")" }
            detail += handed.map { "Handed to you by \($0.handedFrom ?? "an agent"): \($0.title)" }
        }
        if !held.isEmpty {
            spoken.append(held.count == 1 ? "\(held[0]) didn't reopen." : "\(held.count) sessions didn't reopen.")
            detail += held.map { "Didn't reopen: \($0)" }
        }
        if newAlerts > 0 {
            spoken.append("\(IntentSpeech.count(newAlerts, "new alert")).")
            detail.append("New alerts: \(newAlerts)")
        }

        if spoken.isEmpty {
            let line = sessions == nil && tasks == nil
                ? "I can't see Terminal Deck's sessions or tasks yet."
                : sessions == nil ? "No tasks need you. I can't see your sessions yet." : "Nothing needs you right now."
            return IntentAnswer(spoken: line, detail: [line])
        }
        if sessions == nil { spoken.append("I can't see your sessions yet.") }
        // The first three sentences are what Siri says; the detail has the rest.
        let said = IntentSpeech.shorten(spoken.prefix(3).joined(separator: " "))
        return IntentAnswer(spoken: said, detail: detail)
    }

    private static func leadingNumber(_ text: String?) -> Int {
        guard let text else { return 0 }
        return Int(text.prefix { $0.isNumber }) ?? 0
    }
}

private func isSet(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let number = value as? NSNumber { return number.doubleValue > 0 }
    return true
}
