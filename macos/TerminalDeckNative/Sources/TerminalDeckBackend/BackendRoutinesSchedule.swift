import Foundation
import TerminalDeckNativeCore

public enum BackendRoutinesSchedule: Sendable, Equatable {
    /// Local weekday numbering matches JavaScript: Sunday is zero.
    case at(minutes: Int, days: [Int]?)
    case every(intervalMs: Double)
    public var kind: String { if case .at = self { return "at" }; return "every" }
    public var wire: NativeRPCValue {
        switch self {
        case .at(let minutes, let days): return BackendRoutinesValues.object([
            ("kind", .string("at")), ("minutes", .number(Double(minutes))),
            ("days", days.map { .array($0.map { .number(Double($0)) }) } ?? .null)])
        case .every(let interval): return BackendRoutinesValues.object([("kind", .string("every")), ("intervalMs", .number(interval))])
        }
    }
}

public struct BackendRoutinesScheduleParseResult: Sendable, Equatable {
    public let schedule: BackendRoutinesSchedule?
    public let problem: String?
    public init(schedule: BackendRoutinesSchedule) { self.schedule = schedule; problem = nil }
    public init(problem: String) { schedule = nil; self.problem = problem }
}

/// schedule.ts: computes due instants, without owning timers or reading a clock.
public enum BackendRoutinesScheduling {
    public static let minIntervalMs: Double = 5 * 60 * 1_000
    public static let maxIntervalMs: Double = 7 * 24 * 60 * 60 * 1_000
    private static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public static func parse(_ text: String) -> BackendRoutinesScheduleParseResult {
        let trimmed = BackendRoutinesValues.trim(text).lowercased()
        guard !trimmed.isEmpty else { return .init(problem: "`when: schedule` needs a time, like `schedule 09:00` or `schedule every 2h`.") }
        if trimmed.hasPrefix("every") {
            let rest = BackendRoutinesValues.trim(String(trimmed.dropFirst(5)))
            guard let match = BackendRoutinesValues.match(rest, #"^([0-9]{1,5})(s|m|h|d)$"#),
                  let count = Double(match[1]) else { return .init(problem: "`schedule every \(rest)` needs a duration, like `every 2h`.") }
            let sizes: [String: Double] = ["s": 1_000, "m": 60_000, "h": 3_600_000, "d": 86_400_000]
            let interval = count * sizes[match[2]]!
            if interval < minIntervalMs { return .init(problem: "`schedule every \(rest)` is faster than this app will run a routine unattended (5m).") }
            if interval > maxIntervalMs { return .init(problem: "`schedule every \(rest)` is longer than a week — use a time of day.") }
            return .init(schedule: .every(intervalMs: interval))
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let clock = String(parts[0]), dayText = parts.count == 2 ? String(parts[1]) : ""
        guard let match = BackendRoutinesValues.match(clock, #"^([0-9]{1,2}):([0-9]{2})$"#),
              let hour = Int(match[1]), let minute = Int(match[2]) else { return .init(problem: "`schedule \(clock)` should be a 24-hour time, like `09:00`.") }
        guard hour <= 23, minute <= 59 else { return .init(problem: "`schedule \(clock)` is not a real time.") }
        if dayText.isEmpty { return .init(schedule: .at(minutes: hour * 60 + minute, days: nil)) }
        let separated = BackendRoutinesValues.replace(dayText, "(?:,|" + BackendRoutinesValues.whitespacePattern + ")+", ",")
        let names = separated.components(separatedBy: ",").filter { !$0.isEmpty }
        var days = Set<Int>()
        for name in names {
            if name == "weekdays" { days.formUnion([1, 2, 3, 4, 5]); continue }
            if name == "weekends" { days.formUnion([0, 6]); continue }
            guard let day = dayNames.firstIndex(of: String(name.prefix(3))) else { return .init(problem: "`\(name)` is not a day of the week.") }
            days.insert(day)
        }
        guard !days.isEmpty else { return .init(problem: "No days were named.") }
        return .init(schedule: .at(minutes: hour * 60 + minute, days: days.sorted()))
    }

    public static func serialize(_ schedule: BackendRoutinesSchedule) -> String {
        switch schedule {
        case .every(let ms):
            for (unit, size) in [("d", 86_400_000.0), ("h", 3_600_000.0), ("m", 60_000.0)] {
                if ms >= size, ms.truncatingRemainder(dividingBy: size) == 0 { return "every \(BackendRoutinesValues.integerText(ms / size))\(unit)" }
            }
            return "every \(BackendRoutinesValues.integerText(floor(ms / 1_000 + 0.5)))s"
        case .at(let minutes, let days):
            let clock = String(format: "%02d:%02d", minutes / 60, minutes % 60)
            guard let days else { return clock }
            return clock + " " + days.map { dayNames[$0] }.joined(separator: ",")
        }
    }

    public static func nextDue(_ schedule: BackendRoutinesSchedule, from: Double, anchor: Double? = nil, calendar: Calendar? = nil) -> Double {
        switch schedule {
        case .every(let interval):
            guard let anchor else { return from + interval }
            var next = anchor + interval
            if next <= from {
                next = anchor + ceil((from - anchor) / interval) * interval
                if next <= from { next += interval }
            }
            return next
        case .at(let minutes, let days):
            var local = calendar ?? Calendar(identifier: .gregorian)
            if calendar == nil { local.timeZone = .current }
            let start = Date(timeIntervalSince1970: from / 1_000), dayStart = local.startOfDay(for: start)
            for ahead in 0...8 {
                guard let date = local.date(byAdding: .day, value: ahead, to: dayStart),
                      let candidate = local.nextDate(after: date.addingTimeInterval(-1),
                          matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                          matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first, direction: .forward) else { continue }
                let due = candidate.timeIntervalSince1970 * 1_000
                if due <= from { continue }
                if let days, !days.contains(local.component(.weekday, from: candidate) - 1) { continue }
                return due
            }
            return from + 7 * 86_400_000
        }
    }

    public static func missedRuns(_ schedule: BackendRoutinesSchedule, since: Double, now: Double, cap: Int = 99, calendar: Calendar? = nil) -> Int {
        guard since < now else { return 0 }
        var count = 0, cursor = since
        while count < cap {
            let anchor: Double? = schedule.kind == "every" ? cursor : nil
            let due = nextDue(schedule, from: cursor, anchor: anchor, calendar: calendar)
            if due > now { break }
            count += 1; cursor = due
        }
        return count
    }
}
