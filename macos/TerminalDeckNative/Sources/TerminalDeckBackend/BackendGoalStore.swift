import Foundation
import TerminalDeckNativeCore

public actor BackendGoalStore {
    private let persistence: BackendTaskPersistence
    private var goals: [String: NativeRPCValue] = [:], loaded = false
    private var order: [String] = []
    private var removingIDs = Set<String>()
    private let changed: @Sendable () async -> Void
    private var listeners: [UUID: @Sendable () async -> Void] = [:]
    public init(persistence: BackendTaskPersistence, changed: @escaping @Sendable () async -> Void = {}) {
        self.persistence = persistence; self.changed = changed
    }
    public func start() throws {
        guard !loaded else { return }
        if let file = try persistence.read("goals.json") {
            guard file["v"].number == 1 else { throw NativeRPCError.malformed("Unsupported goals.json version") }
            for goal in file["goals"].elements ?? [] {
                if let id = goal["id"].string, goal["title"].string != nil, goal["description"].string != nil,
                   ["planned", "active", "achieved", "cancelled"].contains(goal["status"].string ?? ""),
                   goal["createdAt"].number != nil, goal["updatedAt"].number != nil, goal["parentId"] == .null || goal["parentId"].string != nil,
                   goal["project"] == .null || goal["project"].string != nil { if goals[id] == nil { order.append(id) }; goals[id] = goal }
            }
            for id in order { if let parent = goals[id]?["parentId"].string, goals[parent] == nil { goals[id] = goals[id]!.setting("parentId", .null) } }
        }; loaded = true
    }
    public func all() throws -> [NativeRPCValue] { try started(); let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) }); return goals.values.sorted { let a = $0["createdAt"].number ?? 0, b = $1["createdAt"].number ?? 0; return a == b ? (positions[$0["id"].string ?? ""] ?? 0) < (positions[$1["id"].string ?? ""] ?? 0) : a < b } }
    public func byID(_ id: String) throws -> NativeRPCValue? { try started(); return goals[id] }
    /// goal-store.ts `subtree`: the goal and every goal below it, parents first.
    public func subtree(_ id: String) throws -> [NativeRPCValue] {
        try started(); guard let root = goals[id] else { return [] }
        let sorted = try all(); var out = [root], at = 0
        while at < out.count, out.count <= 500 { let parent = out[at]["id"].string; out += sorted.filter { $0["parentId"].string == parent }; at += 1 }
        return out
    }
    /// goal-store.ts `onChange`: the listener hears every save and removal until the returned token is cancelled.
    public func observe(_ listener: @escaping @Sendable () async -> Void) -> NativeRPCSubscription {
        let token = UUID(); listeners[token] = listener
        return NativeRPCSubscription { [weak self] in await self?.unobserve(token) }
    }
    private func unobserve(_ token: UUID) { listeners[token] = nil }
    private func announce() async { await changed(); for listener in listeners.values { await listener() } }
    public func chain(_ id: String) throws -> [NativeRPCValue] {
        try started(); var result: [NativeRPCValue] = [], seen = Set<String>(), at: String? = id
        while let key = at, let goal = goals[key], result.count < 8, seen.insert(key).inserted { result.append(goal); at = goal["parentId"].string }; return result
    }
    public func save(_ input: NativeRPCValue) async throws -> NativeRPCValue {
        try started(); try persistence.writable(); _ = try input.requireObject("goal")
        let requested = input["id"].string?.trimmingCharacters(in: .whitespacesAndNewlines), new = requested == nil || requested == ""
        let id = new ? "goal-" + UUID().uuidString.lowercased() : requested!
        guard !removingIDs.contains(id) else { throw NativeRPCError.invalidArguments("That goal is being removed.") }
        guard new || goals[id] != nil else { throw NativeRPCError.invalidArguments("That goal no longer exists.") }
        guard !new || goals.count < 500 else { throw NativeRPCError.invalidArguments("There are already 500 goals. Remove one you no longer need first.") }
        let now = BackendTaskValues.time()
        var goal = goals[id] ?? BackendTaskValues.object([("id", .string(id)), ("title", .string("")), ("description", .string("")), ("status", .string("active")), ("parentId", .null), ("project", .null), ("createdAt", .number(now))])
        if new || input.has("title") { goal = goal.setting("title", .string(try BackendTaskValues.text(input["title"], "The goal’s title", max: 200, required: true)!)) }
        if let text = try BackendTaskValues.text(input["description"], "The description", max: 4_000) { goal = goal.setting("description", .string(text)) }
        if !input["status"].isNullish, input["status"].string != "" {
            guard let status = input["status"].string, ["planned", "active", "achieved", "cancelled"].contains(status) else { throw NativeRPCError.invalidArguments("A goal’s status is one of: planned, active, achieved, cancelled.") }
            goal = goal.setting("status", .string(status))
        }
        if input.has("project") {
            let project = try BackendTaskValues.text(input["project"], "The project folder", max: 1_024)
            guard project == nil || project == "" || (project!.hasPrefix("/") && !project!.contains("\0")) else { throw NativeRPCError.invalidArguments("\(project ?? "") is not a full folder path.") }
            goal = goal.setting("project", project == nil || project == "" ? .null : .string(project!))
        }
        if input.has("parentId") {
            let parent = input["parentId"].string
            if let parent, !parent.isEmpty {
                guard goals[parent] != nil, !removingIDs.contains(parent) else { throw NativeRPCError.invalidArguments("That parent goal no longer exists.") }
                let ancestors = try chain(parent)
                guard !ancestors.contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("A goal cannot sit under itself or under one of its own sub-goals.") }
                var below = 0, children = goals.values.filter { $0["parentId"].string == id }
                while !children.isEmpty, below < 8 { below += 1; let ids = Set(children.compactMap { $0["id"].string }); children = goals.values.filter { ids.contains($0["parentId"].string ?? "") } }
                guard ancestors.count + 1 + below <= 8 else { throw NativeRPCError.invalidArguments("Goals can be nested at most 8 deep.") }
                goal = goal.setting("parentId", .string(parent))
            } else {
                guard input["parentId"].isNullish || input["parentId"].string == "" else { throw NativeRPCError.invalidArguments("The parent goal has to be a goal’s id.") }
                goal = goal.setting("parentId", .null)
            }
        }
        let before = goals, oldOrder = order; if goals[id] == nil { order.append(id) }; goals[id] = goal.setting("updatedAt", .number(now))
        do { try flush() } catch { goals = before; order = oldOrder; throw error }; let result = goals[id]!; await announce(); return result
    }
    /// Answers what goal-store.ts `remove` does: the removed goal and the parent its children were relinked to.
    @discardableResult public func remove(_ id: String, tasks: BackendTaskStore) async throws -> NativeRPCValue {
        try started(); try persistence.writable(); guard let goal = goals[id] else { throw NativeRPCError.invalidArguments("That goal no longer exists.") }
        guard removingIDs.isEmpty else { throw NativeRPCError.invalidArguments("Another goal removal is still in progress.") }
        removingIDs.insert(id); defer { removingIDs.remove(id) }
        // Keep a removed id from being replaced during the cross-store relink.
        let parent = goal["parentId"].string
        let affected = try await tasks.relinkGoal(id, parent: parent)
        let before = goals, oldOrder = order
        for key in Array(goals.keys) where goals[key]?["parentId"].string == id { goals[key] = goals[key]!.setting("parentId", parent.map(NativeRPCValue.string) ?? .null).setting("updatedAt", .number(BackendTaskValues.time())) }
        goals[id] = nil; order.removeAll { $0 == id }
        do { try flush() } catch { goals = before; order = oldOrder; try? await tasks.restoreGoalLinks(affected, expectedParent: parent); throw error }; await announce()
        return BackendTaskValues.object([("removed", goal), ("parentId", parent.map(NativeRPCValue.string) ?? .null)])
    }
    public func progress(_ id: String, tasks: [BackendTaskRecord]) throws -> NativeRPCValue {
        try started(); guard let goal = goals[id] else { throw NativeRPCError.invalidArguments("That goal no longer exists.") }
        var ids: Set<String> = [id], grew = true
        while grew { grew = false; for row in goals.values { if let parent = row["parentId"].string, ids.contains(parent), let key = row["id"].string, ids.insert(key).inserted { grew = true } } }
        let mine = tasks.filter { $0.isLocal && $0.value["archivedAt"].isNullish && ids.contains($0.value["goalId"].string ?? "") }
        var statuses = Dictionary(uniqueKeysWithValues: BackendTaskLocalService.statuses.map { ($0, 0) }), processes = Dictionary(uniqueKeysWithValues: ["idle", "queued", "running", "exited"].map { ($0, 0) })
        for task in mine { statuses[task.value["crmStatus"].string ?? "", default: 0] += 1; processes[task.process, default: 0] += 1 }
        return BackendTaskValues.object([("goal", .string(id)), ("title", goal["title"]), ("status", goal["status"]), ("total", .number(Double(mine.count))),
            ("done", .number(Double(mine.filter { $0.value["crmStatus"].string == "Done" }.count))),
            ("verified", .number(Double(mine.filter { $0.value["result"]["verified"].bool == true }.count))),
            ("unverified", .number(Double(mine.filter { (!$0.value["result"].isNullish || $0.value["crmStatus"].string == "Done") && $0.value["result"]["verified"].bool != true }.count))),
            ("stalled", .number(Double(mine.filter { !$0.value["stalled"].isNullish }.count))), ("blocked", .number(Double(mine.filter { !Self.blockers($0, all: tasks).isEmpty }.count))),
            ("byStatus", .object(statuses.map { .init($0.key, .number(Double($0.value))) })), ("byProcess", .object(processes.map { .init($0.key, .number(Double($0.value))) })),
            ("tasks", .array(mine.map { task in BackendTaskValues.object([("task", .string(task.id)), ("title", task.value["title"]), ("goal", task.value["goalId"]), ("status", task.value["crmStatus"]), ("process", task.value["process"]), ("assignee", .string(task.agentID)), ("verified", task.value["result"].isNullish ? .null : task.value["result"]["verified"]), ("stalled", task.value["stalled"].isNullish ? .null : task.value["stalled"]), ("blockedBy", .array(Self.blockers(task, all: tasks).map { BackendTaskValues.object([("task", .string($0.id)), ("title", $0.value["title"])]) }))]) })),
            ("children", .array(goals.values.filter { $0["parentId"].string == id }.map { BackendTaskValues.object([("goal", $0["id"]), ("title", $0["title"]), ("status", $0["status"])]) }))])
    }
    public nonisolated static func blockers(_ task: BackendTaskRecord, all: [BackendTaskRecord]) -> [BackendTaskRecord] {
        guard task.isLocal else { return [] }; var ids = Set<String>()
        for dep in task.value["detail"]["dependencies"].elements ?? [] where dep["kind"].string == "blocked_by" { if let id = dep["otherTaskId"].string { ids.insert(id) } }
        for other in all where other.isLocal && other.id != task.id {
            if (other.value["detail"]["dependencies"].elements ?? []).contains(where: { $0["kind"].string == "blocks" && $0["otherTaskId"].string == task.id }) { ids.insert(other.id) }
        }; return all.filter { $0.id != task.id && $0.isLocal && ids.contains($0.id) && $0.value["crmStatus"].string != "Done" }
    }
    public func stop() throws { if loaded, persistence.ownership != .readOnly { try flush() } }
    private func started() throws { guard loaded else { throw NativeRPCError(code: "not-started", message: "Goal records have not been opened") } }
    private func flush() throws { try persistence.write("goals.json", value: BackendTaskValues.object([("v", .number(1)), ("goals", .array(order.compactMap { goals[$0] }))])) }
}
