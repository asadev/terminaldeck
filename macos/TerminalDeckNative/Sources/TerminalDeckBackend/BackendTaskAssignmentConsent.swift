import Foundation
import TerminalDeckNativeCore

/// FORK-TASKS (11 Oct). The owner giving someone a task, or asking them in its comments, is the
/// owner's yes to the task tools ON THAT ONE TASK: comment on it, hand a part of it on, give the
/// verdict on it. Before this every such call asked the owner again ("Use tasks.comment"), and with
/// nobody at the screen it was refused: the assignee was woken and then could not answer.
///
/// Anything wider still asks on screen: another task, a task the caller does not hold, creating,
/// reassigning, retrying, planning, agent profiles.
public enum BackendTaskAssignmentConsent {
    public enum Caller: Sendable, Equatable {
        /// Hoot's own tool door on this computer.
        case hoot
        /// A session the task engine started for a task.
        case session(String)
        /// A phone, an AI app's key, anything else: never covered here.
        case other
    }
    /// The tools an assignee needs to answer in its task.
    public static let tools: Set<String> = ["tasks.comment", "tasks.delegate", "tasks.verify", "tasks.review"]

    public static func covers(tool: String, arguments: NativeRPCValue, caller: Caller, store: BackendTaskStore) async throws -> Bool {
        try await covers(tool: tool, arguments: arguments, caller: caller,
                         byID: { try await store.byID($0) }, bySession: { try await store.bySession($0) })
    }

    public static func covers(tool: String, arguments: NativeRPCValue, caller: Caller,
                              byID: @Sendable (String) async throws -> BackendTaskRecord?,
                              bySession: @Sendable (String) async throws -> BackendTaskRecord?) async throws -> Bool {
        let name = tool.hasPrefix("tasks_") ? "tasks." + tool.dropFirst("tasks_".count) : tool
        guard tools.contains(name), let id = arguments["task"].string, let task = try await byID(id), task.value["stopped"].bool != true else { return false }
        switch caller {
        case .other: return false
        case .hoot:
            // A task given to Hoot (a question asked with @Hoot is one too), or one Hoot coordinates:
            // it asked for it, or it is a part of a task Hoot holds.
            if task.assigneeKind == "hoot" || task.value["requestedBy"].string == "hoot" { return true }
            let parentID = task.value["parentTaskId"].string
                ?? task.value["parentExternalTaskId"].string.flatMap { external in task.value["keyId"].string.map { $0 + ":" + external } }
            guard let parentID, let parent = try await byID(parentID) else { return false }
            return parent.assigneeKind == "hoot"
        case .session(let session):
            guard let worker = try await bySession(session), worker.assigneeKind == "agent", worker.value["stopped"].bool != true else { return false }
            switch name {
            case "tasks.comment", "tasks.delegate":
                // Only the task this very session is working.
                return task.id == worker.id
            default:
                // The verdict: only the reviewer the engine itself started for this task's current result.
                return worker.value["reviewOfTaskId"].string == task.id && task.value["reviewerTaskId"].string == worker.id
            }
        }
    }
}
