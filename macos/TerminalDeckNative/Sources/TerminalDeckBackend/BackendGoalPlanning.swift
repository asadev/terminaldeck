import Foundation
import TerminalDeckNativeCore

/// goal-tools.ts plan preparation: validate every key/agent/dependency before
/// making records, create unassigned, install all waits, then assign workers.
public actor BackendGoalPlanning {
    private let goals: BackendGoalStore, tasks: BackendTaskStore, config: BackendTaskConfiguration, local: BackendTaskLocalService, detail: BackendTaskDetailService
    private var busy = false, waiters: [CheckedContinuation<Void, Never>] = []
    public init(goals: BackendGoalStore, tasks: BackendTaskStore, configuration: BackendTaskConfiguration, local: BackendTaskLocalService, detail: BackendTaskDetailService) {
        self.goals = goals; self.tasks = tasks; config = configuration; self.local = local; self.detail = detail
    }
    public func validate(_ input: NativeRPCValue) async throws -> String? {
        guard let goalID = input["goal"].string, !goalID.isEmpty else { throw NativeRPCError.invalidArguments("goal is required: an id from tasks_goals") }
        guard let goal = try await goals.byID(goalID) else { throw NativeRPCError.invalidArguments("there is no goal \(goalID)") }
        let steps = try await steps(input["tasks"]), project = input["project"].string ?? goal["project"].string
        if project == nil, steps.contains(where: { $0.agent != nil }) { throw NativeRPCError.invalidArguments("project is required: name the folder the agents work in, or give the goal one") }
        if let project, !project.hasPrefix("/") || project.contains("\0") { throw NativeRPCError.invalidArguments("project must be a full folder path") }; return project
    }
    public func create(_ input: NativeRPCValue, authorizeProject: @escaping @Sendable (String) async throws -> Void) async throws -> NativeRPCValue {
        await enter(); defer { leave() }; try Task.checkCancellation()
        let project = try await validate(input), goalID = input["goal"].string!, steps = try await steps(input["tasks"])
        if let project { try await authorizeProject(project) }
        var made: [String: BackendTaskRecord] = [:]
        for step in steps {
            try Task.checkCancellation()
            let task = try await local.create(BackendTaskValues.object([("title", .string(step.title)), ("instructions", .string(step.details)), ("project", .string(project ?? "")), ("assignee", .string("none")), ("goalId", .string(goalID)), ("useWorkspace", .bool(step.workspace))]), by: "hoot")
            made[step.key] = task
        }
        for step in steps { for wait in step.after {
            let linked = await detail.call("addTaskDependency", arguments: [.string(made[step.key]!.id), .string(made[wait]!.id), .string("blocked_by")], by: "hoot")
            guard linked["ok"].bool == true else { throw NativeRPCError(code: "partial-plan", message: "The tasks were made, but \(step.key) could not be set to wait for \(wait): \(linked["error"].string ?? "refused"). The saved task ids are \(made.values.map(\.id).sorted().joined(separator: ", ")).") }
        } }
        for step in steps { if let agent = step.agent { _ = try await local.update(made[step.key]!.id, input: BackendTaskValues.object([("assignee", agent["id"])]), by: "hoot") } }
        var rows: [NativeRPCValue] = []
        for step in steps { let current = try await tasks.byID(made[step.key]!.id) ?? made[step.key]!; rows.append(BackendTaskValues.object([("key", .string(step.key)), ("task", .string(current.id)), ("title", current.value["title"]), ("agent", step.agent?["name"] ?? .null), ("waitsFor", .array(step.after.map(NativeRPCValue.string))), ("process", current.value["process"])])) }
        return BackendTaskValues.object([("goal", .string(goalID)), ("project", project.map(NativeRPCValue.string) ?? .null), ("tasks", .array(rows))])
    }
    private struct Step: Sendable { let key: String, title: String, details: String; let agent: NativeRPCValue?; let after: [String]; let workspace: Bool }
    private func steps(_ raw: NativeRPCValue) async throws -> [Step] {
        // goal-tools.ts planSteps: checked whole, same words, before anything is made.
        guard let rows = raw.elements, !rows.isEmpty else { throw NativeRPCError.invalidArguments("tasks is required: a list of at least one task") }
        guard rows.count <= 20 else { throw NativeRPCError.invalidArguments("a plan can make at most 20 tasks at once") }
        var result: [Step] = []
        for (index, row) in rows.enumerated() {
            guard row.fields != nil else { throw NativeRPCError.invalidArguments("tasks[\(index)] must be an object") }
            func trimmed(_ key: String, _ message: String) throws -> String? {
                if row[key].isNullish { return nil }; guard let text = row[key].string else { throw NativeRPCError.invalidArguments(message) }; return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let key = row["key"].string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
            guard let title = row["title"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { throw NativeRPCError.invalidArguments("title is required") }
            let details = try trimmed("details", "details must be text") ?? ""
            var agent: NativeRPCValue?
            if !row["agent"].isNullish, row["agent"].string != "" {
                guard let name = row["agent"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw NativeRPCError.invalidArguments("agent is required: a task agent’s name or id") }
                guard let known = try await config.agent(name) else { throw NativeRPCError.invalidArguments("there is no task agent called \(name); tasks_agents lists them") }
                guard known["status"].string == nil || known["status"].string == "active" else { throw NativeRPCError.invalidArguments("\(name) is not taking new work.") }; agent = known
            }
            var after: [String] = []
            if !row["after"].isNullish {
                guard let list = row["after"].elements, list.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.invalidArguments("after must be a list of text") }
                after = list.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            result.append(Step(key: key, title: title, details: details, agent: agent, after: after, workspace: row["workspace"].bool == true))
        }
        var keys = Set<String>()
        for step in result { guard keys.insert(step.key).inserted else { throw NativeRPCError.invalidArguments("two tasks share the key \(step.key)") } }
        for step in result { for wait in step.after {
            guard keys.contains(wait) else { throw NativeRPCError.invalidArguments("\(step.key) waits for \(wait), which is not in this plan") }
            guard wait != step.key else { throw NativeRPCError.invalidArguments("\(step.key) cannot wait for itself") }
        } }
        let byKey = Dictionary(uniqueKeysWithValues: result.map { ($0.key, $0) }); var walking = Set<String>(), done = Set<String>()
        func walk(_ key: String) throws {
            if done.contains(key) { return }
            guard walking.insert(key).inserted else { throw NativeRPCError.invalidArguments("the waits loop back to \(key); one of them has to go") }
            for wait in byKey[key]?.after ?? [] { try walk(wait) }; walking.remove(key); done.insert(key)
        }
        for step in result { try walk(step.key) }; return result
    }
    private func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    private func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}
