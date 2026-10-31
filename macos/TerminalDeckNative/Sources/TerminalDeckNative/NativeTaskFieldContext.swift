import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - The editing context

/// What every value editor needs: the task, its fields (formulas read them), the
/// faces, and what a vote, a press, an upload or a link does.
struct FieldCtx {
    var taskId: String?
    var fields: [TaskField] = []
    var people: [String: CrmPerson] = [:]
    var team: [CrmPerson] = []
    var auto: AutoProgress?
    var viewerId: String?
    var readOnly = false
    var busy: Set<String> = []
    var model: TaskDetailModel?
    var rememberPerson: (CrmPerson) -> Void = { _ in }
    var onVote: (TaskField) -> Void = { _ in }
    var onPress: (TaskField) -> Void = { _ in }
    var onFiles: (TaskField, [URL]) -> Void = { _, _ in }
    /// An address inside the app ("/tasks?task=…", "/files/…").
    var onOpen: (String) -> Void = { _ in }

    /// A throwaway context for the Button's "set a field to…" value.
    static func detached(team: [CrmPerson]) -> FieldCtx { FieldCtx(taskId: nil, team: team) }

    func face(_ id: String) -> CrmPerson? { people[id] ?? team.first { $0.id == id } }
}
