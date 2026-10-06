import Foundation

// The reference CRM's routine rules, ported (src/shared/crm/recurrence-rules.ts and
// recurrence.ts): how often a task comes back, from when, until when, and the
// sentences the popup says about it. Days are this Mac's calendar ("YYYY-MM-DD");
// the weekend (Sunday, Saturday) is the days off.

public enum TaskRecurrence {
    public static let all = ["daily", "weekdays", "weekly", "monthly", "yearly"]

    public static func label(_ r: String) -> String {
        switch r {
        case "daily": "Daily"
        case "weekdays": "Every working day (Mon–Sat)"
        case "weekly": "Weekly"
        case "monthly": "Monthly"
        case "yearly": "Yearly"
        default: r
        }
    }

    public static func short(_ r: String) -> String {
        switch r {
        case "daily": "Daily"
        case "weekdays": "Working days"
        case "weekly": "Weekly"
        case "monthly": "Monthly"
        case "yearly": "Yearly"
        default: r
        }
    }
}

public struct RoutineRule: Equatable, Sendable {
    public enum Monthly: Equatable, Sendable {
        case day(Int)
        case nth(Int, weekday: Int)
    }

    public enum Ends: Equatable, Sendable {
        case never
        case until(String)
        case count(Int)
    }

    /// daily · weekly · monthly · yearly · days_after · custom
    public var frequency = "weekly"
    public var interval = 1
    /// day · week · month · year (for custom)
    public var unit = "day"
    public var weekdays: [Int] = []
    public var monthly: Monthly?
    /// status · schedule
    public var trigger = "status"
    public var triggerStatus = "Done"
    public var timeOfDay = "08:00"
    public var ends: Ends = .never
    public var createNew = true
    public var updateStatusTo = "To-Do"
    public var syncToDue = true
    public var skipWeekends = false
    public var perAssignee = false
    /// leave_open · mark_missed
    public var missedPolicy = "leave_open"
    public var pausedAt: String?
    public var stoppedAt: String?
    public var rootTaskId: String?
    public var anchor: String?

    public init() {}
}

