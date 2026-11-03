import Foundation

/// Presentation keeps the existing routine parser and adds the owning agent/project.
public struct ROUTINESRoutine: Identifiable, Equatable, Sendable {
    public let routine: CopilotRoutine
    public let agentID: String
    public let projectID: String
    public var id: String { routine.id }
    public var on: Bool { routine.enabled && ![.disabled, .paused, .broken, .unarmed].contains(routine.state) }
    public var failed: Bool { routine.lastOutcome == "failed" }
    public var description: String {
        if routine.consecutiveFailures >= 5, routine.state == .paused { return "Paused after \(routine.consecutiveFailures) failures in a row." }
        if routine.state == .broken || routine.state == .unarmed { return routine.reason ?? routine.problems.first ?? "Needs a look." }
        return routine.prompt.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }
    public static func list(_ raw: CodingAIJSON, projects: [PROJProject] = PROJProjects.defaults) -> [Self] {
        (raw.array ?? []).compactMap { value in
            guard let routine = CopilotRoutine.list(.array([value])).first else { return nil }
            let agent = value["agentId"].text ?? value["agentID"].text ?? "@hoot"
            let candidate = value["projectId"].text
            let explicitID = candidate.flatMap { PROJProjects.isValidID($0) ? $0 : nil }
            let project: String
            if candidate == nil, agent == "@hoot" { project = "every-project" }
            else { project = PROJProjects.resolve(projectID: value["projectIdInferred"].isTrue ? nil : explicitID, folder: routine.folder, projects: projects) }
            return .init(routine: routine, agentID: agent, projectID: project)
        }
    }
    public init(routine: CopilotRoutine, agentID: String = "@hoot", projectID: String = "every-project") {
        self.routine = routine; self.agentID = agentID; self.projectID = projectID
    }
}

public enum ROUTINESFilter: String, CaseIterable, Sendable {
    case all, on, off, failed
    public var title: String { switch self { case .all: "All"; case .on: "On"; case .off: "Off"; case .failed: "Failed last time" } }
    public func accepts(_ routine: ROUTINESRoutine) -> Bool {
        switch self { case .all: true; case .on: routine.on; case .off: !routine.on; case .failed: routine.failed }
    }
}

public struct ROUTINESRun: Identifiable, Equatable, Sendable {
    public let id: String, routineID: String, agentID: String, result: String
    public let when: Double
    public let tookMs: Double?, tokens: Double?, sessionIDs: [String], error: String?, output: String?
    public static func list(_ value: CodingAIJSON) -> [Self] {
        (value.array ?? value["runs"].array ?? []).compactMap { row in
            guard let id = row["runId"].text ?? row["id"].text, let routine = row["routine"].text ?? row["routineId"].text else { return nil }
            // When it started: the reducer keeps the first ("started") row's time as startedAt.
            func ms(_ v: CodingAIJSON) -> Double? { v.number ?? v.string.flatMap { ISO8601DateFormatter().date(from: $0)?.timeIntervalSince1970 }.map { $0 * 1_000 } }
            let time = ms(row["startedAt"]) ?? ms(row["at"]) ?? 0
            let rawTokens = row["tokens"].number ?? row["data"]["tokens"].number
            let tokens = rawTokens.flatMap { $0 >= 0 && $0 < Double(Int.max) ? $0 : nil }
            return .init(id: id, routineID: routine, agentID: row["agentId"].text ?? "@hoot", result: row["outcome"].text ?? "running", when: time,
                         tookMs: row["ms"].number ?? row["data"]["ms"].number, tokens: tokens,
                         sessionIDs: (row["sessions"].array ?? row["data"]["sessions"].array ?? []).compactMap(\.text), error: row["detail"].text, output: row["data"]["output"].text)
        }.sorted { $0.when > $1.when }
    }
}

