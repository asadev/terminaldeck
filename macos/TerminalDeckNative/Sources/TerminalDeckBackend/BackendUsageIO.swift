import Foundation
import Darwin
import TerminalDeckNativeCore

/// Shared bounded readers for metrics. No reader is opened by a constructor.
enum BackendUsageIO {
    static let chunkBytes = 4 * 1024 * 1024
    static let maximumLineBytes = 8 * 1024 * 1024
    static let maximumFileBytes = 512 * 1024 * 1024
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    static func string(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func number(_ value: Double?) -> NativeRPCValue { value.map(NativeRPCValue.number) ?? .null }
    static func timestamp(_ value: NativeRPCValue) -> Double {
        guard let text = value.string else { return 0 }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text).map { $0.timeIntervalSince1970 * 1000 } ?? 0
    }
    static func integer(_ value: NativeRPCValue, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard !value.isNullish else { return fallback }
        guard let number = value.number, number.rounded(.towardZero) == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
            throw NativeRPCError.invalidArguments("A metrics limit is outside its permitted range.")
        }
        return Int(number)
    }
    static func matches(_ pattern: String, _ text: String, insensitive: Bool = false) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: insensitive ? [.caseInsensitive] : []) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
    static func openChecked(_ path: String, roots: [String]) throws -> (Int32, stat) {
        let canonical = NativeTranscriptPaths.canonical(path)
        guard roots.contains(where: { NativeTranscriptPaths.isDescendant(canonical, of: NativeTranscriptPaths.canonical($0)) }) else {
            throw NativeRPCError(code: "access-denied", message: "This transcript is outside the account's approved data directories.")
        }
        let fd = Darwin.open(canonical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw NativeRPCError.malformed("The transcript is not a regular readable file.") }
            var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &name) == 0 else { throw NativeRPCError.malformed("The opened transcript path could not be checked.") }
            let opened = NativeTranscriptPaths.canonical(String(cString: name))
            guard roots.contains(where: { NativeTranscriptPaths.isDescendant(opened, of: NativeTranscriptPaths.canonical($0)) }) else { throw NativeRPCError(code: "access-denied", message: "The transcript moved outside the approved data directory.") }
            return (fd, info)
        } catch { Darwin.close(fd); throw error }
    }
    struct Scan: Sendable { var bytes = 0; var lines = 0; var oversizedLines = 0; var truncated = false }
    /// UTF8 is decoded only after a complete newline-delimited byte sequence.
    /// Torn final JSON, malformed records and overlarge individual lines are skipped.
    static func lines(path: String, roots: [String], maximumBytes: Int = maximumFileBytes,
                      cancellation: BackendMCPCancellation? = nil, deadline: Double? = nil,
                      isolation: isolated (any Actor)? = #isolation,
                      consume: (String) throws -> Void) async throws -> Scan {
        let (fd, info) = try openChecked(path, roots: roots); defer { Darwin.close(fd) }
        var result = Scan(), pending = Data(), dropping = false
        let limit = min(Int(info.st_size), maximumBytes)
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        while result.bytes < limit {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            if let deadline, now() >= deadline { result.truncated = true; break }
            let amount = Darwin.read(fd, &buffer, min(buffer.count, limit - result.bytes))
            if amount < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if amount == 0 { break }
            result.bytes += amount
            var start = 0
            for i in 0..<amount where buffer[i] == 10 {
                if result.lines % 512 == 0 {
                    if cancellation?.isCancelled == true || Task.isCancelled { throw CancellationError() }
                    if let deadline, now() >= deadline { result.truncated = true; return result }
                }
                if !dropping {
                    pending.append(contentsOf: buffer[start..<i])
                    if pending.count <= maximumLineBytes, let text = String(data: pending, encoding: .utf8) { try consume(text) }
                    else { result.oversizedLines += 1 }
                }
                pending.removeAll(keepingCapacity: true); dropping = false; start = i + 1; result.lines += 1
            }
            if start < amount, !dropping {
                pending.append(contentsOf: buffer[start..<amount])
                if pending.count > maximumLineBytes { pending.removeAll(keepingCapacity: true); dropping = true; result.oversizedLines += 1 }
            }
            await Task.yield()
        }
        // A complete final record without a newline is legitimate; JSON parsing
        // at the consumer rejects a partially appended final record.
        if !dropping, !pending.isEmpty, let text = String(data: pending, encoding: .utf8) { try consume(text) }
        result.truncated = result.truncated || info.st_size > maximumBytes || result.oversizedLines > 0
        return result
    }
    static func tail(path: String, roots: [String], bytes: Int) throws -> (String, Double) {
        let (fd, info) = try openChecked(path, roots: roots); defer { Darwin.close(fd) }
        let count = min(Int(info.st_size), bytes), offset = max(0, Int(info.st_size) - count)
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
        var data = Data(count: count), readCount = 0
        try data.withUnsafeMutableBytes { raw in
            while readCount < count {
                let amount = Darwin.read(fd, raw.baseAddress!.advanced(by: readCount), count - readCount)
                if amount < 0 { if errno == EINTR { continue }; throw POSIXError(.EIO) }
                if amount == 0 { break }; readCount += amount
            }
        }
        data.count = readCount
        // Drop the leading partial line and any split UTF8 scalar with it.
        if offset > 0 { if let cut = data.firstIndex(of: 10) { data.removeSubrange(...cut) } else { data.removeAll() } }
        return (String(decoding: data, as: UTF8.self), Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000)
    }
}

/// Vnode updates share one-shot debounce scheduling, never an idle polling loop.
final class BackendUsageFileWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "native.metrics.file-watch")
    private let changed: @Sendable () -> Void
    init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    @discardableResult func install(paths: [String]) throws -> Int {
        stop()
        var installed = 0
        var seen = Set<String>()
        for path in paths.filter({ seen.insert($0).inserted }).prefix(32) {
            let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
            if fd < 0 { if errno == ENOENT { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: queue)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in self?.schedule() }
            lock.withLock { sources.append(source) }; source.resume()
            installed += 1
        }
        return installed
    }
    private func schedule() {
        lock.withLock { pending?.cancel(); let item = DispatchWorkItem { [weak self] in self?.changed() }; pending = item; queue.asyncAfter(deadline: .now() + .milliseconds(750), execute: item) }
    }
    func stop() { let old = lock.withLock { pending?.cancel(); pending = nil; let old = sources; sources.removeAll(); return old }; old.forEach { $0.cancel() } }
    deinit { stop() }
}
