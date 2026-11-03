import Foundation

/// A bounded projection, independent of the engine clock and timer. Calendar
/// schedules use the same calendar-aware nextDue calculation as normal firings.
public enum BackendRoutinesPolicies {
    public struct Due: Sendable, Equatable {
        public let times: [Double]
        public let hasMore: Bool
    }
    public static func occurrences(_ schedule: BackendRoutinesSchedule, after cursor: Double, through now: Double, limit: Int, calendar: Calendar? = nil) -> Due {
        guard cursor.isFinite, now.isFinite, cursor < now else { return .init(times: [], hasMore: false) }
        let bound = min(50, max(1, limit))
        var times: [Double] = [], at = cursor
        for _ in 0...bound {
            let due = BackendRoutinesScheduling.nextDue(schedule, from: at, anchor: at, calendar: calendar)
            guard due.isFinite, due > at, due <= now else { return .init(times: times, hasMore: false) }
            if times.count == bound { return .init(times: times, hasMore: true) }
            times.append(due); at = due
        }
        return .init(times: times, hasMore: false)
    }
}
