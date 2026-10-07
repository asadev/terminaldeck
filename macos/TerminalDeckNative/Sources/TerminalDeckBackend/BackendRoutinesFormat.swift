import Foundation
import TerminalDeckNativeCore

public enum BackendRoutinesOverlapPolicy: String, Sendable, Equatable { case queue, skip, cancel }

public enum BackendRoutinesTrigger: Sendable, Equatable {
    case sessionFinished, sessionFailed
    case sessionIdle(afterMs: Double)
    case alert(severity: String?, alertKind: String?)
    case gitChange
    case fileChange(glob: String)
    case schedule(BackendRoutinesSchedule)
    case manual
    public var kind: String {
        switch self {
        case .sessionFinished: return "session-finished"
        case .sessionFailed: return "session-failed"
        case .sessionIdle: return "session-idle"
        case .alert: return "alert"
        case .gitChange: return "git-change"
        case .fileChange: return "file-change"
        case .schedule: return "schedule"
        case .manual: return "manual"
        }
    }
    public var wire: NativeRPCValue {
        var fields: [(String, NativeRPCValue)] = [("kind", .string(kind))]
        switch self {
        case .sessionIdle(let after): fields.append(("afterMs", .number(after)))
        case .alert(let severity, let alertKind): fields += [("severity", BackendRoutinesValues.text(severity)), ("alertKind", BackendRoutinesValues.text(alertKind))]
        case .fileChange(let glob): fields.append(("glob", .string(glob)))
        case .schedule(let schedule): fields.append(("schedule", schedule.wire))
        default: break
        }
        return BackendRoutinesValues.object(fields)
    }
}

public struct BackendRoutinesRoutine: Sendable, Equatable {
    public var id: String, name: String, triggers: [BackendRoutinesTrigger], folder: String, prompt: String
    public var enabled: Bool, overlap: BackendRoutinesOverlapPolicy, maxRunsPerHour: Int, maxRunsPerDay: Int
    public var quietForMs: Double, expectEveryMs: Double?, unknown: [String: [String]]
    /// Dictionary iteration is unordered in Swift; preserve header-key order separately.
    public var unknownKeyOrder: [String]
    public init(id: String, name: String, triggers: [BackendRoutinesTrigger], folder: String, prompt: String,
                enabled: Bool = true, overlap: BackendRoutinesOverlapPolicy = .queue,
                maxRunsPerHour: Int = BackendRoutinesFormat.defaultMaxRunsPerHour,
                maxRunsPerDay: Int = BackendRoutinesFormat.defaultMaxRunsPerDay,
                quietForMs: Double = BackendRoutinesFormat.defaultQuietForMs, expectEveryMs: Double? = nil,
                unknown: [String: [String]] = [:], unknownKeyOrder: [String] = []) {
        self.id = id; self.name = name; self.triggers = triggers; self.folder = folder; self.prompt = prompt
        self.enabled = enabled; self.overlap = overlap; self.maxRunsPerHour = maxRunsPerHour; self.maxRunsPerDay = maxRunsPerDay
        self.quietForMs = quietForMs; self.expectEveryMs = expectEveryMs; self.unknown = unknown; self.unknownKeyOrder = unknownKeyOrder
    }
    public var orderedUnknownKeys: [String] {
        var seen = Set<String>(), keys: [String] = []
        for key in unknownKeyOrder + unknown.keys.sorted() where unknown[key] != nil && seen.insert(key).inserted { keys.append(key) }
        // JavaScript Object.entries prints canonical integer keys first.
        let numeric = keys.compactMap { key -> (String, UInt32)? in
            guard let integer = UInt32(key), integer < UInt32.max, String(integer) == key else { return nil }; return (key, integer)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        return numeric + keys.filter { !numeric.contains($0) }
    }
    public var wire: NativeRPCValue { BackendRoutinesValues.object([
        ("id", .string(id)), ("name", .string(name)), ("triggers", .array(triggers.map(\.wire))),
        ("folder", .string(folder)), ("prompt", .string(prompt)), ("enabled", .bool(enabled)),
        ("overlap", .string(overlap.rawValue)), ("maxRunsPerHour", .number(Double(maxRunsPerHour))),
        ("maxRunsPerDay", .number(Double(maxRunsPerDay))), ("quietForMs", .number(quietForMs)),
        ("expectEveryMs", BackendRoutinesValues.number(expectEveryMs)),
        ("unknown", .object(orderedUnknownKeys.map { .init($0, .array((unknown[$0] ?? []).map(NativeRPCValue.string))) }))]) }
    public static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.name == right.name && left.triggers == right.triggers && left.folder == right.folder &&
        left.prompt == right.prompt && left.enabled == right.enabled && left.overlap == right.overlap &&
        left.maxRunsPerHour == right.maxRunsPerHour && left.maxRunsPerDay == right.maxRunsPerDay &&
        left.quietForMs == right.quietForMs && left.expectEveryMs == right.expectEveryMs && left.unknown == right.unknown
    }
}

