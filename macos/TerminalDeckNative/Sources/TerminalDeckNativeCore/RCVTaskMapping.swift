import Foundation

// Where an incoming named value lands in a Terminal Deck task. Generic: the NAME of a
// field decides it. A name that matches one of the task's own fields (status, priority,
// dueDate, tags …) fills that field; every other name becomes a custom field on the task,
// labelled from its name. The Receiver (any source) and the CRM task link both use this,
// so a CRM is only a preset of names, never code of its own.

/// Where one named value goes.
public enum RCVTaskDestination: Equatable, Sendable {
    /// One of the task's own fields (`key` is the task's field key).
    case taskField(key: String, label: String)
    /// Decides the task's project (`project`, `projectId`, `cwd`).
    case project
    /// A list of label/value pairs: each pair becomes its own custom field.
    case customFields
    /// A custom field on the task with this label.
    case custom(label: String)

    /// Plain words for the "where it goes" column.
    public var words: String {
        switch self {
        case .taskField(_, let label): "Task · " + label
        case .project: "Task · Project"
        case .customFields: "Custom fields · one per entry"
        case .custom(let label): "Custom field · “\(label)”"
        }
    }
    public var isTaskField: Bool { if case .taskField = self { true } else { false } }
}

/// A custom field to set on a task: its label, its kind (`text`, `long_text`, `website`) and its value.
public struct RCVTaskCustomField: Codable, Equatable, Sendable {
    /// The incoming name it came from.
    public var name: String
    public var label: String
    public var kind: String
    public var value: String
    public init(name: String, label: String, kind: String, value: String) {
        self.name = name; self.label = label; self.kind = kind; self.value = value
    }
}

/// The task fields one incoming item carries, already in the shape a task accepts.
public struct RCVTaskFields: Codable, Equatable, Sendable {
    public var status: String?
    public var priority: String?
    public var startDate: String?
    public var dueDate: String?
    public var startTime: String?
    public var dueTime: String?
    public var labels: [String]?
    public var board: String?
    public var taskType: String?
    public var estimateMinutes: Int?
    public var custom: [RCVTaskCustomField]
    /// Values a task field could not read. Each one is still kept, as a custom field.
    public var notes: [String]

    public init(custom: [RCVTaskCustomField] = [], notes: [String] = []) { self.custom = custom; self.notes = notes }

    public var isEmpty: Bool { RCVTaskMapping.taskKeys.allSatisfy { text($0) == nil } && custom.isEmpty }

    /// One task field's value as plain text (tags joined with ", "), or nil when it carries none.
    public func text(_ key: String) -> String? {
        switch key {
        case "status": status
        case "priority": priority
        case "startDate": startDate
        case "dueDate": dueDate
        case "startTime": startTime
        case "dueTime": dueTime
        case "labels": labels.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
        case "board": board
        case "taskType": taskType
        case "estimateMinutes": estimateMinutes.map(String.init)
        default: nil
        }
    }

    /// The task keys that carry a value, in the task's own order.
    public var keys: [String] { RCVTaskMapping.taskKeys.filter { text($0) != nil } }

    /// Lines for a brief or a task's details: every value, the task's own fields first.
    public func lines() -> [String] {
        keys.map { "\(RCVTaskMapping.taskLabel($0)): \(text($0)!)" } + custom.map { "\($0.label): \($0.value)" }
    }
}

