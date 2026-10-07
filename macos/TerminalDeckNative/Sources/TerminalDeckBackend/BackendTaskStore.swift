import Foundation
import TerminalDeckNativeCore

/// Wire-preserving record: optional popup fields and unknown future fields are
/// kept byte-semantically through updates rather than discarded by a decoder.
public struct BackendTaskRecord: Sendable, Equatable {
    public let value: NativeRPCValue
    public init(_ value: NativeRPCValue) throws {
        guard let id = value["id"].string, let key = value["keyId"].string, let external = value["externalTaskId"].string,
              id == key + ":" + external, !id.isEmpty else { throw NativeRPCError.malformed("Invalid task identity") }
        self.value = value
    }
    public var id: String { value["id"].string! }
    public var sessionID: String? { value["sessionId"].string }
    public var project: String { value["project"].string ?? "" }
    public var isLocal: Bool { value["local"].bool == true }
    public var process: String { value["process"].string ?? "unknown" }
    public var agentID: String { value["assignee"]["agentId"].string ?? "unknown" }
    public var assigneeKind: String { value["assignee"]["kind"].string ?? "unknown" }
}

public actor BackendTaskStore {
    private let persistence: BackendTaskPersistence
    private var tasks: [String: BackendTaskRecord] = [:], trash: [String: BackendTaskRecord] = [:]
    private var order: [String] = [], trashOrder: [String] = []
    private var seen: [String: NativeRPCValue] = [:], ours: [String: Double] = [:]
    private var seenOrder: [String] = [], oursOrder: [String] = []
    private var loaded = false
    private let changed: @Sendable () async -> Void
    public init(persistence: BackendTaskPersistence, changed: @escaping @Sendable () async -> Void = {}) {
        self.persistence = persistence; self.changed = changed
    }
    public func start() throws {
        guard !loaded else { return }
        if let raw = try persistence.read("tasks.json") {
            guard raw["v"].number == 1 else { throw NativeRPCError.malformed("Unsupported tasks.json version; existing records were kept") }
            for value in raw["tasks"].elements ?? [] { if let task = try? BackendTaskRecord(value) { if tasks[task.id] == nil { order.append(task.id) }; tasks[task.id] = task } }
            for value in raw["trash"].elements ?? [] { if let task = try? BackendTaskRecord(value), tasks[task.id] == nil { if trash[task.id] == nil { trashOrder.append(task.id) }; trash[task.id] = task } }
            for entry in raw["seen"].elements ?? [] { if let pair = entry.elements, pair.count == 2, let key = pair[0].string, pair[1]["at"].number != nil { if seen[key] == nil { seenOrder.append(key) }; seen[key] = pair[1] } }
            for entry in raw["ours"].elements ?? [] { if let pair = entry.elements, pair.count == 2, let key = pair[0].string, let at = pair[1].number { if ours[key] == nil { oursOrder.append(key) }; ours[key] = at } }
        }
        loaded = true; prune()
    }
    public func all(includeTrash: Bool = false) throws -> [BackendTaskRecord] { try requireStarted(); return order.compactMap { tasks[$0] } + (includeTrash ? trashOrder.compactMap { trash[$0] } : []) }
    public func inTrash() throws -> [BackendTaskRecord] { try requireStarted(); return trashOrder.compactMap { trash[$0] } }
    public func byID(_ id: String, includeTrash: Bool = false) throws -> BackendTaskRecord? { try requireStarted(); return tasks[id] ?? (includeTrash ? trash[id] : nil) }
    public func bySession(_ id: String) throws -> BackendTaskRecord? { try requireStarted(); return tasks.values.first { $0.sessionID == id } }
    public func put(_ value: NativeRPCValue) async throws -> BackendTaskRecord {
        try requireStarted(); try persistence.writable(); let record = try BackendTaskRecord(value.setting("updatedAt", .number(BackendTaskValues.time())))
        let before = tasks, oldOrder = order; if tasks[record.id] == nil { order.append(record.id) }; tasks[record.id] = record; prune()
        do { try flush() } catch { tasks = before; order = oldOrder; throw error }; await changed(); return record
    }
    public func update(_ id: String, patch: NativeRPCValue) async throws -> BackendTaskRecord {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        guard !patch.has("id"), !patch.has("keyId"), !patch.has("externalTaskId") else { throw NativeRPCError.invalidArguments("Task identity cannot change") }
        return try await put(task.value.merging(patch))
    }
    public func note(_ id: String, by: String, kind: String, text: String) async throws {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let note = BackendTaskValues.object([("at", .number(BackendTaskValues.time())), ("by", .string(by)), ("kind", .string(kind)), ("text", .string(text))])
        _ = try await update(id, patch: BackendTaskValues.object([("notes", .array(Array(((task.value["notes"].elements ?? []) + [note]).suffix(100))))]))
    }
    public func claim(_ id: String, sessionID: String, liveSessionIDs: Set<String>) async throws -> Bool {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        if let holder = task.sessionID, holder != sessionID, liveSessionIDs.contains(holder) { return false }
        _ = try await update(id, patch: BackendTaskValues.object([("sessionId", .string(sessionID)), ("process", .string("running"))])); return true
    }
    public func release(_ id: String, process: String = "exited") async throws {
        _ = try await update(id, patch: BackendTaskValues.object([("sessionId", .null), ("process", .string(process)), ("keepOpenUntil", .null)]))
    }
    public func moveToTrash(_ id: String) async throws {
        try requireStarted(); try persistence.writable(); guard let record = tasks[id] else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let before = (tasks, trash), now = BackendTaskValues.time()
        tasks[id] = nil; trash[id] = try BackendTaskRecord(record.value.setting("deletedAt", .number(now)).setting("updatedAt", .number(now)))
        let oldOrder = order, oldTrashOrder = trashOrder; order.removeAll { $0 == id }; if !trashOrder.contains(id) { trashOrder.append(id) }
        do { try flush() } catch { (tasks, trash) = before; order = oldOrder; trashOrder = oldTrashOrder; throw error }; await changed()
    }
    public func restore(_ id: String) async throws -> BackendTaskRecord {
        try requireStarted(); try persistence.writable()
        guard let record = trash[id], record.isLocal, tasks[id] == nil else { throw NativeRPCError.invalidArguments("That task is not in the Trash.") }
        let before = (tasks, trash), restored = try BackendTaskRecord(record.value.setting("deletedAt", .null).setting("updatedAt", .number(BackendTaskValues.time())))
        trash[id] = nil; tasks[id] = restored
        let oldOrder = order, oldTrashOrder = trashOrder; trashOrder.removeAll { $0 == id }; order.append(id)
        do { try flush() } catch { (tasks, trash) = before; order = oldOrder; trashOrder = oldTrashOrder; throw error }; await changed(); return restored
    }
    public func updateInTrash(_ id: String, patch: NativeRPCValue) async throws {
        try requireStarted(); try persistence.writable(); guard let current = trash[id] else { throw NativeRPCError.invalidArguments("That task is not in the Trash.") }
        guard !patch.has("id"), !patch.has("keyId"), !patch.has("externalTaskId") else { throw NativeRPCError.invalidArguments("Task identity cannot change") }
        trash[id] = try BackendTaskRecord(current.value.merging(patch).setting("updatedAt", .number(BackendTaskValues.time())))
        do { try flush() } catch { trash[id] = current; throw error }; await changed()
    }
    @discardableResult public func relinkGoal(_ id: String, parent: String?) async throws -> [BackendTaskRecord] {
        try requireStarted(); try persistence.writable(); let before = (tasks, trash)
        let affected = (Array(tasks.values) + Array(trash.values)).filter { $0.value["goalId"].string == id }
        for key in Array(tasks.keys) where tasks[key]?.value["goalId"].string == id { tasks[key] = try BackendTaskRecord(tasks[key]!.value.setting("goalId", parent.map(NativeRPCValue.string) ?? .null)) }
        for key in Array(trash.keys) where trash[key]?.value["goalId"].string == id { trash[key] = try BackendTaskRecord(trash[key]!.value.setting("goalId", parent.map(NativeRPCValue.string) ?? .null)) }
        do { try flush() } catch { (tasks, trash) = before; throw error }; await changed(); return affected
    }
    public func restoreGoalLinks(_ records: [BackendTaskRecord], expectedParent: String?) async throws {
        try requireStarted(); try persistence.writable(); let before = (tasks, trash)
        for record in records {
            if let current = tasks[record.id], current.value["goalId"].string == expectedParent { tasks[record.id] = try BackendTaskRecord(current.value.setting("goalId", record.value["goalId"])) }
            if let current = trash[record.id], current.value["goalId"].string == expectedParent { trash[record.id] = try BackendTaskRecord(current.value.setting("goalId", record.value["goalId"])) }
        }
        do { try flush() } catch { (tasks, trash) = before; throw error }; await changed()
    }
    public func answered(keyID: String, eventID: String) throws -> NativeRPCValue { try requireStarted(); return seen[keyID + ":" + eventID]?["answer"] ?? .missing }
    public func remember(keyID: String, eventID: String, answer: NativeRPCValue) throws {
        try requireStarted(); try persistence.writable(); let before = seen, oldOrder = seenOrder, key = keyID + ":" + eventID
        if seen[key] == nil { seenOrder.append(key) }; seen[key] = BackendTaskValues.object([("at", .number(BackendTaskValues.time())), ("answer", answer)])
        prune(); do { try flush() } catch { seen = before; seenOrder = oldOrder; throw error }
    }
    public func markOurs(keyID: String, eventID: String) throws {
        try requireStarted(); try persistence.writable(); let before = ours, oldOrder = oursOrder, key = keyID + ":" + eventID; if ours[key] == nil { oursOrder.append(key) }; ours[key] = BackendTaskValues.time()
        do { try flush() } catch { ours = before; oursOrder = oldOrder; throw error }
    }
    public func isOurs(keyID: String, eventID: String) throws -> Bool { try requireStarted(); return ours[keyID + ":" + eventID] != nil }
    public func nextSequence(_ id: String) throws -> Int {
        try requireStarted(); try persistence.writable(); guard let current = tasks[id] else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let sequence = Int(current.value["seq"].number ?? 0)
        tasks[id] = try BackendTaskRecord(current.value.setting("seq", .number(Double(sequence + 1))).setting("updatedAt", .number(BackendTaskValues.time())))
        do { try flush() } catch { tasks[id] = current; throw error }; return sequence
    }
    public func stop() throws { if loaded, persistence.ownership != .readOnly { try flush() } }
    public func requireWritableOwnership() throws { try persistence.writable() }
    private func requireStarted() throws { guard loaded else { throw NativeRPCError(code: "not-started", message: "Task records have not been opened") } }
    private func prune() {
        let cutoff = BackendTaskValues.time() - 7 * 86_400_000
        seen = seen.filter { ($0.value["at"].number ?? 0) >= cutoff }; ours = ours.filter { $0.value >= cutoff }
        seenOrder.removeAll { seen[$0] == nil }; oursOrder.removeAll { ours[$0] == nil }
        for key in seenOrder.prefix(max(0, seen.count - 5_000)) { seen[key] = nil }; for key in oursOrder.prefix(max(0, ours.count - 5_000)) { ours[key] = nil }
        seenOrder.removeAll { seen[$0] == nil }; oursOrder.removeAll { ours[$0] == nil }
        let mirrored = order.compactMap { tasks[$0] }.filter { !$0.isLocal }, extra = mirrored.count - 500
        if extra > 0 { for task in mirrored.filter({ $0.sessionID == nil && $0.process != "queued" }).sorted(by: { ($0.value["updatedAt"].number ?? 0) < ($1.value["updatedAt"].number ?? 0) }).prefix(extra) { tasks[task.id] = nil } }
        order.removeAll { tasks[$0] == nil }; trashOrder.removeAll { trash[$0] == nil }
    }
    private func flush() throws {
        try persistence.write("tasks.json", value: BackendTaskValues.object([("v", .number(1)), ("tasks", .array(order.compactMap { tasks[$0]?.value })), ("trash", .array(trashOrder.compactMap { trash[$0]?.value })),
            ("seen", .array(seenOrder.compactMap { key in seen[key].map { .array([.string(key), $0]) } })), ("ours", .array(oursOrder.compactMap { key in ours[key].map { .array([.string(key), .number($0)]) } }))]))
    }
}
