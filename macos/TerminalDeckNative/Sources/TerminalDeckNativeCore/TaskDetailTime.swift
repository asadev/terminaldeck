import Foundation

// MARK: - Time (local-time.ts, task-rules.ts, task-page.ts)

public enum CrmTime {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Milliseconds as an ISO time.
    public static func iso(_ ms: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// An ISO time (with or without fractions), or a plain day, as a date.
    public static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: iso) { return d }
        if TaskList.isYmd(iso) {
            let p = iso.split(separator: "-").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        return nil
    }

    struct Parts { let y, m, d, weekday, hh, mm: Int; let ymd: String }

    static func parts(_ date: Date) -> Parts {
        let c = Calendar.current.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let ymd = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return Parts(y: c.year ?? 1970, m: c.month ?? 1, d: c.day ?? 1, weekday: (c.weekday ?? 1) - 1, hh: c.hour ?? 0,
                     mm: c.minute ?? 0, ymd: ymd)
    }

    /// "3:05 pm" (or "3:05 PM").
    public static func clock(_ date: Date, upper: Bool = false) -> String {
        let p = parts(date)
        let s = "\(p.hh % 12 == 0 ? 12 : p.hh % 12):\(String(format: "%02d", p.mm)) \(p.hh < 12 ? "am" : "pm")"
        return upper ? s.uppercased() : s
    }

    /// "09:30" → "9:30 am".
    public static func hmLabel(_ hm: String?) -> String {
        guard let hm, hm.count >= 5 else { return "" }
        let p = hm.prefix(5).split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return "" }
        return "\(p[0] % 12 == 0 ? 12 : p[0] % 12):\(String(format: "%02d", p[1])) \(p[0] < 12 ? "am" : "pm")"
    }

    public static func todayYmd(_ now: Date = Date()) -> String { parts(now).ymd }

    public static func quickDates(_ now: Date = Date()) -> (today: String, tomorrow: String, nextMonday: String, twoWeeks: String) {
        let today = todayYmd(now)
        let toMonday = (8 - TaskList.ymdWeekday(today)) % 7
        return (today, TaskList.ymdAddDays(today, 1), TaskList.ymdAddDays(today, toMonday == 0 ? 7 : toMonday),
                TaskList.ymdAddDays(today, 14))
    }

    /// The feed's time: "Just now", "5 mins", "3 hours", "Yesterday at 9:05 am", "Sep 3 at …", "Sep 3, 2025".
    public static func activityTime(_ iso: String, now: Date = Date()) -> String {
        guard let date = date(iso) else { return "" }
        let ms = date.timeIntervalSince1970 * 1000
        let s = max(0, Int(((now.timeIntervalSince1970 * 1000 - ms) / 1000).rounded()))
        if s < 60 { return "Just now" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m) min\(m == 1 ? "" : "s")" }
        let h = Int((Double(m) / 60).rounded())
        let startToday = Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000
        if ms >= startToday { return "\(h) hour\(h == 1 ? "" : "s")" }
        if ms >= startToday - 86_400_000 { return "Yesterday at \(clock(date))" }
        let t = parts(date)
        if t.y == parts(now).y { return "\(months[t.m - 1]) \(t.d) at \(clock(date))" }
        return "\(months[t.m - 1]) \(t.d), \(t.y)"
    }

    /// "Sep 3 at 9:05 am".
    public static func stamp(_ iso: String) -> String {
        guard let date = date(iso) else { return "" }
        let t = parts(date)
        return "\(months[t.m - 1]) \(t.d) at \(clock(date))"
    }

    /// "Sep 3".
    public static func monthDay(_ iso: String) -> String {
        guard let date = date(iso) else { return "" }
        let t = parts(date)
        return "\(months[t.m - 1]) \(t.d)"
    }

    public static func ymdMonthDay(_ ymd: String) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), p[2] > 0 else { return "" }
        return "\(months[p[1] - 1]) \(p[2])"
    }

    /// "1h 30m", "45m", "2h", "0h".
    public static func duration(_ seconds: Double) -> String {
        let mins = Int(max(0, seconds) / 60)
        let h = mins / 60, m = mins % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "0h"
    }

    /// "1:05:09".
    public static func clockDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60)):\(String(format: "%02d", s % 60))"
    }

    /// "1:30", "90", "1.5h", "2h 15m", "45m" → seconds; nil when not a time (or over a day).
    public static func parseDuration(_ input: String) -> Double? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.isEmpty { return nil }
        var secs: Double?
        if let m = s.wholeMatch(of: /(\d{1,2}):(\d{2})/) {
            secs = (Double(m.1) ?? 0) * 3600 + (Double(m.2) ?? 0) * 60
        } else if let m = s.wholeMatch(of: /(\d+(?:\.\d+)?)/) {
            secs = ((Double(m.1) ?? 0) * 60).rounded()
        } else if let m = s.wholeMatch(of: /(?:(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?)?\s*(?:(\d+)\s*m?(?:in(?:ute)?s?)?)?/),
                  m.1 != nil || m.2 != nil {
            secs = ((Double(m.1 ?? "0") ?? 0) * 3600).rounded() + (Double(m.2 ?? "0") ?? 0) * 60
        }
        guard let secs, secs.isFinite, secs > 0, secs <= 24 * 3600 else { return nil }
        return secs
    }

    /// Seconds tracked, a running entry counted up to now.
    public static func totalTracked(_ entries: [TimeEntry], now: Date = Date()) -> Double {
        entries.reduce(0) { total, e in
            if let seconds = e.seconds { return total + seconds }
            if e.endedAt == nil, let start = date(e.startedAt) { return total + max(0, (now.timeIntervalSince(start)).rounded(.down)) }
            return total
        }
    }
}
