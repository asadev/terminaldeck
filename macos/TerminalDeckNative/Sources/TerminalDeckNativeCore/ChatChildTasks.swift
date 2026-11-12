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

    // MARK: A task whose process is gone (9 Nov)
    // Asad (9 Nov, iMatch chat): "Working · running a background task · 1 running" for two days while its AI process had
    // no child at all. Claude Code writes a background task's finish into the conversation only at the chat's next turn,
    // so an idle chat never records it. So a task counts as running only while a process that can be its own is alive
    // under the chat's AI process: a shell needs a live descendant born after its command began, and no task outlives
    // the AI process it started under. Nothing is stopped or signalled; only the record says "finished".

    /// A running task that lives in or under the AI process, with when it was first and last reported.
    public struct ProcessCandidate: Equatable, Sendable {
        public let id: String
        /// A shell (Claude local_bash, Codex command): it needs its own live process.
        public let shell: Bool
        /// The earliest moment its process can have been born (the start of its tool call's turn), when that is known.
        public let bound: Double?
        /// The last time the AI reported it running (ms since 1970).
        public let lastSeen: Double
        public init(id: String, shell: Bool, bound: Double?, lastSeen: Double) {
            self.id = id; self.shell = shell; self.bound = bound; self.lastSeen = lastSeen
        }
    }
    /// A shell's process is its own; an in-process agent or workflow lives inside the AI process. A remote agent runs
    /// elsewhere, so the process tree says nothing about it.
    public static func processShell(_ task: NativeRPCValue) -> Bool { ["local_bash", "shell"].contains(task["kind"].string ?? "") }
    public static func livesWithProcess(_ task: NativeRPCValue) -> Bool { task["kind"].string != "remote_agent" }

    public static func awaitingProcess(_ events: [HootChatEvent]) -> [ProcessCandidate] {
        let live = list(events).filter { running($0) && livesWithProcess($0) }
        guard !live.isEmpty else { return [] }
        let ids = Set(live.compactMap { $0["id"].string })
        var calls: [String: Double] = [:], lastSeen: [String: Double] = [:], turnStart: [String: Double] = [:]
        // A tool call's line can reach the app seconds after its command began (a busy app lagged 5-10 s on 9 Nov), so
        // the earliest a command can start is when its turn began: the person's message that started it. A turn with no
        // message on record allows 30 s before the call arrived.
        for event in events where event.record.kind == .user && event.at.isFinite && event.at > 0 {
            turnStart[event.turnID] = min(turnStart[event.turnID] ?? event.at, event.at)
        }
        for event in events where event.at.isFinite && event.at > 0 {
            let value = event.record.value, input = value["input"]
            let earliest = min(turnStart[event.turnID] ?? event.at - 30_000, event.at)
            if event.record.kind == .toolCall, calls[event.record.messageID] == nil { calls[event.record.messageID] = earliest }
            var mentioned: [String] = []
            if let id = value["taskStarted"].string { mentioned.append(id) }
            // A progress or start report says it runs; its finish notice does not.
            if let id = value["childTask"]["id"].string, value["childTask"]["status"].isNullish || running(value["childTask"]) { mentioned.append(id) }
            if event.record.kind == .toolCall, input["type"].string == "commandExecution", let process = input["processId"].string {
                mentioned.append("codex-shell:" + process); calls["codex-shell:" + process] = calls["codex-shell:" + process] ?? earliest
            }
            if event.record.kind == .toolCall {
                for task in codexAgents(input) { if let id = task["id"].string, running(task) { mentioned.append(id) } }
            }
            for id in mentioned where ids.contains(id) { lastSeen[id] = event.at }
        }
        return live.compactMap { task in
            guard let id = task["id"].string, let seen = lastSeen[id] else { return nil }
            let call = (task["toolUseId"].string.flatMap { calls[$0] }) ?? calls[id]
            return .init(id: id, shell: processShell(task), bound: call, lastSeen: seen)
        }
    }

    /// Which candidates no live process accounts for. Each live descendant counts for one shell at most (most
    /// constrained shell first, so the answer is exact for these nested "born after" limits). `slack` allows for the
    /// two clocks (event times in ms, process birth from the kernel).
    public static func gone(_ candidates: [ProcessCandidate], tree: ChatProcessTree, slack: Double = 2_000) -> [String] {
        var gone: [String] = []
        // Reported only before this AI process was born: it belonged to an earlier one, which took it along.
        let current = candidates.filter { candidate in
            if candidate.lastSeen < tree.root.started { gone.append(candidate.id); return false }
            return candidate.shell
        }
        var free = tree.descendants.map(\.started).sorted()
        for shell in current.sorted(by: { ($0.bound ?? -.infinity) > ($1.bound ?? -.infinity) }) {
            // No tool call on record: any live descendant may be it.
            let floor = (shell.bound ?? tree.root.started) - slack
            if let index = free.firstIndex(where: { $0 >= floor }) { free.remove(at: index) } else { gone.append(shell.id) }
        }
        return gone
    }
}

/// A chat's AI process and its live descendants, as the kernel reported them at one moment (birth times in ms since 1970).
public struct ChatProcessTree: Equatable, Sendable {
    public struct Process: Equatable, Sendable {
        public let pid: Int32
        public let started: Double
        public init(pid: Int32, started: Double) { self.pid = pid; self.started = started }
    }
    public let root: Process
    public let descendants: [Process]
    public init(root: Process, descendants: [Process]) { self.root = root; self.descendants = descendants }
}
