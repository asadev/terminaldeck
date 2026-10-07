import Foundation
import TerminalDeckNativeCore

public protocol BackendTaskExecuting: Sendable {
    func accept(_ id: String) async throws
    func reassign(_ id: String, assignee: NativeRPCValue) async throws
    func reply(_ id: String, text: String) async throws
    func cancel(_ id: String, reason: String) async throws
}

public actor BackendTaskLocalService {
    public nonisolated static let statuses = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]
    public let store: BackendTaskStore
    public nonisolated let configuration: BackendTaskConfiguration
    private let config: BackendTaskConfiguration, goals: BackendGoalStore, engine: any BackendTaskExecuting
    public typealias UpdateObserver = @Sendable (BackendTaskRecord, BackendTaskRecord, [NativeRPCValue], String) async throws -> Void
    private var updateObserver: UpdateObserver?
    private var busy = false, waiters: [CheckedContinuation<Void, Never>] = []
    public init(store: BackendTaskStore, configuration: BackendTaskConfiguration, goals: BackendGoalStore, engine: any BackendTaskExecuting) {
        self.store = store; config = configuration; self.configuration = configuration; self.goals = goals; self.engine = engine
    }
    public func assignee(_ input: NativeRPCValue) async throws -> NativeRPCValue {
        let id = input.string ?? "none", kind: String
        guard input.isNullish || input.string != nil else { throw NativeRPCError.invalidArguments("Assign it to nobody, to yourself, to Hoot or to one of your task agents.") }
        if id.isEmpty || id == "none" { return Self.assignment("none", kind: "none") }
        if id == "me" { kind = "human" } else if id == "hoot" { kind = "hoot" }
        else { guard let agent = try await config.agent(id) else { throw NativeRPCError.invalidArguments("Assign it to nobody, to yourself, to Hoot or to one of your task agents.") }; return Self.assignment(agent["id"].string!, kind: "agent") }
        return Self.assignment(id, kind: kind)
    }
    public func create(_ input: NativeRPCValue, by: String = BackendTaskActor.current, parentID: String? = nil) async throws -> BackendTaskRecord {
        await enter(); defer { leave() }; try Task.checkCancellation()
        let title = try BackendTaskValues.text(input["title"], "The title", max: 300, required: true)!, details = try BackendTaskValues.text(input["instructions"], "The details", max: 20_000) ?? ""
        let project = try BackendTaskValues.text(input["project"], "The project folder", max: 1_024) ?? "", assignment = try await assignee(input["assignee"])
        try Self.checkProject(project, assignment: assignment)
        let status = try Self.status(input["status"]) ?? "To-Do", external = UUID().uuidString.lowercased(), now = BackendTaskValues.time()
        let parent: BackendTaskRecord?
        if let parentID { parent = try await task(parentID) } else { parent = nil }
        if let parent { guard (parent.value["hops"].number ?? 0) < 3 else { throw NativeRPCError.invalidArguments("The hand-off limit for this task tree is reached.") } }
        var value = BackendTaskValues.object([("id", .string("local:" + external)), ("keyId", .string("local")), ("externalTaskId", .string(external)),
            ("originExternalTaskId", parent?.value["originExternalTaskId"] ?? .string(external)), ("externalThreadId", .null), ("parentExternalTaskId", parent?.value["externalTaskId"] ?? .null),
            ("title", .string(title)), ("instructions", .string(details)), ("project", .string(project)), ("assignee", assignment), ("mainAssignee", assignment["identity"]),
            ("creator", .string("me")), ("requestedBy", .string(by)), ("crmStatus", .string(status)), ("process", .string("idle")), ("sessionId", .null), ("conversationId", .null),
            ("runStartedAt", .null), ("keepOpenUntil", .null), ("hops", .number((parent?.value["hops"].number ?? -1) + 1)), ("result", .null), ("questionOpen", .bool(false)),
            ("lastTurn", .null), ("childrenTold", .null), ("stopped", .bool(false)), ("seq", .number(0)), ("local", .bool(true)), ("notes", .array([])), ("handedFrom", .null),
            ("labels", .array([])), ("taskType", .string("task")), ("completedAt", status == "Done" ? .number(now) : .null), ("createdAt", .number(now)), ("updatedAt", .number(now))])
        value = try value.merging(Self.fields(input))
        if input.has("goalId") { value = value.setting("goalId", try await goal(input["goalId"])) }
        else if let parent { value = value.setting("goalId", parent.value["goalId"]) }
        if input.has("useWorkspace") { guard let flag = input["useWorkspace"].bool else { throw NativeRPCError.invalidArguments("Running in its own workspace is on or off.") }; value = value.setting("useWorkspace", .bool(flag)) }
        let record = try await store.put(value)
        try await store.note(record.id, by: by, kind: "edited", text: "Created, assigned to \(await nameOf(assignment)).")
        if status != "Done" { try await engine.accept(record.id) }; return try await task(record.id)
    }
    public func update(_ id: String, input: NativeRPCValue, by: String = BackendTaskActor.current) async throws -> BackendTaskRecord {
        await enter(); defer { leave() }; try Task.checkCancellation(); let before = try await task(id)
        var patch = try Self.fields(input)
        for (key, maximum, label) in [("title", 300, "The title"), ("instructions", 20_000, "The details"), ("project", 1_024, "The project folder")] {
            if input.has(key), let text = try BackendTaskValues.text(input[key], label, max: maximum, required: key == "title") { patch = patch.setting(key, .string(text)) }
        }
        let assignment = input.has("assignee") ? try await assignee(input["assignee"]) : before.value["assignee"]
        try Self.checkProject(patch["project"].string ?? before.project, assignment: assignment)
        if let status = try Self.status(input["status"]) { patch = patch.setting("crmStatus", .string(status)).setting("completedAt", status == "Done" ? .number(BackendTaskValues.time()) : .null) }
        if input.has("goalId") { patch = patch.setting("goalId", try await goal(input["goalId"])) }
        if input.has("useWorkspace") { guard let flag = input["useWorkspace"].bool else { throw NativeRPCError.invalidArguments("Running in its own workspace is on or off.") }; patch = patch.setting("useWorkspace", .bool(flag)) }
        if input.has("archived") { patch = patch.setting("archivedAt", input["archived"].bool == true ? .number(BackendTaskValues.time()) : .null) }
        _ = try await store.update(id, patch: patch)
        var changed: [String] = []
        for (key, word) in [("title", "title"), ("instructions", "details"), ("project", "project")] where patch.has(key) && patch[key] != before.value[key] { changed.append(word) }
        for (key, word) in Self.fieldWords where patch.has(key) && Self.same(patch[key], before.value[key]) == false { changed.append(word) }
        if !changed.isEmpty { try await store.note(id, by: by, kind: "edited", text: "Changed the \(changed.joined(separator: ", ")).") }
        if patch.has("crmStatus"), patch["crmStatus"] != before.value["crmStatus"] { try await store.note(id, by: by, kind: "status", text: "Status: " + (patch["crmStatus"].string ?? "")) }
        if patch.has("archivedAt"), patch["archivedAt"].isNullish != before.value["archivedAt"].isNullish { try await store.note(id, by: by, kind: "edited", text: patch["archivedAt"].isNullish ? "Restored from the archive." : "Archived.") }
        if patch.has("goalId"), patch["goalId"] != before.value["goalId"] { let goalID = patch["goalId"].string ?? "", title = try await goals.byID(goalID)?["title"].string ?? goalID; try await store.note(id, by: by, kind: "edited", text: patch["goalId"].isNullish ? "No longer part of a goal." : "Part of the goal “\(title)”.") }
        if patch.has("useWorkspace"), patch["useWorkspace"] != before.value["useWorkspace"] { try await store.note(id, by: by, kind: "edited", text: patch["useWorkspace"].bool == true ? "Runs in a workspace of its own from its next start." : "Runs in its project folder from its next start, unless it already has a workspace.") }
        if assignment["identity"] != before.value["assignee"]["identity"] {
            try await store.note(id, by: by, kind: "assigned", text: "Assigned to \(await nameOf(assignment)).")
            try await engine.reassign(id, assignee: assignment); _ = try await store.update(id, patch: BackendTaskValues.object([("handedFrom", .null)]))
        }
        let after = try await task(id)
        if let updateObserver {
            let beforeNotes = Set((before.value["notes"].elements ?? []).map(\.compact)), writtenNotes = (after.value["notes"].elements ?? []).filter { !beforeNotes.contains($0.compact) }
            try await updateObserver(before, after, writtenNotes, by)
        }; return after
    }
    public func remove(_ id: String, by: String = BackendTaskActor.current) async throws {
        await enter(); defer { leave() }; let record = try await task(id)
        if record.sessionID != nil { try await engine.cancel(id, reason: "the task was deleted.") }
        try await store.note(id, by: by, kind: "edited", text: "Moved to Trash."); try await store.moveToTrash(id)
    }
    public func restore(_ id: String, by: String = BackendTaskActor.current) async throws -> BackendTaskRecord {
        await enter(); defer { leave() }; _ = try await store.restore(id); try await store.note(id, by: by, kind: "edited", text: "Restored from Trash."); return try await task(id)
    }
    public func reply(_ id: String, text: String) async throws -> BackendTaskRecord {
        await enter(); defer { leave() }; let record = try await task(id)
        let reply = try BackendTaskValues.text(.string(text), "The reply", max: 20_000, required: true)!
        let agent = record.assigneeKind == "agent" ? record.agentID : record.value["handedFrom"].string
        var hasWaitingAgent = false
        if let agent { hasWaitingAgent = try await config.agent(agent) != nil }
        guard record.assigneeKind == "hoot" || hasWaitingAgent else { throw NativeRPCError.invalidArguments("No agent is waiting on this task. Assign it to one instead.") }
        try await engine.reply(id, text: reply); return try await task(id)
    }
    public func task(_ id: String) async throws -> BackendTaskRecord {
        guard let task = try await store.byID(id), task.isLocal else { throw NativeRPCError.invalidArguments("That task no longer exists.") }; return task
    }
    public func setUpdateObserver(_ observer: UpdateObserver?) { updateObserver = observer }
    public func installEngineStatusObserver(_ observer: (@Sendable (String, String) async -> Void)?) async -> Bool {
        guard let actual = engine as? BackendTaskEngine else { return false }; await actual.setLocalStatusObserver(observer); return true
    }
    /// task-local.ts FIELD_WORDS, in the order crmFieldsOf yields them (position is not announced).
    private static let fieldWords = [("priority", "priority"), ("startDate", "start date"), ("dueDate", "due date"), ("startTime", "start time"), ("dueTime", "due time"), ("labels", "tags"), ("board", "board"), ("taskType", "type"), ("estimateMinutes", "estimate")]
    /// JSON.stringify(a ?? null) === JSON.stringify(b ?? null)
    private static func same(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool { (a.isNullish && b.isNullish) || a == b }
    private func nameOf(_ assignee: NativeRPCValue) async -> String {
        switch assignee["kind"].string ?? "none" {
        case "none": return "nobody"
        case "human": return "you"
        case "hoot": return "Hoot"
        default: let id = assignee["agentId"].string ?? "nobody"; return (try? await config.agent(id))?["name"].string ?? id
        }
    }
    public nonisolated static func assignment(_ id: String, kind: String) -> NativeRPCValue { BackendTaskValues.object([("kind", .string(kind)), ("agentId", .string(id)), ("identity", .string(id))]) }
    private func goal(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        if raw.isNullish || raw.string == "" { return .null }
        guard let id = raw.string, try await goals.byID(id) != nil else { throw NativeRPCError.invalidArguments("That goal no longer exists.") }; return .string(id)
    }
    private static func status(_ raw: NativeRPCValue) throws -> String? {
        if raw.isNullish || raw.string == "" { return nil }
        guard let status = raw.string, statuses.contains(status) else { throw NativeRPCError.invalidArguments("The status has to be one of: \(statuses.joined(separator: ", ")).") }; return status
    }
    private static func checkProject(_ path: String, assignment: NativeRPCValue) throws {
        guard path.isEmpty || (path.hasPrefix("/") && !path.contains("\0")) else { throw NativeRPCError.invalidArguments("\(path) is not a full folder path.") }
        guard !["agent", "hoot"].contains(assignment["kind"].string ?? "") || !path.isEmpty else { throw NativeRPCError.invalidArguments("Choose the project folder the agent should work in.") }
    }
    private static func fields(_ input: NativeRPCValue) throws -> NativeRPCValue {
        // task-local.ts crmFieldsOf: same refusals, same words, same order.
        var out = NativeRPCValue.object([])
        if input.has("priority") {
            let raw = input["priority"]
            if raw.isNullish || raw.string == "" { out = out.setting("priority", .null) }
            else if let text = raw.string, ["Low", "Medium", "High", "Critical"].contains(text) { out = out.setting("priority", raw) }
            else { throw NativeRPCError.invalidArguments("The priority has to be one of: Low, Medium, High, Critical, or none.") }
        }
        for (key, label) in [("startDate", "The start date"), ("dueDate", "The due date")] where input.has(key) {
            let raw = input[key]
            if raw.isNullish || raw.string == "" { out = out.setting(key, .null); continue }
            guard let text = raw.string, isDate(text) else { throw NativeRPCError.invalidArguments("\(label) has to be a date.") }
            out = out.setting(key, raw)
        }
        for (key, label) in [("startTime", "The start time"), ("dueTime", "The due time")] where input.has(key) {
            let raw = input[key]
            if raw.isNullish || raw.string == "" { out = out.setting(key, .null); continue }
            guard let text = raw.string, text.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("\(label) has to be a time like 09:30.") }
            out = out.setting(key, raw)
        }
        if input.has("labels") {
            guard let raw = input["labels"].elements else { throw NativeRPCError.invalidArguments("Tags have to be a list.") }
            var labels: [String] = []
            for entry in raw {
                guard let text = entry.string else { continue }; let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty || labels.contains(label) { continue }
                guard label.utf16.count <= 40 else { throw NativeRPCError.invalidArguments("A tag can be at most 40 characters.") }
                labels.append(label)
            }
            guard labels.count <= 20 else { throw NativeRPCError.invalidArguments("A task can have at most 20 tags.") }
            out = out.setting("labels", .array(labels.map(NativeRPCValue.string)))
        }
        if input.has("board") {
            let raw = input["board"]
            if raw.isNullish || (raw.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) { out = out.setting("board", .null) }
            else if let text = raw.string?.trimmingCharacters(in: .whitespacesAndNewlines), text.utf16.count <= 40 { out = out.setting("board", .string(text)) }
            else { throw NativeRPCError.invalidArguments("A board's name can be at most 40 characters.") }
        }
        if input.has("taskType") {
            guard let text = input["taskType"].string, ["task", "milestone"].contains(text) else { throw NativeRPCError.invalidArguments("The type is a task or a milestone.") }
            out = out.setting("taskType", .string(text))
        }
        if input.has("estimateMinutes") {
            let raw = input["estimateMinutes"]
            if raw.isNullish || raw.string == "" { out = out.setting("estimateMinutes", .null) }
            else if let number = raw.number, number.rounded() == number, number >= 0, number <= 100_000 { out = out.setting("estimateMinutes", raw) }
            else { throw NativeRPCError.invalidArguments("The estimate is a whole number of minutes, at most 100000.") }
        }
        if input.has("position") {
            let raw = input["position"]
            if raw.isNullish { out = out.setting("position", .null) }
            else if let number = raw.number, number.isFinite { out = out.setting("position", raw) }
            else { throw NativeRPCError.invalidArguments("The position has to be a number.") }
        }
        return out
    }
    private static func isDate(_ text: String) -> Bool {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }; return formatter.string(from: date) == text
    }
    private func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    private func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
}

extension Optional where Wrapped == String {
    func asyncMap<T>(isolation: isolated (any Actor)? = #isolation, _ transform: (String) async throws -> T) async rethrows -> T? { guard let value = self else { return nil }; return try await transform(value) }
}
