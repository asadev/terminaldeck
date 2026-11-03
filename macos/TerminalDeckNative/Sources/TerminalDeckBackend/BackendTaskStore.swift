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
    private var tasks: [String: BackendTaskRecord] = [:] { didSet { sessionIndex = nil } }
    private var trash: [String: BackendTaskRecord] = [:]
    /// U140 (#194): which task holds each session, built on the first look after a change. Every session status event
    /// asks it, several times over; each look used to go through every task.
    private var sessionIndex: [String: String]?
    private var order: [String] = [], trashOrder: [String] = []
    private var seen: [String: NativeRPCValue] = [:], ours: [String: Double] = [:]
    private var seenOrder: [String] = [], oursOrder: [String] = []
    private var runs: [String: NativeRPCValue] = [:], runOrder: [String] = []
    private var runRollups: NativeRPCValue = .object([]), runtimeState: NativeRPCValue = .object([])
    private var historySince: Double?, historyCalendar = Calendar(identifier: .gregorian)
    private var loaded = false
    private let changed: @Sendable () async -> Void
    /// U141 (#182): the records live in three files, each written only when its part changed: the tasks and the Trash
    /// (tasks.json), the agents' run history and runtime state (task-runs.json), and the CRM event receipts
    /// (task-receipts.json). Before, every change rewrote all of them in one file, many times a second while agents worked.
    private struct Parts: OptionSet { let rawValue: Int; static let tasks = Parts(rawValue: 1), runs = Parts(rawValue: 2), receipts = Parts(rawValue: 4); static let all: Parts = [.tasks, .runs, .receipts] }
    static let runsFile = "task-runs.json", receiptsFile = "task-receipts.json"
    private var dirty: Parts = [], lastWrite: Double?, writeTimer: BackendTaskTimer?
    /// Milliseconds a routine change waits after the last write, so a burst of them (token counts, notes, status marks)
    /// is written once. 0 (the default) writes every change at once. Changes that must not be lost (decisions, a session
    /// taken or given up, the Trash, goal links, CRM receipts and sequence numbers, an agent's pause) are always written
    /// at once, with anything still waiting.
    private let writeDelay: Double
    public init(persistence: BackendTaskPersistence, writeDelay: Double = 0, changed: @escaping @Sendable () async -> Void = {}) {
        self.persistence = persistence; self.writeDelay = writeDelay; self.changed = changed
    }
    public func start() throws {
        guard !loaded else { return }
        let raw = try persistence.read("tasks.json")
        if let raw { guard raw["v"].number == 1 else { throw NativeRPCError.malformed("Unsupported tasks.json version; existing records were kept") } }
        // A tasks.json written before U141 still holds the run history and the receipts; their own files win once written.
        let runsRaw = try persistence.read(Self.runsFile), receiptsRaw = try persistence.read(Self.receiptsFile)
        for (file, value) in [(Self.runsFile, runsRaw), (Self.receiptsFile, receiptsRaw)] where value != nil && value?["v"].number != 1 {
            throw NativeRPCError.malformed("Unsupported \(file) version; existing records were kept")
        }
        if let history = runsRaw ?? raw {
            for row in history["agentRuns"].elements ?? [] {
                if let id = row["id"].string, row["agent_id"].string != nil, row["session_id"].string != nil || row["conversation_id"].string != nil, row["started_at"].number != nil {
                    if runs[id] == nil { runOrder.append(id) }; runs[id] = row
                }
            }
            if history["agentRunRollups"].fields != nil { runRollups = history["agentRunRollups"] }
            if history["agentRuntimeState"].fields != nil { runtimeState = history["agentRuntimeState"] }
            historySince = history["agentHistorySince"].number
        }
        if let raw {
            for value in raw["tasks"].elements ?? [] { if let task = try? BackendTaskRecord(value) { if tasks[task.id] == nil { order.append(task.id) }; tasks[task.id] = task } }
            for value in raw["trash"].elements ?? [] { if let task = try? BackendTaskRecord(value), tasks[task.id] == nil { if trash[task.id] == nil { trashOrder.append(task.id) }; trash[task.id] = task } }
        }
        if let receipts = receiptsRaw ?? raw {
            for entry in receipts["seen"].elements ?? [] { if let pair = entry.elements, pair.count == 2, let key = pair[0].string, pair[1]["at"].number != nil { if seen[key] == nil { seenOrder.append(key) }; seen[key] = pair[1] } }
            for entry in receipts["ours"].elements ?? [] { if let pair = entry.elements, pair.count == 2, let key = pair[0].string, let at = pair[1].number { if ours[key] == nil { oursOrder.append(key) }; ours[key] = at } }
        }
        // Moved out of an old tasks.json: their own file is written before tasks.json is written without them.
        if runsRaw == nil, ["agentRuns", "agentRunRollups", "agentRuntimeState", "agentHistorySince"].contains(where: { raw?.has($0) == true }) { dirty.insert(.runs) }
        if receiptsRaw == nil, ["seen", "ours"].contains(where: { raw?.has($0) == true }) { dirty.insert(.receipts) }
        loaded = true; pruneReceipts(); prune()
    }
    public func all(includeTrash: Bool = false) throws -> [BackendTaskRecord] { try requireStarted(); return order.compactMap { tasks[$0] } + (includeTrash ? trashOrder.compactMap { trash[$0] } : []) }
    public func inTrash() throws -> [BackendTaskRecord] { try requireStarted(); return trashOrder.compactMap { trash[$0] } }
    public func byID(_ id: String, includeTrash: Bool = false) throws -> BackendTaskRecord? { try requireStarted(); return tasks[id] ?? (includeTrash ? trash[id] : nil) }
    public func bySession(_ id: String) throws -> BackendTaskRecord? {
        try requireStarted()
        if sessionIndex == nil {
            var index: [String: String] = [:]
            for task in tasks.values { if let session = task.sessionID, index[session] == nil { index[session] = task.id } }
            sessionIndex = index
        }
        return sessionIndex?[id].flatMap { tasks[$0] }
    }
    /// `now`: written at once even inside a burst (U141).
    public func put(_ value: NativeRPCValue, now: Bool = false) async throws -> BackendTaskRecord {
        let record = try putNow(value, now: now); await changed(); return record
    }
    /// Every mutation and flush completes before callbacks can reenter Store.
    private func putNow(_ value: NativeRPCValue, decisionOwner: Bool = false, now: Bool = false) throws -> BackendTaskRecord {
        try requireStarted(); try requireCompletionFence(); try persistence.writable()
        let id = value["id"].string ?? "", previous = tasks[id]
        var value = value
        if !decisionOwner {
            if let previous {
                for key in PCDecisions.protectedKeys {
                    if !value.has(key), key == "decisionEligible" || !PCDecisions.requires(previous.value) {
                        if previous.value.has(key) { value = value.setting(key, previous.value[key]) }
                    } else if value[key] != previous.value[key] {
                        throw NativeRPCError(code: "decision-protected", message: "Only the owner workflow action can change a task's decision requirement.")
                    }
                }
            } else if PCDecisions.protectedKeys.contains(where: { value.has($0) }) {
                throw NativeRPCError(code: "decision-protected", message: "A new task cannot copy or supply decision approval markers.")
            }
        }
        if previous == nil {
            if PCDecisions.eligible(value), value["assignee"]["kind"].string == "none" { value = value.setting("decisionEligible", .bool(true)) }
        } else if let previous {
            if PCDecisions.requires(previous.value), PCDecisions.scopeKeys.filter({ !$0.hasPrefix("decision") }).contains(where: { previous.value[$0] != value[$0] }) {
                value = value.setting("decisionEpoch", .number((previous.value["decisionEpoch"].number ?? 0) + 1))
            }
            if !["none", "human"].contains(value["assignee"]["kind"].string ?? "") { value = value.removing("decisionEligible") }
        }
        let record = try BackendTaskRecord(value.setting("updatedAt", .number(BackendTaskValues.time())))
        let before = tasks, oldOrder = order, historyBefore = (runs, runOrder, runRollups, historySince)
        do {
            let ran = try observeTaskRun(record, before: tasks[record.id])
            if tasks[record.id] == nil { order.append(record.id) }; tasks[record.id] = record; prune()
            try flush(ran ? [.tasks, .runs] : .tasks, now: decisionOwner || now)
        } catch { tasks = before; order = oldOrder; (runs, runOrder, runRollups, historySince) = historyBefore; throw error }; return record
    }
    public func putDecisionTask(_ value: NativeRPCValue) async throws -> BackendTaskRecord {
        guard PCDecisions.eligible(value), value["assignee"]["kind"].string == "none", value["decisionRequired"].bool == true,
              value["decisionCreateRequest"].string != nil, value["decisionID"].string != nil, value["decisionPolicyID"].string != nil else { throw NativeRPCError.invalidArguments("A decision task must be created unassigned with its protected binding.") }
        let record = try putNow(value, decisionOwner: true); await changed(); return record
    }
    /// The business-decision service is the sole registered owner of this seam.
    /// Generic put/update cannot supply, remove or replace these markers.
    public func decisionMarker(_ id: String, policy: String?, decision: String?, required: Bool, expected: String? = nil) async throws -> BackendTaskRecord {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That local task no longer exists.") }
        if let expected, BackendPCDecisionMarker.fingerprint(task) != expected { throw NativeRPCError(code: "decision-stale", message: "The task changed at the marker write boundary.") }
        let value = task.value.setting("decisionRequired", .bool(required))
            .setting("decisionPolicyID", policy.map(NativeRPCValue.string) ?? .null)
            .setting("decisionID", decision.map(NativeRPCValue.string) ?? .null)
            .setting("decisionEpoch", .number((task.value["decisionEpoch"].number ?? 0) + 1))
        let record = try putNow(value, decisionOwner: true); await changed(); return record
    }
    public func noteTokenUsage(sessionID: String, totalTokens: Double, expectedTaskID: String,
                               expectedAssignee: NativeRPCValue, expectedRunID: String?) async throws -> (task: BackendTaskRecord, warned: Bool)? {
        try requireStarted(); try requireCompletionFence()
        guard totalTokens.isFinite, (0...1e15).contains(totalTokens), let task = tasks[expectedTaskID],
              task.sessionID == sessionID, task.value["assignee"] == expectedAssignee,
              task.value["agoptRunID"].string == expectedRunID, task.value["stopped"].bool != true,
              task.value["agoptEfficiencyApplied"].bool == true else { return nil }
        let previous = task.value["agoptUsageTotal"].number ?? 0
        guard totalTokens >= previous else { return nil }
        let used = (task.value["tokenUsage"].number ?? 0) + totalTokens - previous
        var buckets = BackendAGOPTTaskPolicy.usageByAgent(task)
        if let agent = task.value["agoptAgentID"].string { buckets = buckets.setting(agent, .number((buckets[agent].number ?? 0) + totalTokens - previous)) }
        let cap = task.value["agoptTaskTokenBudget"].number ?? 0, percent = task.value["agoptWarningPercent"].number ?? 80
        let warned = cap > 0 && used >= cap * percent / 100 && task.value["agoptTaskBudgetWarned"].bool != true
        var value = task.value.setting("agoptUsageTotal", .number(totalTokens)).setting("agoptUsageMeasured", .bool(true))
            .setting("tokenUsage", .number(used)).setting("tokenUsageByAgent", buckets)
        if warned { value = value.setting("agoptTaskBudgetWarned", .bool(true)) }
        let updated = try putNow(value); await changed(); return (updated, warned)
    }
    public func update(_ id: String, patch: NativeRPCValue, now: Bool = false) async throws -> BackendTaskRecord {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        guard !patch.has("id"), !patch.has("keyId"), !patch.has("externalTaskId") else { throw NativeRPCError.invalidArguments("Task identity cannot change") }
        return try await put(task.value.merging(patch), now: now)
    }
    public func note(_ id: String, by: String, kind: String, text: String) async throws {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let note = BackendTaskValues.object([("id", .string("task-note-" + UUID().uuidString.lowercased())), ("at", .number(BackendTaskValues.time())), ("by", .string(by)), ("kind", .string(kind)), ("text", .string(text))])
        _ = try await update(id, patch: BackendTaskValues.object([("notes", .array(Array(((task.value["notes"].elements ?? []) + [note]).suffix(100))))]))
    }
    public func claim(_ id: String, sessionID: String, liveSessionIDs: Set<String>, expectedAssignee: NativeRPCValue? = nil) async throws -> Bool {
        guard let task = try byID(id) else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        if let expectedAssignee {
            guard task.value["assignee"] == expectedAssignee, task.value["stopped"].bool != true else { throw NativeRPCError.invalidArguments("The task changed assignment before its brief was delivered. The new session was stopped.") }
        }
        if tasks.values.contains(where: { $0.id != id && $0.sessionID == sessionID }) { return false }
        if let holder = task.sessionID, holder != sessionID, liveSessionIDs.contains(holder) { return false }
        _ = try await update(id, patch: BackendTaskValues.object([("sessionId", .string(sessionID)), ("process", .string("running"))]), now: true); return true
    }
    /// Rebind only one completed, identity-matched worker, in one persistence
    /// transaction. No moment leaves two tasks with the same session grant.
    public func transferSession(from oldID: String, to newID: String, expectedAssignee: NativeRPCValue,
                                liveSessionIDs: Set<String>, expectedChoices: NativeRPCValue? = nil) async throws -> Bool {
        try requireStarted(); try persistence.writable()
        guard oldID != newID, let old = tasks[oldID], let next = tasks[newID],
              let session = old.sessionID, liveSessionIDs.contains(session), next.sessionID == nil,
              !old.value["result"].isNullish, old.value["stopped"].bool != true,
              next.value["stopped"].bool != true, next.value["assignee"] == expectedAssignee,
              next.assigneeKind == "agent", BackendTaskSessionGate.ownerAgentID(old) == next.agentID, old.value["agoptEfficiencyApplied"].bool == true,
              next.value["agoptEfficiencyApplied"].bool == true else { return false }
        for field in ["keyId", "notificationKeyId", "project", "projectId", "agoptAgentID", "agoptProvider", "agoptAccount", "agoptProfileID", "agoptSettingsSignature", "agoptModel", "agoptEffort"] {
            guard old.value[field] == next.value[field] else { return false }
        }
        if let expectedChoices {
            for field in ["model", "effort", "tokenBudget"] {
                let current = next.value[field].isNullish ? NativeRPCValue.null : next.value[field]
                let expected = expectedChoices[field].isNullish ? NativeRPCValue.null : expectedChoices[field]
                guard current == expected else { return false }
            }
        }
        guard !tasks.values.contains(where: { $0.id != oldID && $0.sessionID == session }) else { return false }
        let before = tasks, now = BackendTaskValues.time(), historyBefore = (runs, runOrder, runRollups, historySince)
        tasks[oldID] = try BackendTaskRecord(old.value.setting("agoptRunRetired", .bool(true)).setting("agoptRunEndReason", .string("reassigned")).setting("agoptRunID", .string(UUID().uuidString.lowercased())).setting("sessionId", .null).setting("process", .string("exited"))
            .setting("keepOpenUntil", .null).setting("keepAliveUntilClose", .bool(false)).setting("updatedAt", .number(now)))
        tasks[newID] = try BackendTaskRecord(next.value.setting("sessionId", .string(session)).setting("process", .string("running"))
            .setting("agoptPriorTurn", old.value["lastTurn"].isNullish ? (old.value["agoptPriorTurn"].isNullish ? .null : old.value["agoptPriorTurn"]) : old.value["lastTurn"])
            .setting("conversationId", old.value["conversationId"].isNullish ? .null : old.value["conversationId"]).setting("agoptUsageTotal", old.value["agoptUsageTotal"].isNullish ? .number(0) : old.value["agoptUsageTotal"])
            .setting("keepOpenUntil", .null).setting("keepAliveUntilClose", .bool(false)).setting("runStartedAt", .number(now)).setting("updatedAt", .number(now)))
        do {
            if let movedOld = tasks[oldID], let movedNew = tasks[newID] { _ = try observeTaskRun(movedOld, before: old); _ = try observeTaskRun(movedNew, before: next) }
            try flush([.tasks, .runs], now: true)
        } catch { tasks = before; (runs, runOrder, runRollups, historySince) = historyBefore; throw error }
        await changed(); return true
    }
    public func release(_ id: String, process: String = "exited") async throws {
        _ = try await update(id, patch: BackendTaskValues.object([("sessionId", .null), ("process", .string(process)), ("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false))]), now: true)
    }
    public func moveToTrash(_ id: String) async throws {
        try requireStarted(); try persistence.writable(); guard let record = tasks[id] else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let before = (tasks, trash), now = BackendTaskValues.time()
        tasks[id] = nil; trash[id] = try BackendTaskRecord(record.value.setting("deletedAt", .number(now)).setting("updatedAt", .number(now)))
        let oldOrder = order, oldTrashOrder = trashOrder; order.removeAll { $0 == id }; if !trashOrder.contains(id) { trashOrder.append(id) }
        do { try flush(.tasks, now: true) } catch { (tasks, trash) = before; order = oldOrder; trashOrder = oldTrashOrder; throw error }; await changed()
    }
    /// Remove exactly one local record already in Trash; active tasks are never eligible.
    public func purgeTrash(_ id: String) async throws {
        try requireStarted(); try persistence.writable()
        guard let record = trash[id], record.isLocal, record.sessionID == nil else {
            throw NativeRPCError.invalidArguments("Only a stopped local task in Trash can be permanently deleted.")
        }
        let before = trash, beforeOrder = trashOrder
        trash[id] = nil; trashOrder.removeAll { $0 == id }
        do { try flush(.tasks, now: true) } catch { trash = before; trashOrder = beforeOrder; throw error }
        await changed()
    }
    public func restore(_ id: String) async throws -> BackendTaskRecord {
        try requireStarted(); try persistence.writable()
        guard let record = trash[id], record.isLocal, tasks[id] == nil else { throw NativeRPCError.invalidArguments("That task is not in the Trash.") }
        let before = (tasks, trash), restored = try BackendTaskRecord(record.value.setting("deletedAt", .null).setting("updatedAt", .number(BackendTaskValues.time())))
        trash[id] = nil; tasks[id] = restored
        let oldOrder = order, oldTrashOrder = trashOrder; trashOrder.removeAll { $0 == id }; order.append(id)
        do { try flush(.tasks, now: true) } catch { (tasks, trash) = before; order = oldOrder; trashOrder = oldTrashOrder; throw error }; await changed(); return restored
    }
    public func updateInTrash(_ id: String, patch: NativeRPCValue) async throws {
        try requireStarted(); try persistence.writable(); guard let current = trash[id] else { throw NativeRPCError.invalidArguments("That task is not in the Trash.") }
        guard !patch.has("id"), !patch.has("keyId"), !patch.has("externalTaskId") else { throw NativeRPCError.invalidArguments("Task identity cannot change") }
        trash[id] = try BackendTaskRecord(current.value.merging(patch).setting("updatedAt", .number(BackendTaskValues.time())))
        do { try flush(.tasks, now: true) } catch { trash[id] = current; throw error }; await changed()
    }
    @discardableResult public func relinkGoal(_ id: String, parent: String?) async throws -> [BackendTaskRecord] {
        try requireStarted(); try persistence.writable(); let before = (tasks, trash)
        let affected = (Array(tasks.values) + Array(trash.values)).filter { $0.value["goalId"].string == id }
        for key in Array(tasks.keys) where tasks[key]?.value["goalId"].string == id { tasks[key] = try BackendTaskRecord(tasks[key]!.value.setting("goalId", parent.map(NativeRPCValue.string) ?? .null)) }
        for key in Array(trash.keys) where trash[key]?.value["goalId"].string == id { trash[key] = try BackendTaskRecord(trash[key]!.value.setting("goalId", parent.map(NativeRPCValue.string) ?? .null)) }
        do { try flush(.tasks, now: true) } catch { (tasks, trash) = before; throw error }; await changed(); return affected
    }
    public func restoreGoalLinks(_ records: [BackendTaskRecord], expectedParent: String?) async throws {
        try requireStarted(); try persistence.writable(); let before = (tasks, trash)
        for record in records {
            if let current = tasks[record.id], current.value["goalId"].string == expectedParent { tasks[record.id] = try BackendTaskRecord(current.value.setting("goalId", record.value["goalId"])) }
            if let current = trash[record.id], current.value["goalId"].string == expectedParent { trash[record.id] = try BackendTaskRecord(current.value.setting("goalId", record.value["goalId"])) }
        }
        do { try flush(.tasks, now: true) } catch { (tasks, trash) = before; throw error }; await changed()
    }
    public func answered(keyID: String, eventID: String) throws -> NativeRPCValue { try requireStarted(); return seen[keyID + ":" + eventID]?["answer"] ?? .missing }
    public func remember(keyID: String, eventID: String, answer: NativeRPCValue) throws {
        try requireStarted(); try persistence.writable(); let before = seen, oldOrder = seenOrder, key = keyID + ":" + eventID
        if seen[key] == nil { seenOrder.append(key) }; seen[key] = BackendTaskValues.object([("at", .number(BackendTaskValues.time())), ("answer", answer)])
        pruneReceipts(); do { try flush(.receipts, now: true) } catch { seen = before; seenOrder = oldOrder; throw error }
    }
    public func markOurs(keyID: String, eventID: String) throws {
        try requireStarted(); try persistence.writable(); let before = ours, oldOrder = oursOrder, key = keyID + ":" + eventID; if ours[key] == nil { oursOrder.append(key) }; ours[key] = BackendTaskValues.time()
        pruneReceipts(); do { try flush(.receipts, now: true) } catch { ours = before; oursOrder = oldOrder; throw error }
    }
    public func isOurs(keyID: String, eventID: String) throws -> Bool { try requireStarted(); return ours[keyID + ":" + eventID] != nil }
    public func nextSequence(_ id: String) throws -> Int {
        try requireStarted(); try persistence.writable(); guard let current = tasks[id] else { throw NativeRPCError.invalidArguments("That task no longer exists.") }
        let sequence = Int(current.value["seq"].number ?? 0)
        tasks[id] = try BackendTaskRecord(current.value.setting("seq", .number(Double(sequence + 1))).setting("updatedAt", .number(BackendTaskValues.time())))
        do { try flush(.tasks, now: true) } catch { tasks[id] = current; throw error }; return sequence
    }
    public func stop() throws {
        writeTimer?.cancel(); writeTimer = nil
        if loaded, persistence.ownership != .readOnly { try requireCompletionFence(); dirty = .all; try writeDirty() }
    }
    public func requireWritableOwnership() throws { try persistence.writable() }
    private func requireStarted() throws { guard loaded else { throw NativeRPCError(code: "not-started", message: "Task records have not been opened") } }
    /// CRM event receipts older than 7 days, or past 5,000 of a kind, go. Done when one is added and at start (U141: it
    /// went through both 5,000-entry maps on every change of any task).
    private func pruneReceipts() {
        let cutoff = BackendTaskValues.time() - 7 * 86_400_000
        seen = seen.filter { ($0.value["at"].number ?? 0) >= cutoff }; ours = ours.filter { $0.value >= cutoff }
        seenOrder.removeAll { seen[$0] == nil }; oursOrder.removeAll { ours[$0] == nil }
        for key in seenOrder.prefix(max(0, seen.count - 5_000)) { seen[key] = nil }; for key in oursOrder.prefix(max(0, ours.count - 5_000)) { ours[key] = nil }
        seenOrder.removeAll { seen[$0] == nil }; oursOrder.removeAll { ours[$0] == nil }
    }
    /// U141 (#182): a local task 30 days in the Trash is deleted for good, as Purge does, so the Trash (and the file) no
    /// longer only grows. Looked at, at most, once an hour.
    static let trashDays = 30.0
    private var trashAgedAt: Double?
    private func ageTrash() {
        let now = BackendTaskValues.time()
        if let last = trashAgedAt, now - last < 3_600_000 { return }
        trashAgedAt = now
        let cutoff = now - Self.trashDays * 86_400_000
        for id in trashOrder { if let row = trash[id], row.isLocal, row.sessionID == nil, let deleted = row.value["deletedAt"].number, deleted < cutoff { trash[id] = nil } }
    }
    private func prune() {
        ageTrash()
        // U20 (#345): past 500 open CRM tasks the oldest idle ones are archived with a note saying why, never deleted,
        // so they stay findable, restorable and open to later CRM updates.
        let mirrored = order.compactMap { tasks[$0] }.filter { !$0.isLocal && $0.value["archivedAt"].isNullish }, extra = mirrored.count - 500
        if extra > 0 {
            let now = BackendTaskValues.time()
            for task in mirrored.filter({ $0.sessionID == nil && $0.process != "queued" }).sorted(by: { ($0.value["updatedAt"].number ?? 0) < ($1.value["updatedAt"].number ?? 0) }).prefix(extra) {
                let note = BackendTaskValues.object([("id", .string("task-note-" + UUID().uuidString.lowercased())), ("at", .number(now)), ("by", .string("system")), ("kind", .string("edited")),
                    ("text", .string("Archived by itself: more than 500 CRM tasks were open here, so the oldest idle ones moved to the archive. Nothing was deleted; Restore from archive brings it back."))])
                if let archived = try? BackendTaskRecord(task.value.setting("archivedAt", .number(now)).setting("notes", .array(Array(((task.value["notes"].elements ?? []) + [note]).suffix(100))))) { tasks[task.id] = archived }
            }
        }
        order.removeAll { tasks[$0] == nil }; trashOrder.removeAll { trash[$0] == nil }
    }
    /// True when the run history changed (U141: only then is task-runs.json written).
    private func observeTaskRun(_ task: BackendTaskRecord, before: BackendTaskRecord?) throws -> Bool {
        let value = task.value, now = BackendTaskValues.time()
        var touched = false
        if let oldID = before?.value["agoptRunID"].string, oldID != value["agoptRunID"].string,
           let oldRun = runs[oldID], oldRun["ended_at"].isNullish {
            let reason = value["agoptRunEndReason"].string ?? "reassigned"
            runs[oldID] = try BackendAGOPTRunHistory.finish(oldRun, outcome: reason == "paused" ? "paused" : "reassigned", at: now, summary: nil, verified: nil); touched = true
        }
        guard value["agoptRunRetired"].bool != true, let id = value["agoptRunID"].string,
              let agent = value["agoptAgentID"].string else { return touched }
        if runs[id] == nil, let session = task.sessionID {
            var row = NativeRPCValue.object([.init("id", .string(id)), .init("agent_id", .string(agent)), .init("task_id", .string(task.id)),
                .init("session_id", .string(session)), .init("conversation_id", value["conversationId"].isNullish ? .null : value["conversationId"]),
                .init("session_name", value["agoptSessionName"].string.map(NativeRPCValue.string) ?? .string(session)),
                .init("provider", value["agoptProvider"]), .init("account_id", value["agoptProfileID"].isNullish ? .null : value["agoptProfileID"]),
                .init("cwd", value["agoptCwd"].string.map(NativeRPCValue.string) ?? .string(task.project)), .init("project_id", value["projectId"].isNullish ? .null : value["projectId"]),
                .init("task_title", value["title"]), .init("started_at", .number(value["runStartedAt"].number ?? now)), .init("ended_at", .null),
                .init("outcome", .string("working")), .init("tokens", .null), .init("cost_usd", .null), .init("billing_kind", .string("unknown")),
                .init("needed_help", .bool(false)), .init("usage_days", .object([])), .init("requested_model", value["agoptModel"].isNullish ? .null : value["agoptModel"]),
                .init("requested_effort", value["agoptEffort"].isNullish ? .null : value["agoptEffort"]),
                // PLAYBOOK-SEATS: what the run used and where each choice came from (playbook / agent / default / task).
                .init("permission", value["agoptPermission"].isNullish ? .null : value["agoptPermission"]),
                .init("sources", value["agoptSources"].isNullish ? .null : value["agoptSources"]),
                .init("playbook_job", value["playbook"]["job"].string.map(NativeRPCValue.string) ?? .null)])
            if let conversation = value["conversationId"].string { row = row.setting("conversation_id", .string(conversation)) }
            runs[id] = row; runOrder.append(id); historySince = historySince ?? now; touched = true
        }
        guard var run = runs[id] else { return touched }
        if let conversation = value["conversationId"].string { run = run.setting("conversation_id", .string(conversation)) }
        if let name = value["agoptSessionName"].string { run = run.setting("session_name", .string(name)) }
        if value["questionOpen"].bool == true { run = run.setting("needed_help", .bool(true)).setting("outcome", .string("waiting")) }
        let previous = before?.value["tokenUsage"].number ?? 0
        if let total = value["tokenUsage"].number, total >= previous, total > previous || run["tokens"].isNullish && value["agoptUsageMeasured"].bool == true {
            run = try BackendAGOPTRunHistory.addUsage(run, tokens: total - previous, reportedAPIUSD: nil,
                billingKind: run["billing_kind"].string ?? "unknown", source: "exact-agent-transcript", at: now, calendar: historyCalendar)
        }
        if run["ended_at"].isNullish {
            if value["stopped"].bool == true { run = try BackendAGOPTRunHistory.finish(run, outcome: "stopped", at: now, summary: nil, verified: nil) }
            else if !value["result"].isNullish {
                let failed = value["result"]["check"].string != nil
                run = try BackendAGOPTRunHistory.finish(run, outcome: failed ? "failed" : "completed", at: value["result"]["at"].number ?? now,
                    summary: value["result"]["answer"].string, verified: value["result"]["verified"].bool)
            } else if before?.sessionID != nil && task.sessionID == nil {
                let reason = value["agoptRunEndReason"].string == "paused" ? "paused" : "lost"
                run = try BackendAGOPTRunHistory.finish(run, outcome: reason, at: now, summary: nil, verified: nil)
            }
        }
        if value["result"]["verified"].bool == true { run = run.setting("verified", .bool(true)) }
        if run != runs[id] { runs[id] = run; touched = true }
        if touched { try pruneRuns() }; return touched
    }
    public func agentRun(_ id: String) throws -> NativeRPCValue? { try requireStarted(); return runs[id] }
    /// Root installs its one calendar before any real run is recorded.
    public func setRunCalendar(_ calendar: Calendar) { historyCalendar = calendar }
    public func agentRuns(_ profileID: String, days: Int? = nil, now: Double) throws -> [NativeRPCValue] {
        try requireStarted()
        let cutoff = days.flatMap { historyCalendar.date(byAdding: .day, value: -$0, to: historyCalendar.startOfDay(for: Date(timeIntervalSince1970: now / 1_000)))?.timeIntervalSince1970 }.map { $0 * 1_000 }
        return runOrder.compactMap { runs[$0] }.filter { row in row["agent_id"].string == profileID && (cutoff.map { (row["started_at"].number ?? 0) >= $0 } ?? true) }
            .sorted { ($0["started_at"].number ?? 0) > ($1["started_at"].number ?? 0) }
    }
    public func agentMonth(_ profileID: String, now: Double) throws -> NativeRPCValue {
        try requireStarted()
        return try BackendAGOPTRunHistory.month(profileID: profileID, runs: Array(runs.values), compacted: runRollups, calendar: historyCalendar, now: now, trackedSince: historySince)
    }
    public func agentWindow(_ profileID: String, days: Int, now: Double) throws -> NativeRPCValue {
        try requireStarted()
        return try BackendAGOPTRunHistory.window(profileID: profileID, runs: Array(runs.values), compacted: runRollups,
            calendar: historyCalendar, now: now, days: days, trackedSince: historySince)
    }
    public func putAgentRun(_ value: NativeRPCValue) async throws {
        try requireStarted(); try requireCompletionFence(); try persistence.writable()
        guard let id = value["id"].string, value["agent_id"].string != nil,
              value["session_id"].string != nil || value["conversation_id"].string != nil,
              value["started_at"].number != nil else { throw NativeRPCError.invalidArguments("Run history needs its real run, agent and session identity.") }
        let before = (runs, runOrder, runRollups, historySince)
        if runs[id] == nil { runOrder.append(id) }; runs[id] = value
        historySince = historySince ?? BackendTaskValues.time()
        do { try pruneRuns(); try flush(.runs) } catch { (runs, runOrder, runRollups, historySince) = before; throw error }
        await changed()
    }
    public func seedRunUsageBaseline(taskID: String, sessionID: String, totalTokens: Double,
                                     expectedRunID: String? = nil, expectedAssignee: NativeRPCValue? = nil) async throws {
        guard totalTokens.isFinite, (0...1e15).contains(totalTokens), let task = try byID(taskID), task.sessionID == sessionID else {
            throw NativeRPCError(code: "usage-unavailable", message: "The measured usage baseline has no current exact task session.")
        }
        guard expectedRunID == nil || task.value["agoptRunID"].string == expectedRunID,
              expectedAssignee == nil || task.value["assignee"] == expectedAssignee else { throw CancellationError() }
        let value = task.value.setting("agoptUsageTotal", .number(max(task.value["agoptUsageTotal"].number ?? 0, totalTokens))).setting("agoptUsageMeasured", .bool(true))
        _ = try putNow(value); await changed()
    }
    public func addAgentRunUsage(_ id: String, tokens: Double?, apiUSD: Double?, billingKind: String, source: String?, at: Double) async throws {
        guard let run = runs[id] else { throw NativeRPCError(code: "missing-run", message: "That actual run is not recorded.") }
        try await putAgentRun(BackendAGOPTRunHistory.addUsage(run, tokens: tokens, reportedAPIUSD: apiUSD, billingKind: billingKind, source: source, at: at, calendar: historyCalendar))
    }
    public func agentRuntime(_ profileID: String) throws -> NativeRPCValue { try requireStarted(); return runtimeState[profileID] }
    /// L4-AGENTS (11 Oct): an agent id that is used again (a new hire with the same name) must not inherit the
    /// old agent's runs. They are kept for the totals under a retired id, never deleted; its runtime state goes.
    public func retireAgentHistory(_ profileID: String) async throws {
        try requireStarted(); try persistence.writable()
        let ownRuns = runOrder.filter { runs[$0]?["agent_id"].string == profileID }
        let ownRollups = (runRollups.fields ?? []).filter { $0.key.hasPrefix(profileID + ":") }
        guard !ownRuns.isEmpty || !ownRollups.isEmpty || !runtimeState[profileID].isNullish else { return }
        let before = (runs, runRollups, runtimeState), retired = profileID + "~retired-" + String(Int(BackendTaskValues.time()))
        for id in ownRuns { runs[id] = runs[id]?.setting("agent_id", .string(retired)) }
        var rollups = runRollups
        for field in ownRollups {
            rollups = rollups.removing(field.key)
            var bucket = field.value; if bucket["agent_id"].string == profileID { bucket = bucket.setting("agent_id", .string(retired)) }
            rollups = rollups.setting(retired + String(field.key.dropFirst(profileID.count)), bucket)
        }
        runRollups = rollups; runtimeState = runtimeState.removing(profileID)
        do { try flush(.runs, now: true) } catch { (runs, runRollups, runtimeState) = before; throw error }
        await changed()
    }
    public func updateAgentRuntime(_ profileID: String, patch: NativeRPCValue) async throws {
        try requireStarted(); try requireCompletionFence(); try persistence.writable()
        let before = runtimeState
        let existing = runtimeState[profileID].fields == nil ? NativeRPCValue.object([]) : runtimeState[profileID]
        runtimeState = runtimeState.setting(profileID, existing.merging(patch))
        do { try flush(.runs, now: true) } catch { runtimeState = before; throw error }; await changed()
    }
    private func pruneRuns() throws {
        let overflow = runOrder.count - 1_000
        guard overflow > 0 else { return }
        let closed = runOrder.compactMap { runs[$0] }.filter { $0["ended_at"].number != nil }
            .sorted { ($0["ended_at"].number ?? 0) < ($1["ended_at"].number ?? 0) }
        for run in closed.prefix(overflow) {
            runRollups = try BackendAGOPTRunHistory.compact(run, into: runRollups, calendar: historyCalendar)
            if let id = run["id"].string { runs[id] = nil; runOrder.removeAll { $0 == id } }
        }
    }
    public func requireCompletionFence() throws {
        guard let run = BackendAGOPTCompletionFence.current else { return }
        try Task.checkCancellation()
        guard let task = tasks[run.taskID], task.value["stopped"].bool != true,
              task.value["agoptRunID"].string == run.runID else { throw CancellationError() }
    }
    /// Marks `parts` changed and writes them, now or (a routine change inside a burst) when the write delay has passed
    /// since the last write. A write now takes every part still waiting with it.
    private func flush(_ parts: Parts, now: Bool = false) throws {
        try requireCompletionFence()
        dirty.formUnion(parts)
        if !now, writeDelay > 0, let last = lastWrite {
            let since = BackendTaskValues.time() - last
            if since >= 0, since < writeDelay { scheduleWrite(after: writeDelay - since); return }
        }
        try writeDirty()
    }
    /// The run history and receipts go first: an old tasks.json loses them only after their own files hold them.
    private func writeDirty() throws {
        if dirty.contains(.runs) {
            try persistence.write(Self.runsFile, value: BackendTaskValues.object([("v", .number(1)), ("agentRuns", .array(runOrder.compactMap { runs[$0] })), ("agentRunRollups", runRollups),
                ("agentRuntimeState", runtimeState), ("agentHistorySince", historySince.map(NativeRPCValue.number) ?? .null)]))
            dirty.remove(.runs)
        }
        if dirty.contains(.receipts) {
            try persistence.write(Self.receiptsFile, value: BackendTaskValues.object([("v", .number(1)),
                ("seen", .array(seenOrder.compactMap { key in seen[key].map { .array([.string(key), $0]) } })), ("ours", .array(oursOrder.compactMap { key in ours[key].map { .array([.string(key), .number($0)]) } }))]))
            dirty.remove(.receipts)
        }
        if dirty.contains(.tasks) {
            try persistence.write("tasks.json", value: BackendTaskValues.object([("v", .number(1)), ("tasks", .array(order.compactMap { tasks[$0]?.value })), ("trash", .array(trashOrder.compactMap { trash[$0]?.value }))]))
            dirty.remove(.tasks)
        }
        lastWrite = BackendTaskValues.time()
    }
    private func scheduleWrite(after milliseconds: Double) {
        guard writeTimer == nil else { return }
        writeTimer = BackendTaskTimers.schedule(milliseconds: milliseconds) { [weak self] in await self?.writeWaiting() }
    }
    private func writeWaiting() {
        writeTimer = nil
        guard loaded, !dirty.isEmpty else { return }
        // A failed write keeps the parts marked: tried again after the delay, and by the next change written at once.
        do { try writeDirty() } catch { scheduleWrite(after: max(writeDelay, 1_000)) }
    }
}
