import Foundation
import TerminalDeckNativeCore

/// src/shared/crm/crm-shim.ts. This is deliberately broader than the three
/// searchable local tag areas: relationship fields may store any area label.
public enum BackendCrmShim {
    public static let taskStatuses = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]
    public static func isTaskStatus(_ value: CrmValue?) -> Bool { value?.string.map(taskStatuses.contains) ?? false }
    public static func isTagArea(_ value: CrmValue?) -> Bool {
        guard let text = value?.string else { return false }
        return !text.isEmpty && text.utf16.count <= 40
    }
}

/// detail-contract.ts is a catalogue, not a second task service. Its handlers
/// are owned by the BackendTask local-detail implementation.
public enum BackendCrmDetailContract {
    public static let channel = "tasks:local-detail"
    public static let meID = "me", hootID = "hoot"
    public static let functions = [
        "fetchTaskDetailBundle", "listTaskComments", "listTaskActivity", "setTaskStatus", "updateTask", "assignTask",
        "addTaskAssignee", "removeTaskAssignee", "addTaskSubtask", "setTaskSubtaskDone", "deleteTaskSubtask", "setTaskSubtaskAssignee",
        "addChecklist", "renameChecklist", "deleteChecklist", "addChecklistItem", "setChecklistItemDone", "setChecklistItemAssignee",
        "deleteChecklistItem", "addTaskDependency", "removeTaskDependency", "attachExistingDocument", "detachTaskAttachment", "uploadTaskFile",
        "addTaskComment", "fetchTaskPageExtras", "setTaskType", "setTaskLabels", "setTaskLinks", "moveTask", "setTimeEstimate", "setTaskRecurrence",
        "setSubtaskMeta", "startTaskTimer", "stopTaskTimer", "addTaskTimeEntry", "deleteTaskTimeEntry", "duplicateTask", "fetchRoutine", "saveRoutine",
        "stopRoutine", "pauseRoutine", "restartRoutine", "fetchTaskMore", "setFollowing", "addFollower", "removeFollower", "setReminder", "clearReminder",
        "setArchived", "mergeTaskInto", "convertToSubtask", "setSyncSubtaskDates", "setTaskTimes", "setLabelColor", "deleteLabelEverywhere",
        "setTimeEntryTags", "fetchDescriptionHistory", "fetchCommentExtras", "addTaskCommentWith", "toggleCommentReaction", "setCommentResolved",
        "assignComment", "sendScheduledNow", "listTaskFields", "createTaskField", "updateTaskFieldValue", "renameTaskField", "updateTaskFieldConfig",
        "reorderTaskFields", "deleteTaskField", "toggleTaskFieldVote", "pressTaskFieldButton", "chooseTaskFiles", "openTaskFile", "searchTags",
        "setTaskProject", "chooseTaskProject",
    ]
    public static func isLocalDetailFn(_ value: String?) -> Bool { value.map(functions.contains) ?? false }
    public struct LocalUpload: Sendable, Equatable {
        public var name: String, type: String
        public var bytes: Data
        public init(name: String, type: String, bytes: Data) { self.name = name; self.type = type; self.bytes = bytes }
        public var wire: NativeRPCValue { .object([.init("name", .string(name)), .init("type", .string(type)), .init("bytes", .bytes(bytes))]) }
    }
    public static func localPerson(_ id: String, _ name: String) -> CrmPerson { BackendCrmPeople.localPerson(id, name) }
    public static func localPeople(_ agents: [(id: String, name: String)]) -> [CrmPerson] { BackendCrmPeople.localPeople(agents) }
}

