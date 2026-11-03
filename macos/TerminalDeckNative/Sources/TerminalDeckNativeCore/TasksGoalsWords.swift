import Foundation

// MARK: - Goals and the CRM mirror, as the page words them (Goals.tsx, CrmTasks.tsx, MyWork.tsx)

extension Goals {
    /// "3 of 5 done", then only the counts worth a look.
    public static func progressLine(_ progress: GoalProgress) -> String {
        if progress.total == 0 { return "No tasks yet" }
        var parts = ["\(progress.done) of \(progress.total) done"]
        if progress.verified > 0 { parts.append("\(progress.verified) verified") }
        if progress.unverified > 0 { parts.append("\(progress.unverified) to check") }
        if progress.stalled > 0 { parts.append("\(progress.stalled) stalled") }
        if progress.blocked > 0 { parts.append("\(progress.blocked) waiting") }
        return parts.joined(separator: " · ")
    }

    /// Done share, 0–100, rounded.
    public static func share(_ progress: GoalProgress) -> Int {
        progress.total == 0 ? 0 : Int((Double(progress.done) / Double(progress.total) * 100).rounded())
    }

    /// The goals as a picker offers them: tree order, indented.
    public static func options(_ goals: [GoalRow]) -> [(id: String, label: String)] {
        tree(goals).map { entry in
            (entry.goal.id, String(repeating: "\u{00a0}\u{00a0}", count: entry.depth) + (entry.depth > 0 ? "↳ " : "") + entry.goal.title)
        }
    }
}

public enum CrmMirror {
    /// Whether a finished task was checked: by its check command, or by Hoot.
    public static func checkLabel(_ verified: Bool?) -> String {
        guard let verified else { return "not finished" }
        return verified ? "finished and checked" : "finished, not checked yet"
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    public static func agoLabel(_ at: Double, now: Double) -> String {
        let minutes = Int((max(now - at, 0) / 60_000).rounded(.down))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) d ago"
    }

    /// "2 running · 1 queued", or empty.
    public static func summary(_ tasks: [TaskRow]) -> String {
        let running = tasks.filter { $0.process == .running }.count
        let queued = tasks.filter { $0.process == .queued }.count
        return [running > 0 ? "\(running) running" : nil, queued > 0 ? "\(queued) queued" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Trash's "Deleted …": "just now", "5 minutes ago", "3 hours ago", "2 days ago".
    public static func relativeAgo(_ ms: Double) -> String {
        let minutes = Int((max(0, ms) / 60_000).rounded(.down))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
