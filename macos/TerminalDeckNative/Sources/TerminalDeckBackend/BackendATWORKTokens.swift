import Foundation
import Darwin
import TerminalDeckNativeCore

/// Per-conversation token counts, cached by file identity/size/time and local day.
/// Called by inventory events, never by the metrics clock. Large/inaccessible
/// or unsupported transcripts answer nil rather than a lifetime total.
public actor BackendATWORKTokens {
    private struct Cached: Sendable { let size: UInt64, modified: Date, inode: UInt64, device: Int32, day: Date, value: Double? }
    private var cache: [String: Cached] = [:]
    public init() {}
    public func fileIdentity(_ path: String) -> String? {
        guard let value = cache[path] else { return nil }
        return String(value.device) + ":" + String(value.inode)
    }
    public func read(path: String, provider: String, scope: NativeTranscriptScope, now: Date = Date()) async throws -> Double? {
        try await read(target: .init(path: path, scope: scope), provider: provider, now: now)
    }
    public func read(target: BackendTaskTranscriptTarget, provider: String, now: Date = Date()) async throws -> Double? {
        let approved: String, roots: [String]
        if provider == "claude" {
            guard let scope = target.scope else { return nil }
            approved = try NativeTranscriptPaths.assertTranscript(target.path, scope: scope)
            roots = try NativeTranscriptPaths.approvedRoots(scope)
        } else { approved = target.path; roots = target.roots }
        let (fd, info) = try BackendUsageIO.openChecked(approved, roots: roots)
        Darwin.close(fd)
        let size = UInt64(max(0, info.st_size)), inode = UInt64(info.st_ino), device = info.st_dev
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let day = Calendar.current.startOfDay(for: now)
        if let old = cache[approved], old.size == size, old.modified == modified, old.inode == inode, old.device == device, old.day == day { return old.value }
        // Do not label a bounded tail as the whole day's usage. A separate
        // owner can later supply an indexed ledger for larger conversations.
        guard size <= 4 * 1024 * 1024 else { return nil }
        var lines: [String] = []
        let scan = try await BackendUsageIO.lines(path: approved, roots: roots, maximumBytes: 4 * 1024 * 1024) { lines.append($0) }
        guard !scan.truncated else { return nil }
        let value: Double?
        if provider == "gemini", approved.hasSuffix(".json"), let raw = try? NativeRPCValue.parseJSON(Data(lines.joined(separator: "\n").utf8), maximumBytes: 4 * 1024 * 1024) {
            let dayStart = day.timeIntervalSince1970 * 1000
            let dayEnd = (Calendar.current.date(byAdding: .day, value: 1, to: day) ?? now).timeIntervalSince1970 * 1000
            value = Self.today(rows: raw["messages"].elements ?? [], provider: provider, lower: dayStart, upper: dayEnd)
        } else { value = try Self.today(lines: lines, provider: provider, now: now) }
        cache[approved] = .init(size: size, modified: modified, inode: inode, device: device, day: day, value: value)
        if cache.count > 300 { cache.removeAll() }
        return value
    }
    public nonisolated static func today(lines: [String], provider: String, now: Date = Date(), calendar: Calendar = .current) throws -> Double? {
        let day = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        let lower = day.timeIntervalSince1970 * 1000, upper = end.timeIntervalSince1970 * 1000
        let rows = lines.compactMap { try? NativeRPCValue.parseJSON(Data($0.utf8)) }
        return today(rows: rows, provider: provider, lower: lower, upper: upper)
    }
    private nonisolated static func today(rows: [NativeRPCValue], provider: String, lower: Double, upper: Double) -> Double? {
        let during = rows.filter { let at = BackendUsageIO.timestamp($0["timestamp"]); return at >= lower && at < upper }
        if provider == "codex" {
            // AGOPT already handles cumulative records. Subtract the last
            // complete baseline before midnight, never relabel lifetime usage.
            let before = rows.filter { let at = BackendUsageIO.timestamp($0["timestamp"]); return at > 0 && at < lower }
            guard let today = BackendAGOPTTokenUsage.total(provider: provider, rows: during) else {
                return BackendAGOPTTokenUsage.total(provider: provider, rows: rows).map { _ in 0 }
            }
            let baseline = BackendAGOPTTokenUsage.total(provider: provider, rows: before)
            if baseline == nil {
                // Without an earlier counter, only a proved new conversation
                // can attribute its entire cumulative count to this day.
                guard let start = rows.first(where: { $0["type"].string == "session_meta" }),
                      BackendUsageIO.timestamp(start["timestamp"]) >= lower,
                      start["payload"]["forked_from_id"].isNullish else { return nil }
            }
            return max(0, today - (baseline ?? 0))
        }
        guard ["claude", "gemini"].contains(provider) else { return nil }
        var firstAt: [String: Double] = [:]
        func key(_ row: NativeRPCValue) -> String? {
            if provider == "claude", let id = row["message"]["id"].string { return (row["requestId"].string ?? "") + ":" + id }
            if provider == "gemini" { return row["id"].string }
            return nil
        }
        for row in rows {
            guard let id = key(row) else { continue }
            let at = BackendUsageIO.timestamp(row["timestamp"])
            if at > 0 { firstAt[id] = min(firstAt[id] ?? at, at) }
        }
        let requestedToday = rows.filter { row in
            guard let id = key(row), let at = firstAt[id] else { return false }
            return at >= lower && at < upper
        }
        return BackendAGOPTTokenUsage.total(provider: provider, rows: requestedToday) ?? BackendAGOPTTokenUsage.total(provider: provider, rows: rows).map { _ in 0 }
    }
}
