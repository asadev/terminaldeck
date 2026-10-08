import Foundation
import TerminalDeckNativeCore

/// A reviewer is an ordinary task agent with a real child task and explicit
/// verdict tools. Output text alone is never accepted as verification.
public enum BackendTAGTaskReviewer {
    public static func child(parent: BackendTaskRecord, reviewer: NativeRPCValue, turnID: String, workspace: String) throws -> BackendTaskRecord {
        let external = UUID().uuidString.lowercased(), now = BackendTaskValues.time(), agentID = reviewer["id"].string ?? ""
        let tool = parent.isLocal ? "tasks_review" : "tasks_verify"
        let instruction = "Review task \(parent.id). Read its instructions and result with tasks_get, then inspect the changed files and relevant checks in \(workspace). Treat its answer as a claim to check. " +
            (parent.isLocal ? "Call \(tool) on task \(parent.id) with verdict pass and the evidence you checked, or verdict fail with clear reasons." : "Call \(tool) on task \(parent.id) with verified true and a note naming the evidence you checked, or verified false with what is missing.") +
            " Do not change the worker's files. Finish with your verdict and evidence. A final answer without the verdict tool does not complete the review."
        var value = BackendTaskValues.object([
            ("id", .string("local:" + external)), ("keyId", .string("local")), ("externalTaskId", .string(external)),
            ("local", .bool(true)), ("parentTaskId", .string(parent.id)), ("parentExternalTaskId", parent.value["externalTaskId"]),
            ("originExternalTaskId", parent.value["originExternalTaskId"]), ("externalThreadId", parent.value["externalThreadId"]),
            ("reviewOfTaskId", .string(parent.id)), ("reviewTurnId", .string(turnID)), ("reviewWorkspace", .string(workspace)),
            ("useWorkspace", .bool(true)),
            ("title", .string(String(("Review: " + (parent.value["title"].string ?? parent.id)).prefix(300)))),
            ("instructions", .string(instruction)), ("project", .string(parent.project)),
            ("assignee", BackendTaskLocalService.assignment(agentID, kind: "agent")), ("mainAssignee", .string(agentID)),
            ("creator", .string("me")), ("requestedBy", .string("reviewer:" + parent.id)), ("crmStatus", .string("To-Do")),
            ("process", .string("queued")), ("sessionId", .null), ("conversationId", .null), ("runStartedAt", .null),
            ("keepOpenUntil", .null), ("keepAliveUntilClose", .bool(false)), ("hops", .number((parent.value["hops"].number ?? 0) + 1)),
            ("result", .null), ("questionOpen", .bool(false)), ("lastTurn", .null), ("childrenTold", .null),
            ("stopped", .bool(false)), ("seq", .number(0)), ("notes", .array([])), ("handedFrom", .null),
            ("labels", .array([])), ("taskType", .string("task")), ("completedAt", .null),
            ("createdAt", .number(now)), ("updatedAt", .number(now))
        ])
        if let key = BackendTAGTaskNotifications.keyID(parent) { value = value.setting("notificationKeyId", .string(key)) }
        return try BackendTaskRecord(value)
    }
}