/// The short form edits only its own header keys. Limits, comments, unknown keys,
/// additional triggers and file provenance survive an edit unchanged.
public struct ROUTINESDraft: Identifiable, Equatable, Sendable {
    public var id: String, name = "", agentID = "@hoot", projectID = "every-project", folder = "", prompt = "", enabled = true
    public var whenKind = "schedule", schedule = "daily", time = "08:30", day = "mon", hours = 6, event = "session-failed", glob = "**/*"
    public var overlap = "queue", catchUp = "legacy", maxPending = 10, maxCatchUp = 5
    public var originalText = ""
    /// SETTINGS-TRUTH row 92: the argument of an alert or session-idle trigger ("alert session-blocked",
    /// "session-idle 15m"), kept while the event stays the one read from the file.
    public var argument = "", readEvent = ""
    public init(id: String = "") { self.id = id }
    public var trigger: String {
        if whenKind == "event" {
            if event == "file-change" { return "file-change " + glob }
            if event == readEvent, !argument.isEmpty { return event + " " + argument }
            if event == "session-idle" { return "session-idle 15m" }   // the file needs a duration
            return event
        }
        switch schedule { case "weekdays": return "schedule \(time) weekdays"; case "weekly": return "schedule \(time) \(day)"; case "hours": return "schedule every \(hours)h"; default: return "schedule " + time }
    }
    public var problem: String? {
        if !["queue", "merge", "queue-all", "skip", "cancel"].contains(overlap) { return "Choose what happens while busy." }
        if !["legacy", "skip", "once", "replay"].contains(catchUp) { return "Choose what happens to missed schedules." }
        if !(1...100).contains(maxPending) || !(1...50).contains(maxCatchUp) { return "Use a queue limit from 1 to 100 and replay limit from 1 to 50." }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the routine a name." }
        if name.count > 80 { return "Keep the name under 80 characters." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Tell the agent what to do." }
        if prompt.utf8.count > 8_192 { return "Keep the instructions under 8 KB." }
        if folder.isEmpty { return "Choose a project folder for this routine." }
        if hours < 1 || hours > 168 { return "Use between 1 and 168 hours." }
        let parts = time.split(separator: ":")
        if whenKind == "schedule", schedule != "hours", (parts.count != 2 || Int(parts[0]).map { !(0...23).contains($0) } != false || Int(parts[1]).map { !(0...59).contains($0) } != false) { return "Use a real time, such as 08:30." }
        if whenKind == "event", event == "file-change", glob.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a file pattern, such as src/**." }
        if [name, agentID, projectID, folder, glob].contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains("\0") }) { return "A name, project or file pattern must fit on one line." }
        return nil
    }
    public static func read(id: String, text: String) -> Self {
        var draft = Self(id: id); draft.originalText = text
        let lines = text.components(separatedBy: .newlines), boundary = lines.firstIndex(of: "---") ?? lines.count
        draft.prompt = lines.dropFirst(min(boundary + 1, lines.count)).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let heading = lines.prefix(boundary).first(where: { $0.hasPrefix("# ") }) { draft.name = String(heading.dropFirst(2)) }
        var firstTrigger: String?
        for line in lines.prefix(boundary) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "agent-id": draft.agentID = value
            case "project-id": draft.projectID = value
            case "in": draft.folder = value
            case "enabled": draft.enabled = !["no", "false", "off", "0"].contains(value.lowercased())
            case "overlap": draft.overlap = value
            case "catch-up": draft.catchUp = value
            case "max-pending": draft.maxPending = Int(value) ?? 0
            case "max-catch-up": draft.maxCatchUp = Int(value) ?? 0
            case "when": if firstTrigger == nil { firstTrigger = value }
            default: break
            }
        }
        if let when = firstTrigger {
            if when.hasPrefix("schedule ") {
                let raw = String(when.dropFirst(9)), words = raw.split(separator: " ").map(String.init)
                if raw.hasPrefix("every "), raw.hasSuffix("h"), let n = Int(raw.dropFirst(6).dropLast()) { draft.schedule = "hours"; draft.hours = n }
                else {
                    draft.time = words.first ?? "08:30"
                    if words.count > 1 { if words[1] == "weekdays" || words[1] == "mon,tue,wed,thu,fri" { draft.schedule = "weekdays" } else { draft.schedule = "weekly"; draft.day = words[1] } }
                }
            } else {
                draft.whenKind = "event"; let words = when.split(separator: " ", maxSplits: 1).map(String.init); draft.event = words.first ?? "session-failed"
                if draft.event == "file-change" { draft.glob = words.count > 1 ? words[1] : "**/*" }
                else { draft.readEvent = draft.event; draft.argument = words.count > 1 ? words[1] : "" }
            }
        }
        return draft
    }
    public var text: String {
        let edited: Set<String> = ["when", "agent-id", "project-id", "in", "enabled", "overlap", "catch-up", "max-pending", "max-catch-up"]
        let lines = originalText.components(separatedBy: .newlines), boundary = lines.firstIndex(of: "---") ?? lines.count
        var retained: [String] = [], seenHeading = false, replacedTrigger = false
        for line in lines.prefix(boundary) {
            if line.hasPrefix("# "), !seenHeading { seenHeading = true; continue }
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "when" { if !replacedTrigger { replacedTrigger = true; continue } else { retained.append(line); continue } }
                if edited.contains(key) { continue }
            }
            if !line.isEmpty { retained.append(line) }
        }
        var policies: [String] = []
        // Keep an explicit legacy queue header when the original file had one.
        if overlap != "queue" || originalText.components(separatedBy: .newlines).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "overlap: queue" }) { policies.append("overlap: " + overlap) }
        if catchUp != "legacy" { policies.append("catch-up: " + catchUp) }
        if maxPending != 10 { policies.append("max-pending: \(maxPending)") }
        if maxCatchUp != 5 { policies.append("max-catch-up: \(maxCatchUp)") }
        return (["# " + name, "", "when: " + trigger, "agent-id: " + agentID, "project-id: " + projectID, "in: " + folder, "enabled: " + (enabled ? "yes" : "no")] + policies + retained + ["", "---", "", prompt, ""]).joined(separator: "\n")
    }
    public static func settingEnabled(_ text: String, to on: Bool) -> String {
        var lines = text.components(separatedBy: "\n"), found = false
        let boundary = lines.firstIndex(of: "---") ?? lines.count
        for index in 0..<boundary {
            guard let colon = lines[index].firstIndex(of: ":"), lines[index][..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "enabled" else { continue }
            lines[index] = "enabled: " + (on ? "yes" : "no"); found = true
        }
        if !found { lines.insert("enabled: " + (on ? "yes" : "no"), at: boundary) }
        return lines.joined(separator: "\n")
    }
}

