import Foundation
import TerminalDeckNativeCore

public struct BackendTaskChannelDependencies: Sendable {
    public let keyViews: @Sendable () async throws -> [NativeRPCValue]
    public let makeCRMKey: (@Sendable (String) async throws -> (id: String, key: String))?
    public let inventory: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)?
    public init(keyViews: @escaping @Sendable () async throws -> [NativeRPCValue],
                makeCRMKey: (@Sendable (String) async throws -> (id: String, key: String))? = nil,
                inventory: (@Sendable (NativeRPCValue) async throws -> NativeRPCValue)? = nil) { self.keyViews = keyViews; self.makeCRMKey = makeCRMKey; self.inventory = inventory }
    public static func suppliedInventory(_ adapter: BackendAppAgentInventoryTaskAdapter) -> @Sendable (NativeRPCValue) async throws -> NativeRPCValue { { try await adapter.inventory($0) } }
}

public struct BackendTaskStateView: Sendable {
    public let store: BackendTaskStore, config: BackendTaskConfiguration, goals: BackendGoalStore, outbox: BackendTaskOutbox
    private let keys: @Sendable () async throws -> [NativeRPCValue]
    public init(store: BackendTaskStore, configuration: BackendTaskConfiguration, goals: BackendGoalStore, outbox: BackendTaskOutbox, keyViews: @escaping @Sendable () async throws -> [NativeRPCValue]) { self.store = store; config = configuration; self.goals = goals; self.outbox = outbox; keys = keyViews }
    public func state() async throws -> NativeRPCValue {
        let agents = try await config.allAgents(), tasks = try await store.all(), trash = try await store.inTrash(), deliveries = await outbox.list()
        var views: [NativeRPCValue] = [], trashed: [NativeRPCValue] = [], goalRows: [NativeRPCValue] = []
        for task in tasks.sorted(by: { ($0.value["updatedAt"].number ?? 0) > ($1.value["updatedAt"].number ?? 0) }) { views.append(Self.taskView(task, agents: agents, all: tasks)) }
        for task in trash.filter(\.isLocal).sorted(by: { ($0.value["deletedAt"].number ?? 0) > ($1.value["deletedAt"].number ?? 0) }) { trashed.append(Self.taskView(task, agents: agents, all: tasks)) }
        for goal in try await goals.all() { let progress = try await goals.progress(goal["id"].string!, tasks: tasks); var counts = NativeRPCValue.object([]); for key in ["total", "done", "verified", "unverified", "stalled", "blocked"] { counts = counts.setting(key, progress[key]) }; goalRows.append(goal.setting("progress", counts)) }
        let keyRows = try await keys().map { row in BackendTaskValues.object([("id", row["id"]), ("name", row["name"]), ("crmOnly", row["crmOnly"]), ("lastApp", row["lastApp"])]) }
        return BackendTaskValues.object([("agents", .array(agents)), ("connections", .array(try await config.connectionViews())), ("keys", .array(keyRows)), ("tasks", .array(views)), ("trash", .array(trashed)),
            ("outbox", BackendTaskValues.object([("pending", .number(Double(deliveries.filter { $0["state"].string == "pending" }.count))), ("undelivered", .number(Double(deliveries.filter { $0["state"].string == "undelivered" }.count)))])), ("localStatuses", .array(BackendTaskLocalService.statuses.map(NativeRPCValue.string))), ("goals", .array(goalRows))])
    }
    public static func taskView(_ task: BackendTaskRecord, agents: [NativeRPCValue], all: [BackendTaskRecord]) -> NativeRPCValue {
        let builtins = ["hoot": "Hoot", "me": "Me", "none": "Unassigned"]
        func name(_ id: String) -> String { builtins[id] ?? agents.first(where: { $0["id"].string == id })?["name"].string ?? id }
        var value = task.value.removing("assignee").setting("agent", .string(name(task.agentID))).setting("assignee", .string(task.agentID)).setting("verified", task.value["result"].isNullish ? .null : task.value["result"]["verified"])
            .setting("local", .bool(task.isLocal)).setting("notes", .array(Array((task.value["notes"].elements ?? []).suffix(30)))).setting("handedFrom", task.assigneeKind == "human" ? task.value["handedFrom"].string.map { .string(name($0)) } ?? .null : .null)
        for key in ["keepOpenUntil", "priority", "startDate", "dueDate", "startTime", "dueTime", "board", "estimateMinutes", "archivedAt", "deletedAt", "completedAt", "position", "recurrence", "goalId", "stalled"] where value[key].isNullish { value = value.setting(key, .null) }
        value = value.setting("labels", task.value["labels"].elements.map(NativeRPCValue.array) ?? .array([])).setting("taskType", task.value["taskType"].string.map(NativeRPCValue.string) ?? .string("task")).setting("useWorkspace", .bool(task.value["useWorkspace"].bool == true))
            .setting("waitingOn", .array(task.process == "queued" ? BackendGoalStore.blockers(task, all: all).map { $0.value["title"] } : []))
        return value
    }
}

