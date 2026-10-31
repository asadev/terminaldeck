import Foundation
import TerminalDeckNativeCore

/// The Files view over the server's existing SSH sign-in. One SFTP channel per open server
/// is kept while it is in use and closed after 45 s of quiet. Galleries use one read-only
/// `find` (streamed for progress); thumbnails and durations use the server's own ffmpeg,
/// ffprobe, convert or pdfinfo when they are there, never installing anything.
public actor BackendServersFilesLive: BackendServersFilesTransport {
    private let connections: BackendServersConnections
    private struct Held { let lease: BackendServersConnectionLease; let sftp: any BackendServersSFTP; var used: Double; var generation: Int }
    private var held: [String: Held] = [:]
    private var generation = 0
    public init(connections: BackendServersConnections) { self.connections = connections }

    private func sftp(_ server: String) async throws -> any BackendServersSFTP {
        if var entry = held[server], await connections.isCurrent(entry.lease) {
            entry.used = Date().timeIntervalSince1970; held[server] = entry; return entry.sftp
        }
        await drop(server)
        let lease = try await connections.acquireLease(server)
        do {
            let channel = try await connections.withConnection(lease) { try await $0.openSFTP() }
            generation += 1
            held[server] = .init(lease: lease, sftp: channel, used: Date().timeIntervalSince1970, generation: generation)
            idle(server, generation)
            return channel
        } catch { await connections.release(lease); throw error }
    }
    private func idle(_ server: String, _ gen: Int) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(45))
                guard let self, let used = await self.lastUse(server, gen) else { return }
                if Date().timeIntervalSince1970 - used >= 44 { await self.drop(server); return }
            }
        }
    }
    private func lastUse(_ server: String, _ gen: Int) -> Double? { held[server].flatMap { $0.generation == gen ? $0.used : nil } }
    private func drop(_ server: String) async {
        guard let entry = held.removeValue(forKey: server) else { return }
        entry.sftp.close(); await connections.release(entry.lease)
    }
    public func close(_ server: String) async { await drop(server) }
    /// One retry on a fresh channel when the held one went away.
    private func withSFTP<T: Sendable>(_ server: String, _ body: @Sendable (any BackendServersSFTP) async throws -> T) async throws -> T {
        do { return try await body(try await sftp(server)) }
        catch let problem as BackendServersProblem where problem.kind == "lost" || problem.kind == "no-answer" {
            await drop(server); return try await body(try await sftp(server))
        } catch is CancellationError { throw CancellationError() }
        catch let error where !(error is BackendServersProblem) && !(error is NativeRPCError) {
            await drop(server); return try await body(try await sftp(server))
        }
    }

    public func home(_ server: String) async throws -> String { try await withSFTP(server) { try await $0.realpath(".") } }
    public func realpath(_ server: String, _ path: String) async throws -> String { try await withSFTP(server) { try await $0.realpath(path) } }
    public func list(_ server: String, _ path: String) async throws -> [BackendServersFileEntry] {
        try await withSFTP(server) { sftp in
            try await sftp.listDetailed(path).map { row in
                .init(name: row.name, path: BackendServersFilePaths.join(path, row.name), kind: row.kind,
                      size: row.size.map { Int64(clamping: $0) }, modified: row.modified.map(Double.init))
            }
        }
    }
    public func stat(_ server: String, _ path: String) async throws -> BackendServersFileEntry {
        try await withSFTP(server) { sftp in
            let row = try await sftp.stat(path)
            return .init(name: (path as NSString).lastPathComponent, path: path, kind: row.kind, size: row.size.map { Int64(clamping: $0) }, modified: row.modified.map(Double.init))
        }
    }
    public func read(_ server: String, _ path: String, from: Int, length: Int) async throws -> (bytes: Data, size: Int) {
        try await withSFTP(server) { sftp in
            let size = try await sftp.size(path), start = max(0, from)
            var out = Data()
            _ = try await sftp.read(path, from: start, length: max(0, min(length, size - start))) { out.append($0) }
            return (out, size)
        }
    }
    public func download(_ server: String, _ path: String, to local: URL) async throws -> Int {
        try await connections.download(server, remotePath: path, localPath: local.path)
    }
    public func rename(_ server: String, _ from: String, _ to: String) async throws { try await withSFTP(server) { try await $0.rename(from, to: to) } }
    public func delete(_ server: String, _ path: String, folder: Bool) async throws {
        try await withSFTP(server) { sftp in if folder { try await sftp.rmdir(path) } else { try await sftp.unlink(path) } }
    }
    public func upload(_ server: String, local: URL, folder: String) async throws -> String {
        try await connections.putFile(server, localPath: local.path, name: local.lastPathComponent, folder: folder)
    }

    /// `find` prints "size<TAB>seconds<TAB>path" per match. GNU find uses -printf; others use
    /// GNU `stat -c` or BSD/macOS `stat -f`. Neither one: no end marker, so the scan fails aloud.
    static func scanScript(skip: [String], extensions: [String], limit: Int) -> String {
        let q = BackendServersConnections.quote
        let prune = skip.map { "-name \(q($0))" }.joined(separator: " -o ")
        let names = extensions.map { "-iname \(q("*." + $0))" }.joined(separator: " -o ")
        let filter = "\\( \(prune) \\) -prune -o -type f \\( \(names) \\)"
        return """
        T=; command -v timeout >/dev/null 2>&1 && T="timeout 600"
        if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then F=printf
        elif stat -c '%s' / >/dev/null 2>&1; then F=gnu
        elif stat -f '%z' / >/dev/null 2>&1; then F=bsd
        else echo 'it has no find -printf and no stat this app can read' >&2; exit 3; fi
        case $F in
          printf) $T find "$@" -xdev \(filter) -printf '%s\\t%T@\\t%p\\n' 2>/dev/null ;;
          gnu) $T find "$@" -xdev \(filter) -exec stat -c '%s\t%Y\t%n' {} + 2>/dev/null ;;
          *) $T find "$@" -xdev \(filter) -exec stat -f '%z%t%m%t%N' {} + 2>/dev/null ;;
        esac | head -n \(limit)
        echo '##td-scan-end'
        """
    }
    static func parseScanLine(_ line: Substring) -> BackendServersFileEntry? {
        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let size = Int64(parts[0]), parts[2].hasPrefix("/") else { return nil }
        let path = String(parts[2])
        return .init(name: (path as NSString).lastPathComponent, path: path, kind: "file", size: size, modified: Double(parts[1]))
    }
    public func scan(_ server: String, roots: [String], skip: [String], extensions: [String], limit: Int,
                     progress: @escaping @Sendable (Int, Int64) -> Void) async throws -> (entries: [BackendServersFileEntry], complete: Bool) {
        let script = Self.scanScript(skip: skip, extensions: extensions, limit: limit)
        let follow = try await connections.follow(server, argv: ["sh", "-c", script, "sh"] + roots)
        let box = ScanBox(limit: limit, progress: progress)
        let ended = BackendServersSSHOnce<BackendServersFollowEnd>()
        let a = follow.onBytes { box.take($0) }
        let b = follow.onEnd { ended.finish(.success($0)) }
        defer { a(); b(); follow.close() }
        let end = try await withTaskCancellationHandler { try await ended.value() } onCancel: { follow.close(); ended.finish(.failure(CancellationError())) }
        let result = box.finish()
        if !result.sawEnd, result.entries.isEmpty, end.code != 0 {
            throw BackendServersProblem("lost", "This server could not search its folders (\(end.stderr.split(separator: "\n").first.map(String.init) ?? "no answer")).")
        }
        return (result.entries, result.sawEnd && result.entries.count < limit)
    }
    private final class ScanBox: @unchecked Sendable {
        private let lock = NSLock(), limit: Int, progress: @Sendable (Int, Int64) -> Void
        private var pending = Data(), entries: [BackendServersFileEntry] = [], bytes: Int64 = 0, sawEnd = false, lastReport = 0
        init(limit: Int, progress: @escaping @Sendable (Int, Int64) -> Void) { self.limit = limit; self.progress = progress }
        func take(_ data: Data) {
            let report: (Int, Int64)? = lock.withLock {
                pending.append(data)
                while let newline = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if line == "##td-scan-end" { sawEnd = true; continue }
                    if entries.count < limit, let entry = BackendServersFilesLive.parseScanLine(Substring(line)) { entries.append(entry); bytes += entry.size ?? 0 }
                }
                if entries.count - lastReport >= 200 { lastReport = entries.count; return (entries.count, bytes) }
                return nil
            }
            if let report { progress(report.0, report.1) }
        }
        func finish() -> (entries: [BackendServersFileEntry], sawEnd: Bool) { lock.withLock { (entries, sawEnd) } }
    }

    public func measure(_ server: String, _ path: String, type: String) async throws -> Double? {
        let argv: [String] = type == "document"
            ? ["sh", "-c", "command -v pdfinfo >/dev/null 2>&1 || exit 3; pdfinfo \"$1\" 2>/dev/null | sed -n 's/^Pages:[[:space:]]*//p'", "sh", path]
            : ["sh", "-c", "command -v ffprobe >/dev/null 2>&1 || exit 3; ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 \"$1\"", "sh", path]
        if type == "document", BackendServersFileTypes.ext(path) != "pdf" { return nil }
        let result = try await connections.run(server, argv: argv)
        guard result.code == 0, let value = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value > 0 else {
            if type == "document" { return try await pdfPagesByReading(server, path) }
            return nil
        }
        return value
    }
    /// No pdfinfo: count page objects in a small PDF.
    private func pdfPagesByReading(_ server: String, _ path: String) async throws -> Double? {
        let size = try await withSFTP(server) { try await $0.size(path) }
        guard size > 0, size <= 8 * 1024 * 1024 else { return nil }
        let bytes = try await read(server, path, from: 0, length: size).bytes
        let text = String(decoding: bytes, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "/Type\\s*/Page(?![a-zA-Z])") else { return nil }
        let count = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        return count > 0 ? Double(count) : nil
    }
    public func serverThumbnail(_ server: String, _ path: String, type: String) async throws -> Data? {
        let seek = type == "video" ? "-ss 1" : ""
        let script = """
        if command -v ffmpeg >/dev/null 2>&1; then
          ffmpeg -nostdin -v error \(seek) -i "$1" -frames:v 1 -vf scale=360:-2 -f image2pipe -vcodec mjpeg - 2>/dev/null | base64
        elif command -v convert >/dev/null 2>&1 && [ "\(type)" = photo ]; then
          convert "$1[0]" -thumbnail 360x360 jpg:- 2>/dev/null | base64
        else exit 3; fi
        """
        let result = try await connections.run(server, argv: ["sh", "-c", script, "sh", path])
        guard result.code == 0, !result.truncated else { return nil }
        let data = Data(base64Encoded: result.stdout.filter { !$0.isWhitespace })
        return (data?.count ?? 0) > 100 ? data : nil
    }
}
