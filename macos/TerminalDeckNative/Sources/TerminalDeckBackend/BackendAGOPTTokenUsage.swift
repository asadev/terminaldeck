import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// Reads the exact account-confined record already selected by the task locator.
/// No account probes, directory search, price estimates or context-window guesses.
public struct BackendAGOPTTokenUsage: Sendable {
    public let locate: @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget?
    private let incremental = BackendAGOPTIncrementalUsage()
    private let ledger: BackendAGOPTTokenLedger
    public init(locate: @escaping @Sendable (BackendSessionMeta) async throws -> BackendTaskTranscriptTarget?, persistence: BackendTaskPersistence? = nil) {
        self.locate = locate; ledger = BackendAGOPTTokenLedger(persistence: persistence)
    }
    public func total(_ session: BackendSessionMeta) async throws -> Double? {
        guard let target = try await locate(session) else { return nil }
        return try await recordedTotal(provider: session.provider, target: target)
    }
    /// Retain observed per-message maxima across transcript rewrites and app
    /// restarts. Rewind changes context; it cannot refund consumed tokens.
    public func recordedTotal(provider: String, target: BackendTaskTranscriptTarget) async throws -> Double? {
        let amounts: [String: Double]
        if provider == "gemini", target.path.hasSuffix(".json") {
            guard let rows = try Self.rows(provider: provider, target: target), let values = Self.amounts(provider: provider, rows: rows) else { return nil }
            amounts = values
        } else {
            guard let values = try await incremental.read(provider: provider, target: target) else { return nil }
            amounts = values
        }
        let identity = provider + "\n" + URL(fileURLWithPath: target.path).resolvingSymlinksInPath().standardizedFileURL.path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let messageIDs = provider == "claude" ? Set(amounts.keys.map { String($0.dropFirst("message:".count)) }) : []
        return try await ledger.observe(key: key, amounts: amounts, claudeMessageIDs: messageIDs)
    }
    /// Reuse the existing vnode event watcher. It reads no account/probe state
    /// and watches only the already-authorized exact transcript and its parent.
    public func observe(_ session: BackendSessionMeta, onChange: @escaping @Sendable () -> Void) async throws -> (@Sendable () -> Void)? {
        guard let target = try await locate(session) else { return nil }
        let path: String, roots: [String]
        if session.provider == "claude" {
            guard let scope = target.scope else { throw NativeRPCError(code: "usage-unavailable", message: "The Claude usage record has no account scope.") }
            path = try NativeTranscriptPaths.assertTranscript(target.path, scope: scope)
            roots = try NativeTranscriptPaths.approvedRoots(scope)
        } else { path = target.path; roots = target.roots }
        let (fd, _) = try BackendUsageIO.openChecked(path, roots: roots); Darwin.close(fd)
        let watcher = BackendUsageFileWatch(changed: onChange)
        guard try watcher.install(paths: [path, URL(fileURLWithPath: path).deletingLastPathComponent().path]) > 0 else { return nil }
        return { watcher.stop() }
    }
    public static let maximumBytes = 32 * 1024 * 1024
    public static func read(provider: String, target: BackendTaskTranscriptTarget) throws -> Double? {
        guard let rows = try rows(provider: provider, target: target) else { return nil }
        return total(provider: provider, rows: rows)
    }
    func bytesRead() async -> Int { await incremental.bytesRead }

