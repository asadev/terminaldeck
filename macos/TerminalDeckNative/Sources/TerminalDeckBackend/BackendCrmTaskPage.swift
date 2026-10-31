import Foundation
import TerminalDeckNativeCore

public enum BackendCrmTaskRules {
    public static let maxUploadBytes = CrmFiles.maxUploadBytes
    public static let maxUploadLabel = "25 MB"
    public static let safeInlineMime: Set<String> = ["application/pdf", "image/png", "image/jpeg", "image/gif", "image/webp"]
    public enum UploadCheck: Equatable, Sendable {
        case allowed
        case refused(error: String, status: Int)
        public var wire: NativeRPCValue {
            switch self {
            case .allowed: .object([.init("ok", .bool(true))])
            case .refused(let error, let status): .object([.init("ok", .bool(false)), .init("error", .string(error)), .init("status", .number(Double(status)))])
            }
        }
    }
    public static func fileExtension(_ name: String) -> String { CrmFiles.fileExtension(name) }
    public static func checkUpload(name: String, size: Double) -> UploadCheck {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .refused(error: "The file has no name.", status: 400) }
        if !size.isFinite || size <= 0 { return .refused(error: "The file is empty.", status: 400) }
        if size > Double(maxUploadBytes) { return .refused(error: "“\(trimmed)” is too big — the limit is \(maxUploadLabel).", status: 413) }
        // Only the extension remains to check. The positive fractional sizes
        // accepted in JS stay accepted without an unsafe Double→Int cast.
        if let error = CrmFiles.checkUpload(name: trimmed, size: 1) { return .refused(error: error, status: 400) }
        return .allowed
    }
    public static func parseDuration(_ text: String) -> Double? { CrmTime.parseDuration(text) }
    public static func formatDuration(_ seconds: Double) -> String { CrmTime.duration(seconds) }
    public static func formatClock(_ seconds: Double) -> String { CrmTime.clockDuration(seconds) }
    public static func totalTracked(_ entries: [TimeEntry], now: Date = Date(), zone: TimeZone = .current) -> Double {
        var total = 0.0
        for entry in entries {
            if let seconds = entry.seconds { total += seconds }
            else if entry.endedAt?.isEmpty != false {
                guard let started = BackendCrmTime.parseInstant(entry.startedAt, zone: zone) else { return .nan }
                total += max(0, floor(now.timeIntervalSince(started)))
            }
        }
        return total
    }
}

