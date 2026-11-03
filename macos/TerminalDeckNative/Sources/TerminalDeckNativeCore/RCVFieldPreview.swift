import Foundation

// "What arrives → where it goes" and "Check connection", for any Receiver source. Built from
// one real payload (the latest event, or a sample the owner pastes or the preset ships): every
// mapped value with its preview and its place in a Terminal Deck task, and every value that
// arrives but nothing reads, each with a one-click "Map it". Generic: no source is special.

/// What one task holds now (its own fields by key, its custom fields by label).
public struct RCVTaskSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var values: [String: String]
    public var custom: [String: String]
    public init(id: String, title: String, status: String, values: [String: String], custom: [String: String]) {
        self.id = id; self.title = title; self.status = status; self.values = values; self.custom = custom
    }
}

public struct RCVFieldPreview: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        /// "title", "text", "kind", "severity", "time", "upstreamId", "split", or "fields.<name>".
        public var id: String
        public var name: String
        public var template: String
        public var value: String
        public var destination: String
        /// True when the value lands in one of the task's own fields (or its title or details).
        public var onTask: Bool
    }
    public struct Unmapped: Codable, Equatable, Sendable, Identifiable {
        public var id: String { path }
        /// The path a template would use, e.g. `task.due_date` or `item.from`.
        public var path: String
        public var value: String
        /// The field "Map it" adds.
        public var suggestion: RCVFieldMap
        /// Where that field would land.
        public var destination: String
    }
    /// Where the payload came from: "latest event · 12 Oct 09:12", "sample", "pasted sample".
    public var basis: String
    public var rows: [Row]
    public var unmapped: [Unmapped]
    /// Set when there was nothing to read.
    public var empty: String?

    public static func nothing(_ words: String) -> RCVFieldPreview { .init(basis: "", rows: [], unmapped: [], empty: words) }

    /// The preview of one payload under a source's mapping.
    public static func build(mapping: RCVMapping, body: Data, headers: [String: String] = [:], basis: String) -> RCVFieldPreview {
        let root = RCVEngine.payload(body, contentType: headers["content-type"] ?? "application/json")
        var item: Any?
        var base: Any = root
        if let split = mapping.split, !split.isEmpty {
            let path = split.hasPrefix("$.") ? String(split.dropFirst(2)) : split
            if let list = RCVEngine.walk(root, path) as? [Any], let first = list.first { item = first; base = first }
            else if root is [String: Any] { item = root }   // a kept split event's payload is its own item
        }
        let context = RCVEngine.Context(payload: root, item: item, headers: headers, meta: [:])
        func fill(_ template: String?) -> String {
            guard let template, !template.isEmpty else { return "" }
            return String(((try? RCVEngine.render(template, in: context, limit: 8_000)) ?? "").prefix(300))
        }
        var rows: [Row] = []
        func add(_ id: String, _ name: String, _ template: String?, _ destination: String, onTask: Bool) {
            guard let template, !template.isEmpty else { return }
            rows.append(.init(id: id, name: name, template: template, value: fill(template), destination: destination, onTask: onTask))
        }
        add("title", "Title", mapping.title, "Task · Title", onTask: true)
        add("text", "Text", mapping.text, "Task · Details (through the rule’s words)", onTask: true)
        add("kind", "Type", mapping.kind, "Receiver · event type (rules match on it)", onTask: false)
        add("severity", "Level", mapping.severity, "Receiver · level (rules match on it)", onTask: false)
        add("time", "Time", mapping.time, "Receiver · when it happened", onTask: false)
        add("upstreamId", "Sender’s id", mapping.upstreamId, "Receiver · drops repeats of the same id", onTask: false)
        for field in mapping.fields {
            let destination = RCVTaskMapping.destination(field.name)
            add("fields." + field.name, field.name, field.value, destination.words, onTask: destination.isTaskField || destination == .project)
        }
        // Everything the templates read, as payload paths (item paths made relative to the item).
        var read: [String] = []
        for template in [mapping.title, mapping.text, mapping.kind, mapping.severity, mapping.time ?? "", mapping.upstreamId ?? ""] + mapping.fields.map(\.value) + mapping.ignore.map(\.path) {
            read += paths(in: template, split: item != nil)
        }
        let prefix = item != nil ? "item." : ""
        var unmapped: [Unmapped] = []
        var taken = Set(mapping.fields.map(\.name))
        for leaf in leaves(base) where !read.contains(where: { covers($0, leaf.path) }) {
            var name = suggestedName(leaf.path)
            var n = 2
            while taken.contains(name) { name = String(suggestedName(leaf.path).prefix(37)) + String(n); n += 1 }
            taken.insert(name)
            unmapped.append(.init(path: prefix + leaf.path, value: String(RCVTaskMapping.readable(leaf.value).prefix(300)),
                                  suggestion: RCVFieldMap(name, "{{\(prefix + leaf.path)}}"), destination: RCVTaskMapping.destination(name).words))
        }
        return .init(basis: basis, rows: rows, unmapped: unmapped, empty: nil)
    }

    /// The payload paths one template reads. `{{a.b|"x"}}` reads a.b; header./meta./secret. read no payload.
    static func paths(in template: String, split: Bool) -> [String] {
        guard let placeholders = try? RCVEngine.placeholders(template) else {
            // An ignore path is a bare path, not a template.
            return template.contains("{{") ? [] : normalised(template, split: split).map { [$0] } ?? []
        }
        if placeholders.isEmpty, !template.contains("{{") { return normalised(template, split: split).map { [$0] } ?? [] }
        return placeholders.flatMap { $0.split(separator: "|").map { String($0).trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.hasPrefix("\"") }.compactMap { normalised($0, split: split) }
    }

    static func normalised(_ path: String, split: Bool) -> String? {
        var p = path.trimmingCharacters(in: .whitespaces)
        for skip in ["header.", "meta.", "secret.", "fields."] where p.hasPrefix(skip) { return nil }
        for prefix in ["$.", "raw.", "$", "raw"] where p.hasPrefix(prefix) { p = String(p.dropFirst(prefix.count)); break }
        if p.hasPrefix("item.") { p = String(p.dropFirst(5)) } else if p == "item" { return "" }
        return p.isEmpty ? (split ? "" : nil) : p
    }

    /// True when reading `read` takes in `leaf` (the same path, a path above it, or a path inside a list it is).
    static func covers(_ read: String, _ leaf: String) -> Bool {
        if read.isEmpty { return true }
        return read == leaf || leaf.hasPrefix(read + ".") || leaf.hasPrefix(read + "[") || read.hasPrefix(leaf + "[") || read.hasPrefix(leaf + ".")
    }

    /// Every value that arrives: plain values, and each list as one value. Empty ones are left out.
    static func leaves(_ node: Any, _ path: String = "", depth: Int = 0) -> [(path: String, value: String)] {
        guard depth <= 6 else { return [] }
        if let object = node as? [String: Any] {
            var out: [(path: String, value: String)] = []
            for (key, value) in object.sorted(by: { $0.key < $1.key }) {
                guard key.range(of: #"^[A-Za-z0-9_\-]{1,64}$"#, options: .regularExpression) != nil else { continue }
                let next = path.isEmpty ? key : path + "." + key
                if value is [String: Any] { out += leaves(value, next, depth: depth + 1) }
                else if let list = value as? [Any] { if !list.isEmpty, let text = RCVEngine.text(list) { out.append((next, text)) } }
                else if let text = RCVEngine.text(value), !text.isEmpty { out.append((next, text)) }
                if out.count >= 200 { break }
            }
            return out
        }
        return []
    }

    /// `task.due_date` → `dueDate`, `people.main.name` → `mainName`, `item.from` → `from`.
    static func suggestedName(_ path: String) -> String {
        let parts = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        var words = Array(parts.suffix(parts.count > 1 && ["name", "id", "value", "label", "title"].contains(parts.last!.lowercased()) ? 2 : 1))
        if words.count == 2, ["task", "item", "data", "payload", "event", "record"].contains(words[0].lowercased()) { words.removeFirst() }
        let pieces = words.joined(separator: "_").split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        let camel = pieces.enumerated().map { $0.offset == 0 ? $0.element.prefix(1).lowercased() + $0.element.dropFirst() : $0.element.prefix(1).uppercased() + $0.element.dropFirst() }.joined()
        let clean = camel.filter { $0.isLetter || $0.isNumber }
        return String((clean.isEmpty ? "field" : clean).prefix(40))
    }

    /// The mapping with one more field. Refuses at the field limit or for a name already used.
    public static func mapping(_ mapping: RCVMapping, adding field: RCVFieldMap) -> RCVMapping? {
        guard mapping.fields.count < RCVEngine.maxFields, !mapping.fields.contains(where: { $0.name == field.name }) else { return nil }
        var next = mapping
        next.fields.append(field)
        return next
    }
}

/// "Check connection": the last real event from a source and whether it became a task correctly.
/// Read only: it never sends anything anywhere.
public struct RCVConnectionCheck: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case working, partly, notTask, nothingYet, refused, paused, offline }
    public struct Landing: Codable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var destination: String
        public var expected: String
        public var landed: Bool
    }
    public var sourceId: String
    public var verdict: Verdict
    public var headline: String
    public var lines: [String]
    public var lastEventId: String?
    public var lastAt: Double?
    public var lastKind: String?
    public var lastTitle: String?
    public var taskId: String?
    public var taskTitle: String?
    public var taskStatus: String?
    public var landings: [Landing]

    public static func make(source: RCVSource, active: Bool, relayConnected: Bool, events: [RCVEvent], snapshot: RCVTaskSnapshot?,
                            when: (Double) -> String) -> RCVConnectionCheck {
        let builtIn = source.origin == .terminalDeck
        let refused = events.filter { $0.status == .rejected }
        let last = events.last { $0.status != .rejected }
        var check = RCVConnectionCheck(sourceId: source.id, verdict: .nothingYet, headline: "", lines: [], landings: [])
        if !source.enabled { check.lines.append("This source is paused, so nothing new is taken in. Turn Receiving on in General.") }
        if !builtIn, !relayConnected { check.lines.append("Terminal Deck is not connected to the relay right now, so this address cannot take deliveries until it reconnects.") }
        else if !builtIn, !active { check.lines.append("The relay has not confirmed this address yet.") }
        if let lastRefused = refused.last {
            check.lines.append("\(refused.count) deliver\(refused.count == 1 ? "y was" : "ies were") refused (the last \(when(lastRefused.receivedAt))): \(lastRefused.text)")
        }
        guard let last else {
            if !refused.isEmpty {
                check.verdict = .refused
                check.headline = "Deliveries arrived but were refused: their proof did not match this source’s secret or signature."
            } else if !source.enabled {
                check.verdict = .paused; check.headline = "Paused. Nothing has arrived yet."
            } else if !builtIn, !relayConnected {
                check.verdict = .offline; check.headline = "Nothing has arrived yet, and Terminal Deck is offline from the relay."
            } else {
                check.verdict = .nothingYet
                check.headline = builtIn ? "Nothing has arrived yet. Terminal Deck has not reported any of these events."
                    : "Nothing has arrived yet. The other side hasn’t sent anything to this address — nothing is wrong in Terminal Deck."
            }
            return check
        }
        check.lastEventId = last.id; check.lastAt = last.receivedAt; check.lastKind = last.kind; check.lastTitle = last.title
        check.lines.insert("Last event: \(when(last.receivedAt)) · \(last.kind) · “\(last.title)”.", at: 0)
        if let taskID = last.taskId {
            check.taskId = taskID
            guard let snapshot else {
                check.verdict = .partly
                check.headline = "The last event became a task, but that task is no longer on this Mac (deleted or moved to Trash)."
                return check
            }
            check.taskTitle = snapshot.title; check.taskStatus = snapshot.status
            let fields = RCVTaskMapping.fields(from: last.fields, order: source.mapping.fields.map(\.name))
            for key in fields.keys {
                let expected = fields.text(key)!
                check.landings.append(.init(name: key, destination: "Task · " + RCVTaskMapping.taskLabel(key), expected: expected, landed: snapshot.values[key] == expected))
            }
            for custom in fields.custom {
                let there = snapshot.custom.first { $0.key.lowercased() == custom.label.lowercased() }?.value ?? ""
                check.landings.append(.init(name: custom.name, destination: "Custom field · “\(custom.label)”", expected: custom.value, landed: !there.isEmpty))
            }
            let missed = check.landings.filter { !$0.landed }
            check.lines.append("It became the task “\(snapshot.title)” (\(snapshot.status.isEmpty ? "no status" : snapshot.status)).")
            if missed.isEmpty {
                check.verdict = .working
                check.headline = check.landings.isEmpty ? "Working. The last event became a task." : "Working. The last event became a task and all \(check.landings.count) of its fields landed."
            } else {
                check.verdict = .partly
                check.headline = "Connected. The last event became a task, but \(missed.count) of \(check.landings.count) fields did not land: \(missed.prefix(5).map(\.name).joined(separator: ", "))."
            }
            check.lines += fields.notes
            return check
        }
        if last.sessionId != nil {
            check.verdict = .working; check.headline = "Working. The last event was typed into a running session (no task, by design)."
            return check
        }
        check.verdict = .notTask
        switch last.status {
        case .unrouted: check.headline = "Connected, but the last event did not become a task: no rule took it. Add a rule (Rules tab) that makes a task."
        case .held: check.headline = "Connected. The last event is waiting (quiet hours or a rate limit) and becomes a task when that passes."
        case .failed: check.headline = "Connected, but handing the last event over failed: \(last.outcome ?? "no reason was kept")."
        case .duplicate: check.headline = "Connected. The last event repeated an earlier one (same sender id), so it was not handed on again."
        case .ignored: check.headline = "Connected. The last event matched this source’s ignore list, so it was kept but not handed on."
        case .delivered: check.headline = "Connected. The last event was handed on: \(last.outcome ?? "delivered")."
        case .rejected: check.headline = "The last delivery was refused."
        }
        return check
    }
}
