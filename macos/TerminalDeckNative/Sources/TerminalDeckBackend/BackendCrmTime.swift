import Foundation
import TerminalDeckNativeCore

/// src/shared/crm/local-time.ts. Calendar dates use UTC; wall clocks use this
/// computer's zone. An explicit zone makes DST rules deterministic to inspect.
public enum BackendCrmTime {
    public static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    public static let dayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    public static let daysOff = [0, 6]
    public static let daysOffLabel = "weekend"
    public struct LocalParts: Sendable, Equatable {
        public let y: Int, m: Int, d: Int, weekday: Int, hh: Int, mm: Int
        public let ymd: String
    }
    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    static let utc = TimeZone(secondsFromGMT: 0)!
    public static func isYmd(_ value: String?) -> Bool {
        value?.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    }
    static func dateParts(_ ymd: String) -> (Int, Int, Int)? {
        guard isYmd(ymd) else { return nil }
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0], p[1], p[2])
    }
    /// Date.UTC/new Date's component normalization, including years 0…99.
    static func utcComponents(_ year: Int, _ month: Int, _ day: Int, constructorYear: Bool = true) -> Date? {
        let y = constructorYear && (0...99).contains(year) ? year + 1900 : year
        let total = month - 1
        let normalizedYear = y + Int(floor(Double(total) / 12))
        let normalizedMonth = ((total % 12) + 12) % 12 + 1
        let cal = calendar(utc)
        guard let first = cal.date(from: DateComponents(year: normalizedYear, month: normalizedMonth, day: 1)) else { return nil }
        return cal.date(byAdding: .day, value: day - 1, to: first)
    }
    static func utcDay(_ ymd: String, constructorYear: Bool = true) -> Date? {
        guard let (y, m, d) = dateParts(ymd) else { return nil }
        return utcComponents(y, m, d, constructorYear: constructorYear)
    }
    public static func ymdAddDays(_ ymd: String, _ n: Int) -> String {
        guard let base = utcDay(ymd) else { return ymd }
        return localToday(base.addingTimeInterval(Double(n) * 86_400), zone: utc)
    }
    public static func ymdDiff(_ a: String, _ b: String) -> Int {
        guard let left = utcDay(a), let right = utcDay(b) else { return 0 }
        return Int(TaskFields.jsRound(right.timeIntervalSince(left) / 86_400))
    }
    public static func ymdWeekday(_ ymd: String) -> Int {
        utcDay(ymd).map { calendar(utc).component(.weekday, from: $0) - 1 } ?? 0
    }
    public static func localParts(_ at: Date, zone: TimeZone = .current) -> LocalParts? {
        guard at.timeIntervalSince1970.isFinite else { return nil }
        let c = calendar(zone).dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: at)
        guard let y = c.year, let m = c.month, let d = c.day, let w = c.weekday, let hh = c.hour, let mm = c.minute else { return nil }
        return LocalParts(y: y, m: m, d: d, weekday: w - 1, hh: hh, mm: mm, ymd: String(format: "%04d-%02d-%02d", y, m, d))
    }
    public static func localParts(_ at: String, zone: TimeZone = .current) -> LocalParts? {
        parseInstant(at, zone: zone).flatMap { localParts($0, zone: zone) }
    }
    public static func localParts(_ milliseconds: Double, zone: TimeZone = .current) -> LocalParts? {
        guard milliseconds.isFinite, abs(milliseconds) <= 8.64e15 else { return nil }
        return localParts(Date(timeIntervalSince1970: milliseconds / 1000), zone: zone)
    }
    public static func localToday(_ now: Date = Date(), zone: TimeZone = .current) -> String { localParts(now, zone: zone)?.ymd ?? "" }
    public static func todayYmd(_ now: Date = Date(), zone: TimeZone = .current) -> String { localToday(now, zone: zone) }
    public static func localDayStartMs(_ now: Date = Date(), zone: TimeZone = .current) -> Double {
        calendar(zone).startOfDay(for: now).timeIntervalSince1970 * 1000
    }
    public static func localClock(_ at: Date, upper: Bool = false, zone: TimeZone = .current) -> String {
        guard let p = localParts(at, zone: zone) else { return "" }
        let text = "\(p.hh % 12 == 0 ? 12 : p.hh % 12):\(String(format: "%02d", p.mm)) \(p.hh < 12 ? "am" : "pm")"
        return upper ? text.uppercased() : text
    }
    public static func localClock(_ at: String, upper: Bool = false, zone: TimeZone = .current) -> String {
        parseInstant(at, zone: zone).map { localClock($0, upper: upper, zone: zone) } ?? ""
    }
    public static func localStamp(_ at: String, zone: TimeZone = .current) -> String {
        guard let p = localParts(at, zone: zone) else { return "" }
        return "\(p.d) \(monthShort[p.m - 1]) \(p.y), \(localClock(at, zone: zone))"
    }
    /// JavaScript's compatible DST resolution: earlier of a repeated time;
    /// advance by the gap for a nonexistent time, preserving its minutes.
    public static func localInstantAt(_ ymd: String, _ hh: Int, _ mm: Int = 0, zone: TimeZone = .current) -> Date? {
        guard let day = utcDay(ymd), abs(Double(hh)) <= 100_000, abs(Double(mm)) <= 100_000 else { return nil }
        let wall = day.addingTimeInterval(Double(hh) * 3600 + Double(mm) * 60)
        let offsets = Set([-172_800.0, -86_400, 0, 86_400, 172_800].map { zone.secondsFromGMT(for: wall.addingTimeInterval($0)) })
        let candidates = offsets.map { wall.addingTimeInterval(-Double($0)) }.sorted()
        for candidate in candidates {
            let represented = candidate.addingTimeInterval(Double(zone.secondsFromGMT(for: candidate)))
            if abs(represented.timeIntervalSince(wall)) < 0.001 { return candidate }
        }
        // No exact match means a gap. The prior offset's candidate lies after
        // the requested local clock by the size of that gap.
        return candidates.filter {
            $0.addingTimeInterval(Double(zone.secondsFromGMT(for: $0))) >= wall
        }.min { left, right in
            left.addingTimeInterval(Double(zone.secondsFromGMT(for: left))) < right.addingTimeInterval(Double(zone.secondsFromGMT(for: right)))
        }
    }
    public static func localFromInput(_ value: String, zone: TimeZone = .current) -> Date? {
        guard let m = value.wholeMatch(of: #/([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2})/#), let hh = Int(m.2), let mm = Int(m.3) else { return nil }
        return localInstantAt(String(m.1), hh, mm, zone: zone)
    }
    /// ISO date-only strings are UTC in JS Date, unlike a datetime-local input.
    public static func parseInstant(_ value: String, zone: TimeZone = .current) -> Date? {
        if isYmd(value), let (y, m, d) = dateParts(value), (1...12).contains(m), (1...31).contains(d) {
            return utcComponents(y, m, d, constructorYear: false)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date }
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: value) { return date }
        if let m = value.wholeMatch(of: #/([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,3}))?)?/#),
           let h = Int(m.2), let minute = Int(m.3), h <= 24, minute < 60 {
            let seconds = m.4.flatMap { Int($0) } ?? 0
            guard seconds < 60, h < 24 || (minute == 0 && seconds == 0 && m.5 == nil) else { return nil }
            let fraction = m.5.map { Double("0." + String($0)) ?? 0 } ?? 0
            return localInstantAt(String(m.1), h, minute, zone: zone)?.addingTimeInterval(Double(seconds) + fraction)
        }
        return nil
    }
    public static func hmLabel(_ hm: String?) -> String {
        guard let hm, let m = hm.firstMatch(of: #/^([0-9]{2}):([0-9]{2})/#), let h = Int(m.1), let minute = Int(m.2) else { return "" }
        return "\(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", minute)) \(h < 12 ? "am" : "pm")"
    }
    public static func localNowHm(_ now: Date = Date(), zone: TimeZone = .current) -> String {
        guard let p = localParts(now, zone: zone) else { return "" }
        return String(format: "%02d:%02d", p.hh, p.mm)
    }
    public static func localQuickDates(_ now: Date = Date(), zone: TimeZone = .current) -> (today: String, tomorrow: String, nextMonday: String, twoWeeks: String) {
        let today = localToday(now, zone: zone), n = (8 - ymdWeekday(today)) % 7
        return (today, ymdAddDays(today, 1), ymdAddDays(today, n == 0 ? 7 : n), ymdAddDays(today, 14))
    }
    public static func isLocalDayOff(_ ymd: String) -> Bool { daysOff.contains(ymdWeekday(ymd)) }
    public static func nextWorkingDay(_ ymd: String) -> String {
        var day = ymd
        for _ in 0..<7 { if !isLocalDayOff(day) { break }; day = ymdAddDays(day, 1) }
        return day
    }
    public static func nextDayOff(_ ymd: String) -> String {
        var day = ymd
        for _ in 0..<7 { if isLocalDayOff(day) { break }; day = ymdAddDays(day, 1) }
        return day
    }
}
