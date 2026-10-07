import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Backend CRM local time and anchored recurrence")
struct BackendCrmCalendarTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private func instant(_ iso: String) -> Date { BackendCrmTime.parseInstant(iso, zone: utc)! }
    private func daily() -> RoutineRule { var r = RoutineRule(); r.frequency = "daily"; r.trigger = "schedule"; return r }
    @Test func plainCalendarArithmeticDoesNotDriftAtDST() {
        #expect(BackendCrmTime.ymdAddDays("2026-03-07", 2) == "2026-03-09")
        #expect(BackendCrmTime.ymdDiff("2026-03-07", "2026-03-09") == 2)
        #expect(BackendCrmTime.ymdWeekday("2026-03-08") == 0)
        #expect(BackendCrmTime.nextWorkingDay("2026-10-10") == "2026-10-12")
        #expect(BackendCrmTime.nextDayOff("2026-10-06") == "2026-10-10")
    }
    @Test func nonexistentWallTimeMovesForwardByTheDSTGap() {
        let date = BackendCrmTime.localInstantAt("2026-03-08", 2, 30, zone: newYork)
        #expect(date == instant("2026-03-08T07:30:00Z"))
        #expect(date.flatMap { BackendCrmTime.localParts($0, zone: newYork) }?.hh == 3)
        #expect(date.flatMap { BackendCrmTime.localParts($0, zone: newYork) }?.mm == 30)
    }
    @Test func repeatedWallTimeChoosesTheEarlierInstant() {
        #expect(BackendCrmTime.localInstantAt("2026-11-01", 1, 30, zone: newYork) == instant("2026-11-01T05:30:00Z"))
        #expect(BackendCrmTime.localFromInput("2026-11-01T01:30", zone: newYork) == instant("2026-11-01T05:30:00Z"))
    }
    @Test func dateOnlyStringsAreUTCWhileInputWithoutZoneIsLocal() {
        #expect(BackendCrmTime.parseInstant("2026-10-06", zone: newYork) == instant("2026-10-06T00:00:00Z"))
        #expect(BackendCrmTime.localParts("2026-10-06", zone: newYork)?.ymd == "2026-10-05")
        #expect(BackendCrmTime.localFromInput("2026-10-06T00:00", zone: newYork) == instant("2026-10-06T04:00:00Z"))
        #expect(BackendCrmTime.localFromInput("bad", zone: newYork) == nil)
    }
    @Test func quickDatesAndCommentPresetsUseTheLocalCalendar() {
        let now = instant("2026-03-07T13:00:00Z") // 8 am before the DST switch.
        let presets = BackendCrmComments.schedulePresets(now: now, zone: newYork)
        #expect(presets.first?.at.timeIntervalSince(now) == 1200)
        #expect(presets.first { $0.key == "tomorrow" }?.at.timeIntervalSince(now) == Double(23 * 3600)) // explicit Double: the Int-literal expression resolved the optional compare to a never-equal overload
        #expect(presets.first { $0.key == "tomorrow" }?.hint == "Sun, 8:00 AM")
        #expect(BackendCrmTime.localQuickDates(instant("2026-10-05T08:00:00Z"), zone: utc).nextMonday == "2026-10-12")
        #expect(BackendCrmTime.hmLabel("16:00:00") == "4:00 pm")
    }
    @Test func aClampedMonthDoesNotMoveTheAnchor() {
        var rule = RoutineRule(); rule.frequency = "monthly"; rule.anchor = "2027-01-31"
        #expect(BackendCrmRoutineRules.nextOccurrence("2027-01-31", rule: rule) == "2027-02-28")
        #expect(BackendCrmRoutineRules.nextOccurrence("2027-02-28", rule: rule) == "2027-03-31")
        #expect(BackendCrmRoutineRules.upcoming("2027-01-31", rule: rule) == ["2027-02-28", "2027-03-31", "2027-04-30"])
    }
    @Test func leapDaysAndLastWeekdaysKeepTheirIntendedDates() {
        var yearly = RoutineRule(); yearly.frequency = "yearly"; yearly.anchor = "2024-02-29"
        #expect(BackendCrmRoutineRules.nextOccurrence("2027-02-28", rule: yearly) == "2028-02-29")
        #expect(BackendCrmRoutineRules.nthWeekdayOfMonth(2026, 10, nth: -1, weekday: 5) == "2026-10-30")
        #expect(BackendCrmRoutineRules.defaultUntil("2027-01-31", today: "2027-01-01") == "2027-02-28")
        #expect(!BackendCrmRoutineRules.isCalendarDate("2027-02-30"))
    }
    @Test func anExplicitDayOffOverridesSkipWeekendsAndWeeksKeepTheirInterval() {
        var rule = RoutineRule(); rule.weekdays = [6]; rule.skipWeekends = true
        #expect(BackendCrmRoutineRules.nextAfter("2026-10-05", rule: rule, after: "2026-10-05") == "2026-10-10")
        rule.weekdays = [1, 3]; rule.interval = 2
        #expect(BackendCrmRoutineRules.nextAfter("2026-10-05", rule: rule, after: "2026-10-07") == "2026-10-19")
    }
    @Test func catchUpKeepsOnlyTheLatestTaskAndFourteenRecentSkippedDates() {
        let rule = daily()
        let due = BackendCrmRoutineRules.dueScheduleDates(anchor: "2026-01-01", last: "2026-01-01", rule: rule,
            now: instant("2026-01-20T07:59:00Z"), datesSoFar: 0, zone: utc)
        #expect(due.latest == "2026-01-19")
        #expect(due.gapTotal == 17)
        #expect(due.gap.count == 14 && due.gap.first == "2026-01-05" && due.gap.last == "2026-01-18")
    }
    @Test func skippedDatesDoNotSpendTheCountButMadeDatesDo() {
        var rule = daily(); rule.ends = .count(1)
        let due = BackendCrmRoutineRules.dueScheduleDates(anchor: "2026-01-01", last: "2026-01-01", rule: rule,
            now: instant("2026-01-20T08:00:00Z"), datesSoFar: 0, zone: utc)
        #expect(due.latest == "2026-01-20" && due.gapTotal == 18)
        let exhausted = BackendCrmRoutineRules.dueScheduleDates(anchor: "2026-01-01", last: "2026-01-01", rule: rule,
            now: instant("2026-01-20T08:00:00Z"), datesSoFar: 1, zone: utc)
        #expect(exhausted.latest == nil && exhausted.gap.isEmpty && exhausted.gapTotal == 0)
    }
    @Test func scheduledEndDateIsInclusive() {
        var rule = daily(); rule.ends = .until("2026-01-04")
        let due = BackendCrmRoutineRules.dueScheduleDates(anchor: "2026-01-01", last: "2026-01-01", rule: rule,
            now: instant("2026-01-20T08:00:00Z"), datesSoFar: 0, zone: utc)
        #expect(due.latest == "2026-01-04" && due.gap == ["2026-01-02", "2026-01-03"] && due.gapTotal == 2)
    }
    @Test func scheduledCatchUpUsesTheResolvedLocalMoment() {
        var rule = daily(); rule.timeOfDay = "02:30"
        let before = BackendCrmRoutineRules.dueScheduleDates(anchor: "2026-03-07", last: "2026-03-07", rule: rule,
            now: instant("2026-03-08T07:29:59Z"), datesSoFar: 0, zone: newYork)
        let after = BackendCrmRoutineRules.dueScheduleDates(anchor: "2026-03-07", last: "2026-03-07", rule: rule,
            now: instant("2026-03-08T07:30:00Z"), datesSoFar: 0, zone: newYork)
        #expect(before.latest == nil && after.latest == "2026-03-08")
    }
    @Test func nextOnDoneNeverPointsAtADateAlreadyOwnedByTheTask() {
        var rule = RoutineRule(); rule.weekdays = [5]; rule.anchor = "2026-09-25"
        #expect(BackendCrmRoutineRules.nextDateOnDone(rule, anchor: "2026-09-25", occurrence: "2026-10-02", due: "2026-10-01", today: "2026-10-01") == "2026-10-09")
        #expect(BackendCrmRoutineRules.nextDateOnDone(rule, anchor: "2026-09-25", occurrence: nil, due: "2026-09-25", today: "2026-10-01", own: ["2026-10-02"]) == "2026-10-09")
    }
    @Test func rawRoutineRefusalChecksMalformedTypesBeforeNormalization() {
        let original = BackendCrmRoutineRules.serializeRoutine(RoutineRule())
        func changed(_ key: String, _ value: CrmValue) -> CrmValue { var o = original.object!; o[key] = value; return .object(o) }
        #expect(BackendCrmRoutineRules.routineRefusal(changed("interval", .number(1.5)), today: "2026-10-06") == "“Every” needs a number from 1 to 365.")
        #expect(BackendCrmRoutineRules.routineRefusal(changed("createNew", .string("true")), today: "2026-10-06") == "A repeat setting was neither on nor off.")
        #expect(BackendCrmRoutineRules.routineRefusal(changed("weekdays", .string("Monday")), today: "2026-10-06") == "The weekdays must be Sunday to Saturday.")
        #expect(BackendCrmRoutineRules.routineRefusal(changed("monthly", .object(["mode": .string("fifth")])), today: "2026-10-06") == "Choose which day of the month.")
        #expect(BackendCrmRoutineRules.routineRefusal(changed("ends", .null), today: "2026-10-06") == "Choose when it ends: never, on a date, or after a number of times.")
        #expect(BackendCrmRoutineRules.routineRefusal(changed("ends", .object(["type": .string("until"), "until": .string("2027-02-30")])), today: "2026-10-06") == "“Until” needs a date.")
    }
    @Test func legacyOptionsAndFullRulesKeepTheirSavedShape() {
        let first: CrmValue = .object(["forever": .bool(false), "until": .string("2026-12-31"), "updateStatusTo": .string("Done")])
        let rule = BackendCrmRoutineRules.normalizeRoutine(first, legacy: "monthly")!
        #expect(rule.frequency == "monthly" && rule.ends == .until("2026-12-31") && rule.updateStatusTo == "To-Do")
        let stored = BackendCrmRoutineRules.serializeRoutine(rule)
        #expect(stored["forever"] == .bool(false) && stored["until"] == .string("2026-12-31"))
        #expect(BackendCrmRoutineRules.normalizeRoutine(stored) == rule)
    }
    @Test func legacyOccurrenceStartKeepsItsLeadAcrossDST() {
        let dates = BackendCrmRecurrence.nextOccurrenceDates(startDate: "2026-03-06", dueDate: "2026-03-09", rule: "weekly", today: "2026-03-09", zone: newYork)
        #expect(dates.dueDate == "2026-03-16" && dates.startDate == "2026-03-13")
        #expect(BackendCrmRecurrence.nextDueDate("2027-01-31", rule: "monthly", zone: utc) == "2027-02-28")
        #expect(BackendCrmRecurrence.nextDueDate("2026-10-09", rule: "weekdays", zone: utc) == "2026-10-12")
        #expect(BackendCrmRecurrence.label("weekdays") == "Every working day (Mon–Sat)")
    }
    @Test func historyUsesTheCompletedLocalDay() {
        let row = BackendCrmRoutineRules.OccurrenceRow(id: "o", occurrenceDate: "2026-10-05", dueDate: "2026-10-05", status: "done", completedAt: "2026-10-06T01:00:00Z")
        #expect(BackendCrmRoutineRules.historyState(row, today: "2026-10-06", zone: newYork) == .onTime)
        #expect(BackendCrmRoutineRules.historyState(row, today: "2026-10-06", zone: utc) == .late)
    }
}
