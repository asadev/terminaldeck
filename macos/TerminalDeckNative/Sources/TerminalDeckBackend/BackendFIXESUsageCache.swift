import Foundation
import Darwin
import TerminalDeckNativeCore

/// In-memory checkpoints keep Overview reads short. Caller authorization and
/// transcript membership are still checked by BackendCostService on every read.
actor BackendFIXESUsageCache {
    static func budgetNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
    /// Internal checkpoint metadata includes file identity; it is not a second
    /// public transcript/session presentation model.
    struct CatalogFile: Sendable {
        let path: String
        let bytes: Int64
        let modifiedAt: Double
        let identity: String
    }
    struct CatalogueRead: Sendable {
        let files: [CatalogFile]
        let scanning: Bool
        let progress: Int
        let limited: Bool
    }
    private struct Catalogue {
        let signature: String
        var directory = 0
        var visited = 0
        var enumerator: FileManager.DirectoryEnumerator?
        var files: [CatalogFile] = []
        var validationCursor = 0
        var progress = 0
        var retainedBytes = 0
        var limited = false
    }
    struct Read: Sendable {
        let transcript: BackendCostTranscript
        let bytesRead: Int
        let scanning: Bool
        let limited: Bool
    }
    private struct Stamp {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanoseconds = info.st_birthtimespec.tv_nsec
            size = info.st_size; seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanoseconds = info.st_ctimespec.tv_nsec
        }
        func canAppend(to next: Self) -> Bool {
            device == next.device && inode == next.inode && birthSeconds == next.birthSeconds &&
            birthNanoseconds == next.birthNanoseconds && size <= next.size &&
            (size != next.size || (seconds == next.seconds && nanoseconds == next.nanoseconds &&
                changedSeconds == next.changedSeconds && changedNanoseconds == next.changedNanoseconds))
        }
    }
    private struct Entry {
        var stamp: Stamp
        var transcript: BackendCostTranscript
        var offset = 0
        var pending = Data()
        var dropping = false
        var touched: UInt64 = 0
        var membershipCwd: String?
        var membershipLines = 0
        var budgetReached = false
        var retainedBytes = 1024
        var header = Data()
        var boundary = Data()
    }
    private var entries: [String: Entry] = [:]
    private var catalogues: [String: Catalogue] = [:]
    private var serial: UInt64 = 0
    private let maximumEntries = 512
    private let maximumRetainedRecords = 250_000
    private let maximumRetainedBytes = 64 * 1024 * 1024

    /// Directory discovery also has a cursor: even a large folder can return
    /// a useful partial answer without a synchronous all-files stat pass.
    func catalogue(project: String, scope: NativeTranscriptScope, deadline: Double) throws -> CatalogueRead {
        let directories = try NativeTranscriptPaths.projectDirectories(project, scope: scope)
        let key = NativeTranscriptPaths.resolved(project) + "\n" + directories.joined(separator: "\n") + "\n" + (scope.projectFolders ?? []).joined(separator: "\n") + "\n" + String(scope.maximumDirectoryEntries)
        let signature = directories.map { directory -> String in
            let date = try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return directory + "=" + String(date?.timeIntervalSince1970 ?? 0)
        }.joined(separator: "\n")
        var catalogue = catalogues[key].flatMap { $0.signature == signature ? $0 : nil } ?? Catalogue(signature: signature)
        var visited = 0
        while catalogue.directory < directories.count, visited < 128, Self.budgetNow() < deadline {
            try Task.checkCancellation()
            let directory = directories[catalogue.directory]
            if catalogue.enumerator == nil {
                guard FileManager.default.fileExists(atPath: directory) else { catalogue.directory += 1; continue }
                guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: directory),
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey],
                    options: [.skipsSubdirectoryDescendants]) else {
                    catalogue.limited = true; catalogue.directory += 1; continue
                }
                catalogue.enumerator = enumerator; catalogue.visited = 0
            }
            guard let url = catalogue.enumerator?.nextObject() as? URL else {
                catalogue.enumerator = nil; catalogue.directory += 1; continue
            }
            catalogue.visited += 1; visited += 1; catalogue.progress += 1
            guard catalogue.visited <= scope.maximumDirectoryEntries else {
                catalogue.limited = true; catalogue.directory = directories.count; catalogue.enumerator = nil; break
            }
            if let metadata = try metadata(url, scope: scope) {
                let weight = 512 + metadata.path.utf8.count + metadata.identity.utf8.count
                if catalogue.files.count >= 10_000 || catalogue.retainedBytes + weight > 4 * 1024 * 1024 {
                    catalogue.limited = true; catalogue.directory = directories.count; catalogue.enumerator = nil; break
                }
                catalogue.retainedBytes += weight
                catalogue.files.append(metadata)
            }
        }
        var scanning = catalogue.directory < directories.count
        if !scanning {
            // Appends do not change a directory's date. Recheck file metadata
            // with its own cursor so warm reads notice changes without polling.
            var checked = 0
            while catalogue.validationCursor < catalogue.files.count, checked < 128, Self.budgetNow() < deadline {
                let index = catalogue.validationCursor
                if let metadata = try metadata(URL(fileURLWithPath: catalogue.files[index].path), scope: scope) {
                    catalogue.files[index] = metadata
                } else {
                    catalogue.files.remove(at: index); continue
                }
                catalogue.validationCursor += 1; checked += 1
                catalogue.progress += 1
            }
            scanning = catalogue.validationCursor < catalogue.files.count
            if !scanning { catalogue.validationCursor = 0 }
        }
        catalogues[key] = catalogue
        if catalogues.count > 12 { for old in Array(catalogues.keys) where old != key { catalogues[old] = nil; break } }
        var seen = Set<String>()
        return CatalogueRead(files: catalogue.files.filter { seen.insert($0.path).inserted }.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.path < $1.path : $0.modifiedAt > $1.modifiedAt
        }, scanning: scanning, progress: catalogue.progress, limited: catalogue.limited)
    }
    private func metadata(_ url: URL, scope: NativeTranscriptScope) throws -> CatalogFile? {
        guard url.pathExtension == "jsonl", let path = try? NativeTranscriptPaths.assertTranscript(url.path, scope: scope),
              let (fd, info) = try? BackendUsageIO.openChecked(path, roots: NativeTranscriptPaths.approvedRoots(scope)) else { return nil }
        defer { Darwin.close(fd) }
        let modified = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
        let identity = [String(info.st_dev), String(info.st_ino), String(info.st_birthtimespec.tv_sec), String(info.st_birthtimespec.tv_nsec),
            String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)].joined(separator: ":")
        return CatalogFile(path: path, bytes: info.st_size, modifiedAt: modified, identity: identity)
    }

    /// A step reads only new bytes, and checks its time budget between records.
    /// Pending bytes survive steps: split UTF8 and torn JSON are never consumed.
    func read(path: String, scope: NativeTranscriptScope, cwd: String,
              maximumNewBytes: Int = 2 * 1024 * 1024,
              deadline: Double? = nil,
              cancellation: BackendMCPCancellation? = nil) throws -> Read {
        try Task.checkCancellation()
        if cancellation?.isCancelled == true { throw CancellationError() }
        let approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        let (fd, info) = try BackendUsageIO.openChecked(approved, roots: NativeTranscriptPaths.approvedRoots(scope))
        defer { Darwin.close(fd) }
        let stamp = Stamp(info)
        var entry: Entry
        if let old = entries[approved], old.stamp.canAppend(to: stamp),
           try sample(fd, offset: 0, count: old.header.count) == old.header,
           try sample(fd, offset: max(0, old.offset - old.boundary.count), count: old.boundary.count) == old.boundary { entry = old }
        else {
            entry = Entry(stamp: stamp, transcript: BackendCostTranscript(
                path: approved, sessionID: URL(fileURLWithPath: approved).deletingPathExtension().lastPathComponent, cwd: ""))
            entry.retainedBytes += approved.utf8.count + 4096 + 256
        }
        if let membershipCwd = entry.membershipCwd {
            try assertProject(membershipCwd, project: cwd, scope: scope)
        }
        guard lseek(fd, off_t(entry.offset), SEEK_SET) >= 0 else { throw POSIXError(.EIO) }
        let end = min(Int(info.st_size), BackendUsageIO.maximumFileBytes)
        let limit = min(end, entry.offset + max(0, maximumNewBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var bytesRead = 0, lines = 0
        while entry.offset < limit, !entry.budgetReached {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            if let deadline, Self.budgetNow() >= deadline { break }
            let amount = Darwin.read(fd, &buffer, min(buffer.count, limit - entry.offset))
            if amount < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if amount == 0 { break }
            var start = 0
            for index in 0..<amount where buffer[index] == 10 {
                if !entry.dropping {
                    entry.pending.append(contentsOf: buffer[start..<index])
                    if entry.pending.count <= BackendUsageIO.maximumLineBytes,
                       let text = String(data: entry.pending, encoding: .utf8) {
                        if entry.membershipCwd == nil, entry.membershipLines < 256, entry.offset < 4 * 1024 * 1024,
                           entry.pending.count <= 1024 * 1024, text.contains("\"cwd\""),
                           let raw = try? NativeRPCValue.parseJSON(entry.pending, maximumBytes: 1024 * 1024),
                           let directory = raw["cwd"].string, directory.hasPrefix("/"), directory.utf8.count <= 4096 {
                            try assertProject(directory, project: cwd, scope: scope)
                            entry.membershipCwd = directory; entry.transcript.cwd = directory
                        }
                        try consume(text, into: &entry)
                    } else { entry.transcript.truncated = true }
                }
                entry.pending = Data(); entry.dropping = false
                start = index + 1; lines += 1; entry.membershipLines += 1
                if entry.budgetReached { break }
                if entry.membershipCwd == nil,
                   entry.membershipLines >= 256 || entry.offset + start >= 4 * 1024 * 1024 {
                    throw NativeRPCError(code: "transcript-membership", message: "This transcript has no bounded folder record proving its granted project.")
                }
                if lines % 32 == 0 {
                    try Task.checkCancellation()
                    if cancellation?.isCancelled == true { throw CancellationError() }
                    if let deadline, Self.budgetNow() >= deadline { break }
                }
            }
            // If the deadline fired mid-chunk, save only the consumed prefix.
            // The rest is read again next step, so no record is lost.
            if entry.budgetReached {
                entry.offset += start; bytesRead += start; break
            }
            if let deadline, Self.budgetNow() >= deadline, start > 0, start < amount {
                entry.offset += start; bytesRead += start; break
            }
            if start < amount, !entry.dropping {
                entry.pending.append(contentsOf: buffer[start..<amount])
                if entry.pending.count > BackendUsageIO.maximumLineBytes {
                    entry.pending = Data(); entry.dropping = true
                    entry.transcript.truncated = true
                }
            }
            entry.offset += amount; bytesRead += amount
        }
        entry.stamp = stamp; entry.transcript.readBytes = entry.offset
        let header = try sample(fd, offset: 0, count: min(4096, Int(info.st_size)))
        let boundary = try sample(fd, offset: max(0, entry.offset - 128), count: min(128, entry.offset))
        entry.retainedBytes += header.count + boundary.count - entry.header.count - entry.boundary.count
        entry.header = header; entry.boundary = boundary
        entry.transcript.truncated = entry.transcript.truncated || info.st_size > BackendUsageIO.maximumFileBytes
        serial &+= 1; entry.touched = serial; entries[approved] = entry
        if entries.count > maximumEntries, let oldest = entries.min(by: { $0.value.touched < $1.value.touched })?.key {
            entries[oldest] = nil
        }
        var records = entries.values.reduce(0) { $0 + $1.transcript.requestCount }
        var retained = entries.values.reduce(0) { $0 + $1.pending.count + $1.retainedBytes }
        for old in entries.keys.filter({ $0 != approved }).sorted(by: { entries[$0]!.touched < entries[$1]!.touched }) {
            guard records > maximumRetainedRecords || retained > maximumRetainedBytes else { break }
            let removed = entries.removeValue(forKey: old)!
            records -= removed.transcript.requestCount
            retained -= removed.pending.count + removed.retainedBytes
        }
        var result = entry.transcript
        var tailLimited = false
        // A final complete JSON record without a newline is valid. Parse into
        // a copy: retained bytes can become a different record after an append.
        if entry.offset == end, !entry.dropping, !entry.pending.isEmpty,
           let text = String(data: entry.pending, encoding: .utf8) {
            if entry.membershipCwd == nil, entry.membershipLines < 256, entry.offset < 4 * 1024 * 1024,
               entry.pending.count <= 1024 * 1024,
               let raw = try? NativeRPCValue.parseJSON(entry.pending, maximumBytes: 1024 * 1024),
               let directory = raw["cwd"].string, directory.hasPrefix("/"), directory.utf8.count <= 4096 {
                try assertProject(directory, project: cwd, scope: scope)
                entry.membershipCwd = directory; result.cwd = directory; entries[approved] = entry
            }
            var tail = entry; tail.transcript = result
            try consume(text, into: &tail)
            result = tail.transcript; tailLimited = tail.budgetReached
        }
        if entry.membershipCwd == nil, info.st_size > 0 {
            guard entry.offset < end else {
                throw NativeRPCError(code: "transcript-membership", message: "This transcript has no folder record proving its granted project.")
            }
            result = BackendCostTranscript(path: approved, sessionID: result.sessionID, cwd: "")
        } else if !result.cwd.isEmpty { try assertProject(result.cwd, project: cwd, scope: scope) }
        return Read(transcript: result, bytesRead: bytesRead, scanning: !entry.budgetReached && entry.offset < end,
            limited: entry.budgetReached || tailLimited || (info.st_size > BackendUsageIO.maximumFileBytes && entry.offset >= end))
    }
    private func assertProject(_ directory: String, project: String, scope: NativeTranscriptScope) throws {
        try BackendCompositionAuthorityTranscripts.assertCwd(directory, scope: scope)
        guard BackendCompositionAuthority.within(directory, project) else {
            throw NativeRPCError(code: "access-denied", message: "This session record belongs to another folder.")
        }
    }
    /// Fixed small samples catch ordinary prefix/boundary rewrites during an
    /// apparent append. They never rescan historical contents or parse them.
    private func sample(_ fd: Int32, offset: Int, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count), read = 0
        try data.withUnsafeMutableBytes { buffer in
            while read < count {
                let amount = Darwin.pread(fd, buffer.baseAddress!.advanced(by: read), count - read, off_t(offset + read))
                if amount < 0 { if errno == EINTR { continue }; throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if amount == 0 { break }; read += amount
            }
        }
        data.count = read; return data
    }
    private func consume(_ text: String, into entry: inout Entry) throws {
        guard text.contains("\"usage\"") || text.contains("compact_boundary") else { return }
        guard let raw = try? NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: BackendUsageIO.maximumLineBytes) else {
            entry.transcript.truncated = true; return
        }
        let requestCount = entry.transcript.requestCount, compactCount = entry.transcript.compactions.count
        let requestKey = raw["message"]["id"].string ?? raw["requestId"].string ?? raw["uuid"].string
        let previous = requestKey.flatMap { entry.transcript.dedupe[$0] }
        let stopBytes = previous.map { entry.transcript.requests[$0].stopReason?.utf8.count ?? 0 } ?? 0
        do { try entry.transcript.consumeParsed(raw, includeTools: false) }
        catch let error as NativeRPCError where error.code == "malformed" {
            entry.transcript.truncated = true
            if error.message.contains("request-count") || error.message.contains("compaction-metadata") { entry.budgetReached = true }
            return
        }
        for request in entry.transcript.requests.dropFirst(requestCount) {
            entry.retainedBytes += 512 + (request.key?.utf8.count ?? 0) + request.model.utf8.count +
                request.speed.utf8.count + (request.stopReason?.utf8.count ?? 0)
        }
        if let previous {
            entry.retainedBytes += max(0, (entry.transcript.requests[previous].stopReason?.utf8.count ?? 0) - stopBytes)
        }
        for compact in entry.transcript.compactions.dropFirst(compactCount) { entry.retainedBytes += retainedBytes(compact) }
        if entry.transcript.requestCount >= maximumRetainedRecords || entry.retainedBytes + entry.pending.count >= maximumRetainedBytes {
            entry.budgetReached = true; entry.transcript.truncated = true
        }
    }
    private func retainedBytes(_ value: NativeRPCValue) -> Int {
        switch value {
        case .string(let text): return 32 + text.utf8.count
        case .bytes(let bytes): return 32 + bytes.count
        case .array(let values): return 32 + values.reduce(0) { $0 + retainedBytes($1) }
        case .object(let fields): return 32 + fields.reduce(0) { $0 + 64 + $1.key.utf8.count + retainedBytes($1.value) }
        default: return 32
        }
    }
    func removeAll() { entries.removeAll(); catalogues.removeAll() }
    func retainedCheckpointBytes() -> Int { entries.values.reduce(0) { $0 + $1.retainedBytes + $1.pending.count } }
    func pendingBytes() -> Int { entries.values.reduce(0) { $0 + $1.pending.count } }
}