/// What the popup channel needs from the task-detail owner: whether it is running, and one function call.
public protocol BackendTaskDetailCalling: Sendable {
    func isRunning() async -> Bool
    func callDetail(_ function: String, arguments: [NativeRPCValue]) async -> NativeRPCValue
    func poke() async
}
extension BackendTaskDetailService: BackendTaskDetailCalling {
    public func isRunning() async -> Bool { !stopped }
    public func callDetail(_ function: String, arguments: [NativeRPCValue]) async -> NativeRPCValue { await call(function, arguments: arguments) }
}

public enum BackendTaskChannels {
    public static func register(registry: NativeChannelRegistry, ownerID: String, view: BackendTaskStateView, local: BackendTaskLocalService,
                                engine: BackendTaskEngine, detail: any BackendTaskDetailCalling, dependencies: BackendTaskChannelDependencies) async throws -> [String] {
        let channels = ["tasks:state", "tasks:agents-import", "tasks:agent-save", "tasks:agent-status", "tasks:agent-remove", "tasks:connection-save", "tasks:connection-remove", "tasks:local-create", "tasks:local-update", "tasks:local-delete", "tasks:local-restore", "tasks:local-reply", "tasks:local-detail", "tasks:close-session", "tasks:goal-save", "tasks:goal-remove", "tasks:inventory", "tasks:connection-create"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID, policy: { ctx in guard ctx.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "tasks: only the app’s own window may change tasks or goals") } }) { context, args in
                if channel == "tasks:state" { return try await view.state() }
                if channel == "tasks:inventory" { guard let inventory = dependencies.inventory else { return .null }; return try await inventory(context.argument(0, in: args)) }
                if channel == "tasks:local-detail" {
                    // tasks-ipc.ts: the verb, then the shape, then whether tasks are running.
                    guard let function = context.argument(0, in: args).string, BackendCrmDetailContract.isLocalDetailFn(function) else { return BackendTaskValues.object([("ok", .bool(false)), ("error", .string("That is not something the task popup can do."))]) }
                    guard let arguments = context.argument(1, in: args).elements else { return BackendTaskValues.object([("ok", .bool(false)), ("error", .string("That request was not understood."))]) }
                    guard await detail.isRunning() else { return BackendTaskValues.object([("ok", .bool(false)), ("error", .string("Tasks are not running on this computer right now."))]) }
                    return await detail.callDetail(function, arguments: arguments)
                }
                var extra = NativeRPCValue.object([])
                do {
                    func text(_ index: Int) throws -> String { try context.argument(index, in: args).requireString("id", nonempty: true) }
                    let raw = context.argument(0, in: args)
                    switch channel {
                    case "tasks:agents-import":
                        extra = try await view.config.importAgents(folder: text(0))
                        let added = Int(extra["imported"].number ?? 0), updated = Int(extra["updated"].number ?? 0), errors = extra["errors"].elements ?? []
                        var message = "Imported \(added) agents. Updated \(updated)."
                        if !errors.isEmpty { message += " \(errors.count) files need attention. " + (errors.first?["message"].string ?? "Check the source files.") }
                        extra = extra.setting("message", .string(message))
                    case "tasks:agent-save": _ = try await view.config.saveAgent(raw)
                    case "tasks:agent-status": _ = try await view.config.setStatus(text(0), action: text(1))
                    case "tasks:agent-remove": try await view.config.removeAgent(text(0))
                    case "tasks:connection-save":
                        let id = try text(0); guard try await dependencies.keyViews().contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That access key no longer exists.") }
                        let saved = try await view.config.saveConnection(id, input: context.argument(1, in: args)); if saved["secret"].string != nil { extra = extra.setting("secret", saved["secret"]) }
                    case "tasks:connection-create":
                        guard raw["confirmed"].bool == true else { throw NativeRPCError.invalidArguments("Confirm making a new key for this CRM first.") }
                        guard let makeCRMKey = dependencies.makeCRMKey else { throw NativeRPCError.invalidArguments("This build cannot make a key for a CRM.") }
                        let name = try BackendTaskValues.text(raw["name"], "The CRM name", max: 50, required: true)!, key = try await makeCRMKey(name)
                        let saved = try await view.config.saveConnection(key.id, input: BackendTaskValues.object([("name", .string(name))])); extra = extra.setting("key", .string(key.key)).setting("secret", saved["secret"])
                    case "tasks:connection-remove": try await view.config.removeConnection(text(0))
                    case "tasks:local-create": _ = try await local.create(raw)
                    case "tasks:local-update": _ = try await local.update(text(0), input: context.argument(1, in: args))
                    case "tasks:local-delete": try await local.remove(text(0))
                    case "tasks:local-restore": _ = try await local.restore(text(0))
                    case "tasks:local-reply": _ = try await local.reply(text(0), text: text(1))
                    case "tasks:close-session": try await engine.closeSession(text(0))
                    case "tasks:goal-save": _ = try await view.goals.save(raw)
                    case "tasks:goal-remove": try await view.goals.remove(text(0), tasks: view.store)
                    default: throw BackendSessionFailure.missingCapability("the requested native task channel")
                    }
                    await engine.nudge(); await detail.poke()
                    return BackendTaskValues.object([("ok", .bool(true)), ("state", try await view.state())]).merging(extra)
                } catch { return BackendTaskValues.object([("ok", .bool(false)), ("message", .string(error.localizedDescription)), ("state", try await view.state())]) }
            }
        }; return channels
    }
}
