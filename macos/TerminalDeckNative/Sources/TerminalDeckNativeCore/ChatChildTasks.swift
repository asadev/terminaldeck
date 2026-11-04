import Foundation

public enum ChatChildTasks {
    public static func codexAgent(_ thread: String, status: String, title: String? = nil, parentThreadId: String? = nil) -> NativeRPCValue {
        let normalized: String
        switch status {
        case "pendingInit": normalized = "pending"
        case "interrupted", "shutdown": normalized = "stopped"
        case "errored": normalized = "failed"
        default: normalized = status
        }
        var task = NativeRPCValue.object([.init("id", .string("codex:" + thread)), .init("threadId", .string(thread)),
            .init("kind", .string("agent")), .init("status", .string(normalized)), .init("canStop", .bool(true))])
        if let title, !title.isEmpty { task = task.setting("title", .string(title)) }
        if let parentThreadId, !parentThreadId.isEmpty { task = task.setting("parentThreadId", .string(parentThreadId)) }
        return task
    }
    private static func reportedMetadata(_ task: NativeRPCValue, source: NativeRPCValue) -> NativeRPCValue {
        var result = task
        for key in ["parentThreadId", "parentTaskId", "parentId", "appTaskId", "agentPath", "agentRole", "agentNickname", "senderThreadId", "source"] where !source[key].isNullish {
            result = result.setting(key, source[key])
        }
        if result["parentThreadId"].isNullish, let parent = source["source"]["subAgent"]["thread_spawn"]["parent_thread_id"].string {
            result = result.setting("parentThreadId", .string(parent))
        }
        return result
    }
    public static func codexAgents(_ item: NativeRPCValue) -> [NativeRPCValue] {
        if item["type"].string == "subAgentActivity", let thread = item["agentThreadId"].string, !thread.isEmpty {
            let status = ["started": "running", "interacted": "running", "interrupted": "stopped", "completed": "completed"][item["kind"].string ?? ""]
            return status.map { [reportedMetadata(codexAgent(thread, status: $0), source: item)] } ?? []
        }
        guard item["type"].string == "collabAgentToolCall" else { return [] }
        let ids = Set((item["receiverThreadIds"].elements?.compactMap(\.string) ?? []) + (item["agentsStates"].fields?.map(\.key) ?? []))
        return ids.filter { !$0.isEmpty }.sorted().map {
            let task = reportedMetadata(codexAgent($0, status: item["agentsStates"][$0]["status"].string ?? "running"), source: item)
            return reportedMetadata(task, source: item["agentsStates"][$0])
        }
    }
    public static func list(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        var tasks: [String: NativeRPCValue] = [:], order: [String] = []
        var shellsByTool: [String: String] = [:]
        var interruptedTurns: Set<String> = []
        var codexRoot: String?
        func keep(_ task: NativeRPCValue, event: HootChatEvent) {
            guard let id = task["id"].string, !id.isEmpty else { return }
            if tasks[id] == nil { order.append(id) }
            var value = tasks[id] ?? .object([.init("id", .string(id)), .init("turnId", .string(event.turnID)), .init("title", .string(task["kind"].string == "agent" ? "Codex agent" : "Background task")), .init("status", .string("running"))])
            for field in task.fields ?? [] where !field.value.isNullish { value = value.setting(field.key, field.value) }
            // Use the first recorded start, never the time a view was opened or a progress update arrived.
            let input = event.record.value["input"]
            let startReported = event.record.value["taskStarted"].string == id ||
                event.record.kind == .toolCall && (input["type"].string == "commandExecution" ||
                    input["type"].string == "subAgentActivity" && input["kind"].string == "started")
            if value["startedAt"].isNullish, startReported, running(value), event.at.isFinite, event.at > 0 {
                value = value.setting("startedAt", .number(event.at))
            }
            if value["kind"].string == "shell", interruptedTurns.contains(event.turnID), running(value) { value = value.setting("status", .string("stopped")) }
            tasks[id] = value
        }
        for event in events {
            if event.record.kind == .interrupted {
                interruptedTurns.insert(event.turnID)
                for id in order where tasks[id]?["kind"].string == "shell" && tasks[id]?["turnId"].string == event.turnID {
                    if let task = tasks[id], running(task) { tasks[id] = task.setting("status", .string("stopped")) }
                }
            }
            let value = event.record.value
            if event.provider == .codex, event.record.kind == .session, let root = value["sessionId"].string { codexRoot = root }
            if let id = value["taskStarted"].string { keep(.object([.init("id", .string(id)), .init("status", .string("running")), .init("kind", .string("task"))]), event: event) }
            if let id = value["taskFinished"].string { keep(.object([.init("id", .string(id)), .init("status", .string("completed"))]), event: event) }
            if value["childTask"].fields != nil { keep(value["childTask"], event: event) }
            let input = value["input"]
            let toolKey = event.turnID + ":" + event.record.messageID
            if event.record.kind == .toolCall, input["type"].string == "commandExecution", let process = input["processId"].string {
                let id = "codex-shell:" + process
                shellsByTool[toolKey] = id
                keep(.object([.init("id", .string(id)), .init("kind", .string("shell")), .init("title", input["command"]),
                    .init("status", input["status"]), .init("canStop", .bool(false)),
                    .init("limitation", .string("Codex does not expose a separate stop for internal command processes."))]), event: event)
            }
            if event.record.kind == .toolResult, value["partial"].bool != true, let id = shellsByTool[toolKey] {
                keep(.object([.init("id", .string(id)), .init("status", .string(value["isError"].bool == true ? "failed" : "completed"))]), event: event)
            }
            if event.record.kind == .toolCall {
                for task in codexAgents(input) where task["threadId"].string != codexRoot { keep(task, event: event) }
            }
        }
        return order.compactMap { tasks[$0] }
    }
    public static func running(_ task: NativeRPCValue) -> Bool { ["running", "pending", "initializing", "inProgress"].contains(task["status"].string ?? "") }
}