public enum Routine {
    public static let statuses = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]
    public static let frequencies = ["daily", "weekly", "monthly", "yearly", "days_after", "custom"]
    public static let units = ["day", "week", "month", "year"]
    public static let daysOff = [0, 6]
    public static let workingWeekdays = [1, 2, 3, 4, 5]
    public static let skipDaysOffLabel = "Skip weekends"
    static let dayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let dayLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let nthWord = [1: "first", 2: "second", 3: "third", 4: "fourth", -1: "last"]
    static let mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    // MARK: Days

    static func parts(_ ymd: String) -> (y: Int, m: Int, d: Int)? {
        guard TaskList.isYmd(ymd) else { return nil }
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        return (p[0], p[1], p[2])
    }

    /// A UTC day from year, month (1-based, may overflow) and day (may overflow).
    static func ymd(_ y: Int, _ m: Int, _ d: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let first = utc.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date(timeIntervalSince1970: 0)
        let date = utc.date(byAdding: .day, value: d - 1, to: first) ?? first
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        let last = ymd(y, m + 1, 0)
        return parts(last)?.d ?? 28
    }

    public static func addDays(_ ymd: String, _ n: Int) -> String { TaskList.ymdAddDays(ymd, n) }
    public static func weekday(_ ymd: String) -> Int { TaskList.ymdWeekday(ymd) }
    public static func daysBetween(_ a: String, _ b: String) -> Int { TaskList.ymdDiff(a, b) }
    static func mondayOf(_ ymd: String) -> String { addDays(ymd, -((weekday(ymd) + 6) % 7)) }
    public static func isDayOff(_ ymd: String) -> Bool { daysOff.contains(weekday(ymd)) }

    public static func nextWorkingDay(_ ymd: String) -> String {
        var d = ymd
        for _ in 0..<7 where isDayOff(d) { d = addDays(d, 1) }
        return d
    }

    public static func nextDayOff(_ ymd: String) -> String {
        var d = ymd
        for _ in 0..<7 where !isDayOff(d) { d = addDays(d, 1) }
        return d
    }

    public static func nthWeekdayOfMonth(_ y: Int, _ m: Int, nth: Int, weekday wd: Int) -> String {
        if nth == -1 {
            let last = daysInMonth(y, m)
            let w = weekday(ymd(y, m, last))
            return ymd(y, m, last - ((w - wd + 7) % 7))
        }
        let firstW = weekday(ymd(y, m, 1))
        let day = 1 + ((wd - firstW + 7) % 7) + (nth - 1) * 7
        return ymd(y, m, min(day, daysInMonth(y, m)))
    }

    static func addMonths(_ day: String, _ n: Int, _ spec: RoutineRule.Monthly?) -> String {
        guard let p = parts(day) else { return day }
        let total = p.m - 1 + n
        let y = p.y + Int((Double(total) / 12).rounded(.down))
        let m = ((total % 12) + 12) % 12 + 1
        if case .nth(let nth, let wd)? = spec { return nthWeekdayOfMonth(y, m, nth: nth, weekday: wd) }
        var dd = p.d
        if case .day(let d)? = spec { dd = d }
        return ymd(y, m, min(dd, daysInMonth(y, m)))
    }

    static func addYears(_ day: String, _ n: Int) -> String {
        guard let p = parts(day) else { return day }
        return ymd(p.y + n, p.m, min(p.d, daysInMonth(p.y + n, p.m)))
    }

    static func monthsBetween(_ a: String, _ b: String) -> Int {
        guard let pa = parts(a), let pb = parts(b) else { return 0 }
        return (pb.y - pa.y) * 12 + (pb.m - pa.m)
    }

    static func unitOf(_ rule: RoutineRule) -> String {
        if rule.frequency == "custom" { return rule.unit }
        switch rule.frequency {
        case "weekly": return "week"
        case "monthly": return "month"
        case "yearly": return "year"
        default: return "day"
        }
    }

    static func rawNth(_ anchor: String, _ rule: RoutineRule, _ k: Int) -> String {
        let n = max(1, rule.interval)
        switch unitOf(rule) {
        case "week": return addDays(anchor, 7 * n * k)
        case "month": return addMonths(anchor, n * k, rule.monthly)
        case "year": return addYears(anchor, n * k)
        default: return addDays(anchor, n * k)
        }
    }

    /// The first occurrence strictly after `after`, counted from `anchor`.
    public static func nextAfter(_ anchor: String, _ rule: RoutineRule, _ after: String) -> String {
        let n = max(1, rule.interval)
        let unit = unitOf(rule)
        let pickedDayOff = unit == "week" && rule.weekdays.contains { daysOff.contains($0) }
        func shift(_ d: String) -> String { rule.skipWeekends && !pickedDayOff ? nextWorkingDay(d) : d }
        if rule.frequency == "days_after" { return shift(addDays(after, n)) }
        if unit == "week" && !rule.weekdays.isEmpty {
            let start = after >= anchor ? after : addDays(anchor, -1)
            let anchorWeek = mondayOf(anchor)
            for i in 1...(7 * n + 14) {
                let d = addDays(start, i)
                if !rule.weekdays.contains(weekday(d)) { continue }
                if Int((Double(daysBetween(anchorWeek, mondayOf(d))) / 7).rounded()) % n != 0 { continue }
                let out = shift(d)
                if out > after { return out }
            }
            return addDays(after, 7 * n)
        }
        var k0 = 0
        if after > anchor, let pa = parts(after), let pn = parts(anchor) {
            switch unit {
            case "month": k0 = Int((Double(monthsBetween(anchor, after)) / Double(n)).rounded(.down)) - 1
            case "year": k0 = Int((Double(pa.y - pn.y) / Double(n)).rounded(.down)) - 1
            default: k0 = Int((Double(daysBetween(anchor, after)) / Double(n * (unit == "week" ? 7 : 1))).rounded(.down)) - 1
            }
        }
        let base = max(0, k0)
        for k in base..<(base + 400) {
            let out = shift(rawNth(anchor, rule, k))
            if out > after { return out }
        }
        return shift(rawNth(anchor, rule, base + 400))
    }

    public static func isPastEnd(_ rule: RoutineRule, _ ymd: String, occurrencesSoFar: Int) -> Bool {
        switch rule.ends {
        case .until(let until): return ymd > until
        case .count(let count): return occurrencesSoFar >= count
        case .never: return false
        }
    }

    public static func isActive(_ rule: RoutineRule?) -> Bool {
        guard let rule else { return false }
        return rule.pausedAt == nil && rule.stoppedAt == nil
    }

    /// The next `count` occurrences after `from`.
    public static func upcoming(_ from: String, _ rule: RoutineRule, count: Int = 3, occurrencesSoFar: Int = 0) -> [String] {
        var out: [String] = []
        var cur = from
        let anchor = rule.anchor ?? from
        for _ in 0..<count {
            let next = nextAfter(anchor, rule, cur)
            if isPastEnd(rule, next, occurrencesSoFar: occurrencesSoFar + out.count) { break }
            out.append(next)
            cur = next
        }
        return out
    }

    static func isWorkingWeek(_ weekdays: [Int]) -> Bool {
        weekdays.count == workingWeekdays.count && workingWeekdays.allSatisfy(weekdays.contains)
    }

    /// The old one-word recurrence a rule reads as.
    public static func legacy(_ rule: RoutineRule) -> String {
        let unit = rule.frequency == "custom" ? rule.unit : rule.frequency
        if (unit == "daily" || unit == "day") && rule.skipWeekends && rule.interval == 1 { return "weekdays" }
        if (unit == "weekly" || unit == "week") && rule.interval == 1 && isWorkingWeek(rule.weekdays) { return "weekdays" }
        if unit == "weekly" || unit == "week" { return "weekly" }
        if unit == "monthly" || unit == "month" { return "monthly" }
        if unit == "yearly" || unit == "year" { return "yearly" }
        return "daily"
    }

    public static func fromLegacy(_ rec: String) -> RoutineRule {
        var rule = RoutineRule()
        switch rec {
        case "daily": rule.frequency = "daily"
        case "weekdays": rule.frequency = "weekly"; rule.weekdays = workingWeekdays
        case "monthly": rule.frequency = "monthly"
        case "yearly": rule.frequency = "yearly"
        default: rule.frequency = "weekly"
        }
        return rule
    }

    /// A rule as the engine stores it, read defensively; the legacy word fills the gaps.
    public static func normalize(_ raw: CrmValue?, legacy: String? = nil) -> RoutineRule? {
        let base = legacy.flatMap { TaskRecurrence.all.contains($0) ? fromLegacy($0) : nil }
        guard let r = raw?.object else { return base }
        var out = base ?? RoutineRule()
        if let f = r["frequency"]?.string, frequencies.contains(f) { out.frequency = f }
        if let i = r["interval"]?.number, i == i.rounded(), i >= 1, i <= 365 { out.interval = Int(i) }
        if let u = r["unit"]?.string, units.contains(u) { out.unit = u }
        if let w = r["weekdays"]?.array {
            out.weekdays = Array(Set(w.compactMap { $0.number }.filter { $0 == $0.rounded() && $0 >= 0 && $0 <= 6 }.map { Int($0) })).sorted()
        }
        if let mo = r["monthly"]?.object {
            if mo["mode"]?.string == "day", let d = mo["day"]?.number, d == d.rounded(), d >= 1, d <= 31 {
                out.monthly = .day(Int(d))
            } else if mo["mode"]?.string == "nth", let nth = mo["nth"]?.number, [1, 2, 3, 4, -1].contains(nth),
                      let wd = mo["weekday"]?.number, wd == wd.rounded(), wd >= 0, wd <= 6 {
                out.monthly = .nth(Int(nth), weekday: Int(wd))
            }
        }
        func status(_ key: String, _ fallback: String) -> String {
            if let s = r[key]?.string, statuses.contains(s) { return s }
            return fallback
        }
        if let e = r["ends"]?.object {
            switch e["type"]?.string {
            case "until": if let u = e["until"]?.string, TaskList.isYmd(u) { out.ends = .until(u) }
            case "count": if let c = e["count"]?.number, c == c.rounded(), c >= 1, c <= 1000 { out.ends = .count(Int(c)) }
            case "never": out.ends = .never
            default: break
            }
        } else if r["forever"]?.bool == false, let u = r["until"]?.string, TaskList.isYmd(u) {
            out.ends = .until(u)
        }
        func iso(_ key: String) -> String? {
            guard let s = r[key]?.string, CrmTime.date(s) != nil else { return nil }
            return s
        }
        out.trigger = r["trigger"]?.string == "schedule" ? "schedule" : "status"
        out.triggerStatus = status("triggerStatus", "Done")
        if let t = r["timeOfDay"]?.string, isTime(t) { out.timeOfDay = t } else { out.timeOfDay = "08:00" }
        if let b = r["createNew"]?.bool { out.createNew = b }
        let next = status("updateStatusTo", "To-Do")
        out.updateStatusTo = next == "Done" ? "To-Do" : next
        if let b = r["syncToDue"]?.bool { out.syncToDue = b }
        out.skipWeekends = r["skipWeekends"]?.bool == true
        out.perAssignee = r["perAssignee"]?.bool == true
        out.missedPolicy = r["missedPolicy"]?.string == "mark_missed" ? "mark_missed" : "leave_open"
        out.pausedAt = iso("pausedAt")
        out.stoppedAt = iso("stoppedAt")
        if let id = r["rootTaskId"]?.string, !id.isEmpty, id.count <= 64,
           id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) { out.rootTaskId = id } else { out.rootTaskId = nil }
        out.anchor = r["anchor"]?.string.flatMap { TaskList.isYmd($0) ? $0 : nil }
        return out
    }

    static func isTime(_ t: String) -> Bool {
        let p = t.split(separator: ":")
        guard t.count == 5, p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    /// As the engine stores it.
    public static func serialize(_ rule: RoutineRule) -> CrmValue {
        var o: [String: CrmValue] = [
            "frequency": .string(rule.frequency), "interval": .number(Double(rule.interval)), "unit": .string(rule.unit),
            "weekdays": .array(rule.weekdays.map { .number(Double($0)) }), "trigger": .string(rule.trigger),
            "triggerStatus": .string(rule.triggerStatus), "timeOfDay": .string(rule.timeOfDay),
            "createNew": .bool(rule.createNew), "updateStatusTo": .string(rule.updateStatusTo), "syncToDue": .bool(rule.syncToDue),
            "skipWeekends": .bool(rule.skipWeekends), "perAssignee": .bool(rule.perAssignee),
            "missedPolicy": .string(rule.missedPolicy), "pausedAt": rule.pausedAt.map(CrmValue.string) ?? .null,
            "stoppedAt": rule.stoppedAt.map(CrmValue.string) ?? .null, "anchor": rule.anchor.map(CrmValue.string) ?? .null,
        ]
        switch rule.monthly {
        case .day(let d)?: o["monthly"] = .object(["mode": .string("day"), "day": .number(Double(d))])
        case .nth(let n, let wd)?: o["monthly"] = .object(["mode": .string("nth"), "nth": .number(Double(n)), "weekday": .number(Double(wd))])
        case nil: o["monthly"] = .null
        }
        switch rule.ends {
        case .never: o["ends"] = .object(["type": .string("never")])
        case .until(let u): o["ends"] = .object(["type": .string("until"), "until": .string(u)])
        case .count(let c): o["ends"] = .object(["type": .string("count"), "count": .number(Double(c))])
        }
        if let root = rule.rootTaskId { o["rootTaskId"] = .string(root) }
        if case .until(let u) = rule.ends {
            o["forever"] = .bool(false)
            o["until"] = .string(u)
        } else {
            o["forever"] = .bool(true)
            o["until"] = .null
        }
        return .object(o)
    }

    static func shortDate(_ ymd: String) -> String {
        guard let p = parts(ymd) else { return ymd }
        return "\(p.d) \(mon[p.m - 1])"
    }

    /// "Wed 7 Oct".
    public static func shortDay(_ ymd: String) -> String {
        guard let p = parts(ymd) else { return ymd }
        return "\(dayShort[weekday(ymd)]) \(p.d) \(mon[p.m - 1])"
    }

    /// The rule in words: "Every Mon, Wed when done, until 3 Nov".
    public static func summary(_ rule: RoutineRule) -> String {
        let n = rule.interval
        let unit = rule.frequency == "custom" ? rule.unit : rule.frequency
        var what: String
        if rule.frequency == "days_after" {
            what = "\(n) day\(n == 1 ? "" : "s") after it is done"
        } else if (unit == "weekly" || unit == "week") && !rule.weekdays.isEmpty {
            let wd = rule.weekdays.sorted()
            let label = isWorkingWeek(wd) ? "working day" : wd.map { dayShort[$0] }.joined(separator: ", ")
            what = n == 1 ? "Every \(label)" : "Every \(n) weeks on \(label)"
        } else if (unit == "daily" || unit == "day") && rule.skipWeekends && n == 1 {
            what = "Every working day"
        } else if unit == "monthly" || unit == "month" {
            var on = ""
            switch rule.monthly {
            case .nth(let nth, let wd)?: on = " on the \(nthWord[nth] ?? "") \(dayLong[wd])"
            case .day(let d)?: on = " on day \(d)"
            case nil: on = ""
            }
            what = (n == 1 ? "Monthly" : "Every \(n) months") + on
        } else {
            let word = unit == "daily" || unit == "day" ? "day" : unit == "weekly" || unit == "week" ? "week" : "year"
            let ly = ["day": "Daily", "week": "Weekly", "year": "Yearly"]
            what = n == 1 ? (ly[word] ?? word) : "Every \(n) \(word)s"
        }
        var bits = [what + (rule.trigger == "schedule" ? " at \(rule.timeOfDay)" : "")]
        if rule.trigger == "status" { bits.append("when \(rule.triggerStatus == "Done" ? "done" : "set to \(rule.triggerStatus)")") }
        if case .until(let u) = rule.ends { bits.append("until \(shortDate(u))") }
        if case .count(let c) = rule.ends { bits.append("\(c) times") }
        if rule.perAssignee { bits.append("one copy per assignee") }
        if rule.skipWeekends && !what.hasPrefix("Every working day") { bits.append("skipping weekends") }
        let head = bits.joined(separator: ", ")
        if rule.stoppedAt != nil { return "\(head) — stopped" }
        if rule.pausedAt != nil { return "\(head) — paused" }
        return head
    }

    public static func nextMovesWithDue(_ rule: RoutineRule) -> Bool { rule.frequency != "days_after" && rule.syncToDue }

    public static func nextDateOnDone(_ rule: RoutineRule, anchor: String, occurrence: String?, due: String?, today: String,
                                      own: [String] = []) -> String {
        let fromDue = nextMovesWithDue(rule) && due != nil
        let base = fromDue ? anchor : today
        let standsFor: String? = {
            if let o = occurrence, let d = due { return o > d ? o : d }
            return occurrence ?? due
        }()
        var next = nextAfter(base, rule, fromDue ? (standsFor ?? today) : today)
        var i = 0
        while fromDue && next < today && i < 5000 { next = nextAfter(base, rule, next); i += 1 }
        let stands = Set(own + (occurrence.map { [$0] } ?? []))
        i = 0
        while stands.contains(next) && i < 5000 { next = nextAfter(base, rule, next); i += 1 }
        return next
    }

    /// What moving this task's date does to the routine, in words.
    public static func dateMoveNote(_ rule: RoutineRule?, status: String, due: String?, anchor: String?, occurrence: String?,
                                    today: String, datesSoFar: Int = 0, scheduleNext: String? = nil) -> String? {
        guard let rule, rule.stoppedAt == nil else { return nil }
        if rule.pausedAt != nil { return "Routine paused — nothing will be made until it's resumed." }
        if rule.trigger == "schedule" {
            if let next = scheduleNext { return "Next copy: \(shortDay(next)) — moving this date doesn't change it" }
            return "Moving this date moves only this task."
        }
        if status == "Done" || status == rule.triggerStatus { return "Moving this date moves only this task." }
        let anchorDay = anchor ?? due ?? today
        if nextMovesWithDue(rule), let due {
            let d = nextDateOnDone(rule, anchor: anchorDay, occurrence: occurrence, due: due, today: today)
            if isPastEnd(rule, d, occurrencesSoFar: datesSoFar) { return "This is the last one — nothing comes after it." }
            return "\(rule.createNew ? "Next copy" : "Comes back"): \(shortDay(d)) — moves with this date"
        }
        let onDue = due != nil && due! >= today
        let finish = onDue ? due! : today
        let when = onDue ? "on its due date (\(shortDay(finish)))" : "today (\(shortDay(finish)))"
        let d = nextDateOnDone(rule, anchor: anchorDay, occurrence: occurrence, due: due, today: finish)
        if isPastEnd(rule, d, occurrencesSoFar: datesSoFar) {
            if case .until(let until) = rule.ends {
                return "If done \(when), nothing comes after it — the routine ends \(shortDay(until))."
            }
            return "This is the last one — nothing comes after it."
        }
        return rule.createNew
            ? "If done \(when), the next copy is due \(shortDay(d)) — it counts from the day it's done."
            : "If done \(when), it comes back on \(shortDay(d)) — it counts from the day it's done."
    }

    /// A day one month on, held to that month's last day.
    public static func addMonthsClamped(_ day: String, _ n: Int) -> String {
        guard let p = parts(day) else { return day }
        let first = ymd(p.y, p.m + n, 1)
        guard let f = parts(first) else { return day }
        return ymd(f.y, f.m, min(p.d, daysInMonth(f.y, f.m)))
    }

    public static func defaultUntil(due: String?, today: String) -> String {
        addMonthsClamped(due.flatMap { $0 > today ? $0 : nil } ?? today, 1)
    }

    /// What is wrong with a rule before it is saved, or nil.
    public static func refusal(_ r: RoutineRule, today: String) -> String? {
        if !frequencies.contains(r.frequency) { return "Choose how often it repeats." }
        if !(1...365).contains(r.interval) { return "“Every” needs a number from 1 to 365." }
        if r.frequency == "custom" && !units.contains(r.unit) { return "Choose days, weeks, months or years." }
        if !r.weekdays.allSatisfy({ (0...6).contains($0) }) { return "The weekdays must be Sunday to Saturday." }
        switch r.monthly {
        case .day(let d)? where !(1...31).contains(d): return "The day of the month must be 1 to 31."
        case .nth(let n, let wd)? where ![1, 2, 3, 4, -1].contains(n) || !(0...6).contains(wd): return "Choose which weekday of the month."
        default: break
        }
        if r.trigger != "status" && r.trigger != "schedule" { return "Choose when the next one comes: on a status change, or on a schedule." }
        if !statuses.contains(r.triggerStatus) { return "Choose the status that brings the next one." }
        if !statuses.contains(r.updateStatusTo) || r.updateStatusTo == "Done" { return "The next one must start in an open status." }
        if r.trigger == "schedule" && !isTime(r.timeOfDay) { return "The time of day isn't valid." }
        if r.missedPolicy != "leave_open" && r.missedPolicy != "mark_missed" { return "Choose what happens to the previous open one." }
        switch r.ends {
        case .count(let c) where !(1...1000).contains(c): return "“After” needs a number of times from 1 to 1,000."
        case .until(let u):
            if !TaskList.isYmd(u) || ymd(parts(u)!.y, parts(u)!.m, parts(u)!.d) != u { return "“Until” needs a date." }
            if u < today { return "The end date has already passed" }
        default: break
        }
        return nil
    }

    // MARK: History

    public enum HistoryState: String, Sendable {
        case onTime = "on_time", late, missed, overdue, open, skipped

        public var label: String {
            switch self {
            case .onTime: "Done on time"
            case .late: "Done late"
            case .missed: "Missed"
            case .overdue: "Overdue"
            case .open: "Open"
            case .skipped: "Skipped"
            }
        }
    }

    /// One history row (an occurrence): done on time, late, missed, overdue, open or skipped.
    public static func historyState(status: String, completedAt: String?, dueDate: String?, occurrenceDate: String,
                                    today: String) -> HistoryState {
        let due = dueDate ?? occurrenceDate
        if status == "skipped" { return .skipped }
        if status == "done" {
            let d = completedAt.flatMap(CrmTime.date).map { CrmTime.todayYmd($0) }
            return d.map { $0 > due } == true ? .late : .onTime
        }
        if status == "missed" { return .missed }
        return due < today ? .overdue : .open
    }

    // MARK: The old one-word recurrence (recurrence.ts)

    public static func nextDueDate(_ due: String, _ rule: String) -> String {
        guard let p = parts(due) else { return due }
        switch rule {
        case "daily": return addDays(due, 1)
        case "weekdays": return nextWorkingDay(addDays(due, 1))
        case "weekly": return addDays(due, 7)
        case "monthly":
            let m = p.m == 12 ? 1 : p.m + 1, y = p.m == 12 ? p.y + 1 : p.y
            return ymd(y, m, min(p.d, daysInMonth(y, m)))
        case "yearly": return ymd(p.y + 1, p.m, min(p.d, daysInMonth(p.y + 1, p.m)))
        default: return due
        }
    }
}

extension Routine {
    /// The rule as if neither paused nor stopped (for its summary beside its state).
    public static func running(_ rule: RoutineRule) -> RoutineRule {
        var r = rule
        r.pausedAt = nil
        r.stoppedAt = nil
        return r
    }
}