public enum BackendCrmAttachmentRules {
    public static let localFileScheme = "task-file:"
    public static func servesInline(_ mime: String?) -> Bool { mime.map(BackendCrmTaskRules.safeInlineMime.contains) ?? false }
    public static func taskAttachmentHref(taskID: String, attachmentID: String, download: Bool = false) -> String {
        CrmFiles.href(taskId: taskID, attachmentId: attachmentID, download: download)
    }
    /// JS decodeURIComponent throws on malformed percent escapes; never guess
    /// an undecodable attachment ID into a filesystem lookup.
    public static func parseTaskAttachmentHref(_ href: String) throws -> (taskId: String, attachmentId: String)? {
        guard href.hasPrefix(localFileScheme) else { return nil }
        let path = String(href.dropFirst(localFileScheme.count)).components(separatedBy: "?")[0]
        let parts = try path.components(separatedBy: "/").map { part -> String in
            guard let decoded = part.removingPercentEncoding else { throw NativeRPCError(code: "URIError", message: "URI malformed") }
            return decoded
        }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
    public static func inlineKind(_ mime: String?, fileName: String) -> String { CrmFiles.isImage(mime: mime, fileName: fileName) ? "image" : "file" }
}

public enum BackendCrmTaskPage {
    public static let headingMax = 80, maxLabels = 20, maxLabelLength = 40
    public static let migration = "2026-09-15-task-page.sql"
    public static let statusFlow = ["To-Do", "Working on it", "In Progress", "Done"]
    public static let taskTypes = ["task", "milestone"]
    public static let taskTypeLabel = ["task": "Task", "milestone": "Milestone"]
    public static let defaultRecurrenceRule: CrmValue = .object(["createNew": .bool(true), "forever": .bool(true), "until": .null, "updateStatusTo": .null, "syncToDue": .bool(true)])
    public static func splitTaskText(_ text: String) -> (heading: String, body: String, cut: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Position { let storage: Int, visible: Int; let character: String? }
        var positions: [Position] = [], storage = 0, visible = 0
        for part in BackendCrmInlineFiles.splitInlineFiles(trimmed) {
            switch part {
            case .file(let id):
                positions.append(Position(storage: storage, visible: visible, character: nil))
                storage += BackendCrmInlineFiles.fileToken(id).utf16.count
            case .text(let run):
                // JavaScript for…of counts Unicode code points, not graphemes.
                for scalar in run.unicodeScalars {
                    let ch = String(scalar)
                    positions.append(Position(storage: storage, visible: visible, character: ch))
                    storage += ch.utf16.count; visible += 1
                }
            }
        }
        func at(_ i: Int) -> Int { i < positions.count && i >= 0 ? positions[i].storage : trimmed.utf16.count }
        func slice(_ start: Int, _ end: Int? = nil) -> String { BackendCrmInlineFiles.slice(trimmed, start, end).trimmingCharacters(in: .whitespacesAndNewlines) }
        let nl = positions.firstIndex { $0.character == "\n" } ?? -1
        if nl > 0 && positions[nl].visible <= headingMax { return (slice(0, at(nl)), slice(at(nl) + 1), false) }
        if positions.count > 1 {
            for i in 0..<(positions.count - 1) {
                let p = positions[i]
                if p.visible >= headingMax { break }
                if [".", "?", "!"].contains(p.character ?? ""), positions[i + 1].character == " " {
                    let end = at(i + 1), rest = slice(end)
                    if !rest.isEmpty { return (slice(0, end), rest, false) }
                }
            }
        }
        if visible <= headingMax && nl < 0 { return (trimmed, "", false) }
        if visible <= headingMax { return (slice(0, at(nl)), slice(at(nl) + 1), false) }
        var cut = positions.firstIndex { $0.visible >= headingMax && $0.character != nil } ?? 0
        if cut > 0 {
            for i in stride(from: cut, through: 1, by: -1) {
                if positions[i].character == " " || positions[i].character == "\n" { cut = i; break }
            }
        }
        let end = at(cut)
        return (slice(0, end) + "…", "…" + slice(end), true)
    }
    public static func nextStatus(_ status: String) -> String? { CrmText.nextStatus(status) }
    public static func statusWord(_ status: String) -> String { CrmText.statusWord(status) }
    public static func activityTime(_ iso: String, now: Date = Date(), zone: TimeZone = .current) -> String {
        guard let date = BackendCrmTime.parseInstant(iso, zone: zone) else { return "" }
        let seconds = max(0, TaskFields.jsRound(now.timeIntervalSince(date)))
        if seconds < 60 { return "Just now" }
        let minutes = TaskFields.jsRound(seconds / 60)
        if minutes < 60 { return "\(TaskFields.js(minutes)) min\(minutes == 1 ? "" : "s")" }
        let hours = TaskFields.jsRound(minutes / 60), start = BackendCrmTime.localDayStartMs(now, zone: zone) / 1000
        if date.timeIntervalSince1970 >= start { return "\(TaskFields.js(hours)) hour\(hours == 1 ? "" : "s")" }
        if date.timeIntervalSince1970 >= start - 86_400 { return "Yesterday at \(BackendCrmTime.localClock(date, zone: zone))" }
        guard let parts = BackendCrmTime.localParts(date, zone: zone), let current = BackendCrmTime.localParts(now, zone: zone) else { return "" }
        let day = "\(BackendCrmTime.monthShort[parts.m - 1]) \(parts.d)"
        return parts.y == current.y ? "\(day) at \(BackendCrmTime.localClock(date, zone: zone))" : "\(day), \(parts.y)"
    }
    public static func activityStamp(_ iso: String, zone: TimeZone = .current) -> String {
        guard let p = BackendCrmTime.localParts(iso, zone: zone) else { return "" }
        return "\(BackendCrmTime.monthShort[p.m - 1]) \(p.d) at \(BackendCrmTime.localClock(iso, zone: zone))"
    }
    public static func timeEntryDay(_ entry: TimeEntry, zone: TimeZone = .current) -> String {
        BackendCrmTime.localParts(entry.endedAt ?? entry.startedAt, zone: zone)?.ymd ?? ""
    }
    public static func ymdMonthDay(_ day: String) -> String { CrmTime.ymdMonthDay(day) }
    public static func monthDay(_ iso: String, zone: TimeZone = .current) -> String {
        guard let p = BackendCrmTime.localParts(iso, zone: zone) else { return "" }
        return "\(BackendCrmTime.monthShort[p.m - 1]) \(p.d)"
    }
    public static func normalizeRecurrenceRule(_ raw: CrmValue?) -> CrmValue {
        guard let r = raw?.object else { return defaultRecurrenceRule }
        let until = r["until"]?.string.flatMap { BackendCrmTime.isYmd($0) ? $0 : nil }
        let status = BackendCrmShim.isTaskStatus(r["updateStatusTo"]) && r["updateStatusTo"] != .string("Done") ? r["updateStatusTo"]! : .null
        return .object(["createNew": .bool(r["createNew"]?.bool ?? true), "forever": .bool(r["forever"]?.bool ?? true),
            "until": r["forever"] == .bool(false) ? until.map(CrmValue.string) ?? .null : .null,
            "updateStatusTo": status, "syncToDue": .bool(r["syncToDue"]?.bool ?? true)])
    }
    public static func normalizeLabels(_ input: [CrmValue]) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for value in input {
            guard let text = value.string else { continue }
            let normalized = BackendCrmInlineFiles.slice(BackendCrmFields.collapse(text), 0, maxLabelLength)
            if normalized.isEmpty || !seen.insert(normalized.lowercased()).inserted { continue }
            out.append(normalized)
            if out.count >= maxLabels { break }
        }
        return out
    }
    public static func isTaskType(_ value: String?) -> Bool { value.map(taskTypes.contains) ?? false }
    public static func notAvailableSentence(code: String?) -> String {
        ["42P01", "PGRST205", "42703", "PGRST204", "PGRST202", "42883"].contains(code ?? "") ? "This isn't available yet." : "This could not be read just now."
    }
}

