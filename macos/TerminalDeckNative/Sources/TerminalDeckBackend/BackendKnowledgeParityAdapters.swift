import Foundation
import TerminalDeckNativeCore

public extension BackendKnowledgeTaskScope {
    /// Source knowledge-tools.ts taskScopeOf. Preserve its absence and exact
    /// task identity; a goal is not supplied by this source adapter.
    static func fromTask(_ task: BackendTaskRecord?) -> BackendKnowledgeTaskScope? {
        guard let task else { return nil }
        let conversation = task.value["conversationId"].string.flatMap { $0.isEmpty ? nil : $0 }
        return .init(taskId: task.id, project: task.project,
            agentId: task.assigneeKind == "agent" ? task.value["assignee"]["agentId"].string : nil,
            conversationId: conversation)
    }
}
