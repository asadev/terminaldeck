import Foundation

// The Activity column's rules (src/renderer/crm-task/activity-feed.tsx): each
// activity row said in words, the filter categories, consecutive checklist adds
// gathered into one line, comments threaded, the feed in time order.

public enum FeedPart: Equatable, Sendable {
    case text(String)
    case strong(String)
    case flag(String)
    case timer
}

public enum FeedCategory: String, Equatable, Sendable, CaseIterable {
    case comments, status, people, dates, priority, subtasks, checklists, attachments, relationships, time, details

    public var label: String {
        switch self {
        case .comments: "Comments"
        case .status: "Status"
        case .people: "Assignees"
        case .dates: "Dates"
        case .priority: "Priority"
        case .subtasks: "Subtasks"
        case .checklists: "Checklists"
        case .attachments: "Attachments"
        case .relationships: "Relationships"
        case .time: "Time tracking"
        case .details: "Name, description, tags, type & moves"
        }
    }
}

public enum FeedEntry: Equatable, Sendable, Identifiable {
    case activity(id: String, at: String, actor: CrmPerson?, actorId: String?, parts: [FeedPart], text: String, category: FeedCategory?)
    case comment(TaskComment)

    public var id: String {
        switch self {
        case .activity(let id, _, _, _, _, _, _): id
        case .comment(let c): c.id
        }
    }

    public var at: String {
        switch self {
        case .activity(_, let at, _, _, _, _, _): at
        case .comment(let c): c.createdAt
        }
    }
}

public enum ActivityFeedRules {
    public static func partsText(_ parts: [FeedPart]) -> String {
        parts.map { p -> String in
            switch p {
            case .text(let s), .strong(let s): s
            case .flag, .timer: ""
            }
        }.joined()
    }

    public static func category(_ kind: String) -> FeedCategory? {
        switch kind {
        case "title", "description", "map", "tags", "task_type", "moved", "field", "archived", "merged": .details
        case "status": .status
        case "priority": .priority
        case "dates", "recurrence": .dates
        case "assigned", "unassigned", "follower": .people
        case "subtask_added", "subtask_done", "converted": .subtasks
        case "checklist_added", "checklist_item": .checklists
        case "dependency": .relationships
        case "attachment": .attachments
        case "comment": .comments
        case "time_tracked", "estimate": .time
        default: nil
        }
    }

