import Foundation
import TerminalDeckNativeCore

public enum BackendChatTodos {
    public struct Progress: Sendable {
        public let rows: [NativeRPCValue]
        public let anchorRowID: String?
        public var wire: NativeRPCValue {
            .object([.init("id", .string("task-progress")), .init("anchorRowId", anchorRowID.map(NativeRPCValue.string) ?? .null),
                .init("steps", .array(rows))])
        }
    }
    public static func list(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        progress(events).rows
    }
    private struct TaskEntry { var title: String; var active: String?; var status: String }
    private static let created = try? NSRegularExpression(pattern: #"^Task #([A-Za-z0-9_-]{1,128}) created successfully"#)
    private static func taskID(_ output: NativeRPCValue) -> String? {
        let text = output.string ?? output.elements?.compactMap { $0["text"].string ?? $0.string }.joined(separator: "\n") ?? ""
        let object = output.fields != nil ? output : (text.utf8.count <= 65_536 ? try? NativeRPCValue.parseJSON(Data(text.utf8)) : nil)
        if let id = object?["task"]["id"].string ?? object?["taskId"].string ?? object?["id"].string { return id }
        guard let match = created?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    public static func progress(_ events: [HootChatEvent], children supplied: [NativeRPCValue]? = nil) -> Progress {
        var calls: [String: HootChatRecord] = [:], tasks: [String: TaskEntry] = [:], order: [String] = []
        var rows: [NativeRPCValue] = [], anchor: String?, userRow: String?
        var agentSteps: [String: String] = [:], childSteps: [String: String] = [:]
        func currentStep() -> String? {
            let running = rows.filter { $0["state"].string == "current" }
            return running.count == 1 ? running[0]["id"].string : nil
        }
        func keepChild(_ child: NativeRPCValue) {
            guard let id = child["id"].string, childSteps[id] == nil else { return }
            // Prefer the actual launch tool; use temporal association only with one current step.
            if let tool = child["toolUseId"].string, let step = agentSteps[tool] { childSteps[id] = step }
            else if let step = currentStep() { childSteps[id] = step }
        }
        for event in events {
            let record = event.record, key = event.turnID + ":" + record.messageID
            if record.kind == .user, !event.turnID.hasPrefix("bg:") {
                userRow = event.turnID + ":" + (record.messageID.isEmpty ? event.id : record.messageID)
            }
            if record.value["childTask"].fields != nil { keepChild(record.value["childTask"]) }
            if record.kind == .toolCall {
                if ["Agent", "Task"].contains(record.value["name"].string ?? ""), let step = currentStep() { agentSteps[record.messageID] = step }
                for child in ChatChildTasks.codexAgents(record.value["input"]) { keepChild(child) }
            }
            guard !event.turnID.hasPrefix("bg:") else { continue }
            let snapshot = record.kind == .toolCall && record.value["name"].string == "TodoWrite" ? record.value["input"]["todos"].elements :
                record.kind == .session ? record.value["todoPlan"].elements : nil
            if let snapshot {
                rows = snapshot.enumerated().compactMap { index, row in
                    normalized(id: String(index), title: row["content"].string ?? row["step"].string,
                        active: row["activeForm"].string, status: row["status"].string ?? "pending")
                }
                if anchor == nil, !rows.isEmpty { anchor = userRow }
            }
            if record.kind == .toolCall, ["TaskCreate", "TaskUpdate"].contains(record.value["name"].string ?? "") { calls[key] = record; continue }
            guard record.kind == .toolResult, record.value["partial"].bool != true, record.value["isError"].bool != true, let call = calls.removeValue(forKey: key) else { continue }
            let input = call.value["input"]
            if call.value["name"].string == "TaskCreate" {
                guard let id = taskID(record.value["output"]), let subject = input["subject"].string, !subject.isEmpty else { continue }
                if tasks[id] == nil { order.append(id) }
                tasks[id] = .init(title: subject, active: input["activeForm"].string, status: "pending")
            } else if let id = input["taskId"].string {
                if input["status"].string == "deleted" { tasks[id] = nil; order.removeAll { $0 == id } }
                else {
                    if tasks[id] == nil { order.append(id) }
                    var row = tasks[id] ?? .init(title: "Task " + id, active: nil, status: "pending")
                    if let subject = input["subject"].string, !subject.isEmpty { row.title = subject }
                    if let active = input["activeForm"].string { row.active = active }
                    if let status = input["status"].string { row.status = status }
                    tasks[id] = row
                }
            }
            rows = order.compactMap { id in tasks[id].flatMap { normalized(id: "task:" + id, title: $0.title, active: $0.active, status: $0.status) } }
            if anchor == nil, !rows.isEmpty { anchor = userRow }
        }
        let children = supplied ?? ChatChildTasks.list(events)
        let running = children.filter {
            let kind = $0["kind"].string ?? ""
            return ChatChildTasks.running($0) && (kind.contains("agent") || kind == "task")
        }
        return Progress(rows: rows.map { row in
            let ids = running.compactMap { child -> String? in
                guard let id = child["id"].string, childSteps[id] == row["id"].string else { return nil }
                return id
            }
            return row.setting("runningTasks", .number(Double(ids.count))).setting("childTaskIds", .array(ids.map(NativeRPCValue.string)))
        }, anchorRowID: anchor)
    }
    private static func normalized(id: String, title: String?, active: String?, status: String) -> NativeRPCValue? {
        let raw = status.lowercased().replacingOccurrences(of: "_", with: "")
        let state = raw == "completed" ? "done" : ["inprogress", "running"].contains(raw) ? "current" : "next"
        guard let text = state == "current" ? active ?? title : title, !text.isEmpty else { return nil }
        return .object([.init("id", .string(id)), .init("text", .string(text)), .init("state", .string(state))])
    }
}
