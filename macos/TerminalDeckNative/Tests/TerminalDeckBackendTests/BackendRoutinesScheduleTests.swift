import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("Routine schedules — schedule.ts")
struct BackendRoutinesScheduleTests {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, calendar: Calendar? = nil) -> Double {
        (calendar ?? utc).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0))!.timeIntervalSince1970 * 1_000
    }
    @Test func readsClockAndDayWords() {
        #expect(BackendRoutinesScheduling.parse("09:00").schedule == .at(minutes: 540, days: nil))
        #expect(BackendRoutinesScheduling.parse("02:30").schedule == .at(minutes: 150, days: nil))
        #expect(BackendRoutinesScheduling.parse("09:00 mon,wed,fri").schedule == .at(minutes: 540, days: [1, 3, 5]))
        #expect(BackendRoutinesScheduling.parse("18:00 weekdays").schedule == .at(minutes: 1_080, days: [1, 2, 3, 4, 5]))
        #expect(BackendRoutinesScheduling.parse("10:00 weekends").schedule == .at(minutes: 600, days: [0, 6]))
        #expect(BackendRoutinesScheduling.parse("09:00 Friday,mon,FRIDAY").schedule == .at(minutes: 540, days: [1, 5]))
    }
    @Test func floorsIntervalsAndCapsAtAWeek() {
        #expect(BackendRoutinesScheduling.parse("every 2h").schedule == .every(intervalMs: 7_200_000))
        #expect(BackendRoutinesScheduling.parse("every 5m").schedule == .every(intervalMs: BackendRoutinesScheduling.minIntervalMs))
        #expect(BackendRoutinesScheduling.parse("every 7d").schedule == .every(intervalMs: BackendRoutinesScheduling.maxIntervalMs))
        #expect(BackendRoutinesScheduling.parse("every 30s").problem == "`schedule every 30s` is faster than this app will run a routine unattended (5m).")
        #expect(BackendRoutinesScheduling.parse("every 8d").problem == "`schedule every 8d` is longer than a week — use a time of day.")
    }
    @Test func refusesMalformedScheduleWithExactMessages() {
        #expect(BackendRoutinesScheduling.parse("").problem == "`when: schedule` needs a time, like `schedule 09:00` or `schedule every 2h`.")
        #expect(BackendRoutinesScheduling.parse("25:00").problem == "`schedule 25:00` is not a real time.")
        #expect(BackendRoutinesScheduling.parse("09:60").problem != nil)
        #expect(BackendRoutinesScheduling.parse("9am").problem == "`schedule 9am` should be a 24-hour time, like `09:00`.")
        #expect(BackendRoutinesScheduling.parse("09:00 funday").problem == "`funday` is not a day of the week.")
        #expect(BackendRoutinesScheduling.parse("09:00 , ,").problem == "No days were named.")
        #expect(BackendRoutinesScheduling.parse("every 2").problem == "`schedule every 2` needs a duration, like `every 2h`.")
    }
    @Test func roundTripsSchedule() throws {
        for text in ["09:00", "02:30 mon,fri", "every 2h", "every 30m"] {
            let schedule = try #require(BackendRoutinesScheduling.parse(text).schedule)
            #expect(BackendRoutinesScheduling.serialize(schedule) == text)
        }
    }
    @Test func choosesTodayOrTomorrowAndNeverNow() {
        let nine = BackendRoutinesSchedule.at(minutes: 540, days: nil)
        #expect(BackendRoutinesScheduling.nextDue(nine, from: at(2026, 8, 17, 8), calendar: utc) == at(2026, 8, 17, 9))
        #expect(BackendRoutinesScheduling.nextDue(nine, from: at(2026, 8, 17, 10), calendar: utc) == at(2026, 8, 18, 9))
        #expect(BackendRoutinesScheduling.nextDue(nine, from: at(2026, 8, 17, 9), calendar: utc) == at(2026, 8, 18, 9))
    }
    @Test func skipsToNamedWeekday() {
        #expect(BackendRoutinesScheduling.nextDue(.at(minutes: 540, days: [5]), from: at(2026, 8, 17, 10), calendar: utc) == at(2026, 8, 21, 9))
    }
    @Test func intervalsUseAnchorAndCatchUpWithoutABurst() {
        let hourly = BackendRoutinesSchedule.every(intervalMs: 3_600_000), anchor = at(2026, 8, 17, 9)
        #expect(BackendRoutinesScheduling.nextDue(hourly, from: at(2026, 8, 17, 9, 30), anchor: anchor) == at(2026, 8, 17, 10))
        #expect(BackendRoutinesScheduling.nextDue(hourly, from: at(2026, 8, 17, 14, 10), anchor: anchor) == at(2026, 8, 17, 15))
        #expect(BackendRoutinesScheduling.nextDue(hourly, from: at(2026, 8, 17, 14), anchor: anchor) == at(2026, 8, 17, 15))
        #expect(BackendRoutinesScheduling.nextDue(hourly, from: anchor) == anchor + 3_600_000)
    }
    @Test func localCalendarSurvivesFallDSTChange() {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let due = BackendRoutinesScheduling.nextDue(.at(minutes: 540, days: nil), from: at(2026, 10, 24, 10, calendar: berlin), calendar: berlin)
        #expect(due == at(2026, 10, 25, 9, calendar: berlin))
        #expect(due - at(2026, 10, 24, 9, calendar: berlin) == 25 * 3_600_000)
    }
    @Test func springGapMovesForwardKeepingMinutesLikeJavaScriptDate() {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let due = BackendRoutinesScheduling.nextDue(.at(minutes: 150, days: nil), from: at(2026, 3, 29, 1, calendar: berlin), calendar: berlin)
        #expect(due == at(2026, 3, 29, 3, 30, calendar: berlin))
    }
    @Test func repeatedHourUsesFirstOccurrence() {
        var berlin = Calendar(identifier: .gregorian); berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let first = BackendRoutinesScheduling.nextDue(.at(minutes: 150, days: nil), from: at(2026, 10, 25, 1, calendar: berlin), calendar: berlin)
        #expect(first == at(2026, 10, 25, 0, 30))
        #expect(BackendRoutinesScheduling.nextDue(.at(minutes: 150, days: nil), from: first + 1, calendar: berlin) == at(2026, 10, 26, 2, 30, calendar: berlin))
    }
    @Test func missedRunsReportsAbsenceAndCap() {
        let nine = BackendRoutinesSchedule.at(minutes: 540, days: nil)
        #expect(BackendRoutinesScheduling.missedRuns(nine, since: at(2026, 8, 14, 9), now: at(2026, 8, 17, 10), calendar: utc) == 3)
        #expect(BackendRoutinesScheduling.missedRuns(nine, since: at(2026, 8, 17, 9), now: at(2026, 8, 17, 10), calendar: utc) == 0)
        #expect(BackendRoutinesScheduling.missedRuns(nine, since: 5, now: 5) == 0)
        #expect(BackendRoutinesScheduling.missedRuns(.every(intervalMs: 3_600_000), since: at(2026, 7, 1, 0), now: at(2026, 8, 17, 0), cap: 10) == 10)
    }
}
