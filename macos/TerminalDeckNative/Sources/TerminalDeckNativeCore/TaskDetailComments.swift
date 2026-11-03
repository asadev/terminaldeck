import Foundation

// MARK: - Comments (task-comments.ts)

public enum CrmComments {
    public static let reactions = ["👍", "❤️", "😂", "🎉", "👀", "🙏", "✅", "🔥"]

    /// A scheduled comment not delivered yet.
    public static func isPending(_ meta: CommentMeta?, now: Date = Date()) -> Bool {
        guard let meta, let scheduled = meta.scheduledFor, meta.withdrawn == nil else { return false }
        if let delivered = meta.deliveredAt { return delivered == nil }
        return (CrmTime.date(scheduled)?.timeIntervalSince(now) ?? 0) > 0
    }

    /// A pending comment is only its author's.
    public static func visible(_ comment: TaskComment, _ meta: CommentMeta?, viewer: String, now: Date = Date()) -> Bool {
        !isPending(meta, now: now) || comment.authorUserId == viewer
    }

    /// Top-level comments, and the replies under each.
    public static func thread(_ comments: [TaskComment], meta: [String: CommentMeta]) -> (top: [TaskComment], replies: [String: [TaskComment]]) {
        let ids = Set(comments.map(\.id))
        var top: [TaskComment] = []
        var replies: [String: [TaskComment]] = [:]
        for c in comments {
            if let parent = meta[c.id]?.parentId, ids.contains(parent) {
                replies[parent, default: []].append(c)
            } else {
                top.append(c)
            }
        }
        return (top, replies)
    }

    /// "Send later" choices: in 20 minutes, in 2 hours, tomorrow, in 2 days, next week (8 am).
    public static func schedulePresets(now: Date = Date()) -> [(key: String, label: String, at: Date, hint: String)] {
        let today = CrmTime.todayYmd(now)
        func day(_ n: Int) -> Date {
            let p = TaskList.ymdAddDays(today, n).split(separator: "-").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 8)) ?? now
        }
        let toMonday = (8 - TaskList.ymdWeekday(today)) % 7
        let presets: [(String, String, Date)] = [
            ("20m", "In 20 minutes", now.addingTimeInterval(20 * 60)),
            ("2h", "In 2 hours", now.addingTimeInterval(2 * 3600)),
            ("tomorrow", "Tomorrow", day(1)),
            ("2d", "In 2 days", day(2)),
            ("next-week", "Next week", day(toMonday == 0 ? 7 : toMonday)),
        ]
        return presets.map { key, label, at in
            let hint = key == "20m" || key == "2h" ? CrmTime.clock(at, upper: true)
                : "\(CrmTime.days[CrmTime.parts(at).weekday]), \(CrmTime.clock(at, upper: true))"
            return (key, label, at, hint)
        }
    }

    /// "Today at 3:05 PM", "Tomorrow at …", "Wed, Sep 3 at …".
    public static func formatScheduled(_ iso: String, now: Date = Date()) -> String {
        guard let date = CrmTime.date(iso) else { return "" }
        let p = CrmTime.parts(date)
        let diff = TaskList.ymdDiff(CrmTime.todayYmd(now), p.ymd)
        let when = diff == 0 ? "Today" : diff == 1 ? "Tomorrow" : "\(CrmTime.days[p.weekday]), \(CrmTime.months[p.m - 1]) \(p.d)"
        return "\(when) at \(CrmTime.clock(date, upper: true))"
    }
}
