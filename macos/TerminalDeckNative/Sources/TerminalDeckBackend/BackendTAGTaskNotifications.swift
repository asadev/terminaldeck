import Foundation
import TerminalDeckNativeCore

/// Task events use the same durable per-key inbox, long wait and signed webhook
/// as coding sessions. The task's authenticated origin is never body input.
public enum BackendTAGTaskNotifications {
    public static let eventNames: [String: String] = [
        "task.started": "task.started", "task.progress": "task.progress",
        "task.question": "task.question", "task.blocked": "task.blocked",
        "task.finished": "task.finished", "task.needs-reply": "task.needs_reply"
    ]
    public static func keyID(_ task: BackendTaskRecord) -> String? {
        if let key = task.value["notificationKeyId"].string, !key.isEmpty, key != "local" { return key }
        guard !task.isLocal, let key = task.value["keyId"].string, !key.isEmpty, key != "local" else { return nil }
        return key
    }
    public static func valid(_ event: NativeRPCValue) -> Bool {
        eventNames[event["type"].string ?? ""] != nil && event["taskId"].string != nil
    }
    public static func event(_ task: BackendTaskRecord, type: String, body: String, agentID: String? = nil) -> NativeRPCValue {
        BackendTaskValues.object([
            ("id", .string("task-event-" + UUID().uuidString.lowercased())), ("type", .string(type)),
            ("taskId", .string(task.id)), ("externalTaskId", task.value["externalTaskId"]),
            ("sessionId", .string(task.sessionID ?? "task:" + task.id)),
            ("sessionName", task.value["title"]), ("title", task.value["title"]),
            ("project", .string(task.project)), ("agentId", .string(agentID ?? task.value["handedFrom"].string ?? task.agentID)),
            ("at", .number(BackendTaskValues.time())), ("body", .string(body)),
            ("answer", BackendTaskValues.object([("text", .string(BackendTaskBriefComposition.utf16Prefix(body, 2_000))), ("truncated", .bool(body.utf16.count > 2_000))])),
            ("verified", task.value["result"]["verified"].isNullish ? .null : task.value["result"]["verified"]),
            ("suggestedTool", .string(task.isLocal ? (type == "task.needs-reply" || type == "task.question" ? "tasks_local_change" : "tasks_local") : "crm_task")),
            ("note", .string(BackendTaskBriefComposition.utf16Prefix(body, 500)))
        ])
    }
}

extension BackendDeckCoreEventsComposition {
    /// Returns false when notifications are off or the key no longer exists.
    @discardableResult public func publishTask(keyId: String, event: NativeRPCValue) async -> Bool {
        guard await hub.publishTask(keyId: keyId, event: event) else { return false }
        _ = await events.offer(keyId: keyId, event: event)
        return true
    }
    public var taskNotifications: @Sendable (BackendTaskRecord, NativeRPCValue) async throws -> Void {
        { task, event in
            guard let key = BackendTAGTaskNotifications.keyID(task) else { return }
            _ = await self.publishTask(keyId: key, event: event)
        }
    }
}

extension BackendDeckCoreEventsHub {
    @discardableResult public func publishTask(keyId: String, event: NativeRPCValue) async -> Bool {
        guard BackendTAGTaskNotifications.valid(event) else { return false }
        return await enqueue(keyId: keyId, event: event)
    }
}
