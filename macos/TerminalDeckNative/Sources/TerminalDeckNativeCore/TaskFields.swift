import Foundation

// A task's custom fields (shared/crm/task-fields.ts): the 23 kinds in ClickUp's
// order, their settings and value rules, the formula engine (a tokenizer and a
// recursive-descent parser, never code), auto progress, and how a value reads.
// The engine runs the same rules; this copy is what the popup checks before it
// shows a change, so a refusal reads the same on both sides.

public struct FieldFail: Error, Equatable, Sendable {
    public let error: String
    public init(_ error: String) { self.error = error }
}

public typealias FieldRes<T> = Result<T, FieldFail>

// MARK: - The catalogue

/// Storage keys — a vocabulary, never renamed. Declared in FIELD_KINDS order.
public enum FieldKind: String, CaseIterable, Sendable {
    case dropdown, text, date
    case longText = "long_text"
    case number, labels, checkbox, money, website, formula, files, relationship, people
    case progressAuto = "progress_auto"
    case email, phone, tasks, location
    case progressManual = "progress_manual"
    case rating, voting, signature, button
}

/// The picker's filter row, in FIELD_GROUPS order ("All" goes first, in the view).
public enum FieldGroup: String, CaseIterable, Sendable {
    case basic, choice, numbers, contact, links, actions

    public var label: String {
        switch self {
        case .basic: "Basic"
        case .choice: "Choice"
        case .numbers: "Numbers"
        case .contact: "Contact"
        case .links: "Links"
        case .actions: "Actions"
        }
    }
}

public struct FieldTypeInfo: Equatable, Sendable {
    public let kind: FieldKind
    /// ClickUp's own name — what the picker shows.
    public let name: String
    /// The one line under the name.
    public let hint: String
    public let group: FieldGroup
    /// The design system's hue for the icon tile (`--hue-<hue>`).
    public let hue: String
}

public struct FieldOption: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var label: String
    public var color: String

    public init(id: String, label: String, color: String) {
        self.id = id
        self.label = label
        self.color = color
    }
}

public enum RatingIcon: String, CaseIterable, Sendable {
    case star, heart, fire, thumb, smile

    public var glyph: String {
        switch self {
        case .star: "★"
        case .heart: "♥"
        case .fire: "🔥"
        case .thumb: "👍"
        case .smile: "😀"
        }
    }

    public var label: String {
        switch self {
        case .star: "Stars"
        case .heart: "Hearts"
        case .fire: "Fire"
        case .thumb: "Thumbs"
        case .smile: "Smiles"
        }
    }
}

public enum ButtonAction: Equatable, Sendable {
    case status(String)
    case comment(String)
    case field(fieldId: String, value: CrmValue)

    public var type: String {
        switch self {
        case .status: "status"
        case .comment: "comment"
        case .field: "field"
        }
    }

    public var crm: CrmValue {
        switch self {
        case .status(let s): .object(["type": .string("status"), "status": .string(s)])
        case .comment(let b): .object(["type": .string("comment"), "body": .string(b)])
        case .field(let id, let v): .object(["type": .string("field"), "fieldId": .string(id), "value": v])
        }
    }
}

/// One flat bag, normalised per kind so the keys that kind needs are present.
public struct FieldConfig: Equatable, Sendable {
    public var options: [FieldOption]?
    public var decimals: Int?
    public var currency: String?
    public var includeTime: Bool?
    public var max: Int?
    public var icon: RatingIcon?
    public var start: Double?
    public var end: Double?
    public var subtasks: Bool?
    public var checklists: Bool?
    public var expression: String?
    public var areas: [String]?
    public var label: String?
    public var color: String?
    public var action: ButtonAction?

    public init() {}