/// The absent profile-read adapter from task-people.ts. Avatars and the UTF-16
/// hash reuse CrmPerson/CrmPeople instead of inventing another person type.
public enum BackendCrmPeople {
    public static let avatarPalette = CrmPeople.avatarPalette
    public typealias TaskAssignee = CrmPerson
    public struct ProfileLite: Sendable, Equatable {
        public var id: String
        public var name: String?, email: String?, initials: String?, avatarBackground: String?, avatarURL: String?
        public init(id: String, name: String? = nil, email: String? = nil, initials: String? = nil, avatarBackground: String? = nil, avatarURL: String? = nil) {
            self.id = id; self.name = name; self.email = email; self.initials = initials; self.avatarBackground = avatarBackground; self.avatarURL = avatarURL
        }
    }
    public static func hashStringToIndex(_ text: String, _ modulo: Int) -> Int { CrmPeople.hashStringToIndex(text, modulo) }
    public static func deriveInitials(_ name: String?) -> String {
        let safe = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = safe.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = words.first else { return "?" }
        if words.count == 1 { return BackendCrmInlineFiles.slice(first, 0, 2).uppercased() }
        return (BackendCrmInlineFiles.slice(first, 0, 1) + BackendCrmInlineFiles.slice(words[1], 0, 1)).uppercased()
    }
    public static func toAssignee(_ profile: ProfileLite) -> CrmPerson {
        let storedInitials = (profile.initials ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let initials = !storedInitials.isEmpty && storedInitials != "?" ? storedInitials : deriveInitials(profile.name)
        let storedBackground = (profile.avatarBackground ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = profile.email.flatMap { $0.isEmpty ? nil : $0 } ?? profile.id
        let color = !storedBackground.isEmpty && storedBackground != "bg-blue-500" ? storedBackground : avatarPalette[hashStringToIndex(seed, avatarPalette.count)]
        return CrmPerson(id: profile.id, name: profile.name ?? "Unknown", initials: initials, color: color, avatarUrl: profile.avatarURL)
    }
    public static func localPerson(_ id: String, _ name: String) -> CrmPerson {
        CrmPerson(id: id, name: name, initials: id == "me" ? "ME" : deriveInitials(name), color: avatarPalette[hashStringToIndex(id, avatarPalette.count)])
    }
    public static func localPeople(_ agents: [(id: String, name: String)]) -> [CrmPerson] {
        [localPerson("me", "You"), localPerson("hoot", "Hoot")] + agents.map { localPerson($0.id, $0.name) }
    }
}

public enum BackendCrmTags {
    public static let areas = TaskFields.tagAreas
    public static let areaKeys = areas.map(\.key)
    public static func isTagArea(_ value: String?) -> Bool { value.map(areaKeys.contains) ?? false }
    public static func tagAreaLabel(_ key: String) -> String { TaskFields.tagAreaLabel(key) }
    /// tag-areas.ts's TagHit/TaskTag are missing from Core. Optional secondary
    /// and status are omitted on the wire when absent, as in the source.
    public struct Hit: Sendable, Equatable {
        public var area: String, id: String, label: String, href: String
        public var secondary: String?, status: String?
        public init(area: String, id: String, label: String, href: String, secondary: String? = nil, status: String? = nil) {
            self.area = area; self.id = id; self.label = label; self.href = href; self.secondary = secondary; self.status = status
        }
        public var wire: NativeRPCValue {
            tagWire.setting("status", status.map(NativeRPCValue.string) ?? .missing)
        }
        public var tagWire: NativeRPCValue {
            .object([.init("area", .string(area)), .init("id", .string(id)), .init("label", .string(label)), .init("href", .string(href)),
                     .init("secondary", secondary.map(NativeRPCValue.string) ?? .missing)])
        }
    }
}

public enum BackendCrmActivity {
    public static let readLimit = 500
    public static let kinds = ["created", "title", "description", "status", "priority", "dates", "assigned", "unassigned", "subtask_added", "subtask_done",
        "checklist_added", "checklist_item", "dependency", "attachment", "comment", "time_tracked", "estimate", "tags", "task_type", "moved", "recurrence",
        "field", "archived", "follower", "merged", "converted", "map"]
    public typealias Row = TaskActivityRow
    public typealias Payload = [String: CrmValue]
}

public enum BackendCrmMore {
    public static let migration = "2026-09-15-task-page-2.sql"
    public static let labelColors = ["grey", "red", "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "blue", "indigo", "violet", "purple", "pink"]
    public typealias View = TaskMore
    public typealias Version = DescriptionVersion
    public struct Tone: Sendable, Equatable { public let bg: String, fg: String, dot: String }
    public static func labelTone(_ color: String) -> Tone? {
        let tokens = ["var(--text-muted)", "var(--color-critical)", "color-mix(in srgb, var(--color-warning) 60%, var(--color-critical))",
            "var(--color-warning)", "var(--color-warning)", "var(--color-positive)", "var(--color-positive)", "var(--bind-2)", "var(--color-info)",
            "var(--accent)", "var(--accent)", "var(--bind-1)", "var(--bind-1)", "var(--bind-3)"]
        guard let i = labelColors.firstIndex(of: color) else { return nil }
        return Tone(bg: "color-mix(in srgb, \(tokens[i]) 16%, var(--bg-primary))", fg: "color-mix(in srgb, \(tokens[i]) 80%, var(--text-primary))", dot: tokens[i])
    }
}

/// Existing Core types implement the collaborative and routine view shapes.
/// Keep the source's fallback separate from TaskPeople.assignee(for:), which
/// additionally validates membership for UI display.
public enum BackendCrmCollaboration {
    public static let dependencyKinds = DependencyKind.allCases.map(\.rawValue)
    public static func dependencyLabel(_ kind: DependencyKind) -> String { kind.label }
    public static func checklistProgress(_ list: Checklist) -> (done: Int, total: Int) { list.progress }
    public static func effectiveAssignee(_ item: String?, people: TaskPeople) -> String? { item ?? people.primary?.id }
    public typealias DetailBundle = TaskDetailBundle
    public typealias RoutineActionsView = RoutineView
}

/// tasks-data.ts's presentation constants. TaskRow, CrmTask, CrmPerson,
/// TaskComment and BackendTaskRecord remain the canonical model types.
public enum BackendCrmTasksData {
    public static let statusDot = ["To-Do": "bg-blue-400", "In Progress": "bg-amber-400", "Working on it": "bg-amber-400", "Done": "bg-emerald-500", "Stuck": "bg-rose-500"]
    public static let statusPill = ["To-Do": "bg-blue-50 text-blue-700", "In Progress": "bg-amber-50 text-amber-700", "Working on it": "bg-amber-50 text-amber-700",
        "Done": "bg-emerald-50 text-emerald-700", "Stuck": "bg-rose-50 text-rose-700"]
    public static let priorityPill = ["Low": "bg-slate-100 text-slate-700", "Medium": "bg-blue-50 text-blue-700", "High": "bg-amber-50 text-amber-700", "Critical": "bg-rose-50 text-rose-700"]
    public static func taskBoardLabel(_ board: String) -> String { board.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No board" : board }
    /// Source-only optional task metadata remains on BackendTaskRecord.value;
    /// preserve these keys when composing a task's public CRM-shaped wire row.
    public static let optionalTaskKeys = ["createdAt", "isExtraAssignee", "subtasks", "checklistTotal", "checklistDone", "extraAssignees", "myPosition", "labels",
        "taskType", "archivedAt", "isRoutine", "startTime", "dueTime", "aiAgent"]
    public static func supplement(_ crmTask: NativeRPCValue, from record: BackendTaskRecord) -> NativeRPCValue {
        var wire = crmTask
        for key in optionalTaskKeys where record.value.has(key) {
            let value = record.value[key]
            if ["createdAt", "archivedAt"].contains(key), let milliseconds = value.number { wire = wire.setting(key, .string(CrmTime.iso(milliseconds))) }
            else { wire = wire.setting(key, value) }
        }
        return wire
    }
}
