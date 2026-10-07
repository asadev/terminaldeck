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

    // MARK: Small helpers

    /// An id for an option or a draft — unique, never empty.
    public static func newKey() -> String { UUID().uuidString.lowercased() }

    public static func isUuidLike(_ v: String?) -> Bool {
        guard let v, v.utf8.count == 36 else { return false }
        for (i, c) in v.utf8.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != UInt8(ascii: "-") { return false }
            } else if !((48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c)) {
                return false
            }
        }
        return true
    }

    static func isHex(_ v: String?) -> Bool {
        guard let v, v.utf8.count == 7, v.hasPrefix("#") else { return false }
        return v.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// JavaScript's Math.round: halves go up.
    public static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    public static func roundTo(_ n: Double, _ decimals: Int) -> Double {
        let f = pow(10, Double(decimals))
        return jsRound((n + Double.ulpOfOne) * f) / f
    }

    /// A number as JavaScript writes it ("25", "25.5").
    public static func js(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n == n.rounded(), abs(n) < 1e21 { return String(format: "%.0f", n) }
        return "\(n)"
    }

    static func jsString(_ v: CrmValue?) -> String {
        switch v {
        case .string(let s): s
        case .number(let n): js(n)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case nil: "undefined"
        case .array(let a): a.map { jsString($0) }.joined(separator: ",")
        case .object: "[object Object]"
        }
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func clampInt(_ v: CrmValue?, _ lo: Int, _ hi: Int, _ dflt: Int) -> Int {
        var n = Double.nan
        if case .number(let d) = v { n = d }
        if case .string(let s) = v, !s.trimmingCharacters(in: .whitespaces).isEmpty { n = Double(s.trimmingCharacters(in: .whitespaces)) ?? .nan }
        guard n.isFinite else { return dflt }
        return Swift.min(hi, Swift.max(lo, Int(jsRound(n))))
    }

    public enum Parsed: Equatable, Sendable {
        case empty
        case bad
        case value(Double)
    }

    /// A number from what a person typed: "1,200", "AED 1200.5", 3.
    public static func toNumber(_ raw: CrmValue?) -> Parsed {
        switch raw {
        case nil, .null: return .empty
        case .number(let n): return n.isFinite ? .value(n) : .bad
        case .string(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var body = raw
            // Only a REAL currency code in front of a number is dropped ("AED 1,200").
            if let m = trimmed.firstMatch(of: #/^([A-Za-z]{3})\s*(?=[-+.\d])/#), currencies.contains(String(m.1).uppercased()) {
                body = String(trimmed[m.range.upperBound...])
            }
            let s = body.trimmingCharacters(in: .whitespacesAndNewlines).filter { $0 != "," && !$0.isWhitespace }
            if s.isEmpty { return .empty }
            guard s.wholeMatch(of: #/[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?/#) != nil, let n = Double(s) else { return .bad }
            return n.isFinite ? .value(n) : .bad
        default:
            return .bad
        }
    }

    // MARK: Labels

    public static func normaliseLabel(_ raw: String?) -> FieldRes<String> {
        guard let raw else { return .failure(FieldFail("Field name is required")) }
        let s = collapse(raw)
        if s.isEmpty { return .failure(FieldFail("Field name is required")) }
        if s.utf16.count > maxFieldLabel { return .failure(FieldFail("Field name is too long (\(maxFieldLabel) characters max)")) }
        if s.contains("{") || s.contains("}") { return .failure(FieldFail("Field names cannot contain { or }")) }
        return .success(s)
    }

    /// Case-insensitive: "Price" and "price" are the same name on one task.
    public static func sameLabel(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Config

    public static func defaultConfig(_ kind: FieldKind) -> FieldConfig {
        (try? normaliseConfig(kind, nil).get()) ?? FieldConfig()
    }

    static func normaliseOptions(_ raw: CrmValue?) -> FieldRes<[FieldOption]> {
        guard let raw, raw != .null else { return .success([]) }
        guard let list = raw.array else { return .failure(FieldFail("Options must be a list")) }
        if list.count > 200 { return .failure(FieldFail("Too many options (200 max)")) }
        var out: [FieldOption] = []
        for (i, o) in list.enumerated() {
            guard let obj = o.object else { return .failure(FieldFail("An option is malformed")) }
            let label = obj["label"]?.string.map(collapse) ?? ""
            if label.isEmpty { return .failure(FieldFail("Every option needs a name")) }
            if label.utf16.count > 60 { return .failure(FieldFail("Option “\(label.prefix(20))…” is too long (60 max)")) }
            if out.contains(where: { sameLabel($0.label, label) }) { return .failure(FieldFail("Two options are called “\(label)”")) }
            let given = obj["id"]?.string
            let id = given.map { $0.wholeMatch(of: #/[A-Za-z0-9_-]{1,40}/#) != nil } == true ? given! : String(newKey().prefix(36))
            if out.contains(where: { $0.id == id }) { return .failure(FieldFail("Two options share an id")) }
            let color = isHex(obj["color"]?.string) ? obj["color"]!.string!.uppercased() : colors[i % colors.count]
            out.append(FieldOption(id: id, label: label, color: color))
        }
        return .success(out)
    }

    /// The type's settings, cleaned. With `siblings`, a Button checks the field it sets.
    public static func normaliseConfig(_ kind: FieldKind, _ raw: CrmValue?, siblings: [TaskField]? = nil) -> FieldRes<FieldConfig> {
        if let raw, raw != .null, raw.object == nil { return .failure(FieldFail("Settings are malformed")) }
        let c = raw?.object ?? [:]
        var out = FieldConfig()
        switch kind {
        case .dropdown, .labels:
            switch normaliseOptions(c["options"]) {
            case .failure(let f): return .failure(f)
            case .success(let o): out.options = o
            }
        case .number:
            out.decimals = clampInt(c["decimals"], 0, 6, 2)
        case .money:
            if case .string(let given) = c["currency"] {
                guard currencies.contains(given.uppercased()) else { return .failure(FieldFail("Unknown currency “\(given)”")) }
                out.currency = given.uppercased()
            } else {
                out.currency = defaultCurrency
            }
            out.decimals = clampInt(c["decimals"], 0, 4, 2)
        case .date:
            out.includeTime = c["includeTime"] == .bool(true)
        case .rating:
            out.max = clampInt(c["max"], 1, 10, 5)
            out.icon = c["icon"]?.string.flatMap(RatingIcon.init(rawValue:)) ?? .star
        case .progressManual:
            let start = c["start"] == nil ? Parsed.value(0) : toNumber(c["start"])
            let end = c["end"] == nil ? Parsed.value(100) : toNumber(c["end"])
            guard case .value(let s) = start, case .value(let e) = end else { return .failure(FieldFail("Start and end must be numbers")) }
            if abs(s) > 1e9 || abs(e) > 1e9 { return .failure(FieldFail("Start and end are too large")) }
            if !(s < e) { return .failure(FieldFail("Start must be less than end")) }
            out.start = s
            out.end = e
        case .progressAuto:
            let subtasks = c["subtasks"] == nil ? true : c["subtasks"] == .bool(true)
            let checklists = c["checklists"] == nil ? true : c["checklists"] == .bool(true)
            if !subtasks && !checklists { return .failure(FieldFail("Count subtasks, checklists, or both")) }
            out.subtasks = subtasks
            out.checklists = checklists
        case .formula:
            let expression = c["expression"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if expression.utf16.count > 500 { return .failure(FieldFail("Formula is too long (500 characters max)")) }
            if !expression.isEmpty, case .failure(let f) = parseFormula(expression) { return .failure(FieldFail("Formula: \(f.error)")) }
            var currency: String?
            if case .string(let given) = c["currency"], !given.isEmpty {
                guard currencies.contains(given.uppercased()) else { return .failure(FieldFail("Unknown currency “\(given)”")) }
                currency = given.uppercased()
            }
            out.expression = expression
            out.decimals = clampInt(c["decimals"], 0, 6, 2)
            out.currency = currency
        case .relationship:
            if let given = c["areas"], given.array == nil { return .failure(FieldFail("Areas must be a list")) }
            var areas: [String] = []
            for a in c["areas"]?.array ?? [] {
                guard isRelationshipArea(a.string) else { return .failure(FieldFail("Unknown area “\(jsString(a))”")) }
                if !areas.contains(a.string!) { areas.append(a.string!) }
            }
            out.areas = areas
        case .button:
            let given = c["label"]?.string ?? ""
            let label = given.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Button" : collapse(given)
            if label.utf16.count > 40 { return .failure(FieldFail("Button label is too long (40 max)")) }
            out.label = label
            out.color = isHex(c["color"]?.string) ? c["color"]!.string!.uppercased() : "#2F6BFF"
            let a = c["action"] ?? .object(["type": .string("status"), "status": .string("Done")])
            guard let obj = a.object else { return .failure(FieldFail("Choose what the button does")) }
            switch obj["type"]?.string {
            case "status":
                guard let s = obj["status"]?.string, buttonStatuses.contains(s) else { return .failure(FieldFail("Choose a status for the button")) }
                out.action = .status(s)
            case "comment":
                let body = obj["body"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if body.isEmpty { return .failure(FieldFail("Write the comment the button adds")) }
                if body.utf16.count > 2000 { return .failure(FieldFail("Comment is too long (2000 max)")) }
                out.action = .comment(body)
            case "field":
                guard let fieldId = obj["fieldId"]?.string, !fieldId.isEmpty else { return .failure(FieldFail("Choose the field the button sets")) }
                let value = obj["value"] ?? .null
                out.action = .field(fieldId: fieldId, value: value)
                if let siblings {
                    guard let target = siblings.first(where: { $0.id == fieldId }) else {
                        return .failure(FieldFail("The field this button sets is not on this task"))
                    }
                    if !buttonTargetKinds.contains(target.kind) { return .failure(FieldFail("A button cannot set a \(info(target.kind).name) field")) }
                    switch normaliseValue(target.kind, target.config, value, ctx: ValueCtx(userId: "", now: "")) {
                    case .failure(let f): return .failure(FieldFail("Button value for “\(target.label)”: \(f.error)"))
                    case .success(let v): out.action = .field(fieldId: fieldId, value: v)
                    }
                }
            default:
                return .failure(FieldFail("Choose what the button does"))
            }
        default:
            break
        }
        return .success(out)
    }

    // MARK: Values

    static func isCalendarDate(_ s: String) -> Bool {
        guard let m = s.wholeMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#), let y = Int(m.1), let mo = Int(m.2), let d = Int(m.3) else { return false }
        if y < 1900 || y > 2200 || mo < 1 || mo > 12 || d < 1 { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let days = cal.range(of: .day, in: .month, for: cal.date(from: DateComponents(year: y, month: mo, day: 1))!)?.count ?? 31
        return d <= days
    }

    static func isTime(_ s: String) -> Bool { s.wholeMatch(of: #/([01]\d|2[0-3]):([0-5]\d)/#) != nil }

    static func cleanString(_ raw: CrmValue?, _ max: Int, _ what: String, multiline: Bool) -> FieldRes<String?> {
        guard let raw, raw != .null else { return .success(nil) }
        guard var s = raw.string else { return .failure(FieldFail("\(what) must be text")) }
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if multiline {
            s = s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    var l = Substring(line)
                    while let last = l.last, last.isWhitespace { l = l.dropLast() }
                    return String(l)
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            s = collapse(s)
        }
        if s.isEmpty { return .success(nil) }
        if s.utf16.count > max { return .failure(FieldFail("\(what) is too long (\(max) characters max)")) }
        return .success(s)
    }

    public static func normaliseWebsite(_ raw: CrmValue?) -> FieldRes<String?> {
        let cleaned = cleanString(raw, 2000, "Website", multiline: false)
        guard case .success(let s?) = cleaned else { return cleaned }
        let withScheme = s.firstMatch(of: #/^[a-zA-Z][a-zA-Z0-9+.\-]*:/#) != nil ? s : "https://\(s)"
        guard var u = URLComponents(string: withScheme), let scheme = u.scheme?.lowercased() else {
            return .failure(FieldFail("That is not a web address"))
        }
        if scheme != "http" && scheme != "https" { return .failure(FieldFail("Only http and https links")) }
        guard let host = u.host?.lowercased(), !host.isEmpty else { return .failure(FieldFail("That is not a web address")) }
        if !host.contains(".") && host != "localhost" { return .failure(FieldFail("That is not a web address")) }
        u.scheme = scheme
        u.host = host
        if u.path.isEmpty { u.path = "/" }
        guard let out = u.string else { return .failure(FieldFail("That is not a web address")) }
        return .success(out)
    }

    public static func normaliseEmail(_ raw: CrmValue?) -> FieldRes<String?> {
        let cleaned = cleanString(raw, 254, "Email", multiline: false)
        guard case .success(let s?) = cleaned else { return cleaned }
        if s.wholeMatch(of: #/[^\s@]+@[^\s@]+\.[^\s@]{2,}/#) == nil { return .failure(FieldFail("That is not an email address")) }
        return .success(s)
    }

    public static func normalisePhone(_ raw: CrmValue?) -> FieldRes<String?> {
        let cleaned = cleanString(raw, 40, "Phone", multiline: false)
        guard case .success(let s?) = cleaned else { return cleaned }
        if s.wholeMatch(of: #/\+?[\d\s().\-]+/#) == nil { return .failure(FieldFail("A phone number has digits, spaces, + ( ) - only")) }
        let digits = s.filter { $0.isASCII && $0.isNumber }.count
        if digits < 6 || digits > 15 { return .failure(FieldFail("A phone number has 6 to 15 digits")) }
        return .success(s)
    }

    public static func normaliseLocation(_ raw: CrmValue?) -> FieldRes<CrmValue> {
        guard let raw, raw != .null, raw != .string("") else { return .success(.null) }
        var text: CrmValue? = raw
        var lat: CrmValue = .null
        var lng: CrmValue = .null
        if let o = raw.object {
            text = o["text"]
            lat = o["lat"] ?? .null
            lng = o["lng"] ?? .null
        }
        let t: String
        switch cleanString(text, 300, "Location", multiline: false) {
        case .failure(let f): return .failure(f)
        case .success(nil): return .success(.null)
        case .success(let s?): t = s
        }
        if lat == .null && lng == .null,
           let m = t.wholeMatch(of: #/\s*(-?\d{1,3}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*/#) {
            lat = .number(Double(m.1) ?? .nan)
            lng = .number(Double(m.2) ?? .nan)
        }
        let la: Double? = lat == .null ? nil : (lat.number ?? .nan)
        let ln: Double? = lng == .null ? nil : (lng.number ?? .nan)
        if (la == nil) != (ln == nil) { return .failure(FieldFail("A location needs both latitude and longitude, or neither")) }
        if let la, !la.isFinite || la < -90 || la > 90 { return .failure(FieldFail("Latitude is between -90 and 90")) }
        if let ln, !ln.isFinite || ln < -180 || ln > 180 { return .failure(FieldFail("Longitude is between -180 and 180")) }
        return .success(.object(["text": .string(t), "lat": la.map { .number($0) } ?? .null, "lng": ln.map { .number($0) } ?? .null]))
    }

    /// A Google Maps link for a location, coordinates first when we have them.
    public static func mapHref(_ v: CrmValue) -> String {
        let q: String
        if let la = v["lat"]?.number, let ln = v["lng"]?.number { q = "\(js(la)),\(js(ln))" } else { q = v["text"]?.string ?? "" }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return "https://www.google.com/maps/search/?api=1&query=\(q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q)"
    }

    /// An internal link only — "/…", never "//host" or "javascript:".
    static func isInternalHref(_ h: String?) -> Bool {
        guard let h else { return false }
        return h.utf16.count <= 500 && h.hasPrefix("/") && !h.hasPrefix("//") && !h.contains(where: { $0.isWhitespace || $0 == "\\" })
    }

    static func isDataImage(_ d: String) -> Bool {
        let prefixes = ["data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,"]
        guard let p = prefixes.first(where: { d.hasPrefix($0) }) else { return false }
        let body = d.utf8.dropFirst(p.utf8.count)
        var seenPad = false
        var count = 0
        for c in body {
            if c == UInt8(ascii: "=") {
                seenPad = true
                continue
            }
            if seenPad { return false }
            let ok = (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == UInt8(ascii: "+") || c == UInt8(ascii: "/")
            if !ok { return false }
            count += 1
        }
        return count > 0
    }

    /// THE rule for a value, per kind: what is stored (`.null` = empty), or why not.
    public static func normaliseValue(_ kind: FieldKind, _ config: FieldConfig, _ raw: CrmValue, ctx: ValueCtx) -> FieldRes<CrmValue> {
        if isComputed(kind) { return .failure(FieldFail("This field is calculated — it cannot be set by hand")) }
        if kind == .voting { return .failure(FieldFail("Use the vote button to vote")) }
        if kind == .button { return .failure(FieldFail("Press the button to run it")) }
        func str(_ r: FieldRes<String?>) -> FieldRes<CrmValue> { r.map { $0.map { CrmValue.string($0) } ?? .null } }
        let fail = { (s: String) in FieldRes<CrmValue>.failure(FieldFail(s)) }

        switch kind {
        case .text:
            return str(cleanString(raw, maxText, "Text", multiline: false))
        case .longText:
            return str(cleanString(raw, maxLongText, "Text", multiline: true))
        case .number, .money:
            switch toNumber(raw) {
            case .bad: return fail("That is not a number")
            case .empty: return .success(.null)
            case .value(let n):
                if abs(n) > maxAbsNumber { return fail("That number is too large") }
                return .success(.number(roundTo(n, config.decimals ?? 2)))
            }
        case .checkbox:
            if raw == .null { return .success(.null) }
            guard raw.bool != nil else { return fail("A checkbox is ticked or not") }
            return .success(raw)
        case .date:
            if raw == .null || raw == .string("") { return .success(.null) }
            var date: CrmValue? = raw
            var time: CrmValue = .null
            if let o = raw.object {
                date = o["date"]
                time = o["time"] ?? .null
            }
            if date == .null || date == .string("") { return .success(.null) }
            guard let d = date?.string, isCalendarDate(d) else { return fail("That is not a date") }
            if time != .null && time != .string("") && !(time.string.map(isTime) ?? false) { return fail("That is not a time (HH:MM)") }
            let keep = config.includeTime == true && (time.string.map { !$0.isEmpty } ?? false)
            return .success(.object(["date": .string(d), "time": keep ? time : .null]))
        case .dropdown:
            if raw == .null || raw == .string("") { return .success(.null) }
            guard let id = raw.string else { return fail("Pick one of the options") }
            if !(config.options ?? []).contains(where: { $0.id == id }) { return fail("That option is not on this field") }
            return .success(raw)
        case .labels:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Labels must be a list") }
            var ids: [String] = []
            for v in list {
                guard let id = v.string, (config.options ?? []).contains(where: { $0.id == id }) else { return fail("A label is not on this field") }
                if !ids.contains(id) { ids.append(id) }
            }
            return .success(ids.isEmpty ? .null : .array(ids.map { .string($0) }))
        case .website:
            return str(normaliseWebsite(raw))
        case .email:
            return str(normaliseEmail(raw))
        case .phone:
            return str(normalisePhone(raw))
        case .location:
            return normaliseLocation(raw)
        case .rating:
            if raw == .null || raw == .number(0) { return .success(.null) }
            guard let n = raw.number, n == n.rounded(), n.isFinite else { return fail("A rating is a whole number") }
            let max = config.max ?? 5
            if n < 1 || n > Double(max) { return fail("A rating is 1 to \(max)") }
            return .success(raw)
        case .progressManual:
            switch toNumber(raw) {
            case .bad: return fail("Progress is a number")
            case .empty: return .success(.null)
            case .value(let n):
                let start = config.start ?? 0
                let end = config.end ?? 100
                if n < start || n > end { return fail("Progress is between \(js(start)) and \(js(end))") }
                return .success(.number(roundTo(n, 2)))
            }
        case .people:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("People must be a list") }
            if list.count > maxList { return fail("At most \(maxList) people") }
            var ids: [String] = []
            for v in list {
                guard isUuidLike(v.string) else { return fail("A person is malformed") }
                if !ids.contains(v.string!) { ids.append(v.string!) }
            }
            return .success(ids.isEmpty ? .null : .array(ids.map { .string($0) }))
        case .files:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Files must be a list") }
            if list.count > maxList { return fail("At most \(maxList) files") }
            var out: [CrmValue] = []
            var seen: Set<String> = []
            for f in list {
                guard let o = f.object, let id = o["id"]?.string, isUuidLike(id) else { return fail("A file is malformed") }
                let name = String((o["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").prefix(200))
                if name.isEmpty { return fail("A file has no name") }
                let mime = o["mime"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                if seen.insert(id).inserted { out.append(.object(["id": .string(id), "name": .string(name), "mime": mime.map { .string($0) } ?? .null])) }
            }
            return .success(out.isEmpty ? .null : .array(out))
        case .relationship:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Links must be a list") }
            if list.count > maxList { return fail("At most \(maxList) links") }
            let allowed = config.areas ?? []
            var out: [CrmValue] = []
            var seen: Set<String> = []
            for r in list {
                guard let o = r.object, let area = o["area"]?.string, isRelationshipArea(area) else { return fail("A link is malformed") }
                if !allowed.isEmpty && !allowed.contains(area) { return fail("This field does not link that kind of record") }
                let id = o["id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = String(collapse(o["label"]?.string ?? "").prefix(200))
                if id.isEmpty || id.utf16.count > 100 || label.isEmpty { return fail("A link is malformed") }
                guard isInternalHref(o["href"]?.string) else { return fail("A link must point inside the CRM") }
                if seen.insert("\(area):\(id)").inserted {
                    out.append(.object(["area": .string(area), "id": .string(id), "label": .string(label), "href": o["href"]!]))
                }
            }
            return .success(out.isEmpty ? .null : .array(out))
        case .tasks:
            if raw == .null { return .success(.null) }
            guard let list = raw.array else { return fail("Tasks must be a list") }
            if list.count > maxList { return fail("At most \(maxList) tasks") }
            var out: [CrmValue] = []
            var seen: Set<String> = []
            for t in list {
                guard let o = t.object, let id = o["id"]?.string, isUuidLike(id) else { return fail("A task is malformed") }
                let label = String(collapse(o["label"]?.string ?? "").prefix(200))
                if seen.insert(id).inserted { out.append(.object(["id": .string(id), "label": .string(label.isEmpty ? "Task" : label)])) }
            }
            return .success(out.isEmpty ? .null : .array(out))
        case .signature:
            if raw == .null { return .success(.null) }
            guard let o = raw.object else { return fail("A signature is malformed") }
            switch o["mode"]?.string {
            case "drawn":
                guard let d = o["dataUrl"]?.string, isDataImage(d) else { return fail("The drawn signature is not an image") }
                if d.utf16.count > maxSignatureBytes { return fail("The drawn signature is too large") }
                return .success(.object(["mode": .string("drawn"), "dataUrl": .string(d), "by": .string(ctx.userId), "at": .string(ctx.now)]))
            case "typed":
                switch cleanString(o["text"], 80, "Signature", multiline: false) {
                case .failure(let f): return .failure(f)
                case .success(nil): return fail("Type your name to sign")
                case .success(let t?):
                    return .success(.object(["mode": .string("typed"), "text": .string(t), "by": .string(ctx.userId), "at": .string(ctx.now)]))
                }
            default:
                return fail("Draw or type a signature")
            }
        default:
            return fail("Unknown field type")
        }
    }

    /// After "Edit options", what a stored value becomes.
    public static func reconcileValue(_ kind: FieldKind, _ config: FieldConfig, _ value: CrmValue) -> CrmValue {
        if value == .null { return .null }
        switch kind {
        case .dropdown:
            return (config.options ?? []).contains { $0.id == value.string } ? value : .null
        case .labels:
            guard let list = value.array else { return .null }
            let kept = list.filter { v in (config.options ?? []).contains { $0.id == v.string } }
            return kept.isEmpty ? .null : .array(kept)
        case .rating:
            return value.number.map { .number(Swift.min($0, Double(config.max ?? 5))) } ?? .null
        case .progressManual:
            return value.number.map { .number(Swift.min(config.end ?? 100, Swift.max(config.start ?? 0, $0))) } ?? .null
        case .date:
            guard let d = value["date"]?.string else { return .null }
            return .object(["date": .string(d), "time": config.includeTime == true ? (value["time"] ?? .null) : .null])
        case .number, .money:
            return value.number.map { .number(roundTo($0, config.decimals ?? 2)) } ?? .null
        default:
            return value
        }
    }

    // MARK: The formula engine

    enum Tok: Equatable {
        case num(Double)
        case ref(String)
        case fn(String)
        case op(Character)
        case open, close, comma
    }

    static func tokenize(_ src: String) -> FieldRes<[Tok]> {
        let chars = Array(src)
        var out: [Tok] = []
        var i = 0
        func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
        func isWordStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace {
                i += 1
                continue
            }
            if isDigit(ch) || ch == "." {
                var j = i
                var text = ""
                if isDigit(ch) {
                    while j < chars.count, isDigit(chars[j]) { text.append(chars[j]); j += 1 }
                    if j < chars.count, chars[j] == "." {
                        text.append(".")
                        j += 1
                        while j < chars.count, isDigit(chars[j]) { text.append(chars[j]); j += 1 }
                    }
                } else {
                    guard j + 1 < chars.count, isDigit(chars[j + 1]) else { return .failure(FieldFail("Unexpected “\(ch)”")) }
                    text = "0."
                    j += 1
                    while j < chars.count, isDigit(chars[j]) { text.append(chars[j]); j += 1 }
                }
                out.append(.num(Double(text) ?? 0))
                i = j
                continue
            }
            if ch == "{" {
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else { return .failure(FieldFail("A { has no closing }")) }
                let inside = String(chars[(i + 1)..<close])
                let name = collapse(inside)
                if name.isEmpty { return .failure(FieldFail("Empty {} — put a field name inside")) }
                if name.contains("{") { return .failure(FieldFail("Braces cannot be nested")) }
                out.append(.ref(name))
                i = close + 1
                continue
            }
            if isWordStart(ch) {
                var j = i
                var word = ""
                while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { word.append(chars[j]); j += 1 }
                let lower = word.lowercased()
                guard formulaFunctions.contains(lower) else { return .failure(FieldFail("Unknown word “\(word)” — put field names in {braces}")) }
                out.append(.fn(lower))
                i = j
                continue
            }
            switch ch {
            case "+", "-", "*", "/", "%": out.append(.op(ch))
            case "×": out.append(.op("*"))
            case "÷": out.append(.op("/"))
            case "(": out.append(.open)
            case ")": out.append(.close)
            case ",": out.append(.comma)
            default: return .failure(FieldFail("Unexpected “\(ch)”"))
            }
            i += 1
        }
        if out.count > 300 { return .failure(FieldFail("Formula is too long")) }
        return .success(out)
    }

    static let arity: [String: (Int, Int)] = ["round": (1, 2), "min": (1, 20), "max": (1, 20), "abs": (1, 1), "floor": (1, 1), "ceil": (1, 1)]

    private struct Parser {
        let ts: [Tok]
        var pos = 0
        var depth = 0

        func peek() -> Tok? { pos < ts.count ? ts[pos] : nil }

        mutating func expr() -> FieldRes<FormulaAst> {
            depth += 1
            if depth > 64 { return .failure(FieldFail("Formula is nested too deeply")) }
            var node: FormulaAst
            switch term() {
            case .failure(let f): return .failure(f)
            case .success(let n): node = n
            }
            while case .op(let o)? = peek(), o == "+" || o == "-" {
                pos += 1
                switch term() {
                case .failure(let f): return .failure(f)
                case .success(let r): node = .bin(o, node, r)
                }
            }
            depth -= 1
            return .success(node)
        }

        mutating func term() -> FieldRes<FormulaAst> {
            var node: FormulaAst
            switch unary() {
            case .failure(let f): return .failure(f)
            case .success(let n): node = n
            }
            while case .op(let o)? = peek(), o == "*" || o == "/" || o == "%" {
                pos += 1
                switch unary() {
                case .failure(let f): return .failure(f)
                case .success(let r): node = .bin(o, node, r)
                }
            }
            return .success(node)
        }

        mutating func unary() -> FieldRes<FormulaAst> {
            if case .op(let o)? = peek(), o == "-" || o == "+" {
                pos += 1
                depth += 1
                if depth > 64 { return .failure(FieldFail("Formula is nested too deeply")) }
                let e = unary()
                depth -= 1
                guard case .success(let inner) = e else { return e }
                return o == "-" ? .success(.neg(inner)) : e
            }
            return primary()
        }

        mutating func primary() -> FieldRes<FormulaAst> {
            guard let tk = peek() else { return .failure(FieldFail("The formula ends too early")) }
            switch tk {
            case .num(let v):
                pos += 1
                return .success(.num(v))
            case .ref(let name):
                pos += 1
                return .success(.ref(name))
            case .open:
                pos += 1
                let e = expr()
                guard case .success = e else { return e }
                if peek() != .close { return .failure(FieldFail("A ( has no closing )")) }
                pos += 1
                return e
            case .fn(let name):
                pos += 1
                if peek() != .open { return .failure(FieldFail("\(name) needs ( )")) }
                pos += 1
                var args: [FormulaAst] = []
                if peek() != .close {
                    while true {
                        switch expr() {
                        case .failure(let f): return .failure(f)
                        case .success(let a): args.append(a)
                        }
                        if peek() == .comma {
                            pos += 1
                            continue
                        }
                        break
                    }
                }
                if peek() != .close { return .failure(FieldFail("\(name)( has no closing )")) }
                pos += 1
                let (lo, hi) = TaskFields.arity[name] ?? (1, 1)
                if args.count < lo || args.count > hi {
                    return .failure(FieldFail(lo == hi ? "\(name) takes \(lo) value" : "\(name) takes \(lo) to \(hi) values"))
                }
                return .success(.call(name, args))
            case .close: return .failure(FieldFail("Unexpected )"))
            case .comma: return .failure(FieldFail("Unexpected ,"))
            case .op(let o): return .failure(FieldFail("Unexpected “\(o)”"))
            }
        }
    }

    /// Parse only — refuses a malformed expression at the door.
    public static func parseFormula(_ src: String) -> FieldRes<FormulaAst> {
        if src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failure(FieldFail("The formula is empty")) }
        if src.utf16.count > 500 { return .failure(FieldFail("Formula is too long")) }
        let toks: [Tok]
        switch tokenize(src) {
        case .failure(let f): return .failure(f)
        case .success(let t): toks = t
        }
        var p = Parser(ts: toks)
        let root = p.expr()
        guard case .success = root else { return root }
        if p.pos < toks.count {
            return .failure(FieldFail(toks[p.pos] == .close ? "Unexpected )" : "Something is missing between two values"))
        }
        return root
    }

    /// Every {Name} an expression refers to, in order, de-duplicated.
    public static func formulaRefs(_ src: String) -> [String] {
        var out: [String] = []
        for m in src.matches(of: #/\{([^{}]*)\}/#) {
            let name = collapse(String(m.1))
            if !name.isEmpty && !out.contains(where: { sameLabel($0, name) }) { out.append(name) }
        }
        return out
    }

    /// A field was renamed: point {Old} at {New}.
    public static func renameFormulaRefs(_ src: String, from: String, to: String) -> String {
        src.replacing(#/\{([^{}]*)\}/#) { m in sameLabel(String(m.1), from) ? "{\(to)}" : String(m.0) }
    }

    static func evaluate(_ ast: FormulaAst, _ resolve: (String) -> FieldRes<Double>) -> FieldRes<Double> {
        switch ast {
        case .num(let v): return .success(v)
        case .ref(let name): return resolve(name)
        case .neg(let e): return evaluate(e, resolve).map { -$0 }
        case .bin(let op, let l, let r):
            let lv: Double, rv: Double
            switch evaluate(l, resolve) {
            case .failure(let f): return .failure(f)
            case .success(let v): lv = v
            }
            switch evaluate(r, resolve) {
            case .failure(let f): return .failure(f)
            case .success(let v): rv = v
            }
            if (op == "/" || op == "%") && rv == 0 { return .failure(FieldFail("Division by zero")) }
            let v: Double = switch op {
            case "+": lv + rv
            case "-": lv - rv
            case "*": lv * rv
            case "/": lv / rv
            default: lv.truncatingRemainder(dividingBy: rv)
            }
            return v.isFinite ? .success(v) : .failure(FieldFail("The result is too large"))
        case .call(let fn, let args):
            var vals: [Double] = []
            for a in args {
                switch evaluate(a, resolve) {
                case .failure(let f): return .failure(f)
                case .success(let v): vals.append(v)
                }
            }
            switch fn {
            case "round":
                let d = vals.count > 1 ? jsRound(vals[1]) : 0
                if d < 0 || d > 10 { return .failure(FieldFail("round() keeps 0 to 10 decimals")) }
                return .success(roundTo(vals[0], Int(d)))
            case "min": return .success(vals.min() ?? .infinity)
            case "max": return .success(vals.max() ?? -.infinity)
            case "abs": return .success(abs(vals[0]))
            case "floor": return .success(vals[0].rounded(.down))
            default: return .success(vals[0].rounded(.up))
            }
        }
    }

    public static func evaluateFormula(_ src: String, _ resolve: (String) -> FieldRes<Double>) -> FieldRes<Double> {
        switch parseFormula(src) {
        case .failure(let f): return .failure(f)
        case .success(let ast): return evaluate(ast, resolve)
        }
    }

    /// The number a field gives a formula, or why it cannot.
    public static func numericValue(_ f: TaskField) -> FieldRes<Double> {
        switch f.kind {
        case .number, .money, .rating, .progressManual:
            return f.value.number.map { .success($0) } ?? .failure(FieldFail("“\(f.label)” is empty"))
        case .checkbox:
            return .success(f.value == .bool(true) ? 1 : 0)
        case .formula:
            return .failure(FieldFail("A formula cannot use another formula (“\(f.label)”)"))
        default:
            return .failure(FieldFail("“\(f.label)” is not a number field"))
        }
    }

    /// A formula field's result from its siblings' current values.
    public static func computeFormula(_ expression: String?, _ fields: [TaskField]) -> FieldRes<Double> {
        guard let expression, !expression.isEmpty else { return .failure(FieldFail("No formula yet — Edit options to write one")) }
        return evaluateFormula(expression) { name in
            let hits = fields.filter { sameLabel($0.label, name) }
            if hits.isEmpty { return .failure(FieldFail("Unknown field “\(name)”")) }
            if hits.count > 1 { return .failure(FieldFail("Two fields are called “\(name)”")) }
            return numericValue(hits[0])
        }
    }

    // MARK: Progress

    public static func autoProgress(_ config: FieldConfig, _ auto: AutoProgress?) -> (done: Int, total: Int, percent: Int) {
        guard let auto else { return (0, 0, 0) }
        let done = (config.subtasks != false ? auto.subtasksDone : 0) + (config.checklists != false ? auto.checklistsDone : 0)
        let total = (config.subtasks != false ? auto.subtasksTotal : 0) + (config.checklists != false ? auto.checklistsTotal : 0)
        return (done, total, total > 0 ? Int(jsRound(Double(done) / Double(total) * 100)) : 0)
    }

    public static func manualPercent(_ config: FieldConfig, _ value: Double?) -> Int {
        guard let value else { return 0 }
        let start = config.start ?? 0
        let end = config.end ?? 100
        return Int(jsRound(Swift.min(100, Swift.max(0, (value - start) / (end - start) * 100))))
    }

    // MARK: Reading a value as words

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func formatDate(_ date: String, time: String?) -> String {
        guard let m = date.wholeMatch(of: #/(\d{4})-(\d{2})-(\d{2})/#), let mo = Int(m.2), (1...12).contains(mo), let d = Int(m.3) else { return date }
        let s = "\(d) \(months[mo - 1]) \(m.1)"
        if let time, !time.isEmpty { return "\(s) \(time)" }
        return s
    }

    public static func formatNumber(_ n: Double, _ decimals: Int, fixed: Bool = false) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.minimumFractionDigits = fixed ? decimals : 0
        f.maximumFractionDigits = decimals
        f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: n)) ?? js(n)
    }

    public static func formatMoney(_ n: Double, _ currency: String, _ decimals: Int) -> String {
        "\(currency) \(formatNumber(n, decimals, fixed: true))"
    }

    /// A value as one line of words; nil = empty. `names` turns people ids into names.
    public static func formatValue(_ kind: FieldKind, _ c: FieldConfig, _ v: CrmValue, names: (String) -> String? = { _ in nil }) -> String? {
        if v == .null { return nil }
        switch kind {
        case .text, .longText, .website, .email, .phone:
            return v.string
        case .number:
            return v.number.map { formatNumber($0, c.decimals ?? 2) }
        case .money:
            return v.number.map { formatMoney($0, c.currency ?? defaultCurrency, c.decimals ?? 2) }
        case .checkbox:
            return v == .bool(true) ? "Checked" : "Unchecked"
        case .date:
            return v["date"]?.string.map { formatDate($0, time: v["time"]?.string) }
        case .dropdown:
            return (c.options ?? []).first { $0.id == v.string }?.label
        case .labels:
            guard let list = v.array else { return nil }
            let words = list.compactMap { id in (c.options ?? []).first { $0.id == id.string }?.label }.filter { !$0.isEmpty }.joined(separator: ", ")
            return words.isEmpty ? nil : words
        case .rating:
            return v.number.map { "\(js($0))/\(c.max ?? 5)" }
        case .progressManual:
            return v.number.map { "\(manualPercent(c, $0))%" }
        case .location:
            return v["text"]?.string
        case .people:
            return v.array.map { $0.map { names($0.string ?? "") ?? "someone" }.joined(separator: ", ") }
        case .files:
            return v.array.map { $0.map { $0["name"]?.string ?? "" }.joined(separator: ", ") }
        case .relationship, .tasks:
            return v.array.map { $0.map { $0["label"]?.string ?? "" }.joined(separator: ", ") }
        case .signature:
            guard v.object != nil else { return nil }
            return v["mode"]?.string == "typed" ? "Signed “\(jsString(v["text"]))”" : "Signed"
        case .voting:
            return v["votes"]?.object.map { "\($0.count) votes" }
        case .button:
            return v["count"]?.number.map { "Pressed \(js($0))×" }
        default:
            return nil
        }
    }

    // MARK: Rows

    /// A field from the engine. An unknown kind is dropped, not guessed.
    public static func decode(_ raw: Any?) -> TaskField? {
        guard let o = raw as? [String: Any], let id = o["id"] as? String, let kind = (o["kind"] as? String).flatMap(FieldKind.init(rawValue:)) else {
            return nil
        }
        let config = (try? normaliseConfig(kind, CrmValue(o["config"])).get()) ?? defaultConfig(kind)
        return TaskField(id: id, taskId: o["taskId"] as? String ?? "", label: o["label"] as? String ?? "", kind: kind, config: config,
                         value: CrmValue(o["value"]), sortOrder: (o["sortOrder"] as? NSNumber)?.doubleValue,
                         createdBy: o["createdBy"] as? String, createdAt: o["createdAt"] as? String ?? "", updatedAt: o["updatedAt"] as? String)
    }

    public static func decodeAuto(_ raw: Any?) -> AutoProgress? {
        guard let o = raw as? [String: Any] else { return nil }
        let s = o["subtasks"] as? [String: Any] ?? [:]
        let c = o["checklists"] as? [String: Any] ?? [:]
        func n(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        return AutoProgress(subtasksDone: n(s, "done"), subtasksTotal: n(s, "total"), checklistsDone: n(c, "done"), checklistsTotal: n(c, "total"))
    }

    /// Sorted as stored: sort order ascending (none last), then oldest first.
    public static func sorted(_ rows: [TaskField]) -> [TaskField] {
        rows.sorted { a, b in
            let x = a.sortOrder ?? 9_007_199_254_740_991
            let y = b.sortOrder ?? 9_007_199_254_740_991
            if x != y { return x < y }
            return a.createdAt < b.createdAt
        }
    }
}

public indirect enum FormulaAst: Equatable, Sendable {
    case num(Double)
    case ref(String)
    case neg(FormulaAst)
    case bin(Character, FormulaAst, FormulaAst)
    case call(String, [FormulaAst])
}