    /// "Today", "Tomorrow", "Yesterday", "7 Oct" (· year when not this year).
    public static func relativeDay(_ ymd: String, today: String) -> String {
        guard TaskList.isYmd(ymd) else { return ymd }
        switch TaskList.ymdDiff(today, ymd) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let p = ymd.split(separator: "-").compactMap { Int($0) }
            let label = "\(p[2]) \(TaskList.monthShort[p[1] - 1])"
            return p[0] == Int(today.prefix(4)) ? label : "\(label) \(p[0])"
        }
    }

    static func monthDayOf(_ ymd: String?) -> String {
        guard let ymd else { return "" }
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count >= 3, (1...12).contains(p[1]), p[2] > 0 else { return ymd }
        return "\(TaskList.monthShort[p[1] - 1]) \(p[2])"
    }

    static func statusWord(_ s: String?) -> String {
        guard let s else { return "" }
        return ["To-Do", "Working on it", "In Progress", "Done", "Stuck"].contains(s) ? CrmText.statusWord(s) : s.uppercased()
    }

    /// One field activity line (task-fields.ts `fieldActivitySentence`).
    public static func fieldSentence(_ actor: String, _ p: [String: CrmValue]) -> String {
        func s(_ k: String) -> String? { p[k]?.string }
        let label = s("label") ?? "a field"
        switch s("action") {
        case "added": return "\(actor) added field: \(label)"
        case "removed": return "\(actor) removed field: \(label)"
        case "renamed": return "\(actor) renamed field: \(s("from") ?? "") → \(s("to") ?? "")"
        case "options": return "\(actor) edited the options of \(label)"
        case "voted": return "\(actor) \(s("to") == "voted" ? "voted on" : "took back a vote on") \(label)"
        case "pressed": return "\(actor) pressed \(label)"
        default:
            let from = s("from"), to = s("to")
            if to == nil { return "\(actor) cleared \(label)" }
            return from == nil ? "\(actor) set \(label): \(to!)" : "\(actor) changed \(label): \(from!) → \(to!)"
        }
    }

    /// One activity row in words.
    public static func describe(_ row: TaskActivityRow, viewer: String, today: String, who: (String?) -> String?) -> [FeedPart] {
        let actor = row.actorUserId == viewer ? "You" : row.actor?.name ?? "Someone"
        let p = row.payload
        func str(_ k: String) -> String? { p[k]?.string }
        func num(_ k: String) -> Double? { p[k]?.number }
        func person(_ idKey: String, _ nameKey: String) -> String {
            let id = str(idKey)
            if let id, id == viewer { return "You" }
            return str(nameKey) ?? who(id) ?? "someone"
        }
        switch row.kind {
        case "created":
            return [.text("\(actor) created this task")]
        case "assigned":
            return p["primary"]?.bool == false ? [.text("\(actor) added "), .strong(person("user_id", "name"))]
                : [.text("\(actor) assigned to: "), .strong(person("user_id", "name"))]
        case "unassigned":
            return [.text("\(actor) removed assignee: "), .strong(person("user_id", "name"))]
        case "status":
            if let from = str("from") {
                return [.text("\(actor) changed status from "), .strong(statusWord(from)), .text(" to "), .strong(statusWord(str("to")))]
            }
            return [.text("\(actor) set status to "), .strong(statusWord(str("to")))]
        case "priority":
            if let to = str("to") { return [.text("\(actor) set priority to "), .flag(to), .strong(to)] }
            return [.text("\(actor) removed the priority")]
        case "dates":
            if let sync = p["sync"]?.bool { return [.text("\(actor) turned \(sync ? "on" : "off") "), .strong("Sync dates with subtasks")] }
            var out: [FeedPart] = []
            func pair(_ label: String, _ from: String?, _ to: String?, day: Bool) {
                if from == to { return }
                if !out.isEmpty { out.append(.text(" · ")) }
                let shown = { (v: String) in day ? relativeDay(v, today: today) : v }
                if to == nil { out.append(.text("\(actor) removed the \(label)")) }
                else if from == nil { out.append(contentsOf: [.text("\(actor) set the \(label) to "), .strong(shown(to!))]) }
                else { out.append(contentsOf: [.text("\(actor) changed the \(label) from "), .strong(shown(from!)), .text(" to "), .strong(shown(to!))]) }
            }
            pair("start date", str("start_from"), str("start_to"), day: true)
            pair("due date", str("due_from"), str("due_to"), day: true)
            pair("start time", str("start_time_from"), str("start_time_to"), day: false)
            pair("due time", str("due_time_from"), str("due_time_to"), day: false)
            if p["synced"]?.bool == true, !out.isEmpty {
                return [.text("Synced from a subtask change by \(actor): ")] + out.map { part in
                    if case .text(let t) = part { return .text(t.replacingOccurrences(of: "\(actor) ", with: "")) }
                    return part
                }
            }
            return out.isEmpty ? [.text("\(actor) changed the dates")] : out
        case "title":
            return [.text("\(actor) renamed this task")]
        case "description":
            return [.text("\(actor) updated the description")]
        case "archived":
            return [.text("\(actor) \(p["on"]?.bool == true ? "archived this task" : "restored this task from the archive")")]
        case "follower":
            if let target = str("user"), target != row.actorUserId {
                let name = target == viewer ? "you" : who(target) ?? "someone"
                return p["following"]?.bool == true ? [.text("\(actor) added "), .strong(name), .text(" as a follower")]
                    : [.text("\(actor) removed "), .strong(name), .text(" from the followers")]
            }
            return [.text("\(actor) \(p["following"]?.bool == true ? "is following" : "unfollowed") this task")]
        case "merged":
            if str("into") != nil { return [.text("\(actor) merged this task into "), .strong(str("title") ?? "another task")] }
            let joined = (p["people_added"]?.array ?? []).compactMap(\.string).map { who($0) ?? "someone" }
            let kept: [String] = {
                if let s = p["fields_kept"]?.string { return s.isEmpty ? [] : [s] }
                return (p["fields_kept"]?.array ?? []).compactMap { f in
                    guard let o = f.object else { return nil }
                    let label = o["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "A field"
                    let value: String = {
                        switch o["value"] {
                        case .string(let s)?: return s
                        case nil, .null?: return ""
                        case .number(let n)?: return n == n.rounded() ? String(Int(n)) : String(n)
                        case .bool(let b)?: return b ? "true" : "false"
                        default: return ""
                        }
                    }()
                    return "\(label): \(value.prefix(80))"
                }
            }()
            func more(_ k: String) -> String { (num(k) ?? 0) > 0 ? " and \(Int(num(k)!)) more" : "" }
            var out: [FeedPart] = [.text("\(actor) merged "), .strong(str("title") ?? "a task"), .text(" into this task")]
            if !joined.isEmpty { out += [.text(" and added "), .strong(joined.joined(separator: ", ") + more("people_added_more"))] }
            if !kept.isEmpty {
                out += [.text(" — its values set aside (this task's were kept): "), .strong(kept.joined(separator: "; ") + more("fields_kept_more"))]
            } else if let n = num("fields_kept_more"), n > 0 {
                out.append(.text(" — \(Int(n)) values set aside were too long to show here"))
            }
            return out
        case "converted":
            return [.text("\(actor) converted this task into a subtask")]
        case "subtask_added":
            return [.text("\(actor) created subtask: "), .strong(str("title") ?? "")]
        case "subtask_done":
            return [.text("\(actor) \(p["done"]?.bool == true ? "completed" : "reopened") subtask: "), .strong(str("title") ?? "")]
        case "checklist_added":
            return [.text("\(actor) created checklist "), .strong(str("title") ?? "Checklist")]
        case "checklist_item":
            if p["done"] == nil || p["done"] == .null {
                return [.text("\(actor) added an item to a checklist: "), .strong(str("title") ?? "")]
            }
            return [.text("\(actor) \(p["done"]?.bool == true ? "checked" : "unchecked") "), .strong(str("title") ?? "")]
        case "dependency":
            if p["removed"]?.bool == true { return [.text("\(actor) removed a relationship with "), .strong(str("title") ?? "another task")] }
            let rel = str("kind") == "blocked_by" ? "is waiting on" : str("kind") == "blocks" ? "is blocking" : "is linked to"
            return [.text("\(actor) marked this task \(rel) "), .strong(str("title") ?? "another task")]
        case "attachment":
            return [.text("\(actor) \(p["removed"]?.bool == true ? "removed" : "attached") "), .strong(str("file_name") ?? "a file")]
        case "comment":
            return [.text("\(actor) commented")]
        case "time_tracked":
            if p["tags_to"] != nil || p["tags_from"] != nil {
                if let tags = str("tags_to"), !tags.isEmpty { return [.text("\(actor) tagged a time entry "), .strong(tags)] }
                return [.text("\(actor) removed a time entry's tags")]
            }
            return [.text("\(actor) tracked time "), .timer, .strong(CrmTime.duration(num("seconds") ?? 0)), .text(" on \(monthDayOf(str("on")))")]
        case "estimate":
            if let to = num("to") { return [.text("\(actor) set the time estimate to "), .strong(CrmTime.duration(to * 60))] }
            return [.text("\(actor) removed the time estimate")]
        case "tags":
            if let added = str("added"), !added.isEmpty { return [.text("\(actor) added tag "), .strong(added)] }
            return [.text("\(actor) removed tag "), .strong(str("removed") ?? "")]
        case "task_type":
            return [.text("\(actor) changed task type to "), .strong(str("to") == "milestone" ? "Milestone" : "Task")]
        case "moved":
            return [.text("\(actor) moved this task to "), .strong(CrmText.boardLabel(str("to") ?? ""))]
        case "recurrence":
            if p["restarted"]?.bool == true { return [.text("\(actor) restarted this routine")] }
            if let to = str("to") { return [.text("\(actor) set this task to repeat "), .strong(to)] }
            return [.text("\(actor) stopped this task repeating")]
        case "field":
            return [.text(fieldSentence(actor, p))]
        case "map":
            let topic = str("topic")
            let sub = str("title") ?? topic ?? "a subtask"
            switch str("action") {
            case "made": return [.text("\(actor) made this task from a topic on a mind map")]
            case "made_subtask": return [.text("\(actor) made subtask "), .strong(topic ?? ""), .text(" from a topic on a mind map")]
            case "linked": return [.text("\(actor) linked this task to a topic on a mind map")]
            case "unlinked":
                return str("subtask_id") != nil ? [.text("\(actor) took subtask "), .strong(topic ?? ""), .text(" off its mind map topic")]
                    : [.text("\(actor) took this task off its mind map topic")]
            case "promoted": return [.text("\(actor) made this task from a subtask moved on a mind map")]
            case "subtask_moved_out": return [.text("\(actor) moved subtask "), .strong(sub), .text(" to another task on a mind map")]
            case "subtask_promoted": return [.text("\(actor) turned subtask "), .strong(sub), .text(" into a task of its own on a mind map")]
            default: return [.text("\(actor) changed this task on a mind map")]
            }
        default:
            return [.text("\(actor) changed this task")]
        }
    }

    /// The feed in time order: activity lines (checklist adds by one person within ten
    /// minutes gathered into "added n items"), then the comments, sorted together.
    public static func build(_ rows: [TaskActivityRow], comments: [TaskComment], viewer: String, today: String,
                             who: (String?) -> String?) -> [FeedEntry] {
        var entries: [FeedEntry] = []
        for r in rows where r.kind != "comment" {
            let isAdd = r.kind == "checklist_item" && (r.payload["done"] == nil || r.payload["done"] == .null)
            if isAdd, case .activity(let prevId, let prevAt, let actor, let actorId, _, _, let cat)? = entries.last,
               prevId.hasPrefix("group:"), actorId == r.actorUserId,
               let a = CrmTime.date(r.createdAt), let b = CrmTime.date(prevAt), a.timeIntervalSince(b) < 600 {
                let n = (Int(prevId.split(separator: ":").last ?? "1") ?? 1) + 1
                let name = r.actorUserId == viewer ? "You" : r.actor?.name ?? "Someone"
                let parts: [FeedPart] = [.text("\(name) added "), .strong("\(n) items"), .text(" to a checklist")]
                entries[entries.count - 1] = .activity(id: "group:\(r.id):\(n)", at: r.createdAt, actor: actor, actorId: actorId,
                                                       parts: parts, text: partsText(parts), category: cat)
                continue
            }
            let parts = describe(r, viewer: viewer, today: today, who: who)
            entries.append(.activity(id: isAdd ? "group:\(r.id):1" : r.id, at: r.createdAt, actor: r.actor, actorId: r.actorUserId,
                                     parts: parts, text: partsText(parts), category: category(r.kind)))
        }
        for c in comments { entries.append(.comment(c)) }
        return entries.enumerated().sorted { l, r in
            let a = CrmTime.date(l.element.at)?.timeIntervalSince1970 ?? 0
            let b = CrmTime.date(r.element.at)?.timeIntervalSince1970 ?? 0
            return a != b ? a < b : l.offset < r.offset
        }.map(\.element)
    }
}
