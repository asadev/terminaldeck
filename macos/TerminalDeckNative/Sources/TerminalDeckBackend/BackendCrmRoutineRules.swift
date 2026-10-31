import Foundation
import TerminalDeckNativeCore

/// Completes recurrence-rules.ts around Core Routine/RoutineRule. Ordinary
/// anchored calendar arithmetic, serialization, summaries and next-on-done
/// behavior remain the reviewed Core implementation.
public enum BackendCrmRoutineRules {
    public static let defaultRoutine = RoutineRule()
    public static let workingWeekdays = Routine.workingWeekdays
    public static let skipDaysOffLabel = Routine.skipDaysOffLabel
    public typealias HistoryState = Routine.HistoryState
    /// OccurrenceRow is absent from Core (RoutineView.history is raw JSON).
    public struct OccurrenceRow: Sendable, Equatable {
        public var id: String, occurrenceDate: String
        public var dueDate: String?, assigneeUserId: String?, spawnedTaskId: String?
        public var status: String, completedAt: String?, completedBy: String?
        public init(id: String, occurrenceDate: String, dueDate: String? = nil, assigneeUserId: String? = nil, spawnedTaskId: String? = nil,
                    status: String = "open", completedAt: String? = nil, completedBy: String? = nil) {
            self.id = id; self.occurrenceDate = occurrenceDate; self.dueDate = dueDate; self.assigneeUserId = assigneeUserId
            self.spawnedTaskId = spawnedTaskId; self.status = status; self.completedAt = completedAt; self.completedBy = completedBy
        }
    }
    public struct DueScheduleDates: Sendable, Equatable {
        public let latest: String?
        public let gap: [String]
        public let gapTotal: Int
    }
    public static func addDays(_ ymd: String, _ n: Int) -> String { BackendCrmTime.ymdAddDays(ymd, n) }
    public static func weekdayOf(_ ymd: String) -> Int { BackendCrmTime.ymdWeekday(ymd) }
    public static func daysBetween(_ a: String, _ b: String) -> Int { BackendCrmTime.ymdDiff(a, b) }
    public static func isDayOff(_ ymd: String) -> Bool { BackendCrmTime.isLocalDayOff(ymd) }
    public static func skipDayOff(_ ymd: String) -> String { BackendCrmTime.nextWorkingDay(ymd) }
    public static func nthWeekdayOfMonth(_ y: Int, _ m: Int, nth: Int, weekday: Int) -> String { Routine.nthWeekdayOfMonth(y, m, nth: nth, weekday: weekday) }
    public static func nextAfter(_ anchor: String, rule: RoutineRule, after: String) -> String { Routine.nextAfter(anchor, rule, after) }
    public static func nextOccurrence(_ from: String, rule: RoutineRule) -> String { nextAfter(rule.anchor ?? from, rule: rule, after: from) }
    public static func isPastEnd(_ rule: RoutineRule, _ ymd: String, occurrencesSoFar: Int) -> Bool { Routine.isPastEnd(rule, ymd, occurrencesSoFar: occurrencesSoFar) }
    public static func isActive(_ rule: RoutineRule?) -> Bool {
        guard let rule else { return false }
        return rule.pausedAt?.isEmpty != false && rule.stoppedAt?.isEmpty != false
    }
    public static func localInstant(_ ymd: String, _ timeOfDay: String, zone: TimeZone = .current) -> Date? {
        let text = timeOfDay.wholeMatch(of: #/[0-9]{2}:[0-9]{2}/#) == nil ? "08:00" : timeOfDay
        let p = text.split(separator: ":").compactMap { Int($0) }
        return BackendCrmTime.localInstantAt(ymd, p[0], p[1], zone: zone)
    }
    /// Make only the latest due task, count the entire gap, retain 14 skipped
    /// dates. Skipped dates do not spend an ends.count allowance.
    public static func dueScheduleDates(anchor: String, last: String, rule: RoutineRule, now: Date, datesSoFar: Int,
                                        zone: TimeZone = .current) -> DueScheduleDates {
        if case .count(let count) = rule.ends, datesSoFar >= count { return DueScheduleDates(latest: nil, gap: [], gapTotal: 0) }
        var cur = last, latest: String?, recent: [String] = [], total = 0
        for _ in 0..<20_000 {
            let next = nextAfter(anchor, rule: rule, after: cur)
            guard let moment = localInstant(next, rule.timeOfDay, zone: zone), moment <= now else { break }
            if case .until(let until) = rule.ends, next > until { break }
            if let latest { recent.append(latest); if recent.count > 14 { recent.removeFirst() } }
            latest = next; total += 1; cur = next
        }
        return DueScheduleDates(latest: latest, gap: recent, gapTotal: max(0, total - 1))
    }
    public static func upcoming(_ from: String, rule: RoutineRule, count: Int = 3, occurrencesSoFar: Int = 0) -> [String] {
        guard count > 0 else { return [] }
        return Routine.upcoming(from, rule, count: count, occurrencesSoFar: occurrencesSoFar)
    }
    public static func legacyRecurrence(_ rule: RoutineRule) -> String { Routine.legacy(rule) }
    public static func ruleFromLegacy(_ recurrence: String) -> RoutineRule { Routine.fromLegacy(recurrence) }
    public static func normalizeRoutine(_ raw: CrmValue?, legacy: String? = nil) -> RoutineRule? {
        guard var rule = Routine.normalize(raw, legacy: legacy) else { return nil }
        for key in ["pausedAt", "stoppedAt"] {
            let valid = raw?[key]?.string.flatMap { BackendCrmTime.parseInstant($0) == nil ? nil : $0 }
            if key == "pausedAt" { rule.pausedAt = valid } else { rule.stoppedAt = valid }
        }
        return rule
    }
    public static func serializeRoutine(_ rule: RoutineRule) -> CrmValue { Routine.serialize(rule) }
    public static func localDateOf(_ iso: String, zone: TimeZone = .current) -> String? { BackendCrmTime.localParts(iso, zone: zone)?.ymd }
    public static func historyState(_ row: OccurrenceRow, today: String, zone: TimeZone = .current) -> HistoryState {
        let due = row.dueDate ?? row.occurrenceDate
        if row.status == "skipped" { return .skipped }
        if row.status == "done" {
            let day = row.completedAt.flatMap { localDateOf($0, zone: zone) }
            return day.map { $0 > due } == true ? .late : .onTime
        }
        if row.status == "missed" { return .missed }
        return due < today ? .overdue : .open
    }
    public static func shortDay(_ day: String) -> String { Routine.shortDay(day) }
    public static func routineSummary(_ rule: RoutineRule) -> String {
        var normalized = rule
        if normalized.pausedAt?.isEmpty == true { normalized.pausedAt = nil }
        if normalized.stoppedAt?.isEmpty == true { normalized.stoppedAt = nil }
        return Routine.summary(normalized)
    }
    public static func nextMovesWithDue(_ rule: RoutineRule) -> Bool { Routine.nextMovesWithDue(rule) }
    public static func routineAnchor(_ rule: RoutineRule, rootDue: String?, oldest: String?, taskDue: String?, today: String) -> String {
        rule.anchor ?? (rule.createNew ? rootDue : oldest ?? rootDue) ?? taskDue ?? today
    }
    public static func nextDateOnDone(_ rule: RoutineRule, anchor: String, occurrence: String?, due: String?, today: String, own: [String] = []) -> String {
        Routine.nextDateOnDone(rule, anchor: anchor, occurrence: occurrence, due: due, today: today, own: own)
    }
    public static func dateMoveNote(_ rule: RoutineRule?, status: String, due: String?, anchor: String?, occurrence: String?, today: String,
                                     datesSoFar: Int = 0, scheduleNext: String? = nil) -> String? {
        Routine.dateMoveNote(rule, status: status, due: due, anchor: anchor, occurrence: occurrence, today: today, datesSoFar: datesSoFar, scheduleNext: scheduleNext)
    }
    public static func isCalendarDate(_ ymd: String) -> Bool {
        guard let date = BackendCrmTime.utcDay(ymd) else { return false }
        return BackendCrmTime.localToday(date, zone: BackendCrmTime.utc) == ymd
    }
    public static func addMonthsClamped(_ day: String, _ n: Int) -> String { Routine.addMonthsClamped(day, n) }
    public static func defaultUntil(_ due: String?, today: String) -> String { Routine.defaultUntil(due: due, today: today) }
    /// Check the original value BEFORE normalization. The UI's typed refusal
    /// cannot represent malformed booleans, arrays, monthly modes or ends.
    public static func routineRefusal(_ raw: CrmValue, today: String) -> String? {
        let r = raw.object ?? [:]
        func integer(_ key: String, _ lo: Double, _ hi: Double) -> Bool {
            guard let n = r[key]?.number else { return false }; return n.isFinite && n == n.rounded() && n >= lo && n <= hi
        }
        if !Routine.frequencies.contains(r["frequency"]?.string ?? "") { return "Choose how often it repeats." }
        if !integer("interval", 1, 365) { return "“Every” needs a number from 1 to 365." }
        if r["frequency"] == .string("custom"), !Routine.units.contains(r["unit"]?.string ?? "") { return "Choose days, weeks, months or years." }
        guard let weekdays = r["weekdays"]?.array, weekdays.allSatisfy({ value in
            guard let n = value.number else { return false }; return n.isFinite && n == n.rounded() && n >= 0 && n <= 6
        }) else { return "The weekdays must be Sunday to Saturday." }
        if let monthly = r["monthly"], monthly != .null {
            guard let mo = monthly.object else { return "Choose which day of the month." }
            if mo["mode"] == .string("day") {
                guard let day = mo["day"]?.number, day.isFinite, day == day.rounded(), day >= 1 && day <= 31 else { return "The day of the month must be 1 to 31." }
            } else if mo["mode"] == .string("nth") {
                guard let n = mo["nth"]?.number, [1.0, 2, 3, 4, -1].contains(n), let w = mo["weekday"]?.number,
                      w.isFinite, w == w.rounded(), w >= 0 && w <= 6 else { return "Choose which weekday of the month." }
            } else { return "Choose which day of the month." }
        }
        if r["trigger"] != .string("status") && r["trigger"] != .string("schedule") { return "Choose when the next one comes: on a status change, or on a schedule." }
        if !BackendCrmShim.isTaskStatus(r["triggerStatus"]) { return "Choose the status that brings the next one." }
        if !BackendCrmShim.isTaskStatus(r["updateStatusTo"]) || r["updateStatusTo"] == .string("Done") { return "The next one must start in an open status." }
        if r["trigger"] == .string("schedule"), BackendCrmFields.string(r["timeOfDay"]).wholeMatch(of: #/([01][0-9]|2[0-3]):[0-5][0-9]/#) == nil { return "The time of day isn't valid." }
        if r["missedPolicy"] != .string("leave_open") && r["missedPolicy"] != .string("mark_missed") { return "Choose what happens to the previous open one." }
        for key in ["createNew", "syncToDue", "skipWeekends", "perAssignee"] where r[key]?.bool == nil { return "A repeat setting was neither on nor off." }
        guard let ends = r["ends"]?.object, let type = ends["type"]?.string, ["never", "until", "count"].contains(type) else { return "Choose when it ends: never, on a date, or after a number of times." }
        if type == "count" {
            guard let count = ends["count"]?.number, count.isFinite, count == count.rounded(), count >= 1 && count <= 1000 else { return "“After” needs a number of times from 1 to 1,000." }
        }
        if type == "until" {
            guard let date = ends["until"]?.string, isCalendarDate(date) else { return "“Until” needs a date." }
            if date < today { return "The end date has already passed" }
        }
        return nil
    }
    public static func routineRefusal(_ rule: RoutineRule, today: String) -> String? { routineRefusal(serializeRoutine(rule), today: today) }
}

/// recurrence.ts's legacy vocabulary and date-only recurrence helper.
public enum BackendCrmRecurrence {
    public static let taskRecurrences = TaskRecurrence.all
    public static func isTaskRecurrence(_ raw: String?) -> Bool { raw.map(taskRecurrences.contains) ?? false }
    public static func label(_ recurrence: String) -> String { TaskRecurrence.label(recurrence) }
    public static func short(_ recurrence: String) -> String { TaskRecurrence.short(recurrence) }
    static func looseParts(_ date: String) -> (y: Int, m: Int, d: Int)? {
        let p = date.split(separator: "-", omittingEmptySubsequences: false).prefix(3).map { Int($0) }
        guard p.count == 3, let y = p[0], let m = p[1], let d = p[2], y != 0 && m != 0 && d != 0 else { return nil }
        return (y, m, d)
    }
    static func format(_ y: Int, _ m: Int, _ d: Int) -> String { "\(y)-\(String(format: "%02d-%02d", m, d))" }
    static func daysInMonth(_ y: Int, _ m: Int) -> Int {
        BackendCrmTime.utcComponents(y, m + 1, 0).flatMap { BackendCrmTime.localParts($0, zone: BackendCrmTime.utc)?.d } ?? 28
    }
    public static func nextDueDate(_ due: String, rule: String, zone: TimeZone = .current) -> String {
        guard let p = looseParts(due), let base = BackendCrmTime.localInstantAt(String(format: "%04d-%02d-%02d", p.y, p.m, p.d), 0, zone: zone) else { return due }
        func plusDays(_ n: Int) -> String {
            let cal = BackendCrmTime.calendar(zone)
            guard let date = cal.date(byAdding: .day, value: n, to: base), let d = BackendCrmTime.localParts(date, zone: zone) else { return due }
            return format(d.y, d.m, d.d)
        }
        switch rule {
        case "daily": return plusDays(1)
        case "weekdays": return BackendCrmTime.nextWorkingDay(plusDays(1))
        case "weekly": return plusDays(7)
        case "monthly":
            let m = p.m == 12 ? 1 : p.m + 1, y = p.m == 12 ? p.y + 1 : p.y
            return format(y, m, min(p.d, daysInMonth(y, m)))
        case "yearly": return format(p.y + 1, p.m, min(p.d, daysInMonth(p.y + 1, p.m)))
        default: return due
        }
    }
    public static func nextOccurrenceDates(startDate: String?, dueDate: String?, rule: String, today: String, from: String? = nil,
                                           zone: TimeZone = .current) -> (startDate: String?, dueDate: String) {
        let base = [from, dueDate, today].compactMap { $0 }.first { !$0.isEmpty } ?? today
        let due = nextDueDate(base, rule: rule, zone: zone)
        guard let startDate, !startDate.isEmpty else { return (nil, due) }
        func midnight(_ date: String) -> Date? {
            guard let p = looseParts(date) else { return nil }
            return BackendCrmTime.localInstantAt(String(format: "%04d-%02d-%02d", p.y, p.m, p.d), 0, zone: zone)
        }
        let lead: Int
        if let dueDate, !dueDate.isEmpty, let a = midnight(startDate), let b = midnight(dueDate) { lead = Int(TaskFields.jsRound(b.timeIntervalSince(a) / 86_400)) } else { lead = 0 }
        guard let instant = midnight(due), let shifted = BackendCrmTime.calendar(zone).date(byAdding: .day, value: -max(0, lead), to: instant),
              let parts = BackendCrmTime.localParts(shifted, zone: zone) else { return (startDate, due) }
        return (format(parts.y, parts.m, parts.d), due)
    }
}