public struct BackendRoutinesParseResult: Sendable, Equatable {
    public let routine: BackendRoutinesRoutine?, warnings: [String], problems: [String]
    public var ok: Bool { routine != nil }
    public init(routine: BackendRoutinesRoutine, warnings: [String] = []) { self.routine = routine; self.warnings = warnings; problems = [] }
    public init(problems: [String]) { routine = nil; warnings = []; self.problems = problems }
    public var wire: NativeRPCValue {
        if let routine { return BackendRoutinesValues.object([("ok", .bool(true)), ("routine", routine.wire), ("warnings", .array(warnings.map(NativeRPCValue.string)))]) }
        return BackendRoutinesValues.object([("ok", .bool(false)), ("problems", .array(problems.map(NativeRPCValue.string)))])
    }
}

public struct BackendRoutinesTriggerParseResult: Sendable, Equatable {
    public let trigger: BackendRoutinesTrigger?, problem: String?
    public init(trigger: BackendRoutinesTrigger) { self.trigger = trigger; problem = nil }
    public init(problem: String) { trigger = nil; self.problem = problem }
}

public struct BackendRoutinesDocument: Sendable, Equatable {
    public let heading: String?, header: [String], prompt: String?, comments: [String]
}

/// format.ts, including the same refusal sentences and draft injection guard.
public enum BackendRoutinesFormat {
    public static let maxPromptBytes = 8 * 1_024, maxNameLength = 80, maxFileBytes = 64 * 1_024
    public static let hardMaxRunsPerHour = 60, hardMaxRunsPerDay = 500
    public static let defaultMaxRunsPerHour = 6, defaultMaxRunsPerDay = 24
    public static let defaultQuietForMs: Double = 30_000
    private static let units: [(String, Double)] = [("d", 86_400_000), ("h", 3_600_000), ("m", 60_000), ("s", 1_000)]
    private static let reserved = Set(["con", "prn", "aux", "nul"] + (1...9).map { "com\($0)" } + (1...9).map { "lpt\($0)" })
    private static let known = Set(["when", "in", "enabled", "overlap", "max-runs-per-hour", "max-runs-per-day", "quiet-for", "expect-every"])

