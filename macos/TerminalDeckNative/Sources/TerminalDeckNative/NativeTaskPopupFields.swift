import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// The task's "Fields" section (crm-task/task-fields-section.tsx): ClickUp's
// "+ Create new field" on one task — each field a row (icon · name · value), a
// searchable, filterable type picker, a short create form, and a ⋯ menu per row
// (Rename, Edit options, Move up/down, Delete). A value shows the moment it is
// chosen; a refusal puts the old value back and says why under the row.

// MARK: - The store

@MainActor
@Observable
final class FieldsStore {
    let taskId: String
    @ObservationIgnored private weak var model: TaskDetailModel?
    private(set) var ready = false
    private(set) var loadError: String?
    var fields: [TaskField] = []
    var people: [String: CrmPerson] = [:]
    private(set) var auto: AutoProgress?
    private(set) var viewerId: String?
    var errors: [String: String] = [:]
    var busy: Set<String> = []
    var sectionErr: String?

    init(model: TaskDetailModel) {
        taskId = model.taskId
        self.model = model
    }

    private func call(_ fn: String, _ args: [Any?]) async -> Result<[String: Any], TasksProblem> {
        guard let model else { return .failure(TasksProblem("This task is closed.")) }
        return await model.call(fn, args)
    }

    func load() async {
        switch await call("listTaskFields", [taskId]) {
        case .failure(let problem):
            loadError = problem.message
            fields = []
        case .success(let r):
            fields = TaskFields.sorted((r["fields"] as? [Any] ?? []).compactMap(TaskFields.decode))
            var faces: [String: CrmPerson] = [:]
            for (id, raw) in r["people"] as? [String: Any] ?? [:] {
                if let p = CrmDecode.person(raw) { faces[id] = p }
            }
            people = faces
            auto = TaskFields.decodeAuto(r["auto"])
            viewerId = r["viewerId"] as? String
        }
        ready = true
    }

    func field(_ id: String) -> TaskField? { fields.first { $0.id == id } }

    private func replace(_ f: TaskField) {
        fields = fields.map { $0.id == f.id ? f : $0 }
    }

    private func setValue(_ id: String, _ value: CrmValue) {
        fields = fields.map { f in
            guard f.id == id else { return f }
            var next = f
            next.value = value
            return next
        }
    }

    func remember(_ p: CrmPerson) {
        if people[p.id] == nil { people[p.id] = p }
    }

    /// A value: checked here first (the same rule the engine runs), shown at once,
    /// put back with the reason if the engine refuses it. People, Tasks and Files name
    /// this computer's own ids, which only the engine can carry across the rule's id
    /// check, so those go straight to it.
    func commitValue(_ field: TaskField, _ raw: CrmValue) async {
        var shown = raw
        if ![.people, .tasks, .files].contains(field.kind) {
            let ctx = ValueCtx(userId: viewerId ?? "", now: CrmTime.iso(Date().timeIntervalSince1970 * 1000))
            switch TaskFields.normaliseValue(field.kind, field.config, raw, ctx: ctx) {
            case .failure(let f):
                errors[field.id] = f.error
                return
            case .success(let v):
                shown = v
            }
        }
        let prev = self.field(field.id)?.value ?? field.value
        errors[field.id] = nil
        setValue(field.id, shown)
        switch await call("updateTaskFieldValue", [field.id, raw.any]) {
        case .failure(let problem):
            setValue(field.id, prev)
            errors[field.id] = problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
        }
    }

    func vote(_ field: TaskField) async {
        busy.insert(field.id)
        errors[field.id] = nil
        let result = await call("toggleTaskFieldVote", [field.id])
        busy.remove(field.id)
        switch result {
        case .failure(let problem): errors[field.id] = problem.message
        case .success(let r): if let f = TaskFields.decode(r["field"]) { replace(f) }
        }
    }

    func press(_ field: TaskField) async {
        busy.insert(field.id)
        errors[field.id] = nil
        let result = await call("pressTaskFieldButton", [field.id])
        busy.remove(field.id)
        switch result {
        case .failure(let problem):
            errors[field.id] = problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
            if let t = TaskFields.decode(r["target"]) { replace(t) }
            model?.refetchAll()
        }
    }

    /// Files from the Mac's chooser: each one onto the task, then into the field. #327: the task's own Attach
    /// does it (one way to attach), so its quick name, size and type check refuses a file before it is read or sent.
    func upload(_ field: TaskField, _ urls: [URL]) async {
        guard let model else { return }
        busy.insert(field.id)
        errors[field.id] = nil
        let placed = await model.upload(urls)
        busy.remove(field.id)
        let added: [CrmValue] = placed.map { .object(["id": .string($0.id), "name": .string($0.fileName), "mime": $0.mimeType.map { .string($0) } ?? .null]) }
        if !added.isEmpty, let current = self.field(field.id) {
            await commitValue(current, .array((current.value.array ?? []) + added))
            model.refetchAll()
        }
        if placed.count < urls.count { errors[field.id] = model.error ?? "Some files could not be attached."; model.error = nil }
    }

    /// Resolves to the refusal in words, or nil when renamed.
    func rename(_ field: TaskField, _ label: String) async -> String? {
        let prev = field.label
        var next = field
        next.label = label
        replace(next)
        errors[field.id] = nil
        switch await call("renameTaskField", [field.id, label]) {
        case .failure(let problem):
            if var back = self.field(field.id) {
                back.label = prev
                replace(back)
            }
            errors[field.id] = problem.message
            return problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
            for raw in r["formulas"] as? [Any] ?? [] {
                if let f = TaskFields.decode(raw) { replace(f) }
            }
            return nil
        }
    }

    func saveConfig(_ field: TaskField, _ config: FieldConfig) async -> String? {
        switch await call("updateTaskFieldConfig", [field.id, config.crm(field.kind).any]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
            return nil
        }
    }

    func move(_ field: TaskField, _ dir: Int) async {
        let before = fields
        guard let i = before.firstIndex(where: { $0.id == field.id }) else { return }
        let j = i + dir
        guard j >= 0, j < before.count else { return }
        var next = before
        next.swapAt(i, j)
        fields = next
        sectionErr = nil
        if case .failure(let problem) = await call("reorderTaskFields", [taskId, next.map(\.id)]) {
            fields = before
            sectionErr = problem.message
        }
    }

    func delete(_ field: TaskField) async {
        let before = fields
        fields.removeAll { $0.id == field.id }
        sectionErr = nil
        if case .failure(let problem) = await call("deleteTaskField", [field.id]) {
            fields = before
            sectionErr = "“\(field.label)” was not deleted: \(problem.message)"
        }
    }

    func create(label: String, kind: FieldKind, config: FieldConfig) async -> String? {
        let input: [String: Any] = ["label": label, "kind": kind.rawValue, "config": config.crm(kind).any]
        switch await call("createTaskField", [taskId, input]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { fields.append(f) }
            return nil
        }
    }
}