    /// The settings for the wire, as the kind keeps them.
    public func crm(_ kind: FieldKind) -> CrmValue {
        var o: [String: CrmValue] = [:]
        if let options { o["options"] = .array(options.map { .object(["id": .string($0.id), "label": .string($0.label), "color": .string($0.color)]) }) }
        if let decimals { o["decimals"] = .number(Double(decimals)) }
        if let currency { o["currency"] = .string(currency) } else if kind == .formula { o["currency"] = .null }
        if let includeTime { o["includeTime"] = .bool(includeTime) }
        if let max { o["max"] = .number(Double(max)) }
        if let icon { o["icon"] = .string(icon.rawValue) }
        if let start { o["start"] = .number(start) }
        if let end { o["end"] = .number(end) }
        if let subtasks { o["subtasks"] = .bool(subtasks) }
        if let checklists { o["checklists"] = .bool(checklists) }
        if let expression { o["expression"] = .string(expression) }
        if let areas { o["areas"] = .array(areas.map { .string($0) }) }
        if let label { o["label"] = .string(label) }
        if let color { o["color"] = .string(color) }
        if let action { o["action"] = action.crm }
        return .object(o)
    }
}

/// A field as the popup sees it. `value` is `.null` when empty.
public struct TaskField: Equatable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var label: String
    public var kind: FieldKind
    public var config: FieldConfig
    public var value: CrmValue
    public var sortOrder: Double?
    public var createdBy: String?
    public var createdAt: String
    public var updatedAt: String?

    public init(id: String, taskId: String, label: String, kind: FieldKind, config: FieldConfig, value: CrmValue = .null,
                sortOrder: Double? = nil, createdBy: String? = nil, createdAt: String = "", updatedAt: String? = nil) {
        self.id = id
        self.taskId = taskId
        self.label = label
        self.kind = kind
        self.config = config
        self.value = value
        self.sortOrder = sortOrder
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The counts Progress (Auto) is computed from.
public struct AutoProgress: Equatable, Sendable {
    public var subtasksDone: Int
    public var subtasksTotal: Int
    public var checklistsDone: Int
    public var checklistsTotal: Int

    public init(subtasksDone: Int, subtasksTotal: Int, checklistsDone: Int, checklistsTotal: Int) {
        self.subtasksDone = subtasksDone
        self.subtasksTotal = subtasksTotal
        self.checklistsDone = checklistsDone
        self.checklistsTotal = checklistsTotal
    }
}

/// The areas a Relationship field can link on this computer (tag-areas.ts).
public struct TagArea: Equatable, Sendable {
    public let key: String
    public let label: String
    public let hint: String
}

public struct ValueCtx: Sendable {
    public let userId: String
    public let now: String
    public init(userId: String, now: String) {
        self.userId = userId
        self.now = now
    }
}

public enum TaskFields {
    public static let types: [FieldTypeInfo] = [
        FieldTypeInfo(kind: .dropdown, name: "Dropdown", hint: "One option from a list", group: .choice, hue: "emerald"),
        FieldTypeInfo(kind: .text, name: "Text", hint: "A single line of text", group: .basic, hue: "sky"),
        FieldTypeInfo(kind: .date, name: "Date", hint: "A day, with an optional time", group: .basic, hue: "amber"),
        FieldTypeInfo(kind: .longText, name: "Text area (Long Text)", hint: "Several lines of text", group: .basic, hue: "sky"),
        FieldTypeInfo(kind: .number, name: "Number", hint: "A number, with decimals", group: .numbers, hue: "teal"),
        FieldTypeInfo(kind: .labels, name: "Labels", hint: "Several coloured tags", group: .choice, hue: "violet"),
        FieldTypeInfo(kind: .checkbox, name: "Checkbox", hint: "Yes or no", group: .basic, hue: "fuchsia"),
        FieldTypeInfo(kind: .money, name: "Money", hint: "An amount in a currency", group: .numbers, hue: "emerald"),
        FieldTypeInfo(kind: .website, name: "Website", hint: "A link", group: .contact, hue: "blue"),
        FieldTypeInfo(kind: .formula, name: "Formula", hint: "Maths over this task's numbers", group: .numbers, hue: "indigo"),
        FieldTypeInfo(kind: .files, name: "Files", hint: "Upload files to this field", group: .links, hue: "orange"),
        FieldTypeInfo(kind: .relationship, name: "Relationship", hint: "Link any CRM record", group: .links, hue: "indigo"),
        FieldTypeInfo(kind: .people, name: "People", hint: "Team members", group: .links, hue: "blue"),
        FieldTypeInfo(kind: .progressAuto, name: "Progress (Auto)", hint: "From subtasks and checklists", group: .numbers, hue: "teal"),
        FieldTypeInfo(kind: .email, name: "Email", hint: "An email address", group: .contact, hue: "rose"),
        FieldTypeInfo(kind: .phone, name: "Phone", hint: "A phone number", group: .contact, hue: "violet"),
        FieldTypeInfo(kind: .tasks, name: "Tasks", hint: "Link other tasks", group: .links, hue: "indigo"),
        FieldTypeInfo(kind: .location, name: "Location", hint: "A place, with a map link", group: .contact, hue: "rose"),
        FieldTypeInfo(kind: .progressManual, name: "Progress (Manual)", hint: "A slider you set", group: .numbers, hue: "teal"),
        FieldTypeInfo(kind: .rating, name: "Rating", hint: "Stars out of a maximum", group: .choice, hue: "amber"),
        FieldTypeInfo(kind: .voting, name: "Voting", hint: "One vote per person", group: .choice, hue: "orange"),
        FieldTypeInfo(kind: .signature, name: "Signature", hint: "Draw or type a signature", group: .actions, hue: "violet"),
        FieldTypeInfo(kind: .button, name: "Button", hint: "One press runs an action", group: .actions, hue: "blue"),
    ]

    public static func info(_ kind: FieldKind) -> FieldTypeInfo { types.first { $0.kind == kind } ?? types[1] }

    /// Kinds whose value is computed, never written.
    public static func isComputed(_ kind: FieldKind) -> Bool { kind == .formula || kind == .progressAuto }

    /// Kinds written only by their own action (vote / press).
    public static func isActionOnly(_ kind: FieldKind) -> Bool { kind == .voting || kind == .button }

    /// Kinds with an "Edit options" entry in the row's ⋯ menu.
    public static func hasOptions(_ kind: FieldKind) -> Bool {
        [.dropdown, .labels, .number, .money, .date, .rating, .progressManual, .progressAuto, .formula, .relationship, .button].contains(kind)
    }

    /// ClickUp's option palette, as hex.
    public static let colors = ["#6B7280", "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6", "#EC4899", "#14B8A6", "#F97316",
                                "#0EA5E9", "#84CC16", "#A855F7"]

    /// The Money field's currencies, the first one the default.
    public static let currencies = ["AED", "EUR", "GBP", "SAR", "QAR", "OMR", "KWD", "BHD", "INR", "PKR", "CNY", "RUB", "CAD", "AUD", "CHF", "JPY"]
    public static let defaultCurrency = "AED"

    /// Kinds a Button may set.
    public static let buttonTargetKinds: [FieldKind] = [.text, .longText, .number, .money, .date, .checkbox, .dropdown, .labels, .rating,
                                                        .progressManual, .website, .email, .phone, .location]

    /// The statuses a Button can set (crm-shim TASK_STATUSES).
    public static let buttonStatuses = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]

    public static let tagAreas = [
        TagArea(key: "person", label: "Team", hint: "Someone you work with"),
        TagArea(key: "task", label: "Tasks", hint: "Another task"),
        TagArea(key: "file", label: "Files", hint: "A document already uploaded"),
    ]

    public static func isTagArea(_ v: String?) -> Bool { tagAreas.contains { $0.key == v } }
    public static func isRelationshipArea(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.utf16.count <= 40
    }
    public static func tagAreaLabel(_ key: String) -> String { tagAreas.first { $0.key == key }?.label ?? key }

    public static let maxFieldLabel = 80
    public static let maxText = 500
    public static let maxLongText = 5000
    public static let maxList = 30
    public static let maxSignatureBytes = 200_000
    static let maxAbsNumber = 1e15

    public static let formulaFunctions = ["round", "min", "max", "abs", "floor", "ceil"]

    /// "0 … 6 decimals" in the settings' pickers.
    public static func decimalsLabel(_ n: Int) -> String { n == 0 ? "Whole numbers" : "\(n) decimal\(n > 1 ? "s" : "")" }

}
