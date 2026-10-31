import Foundation
import TerminalDeckNativeCore

// How named values from outside (a Receiver event's fields, a CRM task link's input) land in a
// Terminal Deck task: the task's own fields through the task service's normal create/update input,
// and every other name as a custom field on the task, set in one save. Shared by the Receiver and
// the CRM task link, so neither has a field list of its own (RCVTaskMapping decides).

/// The task popup's field service is assembled after the Receiver; it is handed over here once it exists.
public actor BackendTaskFieldsBox {
    public static let shared = BackendTaskFieldsBox()
    private var service: BackendTaskDetailService?
    public func set(detail: BackendTaskDetailService?) { service = detail }
    public func detail() -> BackendTaskDetailService? { service }
}

public enum BackendTaskFieldLanding {
    /// The task's own fields as task-service input pairs (create or update). Values are already in
    /// the shape the task service accepts (RCVTaskMapping read them).
    public static func input(_ fields: RCVTaskFields) -> [(String, NativeRPCValue)] {
        var out: [(String, NativeRPCValue)] = []
        for key in ["status", "priority", "startDate", "dueDate", "startTime", "dueTime", "board", "taskType"] {
            if let value = fields.text(key) { out.append((key, .string(value))) }
        }
        if let labels = fields.labels, !labels.isEmpty { out.append(("labels", .array(labels.map(NativeRPCValue.string)))) }
        if let minutes = fields.estimateMinutes { out.append(("estimateMinutes", .number(Double(minutes)))) }
        return out
    }

    /// The same values as a stored-task patch (a mirrored task's record keeps them under these keys;
    /// its status is `crmStatus`).
    public static func patch(_ fields: RCVTaskFields) -> NativeRPCValue {
        var value = NativeRPCValue.object([])
        for (key, item) in input(fields) { value = value.setting(key == "status" ? "crmStatus" : key, item) }
        return value
    }

    /// What one task holds now, for "Check connection": its own fields and its custom fields by label.
    public static func snapshot(_ record: BackendTaskRecord) -> RCVTaskSnapshot {
        var values: [String: String] = [:]
        let v = record.value
        if let status = v["crmStatus"].string { values["status"] = status }
        for key in ["priority", "startDate", "dueDate", "startTime", "dueTime", "board", "taskType"] { if let text = v[key].string, !text.isEmpty { values[key] = text } }
        if let labels = v["labels"].elements?.compactMap(\.string), !labels.isEmpty { values["labels"] = labels.joined(separator: ", ") }
        if let minutes = v["estimateMinutes"].number { values["estimateMinutes"] = String(Int(minutes)) }
        var custom: [String: String] = [:]
        for row in v["detail"]["fields"].elements ?? [] {
            guard let label = row["label"].string else { continue }
            custom[label] = row["value"].string ?? (row["value"].isNullish ? "" : (try? String(decoding: row["value"].encodedJSON(), as: UTF8.self)) ?? "")
        }
        for row in v["crmFields"].elements ?? [] { if let label = row["label"].string { custom[label] = row["value"].string ?? "" } }
        return RCVTaskSnapshot(id: record.id, title: v["title"].string ?? "", status: v["crmStatus"].string ?? "", values: values, custom: custom)
    }
}

extension BackendTaskDetailService {
    /// Sets named custom fields on one of this Mac's tasks in ONE save: a field with the same label
    /// (any case) gets the new value, others are added as text, long text or a web address. A value
    /// a kind refuses falls back to text. One plain line goes into the task's history, never one per
    /// field. Returns the labels that could not be set, with why.
    public func setNamedFields(_ taskID: String, _ items: [RCVTaskCustomField], by: String, note: String?) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        await enter(); defer { leave() }
        let task = try await local.task(taskID)
        var fields = decodeFields(task), refused: [String] = [], changed = 0
        let now = BackendTaskOutbox.iso(BackendTaskValues.time())
        for item in items {
            guard case .success(let label) = TaskFields.normaliseLabel(item.label) else { refused.append("\(item.label): not a usable field name"); continue }
            if let index = fields.firstIndex(where: { TaskFields.sameLabel($0.label, label) }) {
                let field = fields[index]
                guard let value = try? await normalizedValue(task, kind: field.kind, config: field.config, raw: .string(item.value)) else {
                    refused.append("\(label): the field there is a \(field.kind.rawValue) field and cannot hold “\(item.value.prefix(40))”"); continue
                }
                if fields[index].value != value { fields[index].value = value; fields[index].updatedAt = now; changed += 1 }
                continue
            }
            guard fields.count < 100 else { refused.append("\(label): the task already holds 100 fields"); continue }
            var kind = FieldKind(rawValue: item.kind) ?? .text
            var value = try? await normalizedValue(task, kind: kind, config: FieldConfig(), raw: .string(item.value))
            if value == nil, kind != .longText {
                kind = item.value.count > 500 || item.value.contains("\n") ? .longText : .text
                value = try? await normalizedValue(task, kind: kind, config: FieldConfig(), raw: .string(String(item.value.prefix(5_000))))
            }
            guard let value, case .success(let config) = BackendCrmFields.normaliseConfig(kind, nil, siblings: fields) else {
                refused.append("\(label): the value could not be stored"); continue
            }
            fields.append(TaskField(id: UUID().uuidString.lowercased(), taskId: task.id, label: label, kind: kind, config: config, value: value,
                                    sortOrder: (fields.compactMap(\.sortOrder).max() ?? -1) + 1, createdBy: by, createdAt: now, updatedAt: now))
            changed += 1
        }
        guard changed > 0 else { return refused }
        try await save(task, d: detail(task).setting("fields", .array(fields.map(BackendCrmWire.field))), by: by)
        if let note { try await store.note(task.id, by: by, kind: "edited", text: note) }
        return refused
    }
}
