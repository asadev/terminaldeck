import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// TAG owns all links and events. This only renders visible stored task notes.
public enum AWAgentsWatchTasks {
    public static func exchanges(tasks: [NativeRPCValue], agents: [AWWatchAgent]) -> [AWWatchEntry] {
        let visible = Dictionary(tasks.compactMap { task in task["id"].string.map { ($0, task) } }, uniquingKeysWith: { first, _ in first })
        var entries: [AWWatchEntry] = []
        for task in tasks {
            guard let taskID = task["id"].string else { continue }
            let parentID = task["parentTaskId"].string ?? task["parentExternalTaskId"].string.flatMap { external in
                task["keyId"].string.map { $0 + ":" + external }
            }
            if let parentID, let parent = visible[parentID] {
                let target = agents.first { $0.taskID == taskID }?.id
                entries.append(AWWatchEntry(id: "handoff:" + taskID, kind: .handoff,
                    speaker: task["requestedBy"].string.map { actor($0, parent: parent) } ?? name(parent),
                    title: "Asked \(name(task))", text: task["title"].string ?? "Child task",
                    at: task["createdAt"].number ?? 0, targetAgentID: target))
            }
            for note in task["notes"].elements ?? [] {
                guard let text = note["text"].string, let by = note["by"].string else { continue }
                let digest = note["id"].string ?? SHA256.hash(data: Data(note.compact.utf8)).map { String(format: "%02x", $0) }.joined()
                entries.append(AWWatchEntry(id: "note:\(taskID):\(digest)", kind: .message, speaker: by,
                    title: task["title"].string ?? "Task", text: text, at: note["at"].number ?? 0,
                    targetAgentID: agents.first { $0.taskID == taskID }?.id))
            }
        }
        var seen = Set<String>()
        return Array(entries.filter { seen.insert($0.id).inserted }.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }.suffix(1000))
    }
    private static func name(_ task: NativeRPCValue) -> String {
        task["agent"].string ?? task["assignee"]["agentId"].string ?? task["assignee"].string ?? "Agent"
    }
    private static func actor(_ raw: String, parent: NativeRPCValue) -> String {
        if raw == "hoot" || raw == "Hoot" { return "Hoot" }
        if raw == "me" { return "You" }
        if let name = BackendTaskActor.appActorName(raw) { return name }
        if raw == "taskagent:" + (parent["assignee"].string ?? "") { return name(parent) }
        return raw
    }
}
