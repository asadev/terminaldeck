import Foundation

// MARK: - Goals

/// A goal while it is being typed.
public struct GoalDraft: Equatable, Sendable {
    public var title: String
    public var description: String
    public var status: GoalStatus
    /// Empty for a top-level goal.
    public var parentId: String

    public init(_ goal: GoalRow?, parentId: String = "") {
        title = goal?.title ?? ""
        description = goal?.description ?? ""
        status = goal?.status ?? .active
        self.parentId = goal?.parentId ?? parentId
    }
}

public enum Goals {
    /// What `tasks:goal-save` is sent, or what to fix first.
    public static func payload(_ draft: GoalDraft, id: String?) -> Result<[String: Any], TasksProblem> {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .failure(TasksProblem("Give the goal a title.")) }
        var payload: [String: Any] = [
            "title": title,
            "description": draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            "status": draft.status.rawValue,
            "parentId": draft.parentId.isEmpty ? jsonNull : draft.parentId,
        ]
        if let id { payload["id"] = id }
        return .success(payload)
    }

    /// Goals in tree order — each followed by the ones under it — with how deep each sits.
    public static func tree(_ goals: [GoalRow]) -> [(goal: GoalRow, depth: Int)] {
        var out: [(goal: GoalRow, depth: Int)] = []
        let ids = Set(goals.map(\.id))
        func visit(_ parentId: String?, _ depth: Int) {
            for goal in goals {
                let parent = goal.parentId.flatMap { ids.contains($0) ? $0 : nil }
                if parent != parentId || out.contains(where: { $0.goal.id == goal.id }) { continue }
                out.append((goal, depth))
                visit(goal.id, depth + 1)
            }
        }
        visit(nil, 0)
        return out
    }

    /// The goals a goal may be put under: any but itself and those under it.
    public static func parentChoices(_ goals: [GoalRow], id: String?) -> [GoalRow] {
        guard let id else { return goals }
        var below: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for goal in goals where goal.parentId.map(below.contains) == true && !below.contains(goal.id) {
                below.insert(goal.id)
                grew = true
            }
        }
        return goals.filter { !below.contains($0.id) }
    }
}

/// A sentence that says what to fix.
public struct TasksProblem: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}
