import Foundation
import TerminalDeckNativeCore

enum NativeChatAgentTree {
    struct Node { let task: NativeRPCValue; let parent: String?; let depth: Int; let cycle: Bool }
    static func nodes(_ tasks: [NativeRPCValue]) -> [Node] {
        var order: [String] = [], map: [String: NativeRPCValue] = [:]
        for task in tasks { guard let id = task["id"].string else { continue }; if map[id] == nil { order.append(id) }; map[id] = task }
        func parent(_ task: NativeRPCValue) -> String? { task["parentId"].string ?? task["parentTaskId"].string ?? task["parentThreadId"].string.map { "codex:" + $0 } }
        func cycle(_ id: String) -> Bool {
            var seen: Set<String> = [id], next = map[id].flatMap(parent)
            for _ in 0..<64 { guard let key = next, let task = map[key] else { return false }; if !seen.insert(key).inserted { return true }; next = parent(task) }
            return false
        }
        var result: [Node] = [], visited = Set<String>()
        func visit(_ id: String, _ depth: Int) {
            guard depth <= 32, visited.insert(id).inserted, let task = map[id] else { return }
            result.append(.init(task: task, parent: parent(task), depth: depth, cycle: cycle(id)))
            for child in order where map[child].flatMap(parent) == id { visit(child, depth + 1) }
        }
        for id in order where map[id].flatMap(parent).flatMap({ map[$0] }) == nil { visit(id, 0) }
        for id in order where !visited.contains(id) { visit(id, 0) }
        return result
    }
    static func source(_ task: NativeRPCValue, events: [HootChatEvent]) -> String? {
        let id = task["id"].string, thread = task["threadId"].string
        return events.last { event in
            let value = event.record.value, input = value["input"]
            return value["childTask"]["id"].string == id && id != nil || value["taskStarted"].string == id && id != nil || value["taskFinished"].string == id && id != nil || thread != nil && (input["agentThreadId"].string == thread || input["receiverThreadIds"].elements?.contains(where: { $0.string == thread }) == true || input["agentsStates"].has(thread ?? ""))
        }?.id
    }
}
extension NativeHootChatModel {
    func agentTreeTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        featurePanel("agents", action)
        let nodes = NativeChatAgentTree.nodes(childTasks)
        if ["stop", "details", "task"].contains(action) {
            guard let node = nodes.first(where: { $0.task["id"].string == request }) else { throw NativeRPCError.invalidArguments("Choose a child ID from this Chat.") }
            if action == "stop" { guard node.task["canStop"].bool == true else { throw NativeRPCError.invalidArguments("This child has no separate Stop capability.") }; _ = try await stopChild(request ?? "") }
            if action == "details" { guard let source = NativeChatAgentTree.source(node.task, events: transcriptExportEvents) else { throw NativeRPCError.invalidArguments("No emitted source record is available for this child.") }; _ = try detailTool("open", query: nil, recordID: source) }
            if action == "task" {
                let id = node.task["appTaskId"].string ?? node.task["id"].string ?? ""
                let tasks = fixtureMode ? fixtureTasksForChecks : TasksStore.shared.state?.tasks ?? []
                guard tasks.contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("This provider child has no matching app task transcript.") }; openTask(id)
            }
        }
        let rows = NativeChatAgentTree.nodes(childTasks).map { node -> NativeRPCValue in
            let task = node.task, id = task["id"].string ?? ""
            var actions: [NativeRPCValue] = []
            if NativeChatAgentTree.source(task, events: transcriptExportEvents) != nil { actions.append(NativeChatPanel.action("Open child source event", "details", id)) }
            let appID = task["appTaskId"].string ?? id, tasks = fixtureMode ? fixtureTasksForChecks : TasksStore.shared.state?.tasks ?? []
            if tasks.contains(where: { $0.id == appID }) { actions.append(NativeChatPanel.action("Open app task and reports", "task", id)) }
            let detail = "\(task["kind"].string ?? "Child") · \(task["status"].string ?? "State unreported")\nID: \(id)\nParent: \(node.parent ?? "Not reported")" + (node.cycle ? "\nReported parent cycle; shown once." : "") + (task["limitation"].string.map { "\n" + $0 } ?? "")
            return NativeChatPanel.row(id, String(repeating: "  ↳", count: node.depth) + (task["title"].string ?? "Child task"), detail, actions)
        }
        return NativeChatPanel.state("Child agents and tasks", "Hierarchy uses reported parent IDs, shown up to 32 levels. Individual Stop controls are in Running above the message box. Source events and confirmed app-task reports are available; provider child transcripts and Resume are not exposed by this Chat service.", rows)
    }
}
