import Foundation
import TerminalDeckNativeCore

/// Source tiers are explicit data, shared by validation tests and dispatch.
enum BackendTaskToolPolicy {
    static let partWords = ["subtask_add", "subtask_done", "subtask_remove", "checklist_add", "checklist_remove", "checklist_item_add", "checklist_item_done", "checklist_item_remove", "dependency_add", "dependency_remove", "time_start", "time_stop", "time_add", "time_remove", "field_create", "field_set", "field_remove", "attach_file", "attachment_remove", "person_add", "person_remove", "subtask_assignee", "checklist_item_assignee", "checklist_rename", "comment_resolve", "comment_react", "task_duplicate", "task_merge", "task_to_subtask", "label_color", "label_delete", "subtask_meta", "field_rename", "field_settings", "field_order", "sync_dates", "description_history"]
    static let overrides: [String: [String: BackendMCPTier]] = [
        "hoot.island": ["get": .read, "set": .alter],
        "tasks.local_change": ["create": .alter, "update": .alter, "status": .act, "assign": .alter, "comment": .act, "reply": .act, "archive": .alter, "unarchive": .alter, "delete": .alter, "restore": .alter, "purge": .alter],
        "tasks.agents": ["list": .read, "save": .alter, "save-many": .alter, "remove": .alter, "pause": .alter, "resume": .alter, "archive": .alter, "restore": .alter],
        "tasks.goals": ["list": .read, "get": .read, "create": .act, "update": .act, "remove": .alter, "link": .act],
        "tasks.local_parts": ["subtask_add": .act, "subtask_done": .act, "subtask_remove": .alter, "checklist_add": .act, "checklist_remove": .alter, "checklist_item_add": .act, "checklist_item_done": .act, "checklist_item_remove": .alter, "dependency_add": .act, "dependency_remove": .alter, "time_start": .act, "time_stop": .act, "time_add": .act, "time_remove": .alter, "field_create": .act, "field_set": .act, "field_remove": .alter, "attach_file": .alter, "attachment_remove": .alter, "person_add": .act, "person_remove": .alter, "subtask_assignee": .act, "checklist_item_assignee": .act, "checklist_rename": .act, "comment_resolve": .act, "comment_react": .act, "task_duplicate": .act, "task_merge": .alter, "task_to_subtask": .alter, "label_color": .act, "label_delete": .alter, "subtask_meta": .act, "field_rename": .act, "field_settings": .act, "field_order": .act, "sync_dates": .act, "description_history": .read],
        "tasks.local_schedule": ["reminder_set": .act, "reminder_clear": .act, "comment_schedule": .act, "comment_send_now": .act, "repeat_set": .alter, "repeat_pause": .alter, "repeat_resume": .alter, "repeat_stop": .alter, "repeat_restart": .alter],
        "tasks.claims": ["list": .read, "claim": .act, "release": .act],
    ]
    static func tier(_ id: String, arguments: NativeRPCValue, fallback: BackendMCPTier) -> BackendMCPTier {
        if id == "tasks.crm_sync" { return arguments["on"].isNullish ? .read : .act }
        return overrides[id]?[arguments["do"].string ?? ""] ?? fallback
    }
}