public enum ROUTINESWords {
    public static func when(_ triggers: [String]) -> String {
        guard let trigger = triggers.first else { return "No trigger" }
        if trigger.hasPrefix("schedule every ") { return "Every " + trigger.dropFirst(15).replacingOccurrences(of: "h", with: " hours").replacingOccurrences(of: "m", with: " minutes").replacingOccurrences(of: "d", with: " days") }
        if trigger.hasPrefix("schedule ") {
            let words = trigger.dropFirst(9).split(separator: " ").map(String.init), clock = words.first ?? ""
            guard words.count > 1 else { return "Every day at " + clock }
            if words[1] == "weekdays" || words[1] == "mon,tue,wed,thu,fri" { return "Weekdays at " + clock }
            let days = ["mon":"Mondays", "tue":"Tuesdays", "wed":"Wednesdays", "thu":"Thursdays", "fri":"Fridays", "sat":"Saturdays", "sun":"Sundays"]
            return (days[words[1]] ?? words[1]) + " at " + clock
        }
        switch trigger {
        case "session-failed": return "When a session fails"
        case "session-finished": return "When a session finishes"
        case "task-created": return "When a task is created"
        case "task-finished": return "When a task is finished"
        default: return trigger.hasPrefix("file-change") ? "When a file changes" : trigger.replacingOccurrences(of: "-", with: " ")
        }
    }
    public static func date(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "never run" }
        let date = Date(timeIntervalSince1970: milliseconds / 1_000)
        if Calendar.current.isDateInToday(date) { return "today " + date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
    public static func subtitle(_ routines: [ROUTINESRoutine]) -> String {
        var result = "\(routines.count) \(routines.count == 1 ? "routine" : "routines")"
        if let next = routines.filter(\.on).filter({ $0.routine.nextDueAt != nil }).min(by: { $0.routine.nextDueAt! < $1.routine.nextDueAt! }) {
            result += " · next: \(next.routine.name), \(Date(timeIntervalSince1970: next.routine.nextDueAt! / 1_000).formatted(date: .omitted, time: .shortened))"
        }
        return result
    }
}