    fileprivate static func checkedLocation(provider: String, target: BackendTaskTranscriptTarget) throws -> (String, [String]) {
        let path: String, roots: [String]
        if provider == "claude" {
            guard let scope = target.scope else { throw NativeRPCError(code: "usage-unavailable", message: "Claude usage needs its exact approved transcript scope.") }
            path = try NativeTranscriptPaths.assertTranscript(target.path, scope: scope)
            roots = try NativeTranscriptPaths.approvedRoots(scope)
        } else { path = target.path; roots = target.roots }
        return (path, roots)
    }
    private static func rows(provider: String, target: BackendTaskTranscriptTarget) throws -> [NativeRPCValue]? {
        let (path, roots) = try checkedLocation(provider: provider, target: target)
        let (fd, _) = try BackendUsageIO.openChecked(path, roots: roots)
        defer { Darwin.close(fd) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let length = Darwin.read(fd, &buffer, buffer.count)
            guard length >= 0 else { throw NativeRPCError(code: "usage-unavailable", message: "The agent's usage record could not be read.") }
            if length == 0 { break }
            guard data.count + length <= maximumBytes else { return nil }
            data.append(contentsOf: buffer.prefix(length))
        }
        if provider == "gemini", target.path.hasSuffix(".json") {
            let raw = try NativeRPCValue.parseJSON(data, maximumBytes: maximumBytes)
            return raw["messages"].elements ?? []
        }
        let rows = data.split(separator: 10).compactMap { try? NativeRPCValue.parseJSON(Data($0), maximumBytes: maximumBytes) }
        return rows
    }
    public static func total(provider: String, rows: [NativeRPCValue]) -> Double? {
        amounts(provider: provider, rows: rows)?.values.reduce(0, +)
    }
    fileprivate static func amounts(provider: String, rows: [NativeRPCValue]) -> [String: Double]? {
        func count(_ value: NativeRPCValue) -> Double? {
            guard let number = value.number, number.isFinite, number >= 0, number <= 1e15 else { return nil }
            return number
        }
        switch provider {
        case "codex":
            // This is the conversation's cumulative usage. `last_token_usage` is
            // one request and model_context_window is capacity, not expenditure.
            return rows.compactMap { row -> Double? in
                guard row["type"].string == "event_msg", row["payload"]["type"].string == "token_count" else { return nil }
                return count(row["payload"]["info"]["total_token_usage"]["total_tokens"])
            }.max().map { ["cumulative": $0] }
        case "claude":
            var requests: [String: Double] = [:]
            for row in rows {
                guard row["type"].string == "assistant", let id = row["message"]["id"].string,
                      row["message"]["usage"].fields != nil else { continue }
                let usage = row["message"]["usage"]
                guard let input = count(usage["input_tokens"]), let output = count(usage["output_tokens"]) else { continue }
                let cacheRead = count(usage["cache_read_input_tokens"]) ?? 0
                let cacheWrite = count(usage["cache_creation_input_tokens"]) ??
                    ((count(usage["cache_creation"]["ephemeral_5m_input_tokens"]) ?? 0) + (count(usage["cache_creation"]["ephemeral_1h_input_tokens"]) ?? 0))
                let key = "message:" + id
                // Streaming updates repeat the same message. Keep its largest
                // measured total rather than charging each fragment again.
                requests[key] = max(requests[key] ?? 0, input + output + cacheRead + cacheWrite)
            }
            return requests.isEmpty ? nil : requests
        case "gemini":
            // Rewind discards context, not tokens already consumed. Repeated
            // message updates are charged once at their largest observed total.
            var totals: [String: Double] = [:]
            for row in rows {
                guard row["type"].string == "gemini", let id = row["id"].string,
                      let value = count(row["tokens"]["total"]) else { continue }
                totals[id] = max(totals[id] ?? 0, value)
            }
            return totals.isEmpty ? nil : totals
        default: return nil
        }
    }
}

/// Keep only the offset and unfinished line. The ledger owns the running message maxima.
private actor BackendAGOPTIncrementalUsage {
    private struct Cursor {
        var device: dev_t, inode: ino_t
        var offset: off_t = 0
        var modified: timespec
        var pending = Data()
        var hasUsage = false
    }
    private var cursors: [String: Cursor] = [:]
    private(set) var bytesRead = 0

    func read(provider: String, target: BackendTaskTranscriptTarget) throws -> [String: Double]? {
        let (path, roots) = try BackendAGOPTTokenUsage.checkedLocation(provider: provider, target: target)
        // Check confinement again even when the file has not grown.
        let (fd, info) = try BackendUsageIO.openChecked(path, roots: roots)
        defer { Darwin.close(fd) }
        guard info.st_size <= BackendAGOPTTokenUsage.maximumBytes else { return nil }
        let key = provider + "\n" + NativeTranscriptPaths.canonical(path)
        var cursor = cursors[key] ?? Cursor(device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec)
        let changed = cursor.modified.tv_sec != info.st_mtimespec.tv_sec || cursor.modified.tv_nsec != info.st_mtimespec.tv_nsec
        if cursor.device != info.st_dev || cursor.inode != info.st_ino || info.st_size < cursor.offset || (info.st_size == cursor.offset && changed) {
            cursor = Cursor(device: info.st_dev, inode: info.st_ino, modified: info.st_mtimespec)
        }
        guard lseek(fd, cursor.offset, SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
        var data = cursor.pending, buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while cursor.offset < info.st_size {
            try Task.checkCancellation()
            let length = Darwin.read(fd, &buffer, min(buffer.count, Int(info.st_size - cursor.offset)))
            if length < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
            if length == 0 { break }
            data.append(contentsOf: buffer.prefix(length)); cursor.offset += off_t(length); bytesRead += length
        }
        let end = data.lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
        let complete = data[..<end]
        let rows = complete.split(separator: 10).compactMap { try? NativeRPCValue.parseJSON(Data($0), maximumBytes: BackendAGOPTTokenUsage.maximumBytes) }
        var amounts = BackendAGOPTTokenUsage.amounts(provider: provider, rows: rows) ?? [:]
        cursor.pending = Data(data[end...])
        // A complete final JSON record need not yet have its newline. Repeated message maxima
        // make reading that same record again when the newline arrives harmless.
        if let row = try? NativeRPCValue.parseJSON(cursor.pending, maximumBytes: BackendAGOPTTokenUsage.maximumBytes),
           let tail = BackendAGOPTTokenUsage.amounts(provider: provider, rows: [row]) {
            for (id, count) in tail { amounts[id] = max(amounts[id] ?? 0, count) }
        }
        cursor.hasUsage = cursor.hasUsage || !amounts.isEmpty
        cursor.modified = info.st_mtimespec
        if cursors.count >= 64, cursors[key] == nil { cursors.removeAll() }
        cursors[key] = cursor
        return cursor.hasUsage ? amounts : nil
    }
}