public enum BackendCrmComments {
    public static let migration = "2026-09-15-task-comments.sql"
    public static let reactionEmoji = CrmComments.reactions
    public static func isReactionEmoji(_ emoji: String?) -> Bool { emoji.map(reactionEmoji.contains) ?? false }
    public static func isPending(_ meta: CommentMeta?, now: Date = Date(), zone: TimeZone = .current) -> Bool {
        guard let meta, let scheduled = meta.scheduledFor, !scheduled.isEmpty, meta.withdrawn == nil else { return false }
        if let delivered = meta.deliveredAt { return delivered == nil }
        return (BackendCrmTime.parseInstant(scheduled, zone: zone)?.timeIntervalSince(now) ?? 0) > 0
    }
    public static func visibleTo(authorUserID: String?, meta: CommentMeta?, viewerID: String, now: Date = Date(), zone: TimeZone = .current) -> Bool {
        !isPending(meta, now: now, zone: zone) || authorUserID == viewerID
    }
    public static func threadComments<C>(_ comments: [C], id: (C) -> String, meta: [String: CommentMeta]) -> (top: [C], replies: [String: [C]]) {
        let ids = Set(comments.map(id))
        var top: [C] = [], replies: [String: [C]] = [:]
        for comment in comments {
            if let parent = meta[id(comment)]?.parentId, !parent.isEmpty, ids.contains(parent) { replies[parent, default: []].append(comment) }
            else { top.append(comment) }
        }
        return (top, replies)
    }
    public static func threadComments(_ comments: [TaskComment], meta: [String: CommentMeta]) -> (top: [TaskComment], replies: [String: [TaskComment]]) {
        threadComments(comments, id: { $0.id }, meta: meta)
    }
    public static func schedulePresets(now: Date = Date(), zone: TimeZone = .current) -> [(key: String, label: String, at: Date, hint: String)] {
        let today = BackendCrmTime.localToday(now, zone: zone), n = (8 - BackendCrmTime.ymdWeekday(today)) % 7
        func day(_ n: Int) -> Date { BackendCrmTime.localInstantAt(BackendCrmTime.ymdAddDays(today, n), 8, zone: zone)! }
        let presets = [("20m", "In 20 minutes", now.addingTimeInterval(1200)), ("2h", "In 2 hours", now.addingTimeInterval(7200)),
            ("tomorrow", "Tomorrow", day(1)), ("2d", "In 2 days", day(2)), ("next-week", "Next week", day(n == 0 ? 7 : n))]
        return presets.map { key, label, at in
            let clock = BackendCrmTime.localClock(at, upper: true, zone: zone)
            let hint = key == "20m" || key == "2h" ? clock : "\(BackendCrmTime.dayShort[BackendCrmTime.localParts(at, zone: zone)!.weekday]), \(clock)"
            return (key, label, at, hint)
        }
    }
    public static func formatScheduled(_ iso: String, now: Date = Date(), zone: TimeZone = .current) -> String {
        guard let p = BackendCrmTime.localParts(iso, zone: zone) else { return "" }
        let diff = BackendCrmTime.ymdDiff(BackendCrmTime.localToday(now, zone: zone), p.ymd)
        let when = diff == 0 ? "Today" : diff == 1 ? "Tomorrow" : "\(BackendCrmTime.dayShort[p.weekday]), \(BackendCrmTime.monthShort[p.m - 1]) \(p.d)"
        return "\(when) at \(BackendCrmTime.localClock(iso, upper: true, zone: zone))"
    }
}
