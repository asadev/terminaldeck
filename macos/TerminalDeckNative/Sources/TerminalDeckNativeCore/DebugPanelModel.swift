import Foundation

// The Debug panel (`components/DebugPanel.tsx`), in Settings → Advanced →
// Diagnostics: the main process's IPC calls live, the session processes, a
// support bundle, and the log.

public struct IpcCallRecord: Equatable, Sendable, Identifiable {
    public let seq: Int
    public let channel: String
    public let kind: String
    public let at: Double
    public let ms: Double
    public let ok: Bool
    public let error: String?
    public var id: Int { seq }

    public init(seq: Int, channel: String, kind: String, at: Double, ms: Double, ok: Bool, error: String?) {
        self.seq = seq
        self.channel = channel
        self.kind = kind
        self.at = at
        self.ms = ms
        self.ok = ok
        self.error = error
    }

    public static func decode(_ raw: Any?) -> IpcCallRecord? {
        guard let r = raw as? [String: Any], let channel = r["channel"] as? String else { return nil }
        return IpcCallRecord(seq: TerminalJSON.int(r["seq"]) ?? 0, channel: channel, kind: r["kind"] as? String ?? "invoke",
                             at: TerminalJSON.number(r["at"]) ?? 0, ms: TerminalJSON.number(r["ms"]) ?? 0,
                             ok: TerminalJSON.bool(r["ok"]) != false, error: r["error"] as? String)
    }

    public static func list(_ raw: Any?) -> [IpcCallRecord] {
        (raw as? [Any] ?? []).compactMap(decode)
    }
}

public struct ChannelSummary: Equatable, Sendable, Identifiable {
    public let channel: String
    public let calls: Int
    public let avgMs: Double
    public let maxMs: Double
    public let errors: Int
    public var id: String { channel }
}

public struct LogTail: Equatable, Sendable {
    public let file: String
    public let lines: [String]
    public static func decode(_ raw: Any?) -> LogTail? {
        guard let r = raw as? [String: Any] else { return nil }
        return LogTail(file: r["file"] as? String ?? "", lines: (r["lines"] as? [Any] ?? []).compactMap { $0 as? String })
    }
}

public enum DebugPanelRules {
    /// The most calls kept on screen (`MAX_ROWS`).
    public static let maxRows = 500
    /// How often the session table re-reads (`SESSION_TICK_MS`).
    public static let sessionTick: Double = 2

    public static func ms(_ value: Double) -> String {
        if value >= 1000 { return String(format: "%.2f s", value / 1000) }
        if value >= 10 { return "\(Int(value.rounded())) ms" }
        return String(format: "%.1f ms", value)
    }

    public static func clock(_ at: Double, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: at / 1000)
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        let millis = Int((at.truncatingRemainder(dividingBy: 1000) + 1000).truncatingRemainder(dividingBy: 1000))
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis)
    }

    public static func duration(_ ms: Double) -> String {
        if ms < 0 { return "0s" }
        let seconds = Int((ms / 1000).rounded(.down))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// `summarizeCalls`: per channel, slowest average first.
    public static func summarize(_ records: [IpcCallRecord]) -> [ChannelSummary] {
        var order: [String] = []
        var by: [String: (total: Double, calls: Int, max: Double, errors: Int)] = [:]
        for record in records {
            if by[record.channel] == nil { order.append(record.channel) }
            var entry = by[record.channel] ?? (0, 0, 0, 0)
            entry.total += record.ms
            entry.calls += 1
            entry.max = max(entry.max, record.ms)
            if !record.ok { entry.errors += 1 }
            by[record.channel] = entry
        }
        let rows = order.map { channel -> ChannelSummary in
            let e = by[channel]!
            return ChannelSummary(channel: channel, calls: e.calls, avgMs: (e.total / Double(e.calls) * 10).rounded() / 10,
                                  maxMs: e.max, errors: e.errors)
        }
        return rows.enumerated().sorted { a, b in
            a.element.avgMs != b.element.avgMs ? a.element.avgMs > b.element.avgMs : a.offset < b.offset
        }.map(\.element)
    }

    /// `orderCalls`: filtered by channel, newest first.
    public static func order(_ records: [IpcCallRecord], filter: String) -> [IpcCallRecord] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = needle.isEmpty ? records : records.filter { $0.channel.lowercased().contains(needle) }
        return rows.reversed()
    }

    /// The newest `maxRows`, after one more arrived.
    public static func appending(_ record: IpcCallRecord, to calls: [IpcCallRecord]) -> [IpcCallRecord] {
        let next = calls + [record]
        return next.count > maxRows ? Array(next.suffix(maxRows)) : next
    }

    public static let subtitle = "Live view of the main process. Nothing here leaves the machine unless you copy it."
    public static let unwired = "The debug bridge is not available in this window."
    public static let bundleHint = "Versions, CLIs, IPC modules, config paths and the recent log. Secrets are stripped — check it before you paste it anyway."
    public static let bundleHelp = "Tokens, API keys, authorization headers and your home directory are stripped before the bundle leaves the main process."
}