    public static func parseDuration(_ text: String) -> Double? {
        guard let match = BackendRoutinesValues.match(BackendRoutinesValues.trim(text), #"^([0-9]{1,6})(s|m|h|d)$"#),
              let count = Double(match[1]), count > 0, let size = units.first(where: { $0.0 == match[2] })?.1 else { return nil }
        return count * size
    }
    public static func serializeDuration(_ ms: Double) -> String {
        for (unit, size) in units where ms >= size && ms.truncatingRemainder(dividingBy: size) == 0 {
            return BackendRoutinesValues.integerText(ms / size) + unit
        }
        return BackendRoutinesValues.integerText(max(1, floor(ms / 1_000 + 0.5))) + "s"
    }
    public static func slugify(_ text: String) -> String {
        var slug = BackendRoutinesValues.replace(text.lowercased(), #"[^a-z0-9]+"#, "-")
        slug = BackendRoutinesValues.replace(slug, #"^-+|-+$"#, "")
        return BackendRoutinesValues.replace(String(slug.prefix(64)), #"-+$"#, "")
    }
    public static func isValidId(_ id: String) -> Bool {
        !reserved.contains(id) && BackendRoutinesValues.match(id, #"^[a-z0-9][a-z0-9-]{0,63}$"#) != nil && !id.hasSuffix("-")
    }
    public static func suggestId(_ name: String, taken: Set<String>, now: Double = Date().timeIntervalSince1970 * 1_000) -> String {
        let slug = slugify(name)
        let base = slug.isEmpty || reserved.contains(slug) ? (slug.isEmpty ? "routine" : slug + "-routine") : slug
        if !taken.contains(base) { return base }
        for index in 2..<1_000 {
            let candidate = String(base.prefix(58)) + "-\(index)"
            if !taken.contains(candidate) { return candidate }
        }
        return String(base.prefix(50)) + "-" + String(Int64(now), radix: 36)
    }
    public static func parseTrigger(_ text: String) -> BackendRoutinesTriggerParseResult {
        let trimmed = BackendRoutinesValues.trim(text)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let keyword = String(parts.first ?? "").lowercased(), argument = parts.count == 2 ? BackendRoutinesValues.trim(String(parts[1])) : ""
        switch keyword {
        case "session-finished": return .init(trigger: .sessionFinished)
        case "session-failed": return .init(trigger: .sessionFailed)
        case "session-idle":
            guard let after = parseDuration(argument) else { return .init(problem: "`when: session-idle` needs a duration, like `session-idle 15m`") }
            return .init(trigger: .sessionIdle(afterMs: after))
        case "alert":
            if argument.isEmpty { return .init(trigger: .alert(severity: nil, alertKind: nil)) }
            if ["critical", "warning", "info"].contains(argument) { return .init(trigger: .alert(severity: argument, alertKind: nil)) }
            guard BackendRoutinesValues.match(argument, #"^[a-z][a-z-]{0,40}$"#) != nil else { return .init(problem: "`when: alert \(argument)` is neither a severity nor an alert kind") }
            return .init(trigger: .alert(severity: nil, alertKind: argument))
        case "git-change": return .init(trigger: .gitChange)
        case "file-change":
            let glob = argument.isEmpty ? "**/*" : argument
            guard !glob.contains("\0"), glob.utf16.count <= 200 else { return .init(problem: "`when: file-change` was given a pattern that is not a pattern") }
            return .init(trigger: .fileChange(glob: glob))
        case "schedule":
            let parsed = BackendRoutinesScheduling.parse(argument)
            if let schedule = parsed.schedule { return .init(trigger: .schedule(schedule)) }
            return .init(problem: parsed.problem!)
        case "manual": return .init(trigger: .manual)
        default: return .init(problem: "`when: \(trimmed)` is not a trigger this build knows. The ones it does: session-finished, session-failed, session-idle 15m, alert, git-change, file-change src/**, schedule 09:00, manual.")
        }
    }
    public static func serializeTrigger(_ trigger: BackendRoutinesTrigger) -> String {
        switch trigger {
        case .sessionIdle(let after): return "session-idle " + serializeDuration(after)
        case .alert(let severity, let alertKind):
            return "alert" + ((severity.flatMap { $0.isEmpty ? nil : $0 } ?? alertKind.flatMap { $0.isEmpty ? nil : $0 }).map { " " + $0 } ?? "")
        case .fileChange(let glob): return "file-change " + glob
        case .schedule(let schedule): return "schedule " + BackendRoutinesScheduling.serialize(schedule)
        default: return trigger.kind
        }
    }
    public static func splitDocument(_ text: String) -> BackendRoutinesDocument {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var heading: String?, header: [String] = [], comments: [String] = [], prompt: String?
        for (index, line) in lines.enumerated() {
            if BackendRoutinesValues.trim(line) == "---" { prompt = lines.dropFirst(index + 1).joined(separator: "\n"); break }
            if BackendRoutinesValues.trim(line).isEmpty { continue }
            if line.hasPrefix("#") {
                let label = BackendRoutinesValues.trim(BackendRoutinesValues.replace(line, "^#+" + BackendRoutinesValues.whitespacePattern + "*", ""))
                if heading == nil { heading = label } else { comments.append(label) }
            } else { header.append(line) }
        }
        return .init(heading: heading, header: header, prompt: prompt, comments: comments)
    }
    private static func count(_ value: String, hardMax: Int, key: String, warnings: inout [String]) -> Int? {
        let text = BackendRoutinesValues.trim(value)
        guard BackendRoutinesValues.match(text, #"^[0-9]{1,9}$"#) != nil, let parsed = Int(text) else { return nil }
        if parsed < 1 { warnings.append("`\(key): \(text)` was raised to 1 — use `enabled: no` to stop a routine."); return 1 }
        if parsed > hardMax {
            warnings.append("`\(key): \(parsed)` was lowered to \(hardMax), which is the most this app will run a routine unattended."); return hardMax
        }
        return parsed
    }
    public static func parseRoutine(_ id: String, text: String) -> BackendRoutinesParseResult {
        guard isValidId(id) else { return .init(problems: ["`\(id)` is not a usable routine name. Use lowercase letters, digits and hyphens."]) }
        // The TS parser checks JS string length; the filesystem store checks bytes.
        guard text.utf16.count <= maxFileBytes else { return .init(problems: ["This file is larger than \(maxFileBytes) bytes."]) }
        let document = splitDocument(text)
        var problems: [String] = [], warnings: [String] = [], triggers: [BackendRoutinesTrigger] = [], unknown: [String: [String]] = [:], order: [String] = []
        var folder: String?, enabled = true, overlap = BackendRoutinesOverlapPolicy.queue
        var hourly = defaultMaxRunsPerHour, daily = defaultMaxRunsPerDay, quiet = defaultQuietForMs, expect: Double?
        for line in document.header {
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else {
                problems.append("`\(BackendRoutinesValues.trim(line))` is not a `key: value` line."); continue
            }
            let key = BackendRoutinesValues.trim(String(line[..<colon])).lowercased(), value = BackendRoutinesValues.trim(String(line[line.index(after: colon)...]))
            if !known.contains(key) {
                if unknown[key] == nil { order.append(key) }; unknown[key, default: []].append(value)
                warnings.append("This build does not understand `\(key):`, so it was left alone."); continue
            }
            switch key {
            case "when":
                let result = parseTrigger(value)
                if let trigger = result.trigger { triggers.append(trigger) } else { problems.append(result.problem!) }
            case "in": folder = value
            case "enabled":
                let lowered = value.lowercased()
                if ["yes", "true", "on", "1"].contains(lowered) { enabled = true }
                else if ["no", "false", "off", "0"].contains(lowered) { enabled = false }
                else { problems.append("`enabled: \(value)` should be yes or no.") }
            case "overlap":
                if let policy = BackendRoutinesOverlapPolicy(rawValue: value) { overlap = policy }
                else { problems.append("`overlap: \(value)` should be queue, skip or cancel.") }
            case "max-runs-per-hour", "max-runs-per-day":
                if let parsed = count(value, hardMax: key == "max-runs-per-hour" ? hardMaxRunsPerHour : hardMaxRunsPerDay, key: key, warnings: &warnings) {
                    if key == "max-runs-per-hour" { hourly = parsed } else { daily = parsed }
                } else { problems.append("`\(key): \(value)` should be a whole number.") }
            case "quiet-for":
                if let duration = parseDuration(value) { quiet = duration }
                else { problems.append("`quiet-for: \(value)` should be a duration, like 30s.") }
            case "expect-every":
                if let duration = parseDuration(value) { expect = duration }
                else { problems.append("`expect-every: \(value)` should be a duration, like 26h.") }
            default: break
            }
        }
        if triggers.isEmpty { problems.append("This routine has no `when:` line, so nothing can start it.") }
        if folder == nil || folder == "" { problems.append("This routine has no `in:` line, so there is nowhere for it to run.") }
        if document.prompt == nil { problems.append("This routine has no `---` line, so there is no prompt beneath it.") }
        let body = BackendRoutinesValues.replace(BackendRoutinesValues.replace(document.prompt ?? "", #"^\n+"#, ""), BackendRoutinesValues.whitespacePattern + "+$", "")
        if document.prompt != nil && body.isEmpty { problems.append("The prompt below `---` is empty.") }
        if body.utf8.count > maxPromptBytes { problems.append("The prompt is longer than \(maxPromptBytes) bytes.") }
        if !problems.isEmpty { return .init(problems: problems) }
        return .init(routine: .init(id: id, name: BackendRoutinesValues.slice(document.heading ?? id, maxNameLength), triggers: triggers,
            folder: folder!, prompt: body, enabled: enabled, overlap: overlap, maxRunsPerHour: hourly, maxRunsPerDay: daily,
            quietForMs: quiet, expectEveryMs: expect, unknown: unknown, unknownKeyOrder: order), warnings: warnings)
    }
    private static func headerValue(_ value: NativeRPCValue, limit: Int = 300) -> String {
        guard let text = value.string else { return "" }
        return BackendRoutinesValues.slice(BackendRoutinesValues.trim(BackendRoutinesValues.replace(text, #"[\r\n]+"#, " ")), limit)
    }
    public static func routineFromDraft(_ id: String, draft: NativeRPCValue) -> BackendRoutinesParseResult {
        let name = headerValue(draft["name"], limit: maxNameLength)
        var lines = ["# " + (name.isEmpty ? id : name), ""]
        let when = draft["when"].elements ?? (draft["when"] == .missing ? [] : [draft["when"]])
        for entry in when.prefix(10) { let text = headerValue(entry); if !text.isEmpty { lines.append("when: " + text) } }
        lines.append("in: " + headerValue(draft["in"], limit: 1_000))
        if draft["enabled"] != .missing { lines.append("enabled: " + (draft["enabled"] == .bool(false) ? "no" : "yes")) }
        if draft["overlap"] != .missing { lines.append("overlap: " + headerValue(draft["overlap"], limit: 20)) }
        for (field, key) in [("maxRunsPerHour", "max-runs-per-hour"), ("maxRunsPerDay", "max-runs-per-day")] where draft[field] != .missing {
            lines.append(key + ": " + headerValue(.string(BackendRoutinesValues.jsString(draft[field])), limit: 20))
        }
        for (field, key) in [("quietFor", "quiet-for"), ("expectEvery", "expect-every")] where draft[field] != .missing {
            lines.append(key + ": " + headerValue(draft[field], limit: 20))
        }
        lines += ["", "---", "", draft["prompt"].string ?? ""]
        return parseRoutine(id, text: lines.joined(separator: "\n"))
    }
    public static func serializeRoutine(_ routine: BackendRoutinesRoutine) -> String {
        var lines = ["# " + routine.name, ""]
        lines += routine.triggers.map { "when: " + serializeTrigger($0) }
        lines += ["in: " + routine.folder, "enabled: " + (routine.enabled ? "yes" : "no")]
        if routine.overlap != .queue { lines.append("overlap: " + routine.overlap.rawValue) }
        if routine.maxRunsPerHour != defaultMaxRunsPerHour { lines.append("max-runs-per-hour: \(routine.maxRunsPerHour)") }
        if routine.maxRunsPerDay != defaultMaxRunsPerDay { lines.append("max-runs-per-day: \(routine.maxRunsPerDay)") }
        if routine.quietForMs != defaultQuietForMs { lines.append("quiet-for: " + serializeDuration(routine.quietForMs)) }
        if let expect = routine.expectEveryMs { lines.append("expect-every: " + serializeDuration(expect)) }
        for key in routine.orderedUnknownKeys { for value in routine.unknown[key] ?? [] { lines.append(key + ": " + value) } }
        lines += ["", "---", "", routine.prompt, ""]
        return lines.joined(separator: "\n")
    }
}