public enum RCVTaskMapping {
    /// The task's own fields a named value can fill, in the task's order.
    public static let taskKeys = ["status", "priority", "startDate", "dueDate", "startTime", "dueTime", "labels", "board", "taskType", "estimateMinutes"]
    public static let statuses = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]
    public static let priorities = ["Low", "Medium", "High", "Critical"]
    /// A task holds at most this many custom fields from one incoming item.
    public static let maxCustom = 40

    /// Field names are matched loosely: case, "_" and "-" do not matter ("due_date" is dueDate).
    static func squash(_ name: String) -> String { name.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " } }

    private static let aliases: [String: String] = [
        "status": "status", "state": "status", "group": "status",
        "priority": "priority",
        "startdate": "startDate", "start": "startDate", "starton": "startDate",
        "duedate": "dueDate", "due": "dueDate", "dueon": "dueDate", "deadline": "dueDate",
        "starttime": "startTime", "duetime": "dueTime",
        "labels": "labels", "tags": "labels",
        "board": "board", "list": "board",
        "tasktype": "taskType",
        "estimateminutes": "estimateMinutes", "timeestimateminutes": "estimateMinutes", "estimate": "estimateMinutes",
    ]

    /// The task field a name fills, or nil when it is a custom field.
    public static func taskKey(_ name: String) -> String? { aliases[squash(name)] }

    public static func taskLabel(_ key: String) -> String {
        switch key {
        case "status": "Status"; case "priority": "Priority"; case "startDate": "Start date"; case "dueDate": "Due date"
        case "startTime": "Start time"; case "dueTime": "Due time"; case "labels": "Tags"; case "board": "Board"
        case "taskType": "Type"; case "estimateMinutes": "Estimate (minutes)"; default: label(key)
        }
    }

    public static func destination(_ name: String) -> RCVTaskDestination {
        let key = squash(name)
        if ["project", "projectid", "cwd"].contains(key) { return .project }
        if key == "customfields" { return .customFields }
        if let task = aliases[key] { return .taskField(key: task, label: taskLabel(task)) }
        return .custom(label: label(name))
    }

    /// "crmTaskId" → "CRM task ID", "assignee_name" → "Assignee name".
    public static func label(_ name: String) -> String {
        var words: [String] = [], current = ""
        let chars = Array(name)
        for (index, c) in chars.enumerated() {
            if c == "_" || c == "-" || c == "." || c == " " { if !current.isEmpty { words.append(current); current = "" }; continue }
            let previous = index > 0 ? chars[index - 1] : " "
            let next = index + 1 < chars.count ? chars[index + 1] : " "
            if c.isUppercase, !current.isEmpty, previous.isLowercase || previous.isNumber || (previous.isUppercase && next.isLowercase) {
                words.append(current); current = ""
            }
            current.append(c)
        }
        if !current.isEmpty { words.append(current) }
        let acronyms: Set<String> = ["id", "url", "crm", "api", "ip", "uuid", "pdf", "sla"]
        let shaped = words.enumerated().map { index, word -> String in
            let lower = word.lowercased()
            if acronyms.contains(lower) { return lower == "uuid" ? "UUID" : lower.uppercased() }
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }
        let text = shaped.joined(separator: " ")
        return String((text.isEmpty ? name : text).prefix(80))
    }

    // MARK: Reading values

    /// To-Do, Working on it, In Progress, Done or Stuck, from common words.
    public static func status(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = statuses.first(where: { $0.lowercased() == word }) { return exact }
        switch word {
        case "todo", "to do", "open", "new", "backlog", "not started", "pending", "queued": return "To-Do"
        case "working", "working-on-it": return "Working on it"
        case "in-progress", "inprogress", "doing", "started", "active", "in review", "review": return "In Progress"
        case "complete", "completed", "closed", "finished", "resolved", "done!": return "Done"
        case "blocked", "on hold", "on-hold", "waiting": return "Stuck"
        default: return nil
        }
    }

    /// Low, Medium, High or Critical.
    public static func priority(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = priorities.first(where: { $0.lowercased() == word }) { return exact }
        switch word {
        case "lowest", "minor", "p3", "p4", "trivial": return "Low"
        case "normal", "moderate", "p2", "default": return "Medium"
        case "major", "p1", "important": return "High"
        case "urgent", "highest", "blocker", "p0", "asap": return "Critical"
        default: return nil
        }
    }

    /// YYYY-MM-DD from a date, a date and time, or Unix seconds/milliseconds.
    public static func date(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 10, text.prefix(10).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let day = String(text.prefix(10))
            return isDay(day) ? day : nil
        }
        guard let number = Double(text), number > 0 else { return nil }
        let date = Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func isDay(_ text: String) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: text) else { return false }
        return formatter.string(from: date) == text
    }

    /// HH:MM from "9:30", "09:30:00" or a date and time ("2026-10-12T09:30:00").
    public static func time(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = text.firstIndex(of: "T"), text.distance(from: text.startIndex, to: t) == 10 { text = String(text[text.index(after: t)...]) }
        guard let match = text.range(of: #"^([01]?\d|2[0-3]):([0-5]\d)"#, options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]) else { return nil }
        return String(format: "%02d:%@", hour, String(parts[1]))
    }

    /// Tags from a JSON list (of words, or of objects with a name/label), or words separated by commas.
    public static func labels(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var words: [String]
        if let list = json(text) as? [Any] { words = list.compactMap { name(of: $0) } }
        else { words = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }).map(String.init) }
        var out: [String] = []
        for word in words {
            let clean = String(word.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if clean.isEmpty || out.contains(clean) { continue }
            out.append(clean)
            if out.count == 20 { break }
        }
        return out
    }

    /// Whole minutes from 0 to 100,000.
    public static func minutes(_ raw: String) -> Int? {
        guard let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, number >= 0, number <= 100_000 else { return nil }
        return Int(number.rounded())
    }

    /// A value as a person reads it: a JSON list becomes its names (or "who: text" lines),
    /// an object its name; anything else stays as it is.
    public static func readable(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = json(text) else { return text }
        if let list = parsed as? [Any] {
            let names = list.compactMap { name(of: $0) }
            if names.isEmpty { return list.isEmpty ? "" : text }
            let long = names.contains { $0.count > 60 || $0.contains("\n") }
            return names.joined(separator: long ? "\n" : ", ")
        }
        return name(of: parsed) ?? text
    }

    /// The best plain name of one JSON value.
    static func name(of value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return RCVEngine.text(number) }
        guard let object = value as? [String: Any] else { return nil }
        func word(_ key: String) -> String? {
            if let text = object[key] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty { return text }
            if let nested = object[key] as? [String: Any] { return nested["name"] as? String ?? nested["label"] as? String }
            return nil
        }
        if let body = word("body") ?? word("text") {
            let who = word("by") ?? word("author") ?? word("authorName")
            return who.map { "\($0): \(body)" } ?? body
        }
        let title = ["name", "title", "label", "file_name", "fileName", "displayName", "handle", "id"].lazy.compactMap(word).first
        guard var title else { return nil }
        if let url = word("url") ?? word("href"), url.hasPrefix("http") { title += " (\(url))" }
        if let done = object["done"] as? Bool { title = (done ? "☑ " : "☐ ") + title }
        return title
    }

    static func json(_ text: String) -> Any? {
        guard let first = text.first, first == "[" || first == "{" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    /// `website` for one web address, `long_text` for long or several-line text, else `text`.
    public static func customKind(_ value: String) -> String {
        if value.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil, value.count <= 2_000 { return "website" }
        return value.count > 500 || value.contains("\n") ? "long_text" : "text"
    }

    // MARK: One item

    /// The task fields one payload carries, read through a mapping (by default the CRM tasks fields).
    /// The CRM task link and the Receiver's Tasks source read the same payload the same way, so what
    /// "Check connection" expects is exactly what the link lands.
    public static func fields(payload: Data, mapping: RCVMapping = RCVPresets.crmTasksMapping) -> RCVTaskFields {
        let source = RCVSource(id: "task-link", name: "Task link", preset: "crm", auth: .init(scheme: .none), mapping: mapping)
        let event = RCVEngine.normalize(body: payload, headers: ["content-type": "application/json"], meta: [:], source: source, receivedAt: 0).first
        return fields(from: event?.fields ?? [:], order: mapping.fields.map(\.name))
    }

    /// The task fields carried by named values (an event's `fields`, or a task link's input).
    /// `order`: the names in the order they were mapped; others follow by name.
    public static func fields(from named: [String: String], order: [String] = []) -> RCVTaskFields {
        var out = RCVTaskFields()
        let names = order.filter { named[$0] != nil } + named.keys.filter { !order.contains($0) }.sorted()
        func keep(_ name: String, _ value: String) {
            guard out.custom.count < maxCustom else { return }
            var label = label(name)
            while out.custom.contains(where: { $0.label.lowercased() == label.lowercased() }) { label += " (2)" }
            let clean = String(value.prefix(5_000))
            out.custom.append(.init(name: name, label: label, kind: customKind(clean), value: clean))
        }
        for name in names {
            guard let raw = named[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw != "null" else { continue }
            switch destination(name) {
            case .project: continue
            case .customFields:
                guard let list = json(raw) as? [Any] else { keep(name, readable(raw)); continue }
                for entry in list {
                    guard let object = entry as? [String: Any] else { continue }
                    let title = (object["label"] ?? object["name"] ?? object["key"]).flatMap { $0 as? String }
                    let shown = (object["shown"] ?? object["value"] ?? object["text"]).flatMap { RCVEngine.text($0) }
                    guard let title, !title.isEmpty, let shown, !shown.isEmpty, shown != "null" else { continue }
                    var label = String(title.prefix(80))
                    while out.custom.contains(where: { $0.label.lowercased() == label.lowercased() }) { label += " (2)" }
                    guard out.custom.count < maxCustom else { break }
                    let value = String(readable(shown).prefix(5_000))
                    out.custom.append(.init(name: name, label: label, kind: customKind(value), value: value))
                }
            case .custom: keep(name, readable(raw))
            case .taskField(let key, let label):
                var read = true
                switch key {
                case "status": if let v = status(raw) { out.status = v } else { read = false }
                case "priority": if let v = priority(raw) { out.priority = v } else { read = false }
                case "startDate": if let v = date(raw) { out.startDate = v } else { read = false }
                case "dueDate": if let v = date(raw) { out.dueDate = v } else { read = false }
                case "startTime": if let v = time(raw) { out.startTime = v } else { read = false }
                case "dueTime": if let v = time(raw) { out.dueTime = v } else { read = false }
                case "labels": let v = labels(raw); if v.isEmpty { read = false } else { out.labels = v }
                case "board": out.board = String(readable(raw).prefix(40))
                case "taskType":
                    let word = raw.lowercased()
                    if ["task", "milestone"].contains(word) { out.taskType = word } else { read = false }
                case "estimateMinutes": if let v = minutes(raw) { out.estimateMinutes = v } else { read = false }
                default: read = false
                }
                if !read {
                    out.notes.append("\(label) “\(String(raw.prefix(60)))” is not something the task’s \(label.lowercased()) can hold, so it is kept as a custom field.")
                    keep(name, readable(raw))
                }
            }
        }
        return out
    }
}
