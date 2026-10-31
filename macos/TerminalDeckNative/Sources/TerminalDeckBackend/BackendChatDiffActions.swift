import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// A review of one provider-reported text edit. The adapter that registers it owns the
/// provider event; renderer callers receive only an opaque proposal ID. No git operations.
public actor BackendChatDiffActions {
    public static let maximumFileBytes = 512 * 1024
    public static let maximumRetainedBytes = 16 * 1024 * 1024
    private let authority: BackendFilesystemAuthority
    private struct Version: Equatable {
        let device: UInt64, inode: UInt64, parentDevice: UInt64, parentInode: UInt64
        let owner: UInt32, group: UInt32
        let mode: UInt16, size: Int64, modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
        let hash: String, metadataHash: String
    }
    private struct Proposal {
        let id: String, root: URL, relative: String, before: Data, after: Data, patch: String, signature: String
        let registered: Version, alreadyApplied: Bool
        var decision: String?
        var verified = true
    }
    private var proposals: [String: Proposal] = [:]
    private var order: [String] = []
    private var acting: Set<String> = []
    public init(authority: BackendFilesystemAuthority) { self.authority = authority }

    /// Supported inputs: Codex FileUpdateChange (path, kind.update, diff), or a
    /// Claude single Edit input (file_path, old_string, new_string). Missing exact
    /// versions, ambiguous mappings, add/delete/rename and binary edits are unavailable.
    public func register(change: NativeRPCValue, projectRoot: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let root = try await authority.authorize(projectRoot, context: context)
        guard root.path != "/" else { throw Self.pathError() }
        let path = change["path"].string ?? change["file_path"].string ?? ""
        let relative = try Self.relative(path, root: root, suppliedRoot: projectRoot)
        let target = try await authorized(root: root, relative: relative, context: context, writing: false)
        let file = try OpenFile(target)
        let current = try file.read()
        do {
            let pair: (before: Data, after: Data)
            let patch: String
            if let diff = change["diff"].string {
                let kind = change["kind"]
                guard kind["type"].string == "update", kind["move_path"].isNullish else {
                    throw Unsupported("Only an existing text-file update without a rename has an exact supported review.")
                }
                let hunks = try UnifiedPatch(diff, relative: relative, root: root, suppliedRoot: projectRoot)
                let lines = try Self.textLines(current.bytes)
                let forward = try? hunks.transform(lines, reverse: false)
                let reverse = try? hunks.transform(lines, reverse: true)
                guard (forward == nil) != (reverse == nil) else {
                    throw Unsupported("The current file does not uniquely match this diff's before or after version. No conditional action is available.")
                }
                if let forward { pair = (current.bytes, Self.bytes(forward)) }
                else { pair = (Self.bytes(reverse!), current.bytes) }
                patch = diff
            } else if let old = change["old_string"].string, let new = change["new_string"].string {
                guard change["replace_all"].bool != true, !old.isEmpty, !new.isEmpty,
                      old.utf8.count <= 262_144, new.utf8.count <= 262_144,
                      !old.contains("\0"), !new.contains("\0"), let text = String(data: current.bytes, encoding: .utf8), !text.contains("\0") else {
                    throw Unsupported("This Edit needs two bounded, nonempty text versions and a single exact replacement.")
                }
                let forward = Self.replacingOnce(current.bytes, old: Data(old.utf8), new: Data(new.utf8))
                let reverse = Self.replacingOnce(current.bytes, old: Data(new.utf8), new: Data(old.utf8))
                guard (forward == nil) != (reverse == nil) else {
                    throw Unsupported("The old and new Edit text do not identify one unique file version.")
                }
                if let forward { pair = (current.bytes, forward) }
                else { pair = (reverse!, current.bytes) }
                patch = "Recorded single text replacement"
            } else { throw Unsupported("The provider did not report an exact supported before/after text change.") }
            guard pair.before != pair.after, pair.before.count <= Self.maximumFileBytes, pair.after.count <= Self.maximumFileBytes else {
                throw Unsupported("The change is empty or exceeds the bounded text review size.")
            }
            guard acting.isEmpty else { throw Self.busy() }
            let signature = Self.hash(try NativeRPCValue.array([root.path, relative, Self.hash(pair.before), Self.hash(pair.after), patch].map(NativeRPCValue.string)).encodedJSON())
            if let existing = order.compactMap({ proposals[$0] }).last(where: { $0.signature == signature && ($0.decision != nil || $0.registered == current.version) }) {
                return Self.receipt(existing)
            }
            let id = UUID().uuidString.lowercased()
            let proposal = Proposal(id: id, root: root, relative: relative, before: pair.before, after: pair.after, patch: patch, signature: signature,
                registered: current.version, alreadyApplied: current.bytes == pair.after)
            proposals[id] = proposal; order.append(id)
            while order.count > 64 || proposals.values.reduce(0, { $0 + $1.before.count + $1.after.count + $1.patch.utf8.count }) > Self.maximumRetainedBytes {
                proposals.removeValue(forKey: order.removeFirst())
            }
            return Self.receipt(proposal)
        } catch let reason as Unsupported {
            return .object([.init("available", .bool(false)), .init("path", .string(relative)), .init("reason", .string(reason.message))])
        }
    }

    public func preview(id: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard let proposal = proposals[id] else { throw Self.stale() }
        guard !acting.contains(id) else { throw Self.busy() }
        let target = try await authorized(root: proposal.root, relative: proposal.relative, context: context, writing: false)
        let current = try OpenFile(target).read()
        if proposal.decision == nil { try Self.requireVersion(current.version, proposal.registered) }
        return Self.receipt(proposal).setting("currentHash", .string(current.version.hash))
            .setting("patch", .string(proposal.patch))
    }

    public func apply(id: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        try await decide(id: id, accepting: true, context: context)
    }
    public func reject(id: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        try await decide(id: id, accepting: false, context: context)
    }
    private func decide(id: String, accepting: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard var proposal = proposals[id] else { throw Self.stale() }
        guard !acting.contains(id) else { throw Self.busy() }
        let decision = accepting ? "accepted" : "rejected"
        if let previous = proposal.decision {
            guard previous == decision else { throw NativeRPCError(code: "diff-decided", message: "This recorded diff already has a review decision. Read the current file before starting another review.") }
            // Reauthorize even the historical receipt; repeated actions never repeat a write.
            _ = try await authorized(root: proposal.root, relative: proposal.relative, context: context, writing: true)
            return Self.receipt(proposal)
        }
        acting.insert(id); defer { acting.remove(id) }
        let target = try await authorized(root: proposal.root, relative: proposal.relative, context: context, writing: true)
        let file = try OpenFile(target), current = try file.read()
        try Self.requireVersion(current.version, proposal.registered)
        let replacement = accepting ? proposal.after : proposal.before
        let needsWrite = current.bytes != replacement
        if needsWrite { try file.publish(replacement, expected: current.version) }
        proposal.decision = decision
        proposals[id] = proposal // Once publication succeeds, an uncertain readback cannot cause a replay.
        do {
            let after = try OpenFile(target).read()
            proposal.verified = after.bytes == replacement
        } catch { proposal.verified = false }
        proposals[id] = proposal
        return Self.receipt(proposal).setting("wroteFile", .bool(needsWrite))
    }
    private func authorized(root: URL, relative: String, context: NativeRPCContext, writing: Bool) async throws -> BackendFilesystemAuthority.Target {
        let target = try await authority.resolve(root: root.path, relative: relative, context: context, intent: writing ? .write : .read)
        let lexical = root.appendingPathComponent(relative).standardizedFileURL
        guard target.root.path == root.path, target.path.path == lexical.path else {
            throw NativeRPCError(code: "diff-path", message: "A reviewed file or parent is a symbolic link or changed its project location.")
        }
        return target
    }
    private static func receipt(_ proposal: Proposal) -> NativeRPCValue {
        .object([.init("available", .bool(true)), .init("id", .string(proposal.id)),
            .init("projectRoot", .string(proposal.root.path)), .init("path", .string(proposal.relative)),
            .init("beforeHash", .string(hash(proposal.before))), .init("afterHash", .string(hash(proposal.after))),
            .init("registeredHash", .string(proposal.registered.hash)),
            .init("versionBasis", .string("Current file bytes and an exact provider-reported text mapping.")),
            .init("beforeBytes", .number(Double(proposal.before.count))), .init("afterBytes", .number(Double(proposal.after.count))),
            .init("state", .string(proposal.decision ?? (proposal.alreadyApplied ? "alreadyApplied" : "pending"))),
            .init("alreadyApplied", .bool(proposal.alreadyApplied)), .init("canApply", .bool(proposal.decision == nil && !proposal.alreadyApplied)),
            .init("canReject", .bool(proposal.decision == nil)), .init("verified", .bool(proposal.verified)),
            .init("rejectEffect", .string(proposal.alreadyApplied ? "Restore the verified exact before bytes if the file is unchanged." : "Dismiss this pending proposal without changing the file."))])
    }
    private static func relative(_ path: String, root: URL, suppliedRoot: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"), !path.contains("\\") else { throw pathError() }
        let relative: String
        if path.hasPrefix("/") {
            let roots = [URL(fileURLWithPath: suppliedRoot).standardizedFileURL.path, root.path]
            guard let base = roots.first(where: { path.hasPrefix($0 + "/") }) else { throw pathError() }
            relative = String(path.dropFirst(base.count + 1))
        } else { relative = path }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }) else { throw pathError() }
        return relative
    }
    private static func pathError() -> NativeRPCError { .init(code: "diff-path", message: "Choose an exact file inside this Chat project without path escapes or repository internals.") }
    private static func stale() -> NativeRPCError { .init(code: "diff-stale", message: "This diff proposal expired. Preview its recorded provider change again.") }
    private static func busy() -> NativeRPCError { .init(code: "diff-busy", message: "This diff is already being reviewed.") }
    private static func requireVersion(_ current: Version, _ expected: Version) throws {
        guard current == expected else { throw NativeRPCError(code: "diff-conflict", message: "The file, its mode or its parent changed after this diff was registered. Nothing was written; preview a fresh version.") }
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func replacingOnce(_ text: Data, old: Data, new: Data) -> Data? {
        guard !old.isEmpty, let range = text.range(of: old),
              text.range(of: old, in: (range.lowerBound + 1)..<text.endIndex) == nil else { return nil }
        return Data(text[..<range.lowerBound]) + new + Data(text[range.upperBound...])
    }
    private struct Unsupported: Error { let message: String; init(_ message: String) { self.message = message } }

    private struct TextLine: Equatable {
        let text: String; var newline: Bool
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.newline == rhs.newline && lhs.text.utf8.elementsEqual(rhs.text.utf8) }
    }
    private static func textLines(_ data: Data) throws -> [TextLine] {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Unsupported("Only exact UTF-8 text changes are supported.") }
        if text.isEmpty { return [] }
        var parts = text.components(separatedBy: "\n"), result: [TextLine] = []
        let ended = text.hasSuffix("\n"); if ended { parts.removeLast() }
        for (index, part) in parts.enumerated() { result.append(TextLine(text: part, newline: ended || index < parts.count - 1)) }
        return result
    }
    private static func bytes(_ lines: [TextLine]) -> Data { Data(lines.map { $0.text + ($0.newline ? "\n" : "") }.joined().utf8) }
    private struct UnifiedPatch {
        private struct Line { let mark: Character; var value: TextLine }
        private struct Hunk { let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int; var lines: [Line] }
        private let hunks: [Hunk]
        init(_ patch: String, relative: String, root: URL, suppliedRoot: String) throws {
            guard patch.utf8.count <= 262_144, !patch.contains("\0") else { throw Unsupported("The provider diff exceeds the bounded text review size.") }
            let rows = patch.components(separatedBy: "\n")
            guard rows.count <= 10_000 else { throw Unsupported("The provider diff has too many lines for a conditional review.") }
            let pattern = try NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@(?:.*)?$"#)
            var hunks: [Hunk] = [], headers = 0, changed = false
            for (index, row) in rows.enumerated() {
                if index == rows.count - 1, row.isEmpty { continue }
                if row.hasPrefix("@@") {
                    let ns = row as NSString
                    guard let match = pattern.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) else { throw Unsupported("The diff hunk header is incomplete.") }
                    func number(_ n: Int, fallback: Int = 1) throws -> Int {
                        let range = match.range(at: n)
                        if range.location == NSNotFound { return fallback }
                        guard let value = Int(ns.substring(with: range)), value <= maximumFileBytes else { throw Unsupported("The diff hunk range exceeds its limit.") }; return value
                    }
                    hunks.append(Hunk(oldStart: try number(1), oldCount: try number(2), newStart: try number(3), newCount: try number(4), lines: [])); continue
                }
                if row == "\\ No newline at end of file" {
                    guard !hunks.isEmpty, !hunks[hunks.count - 1].lines.isEmpty else { throw Unsupported("The diff newline marker has no preceding line.") }
                    let last = hunks.count - 1, line = hunks[last].lines.count - 1
                    guard hunks[last].lines[line].value.newline else { throw Unsupported("The diff repeats a newline marker.") }
                    hunks[last].lines[line].value.newline = false; continue
                }
                if hunks.isEmpty {
                    if row.hasPrefix("diff --git ") { headers += 1; guard headers == 1 else { throw Unsupported("Review one file at a time.") }; continue }
                    if row.hasPrefix("index ") { continue }
                    if row.hasPrefix("--- ") || row.hasPrefix("+++ ") {
                        var named = String(row.dropFirst(4)).components(separatedBy: "\t")[0]
                        if named.hasPrefix("a/") || named.hasPrefix("b/") { named = String(named.dropFirst(2)) }
                        guard try BackendChatDiffActions.relative(named, root: root, suppliedRoot: suppliedRoot) == relative else { throw Unsupported("The diff headers name a different file.") }
                        continue
                    }
                    throw Unsupported("Binary, rename, mode-only and non-unified patches do not have a supported conditional action.")
                }
                guard let mark = row.first, [Character(" "), "+", "-"].contains(mark) else { throw Unsupported("The diff contains an incomplete or unsupported hunk line.") }
                if mark != " " { changed = true }
                hunks[hunks.count - 1].lines.append(Line(mark: mark, value: TextLine(text: String(row.dropFirst()), newline: true)))
            }
            guard !hunks.isEmpty, changed else { throw Unsupported("The provider did not report a complete text change.") }
            for hunk in hunks {
                guard hunk.lines.filter({ $0.mark != "+" }).count == hunk.oldCount,
                      hunk.lines.filter({ $0.mark != "-" }).count == hunk.newCount,
                      hunk.oldCount == 0 || hunk.oldStart > 0, hunk.newCount == 0 || hunk.newStart > 0 else {
                    throw Unsupported("The diff hunk counts do not match the recorded lines.")
                }
            }
            self.hunks = hunks
        }
        func transform(_ source: [TextLine], reverse: Bool) throws -> [TextLine] {
            var output: [TextLine] = [], cursor = 0
            for hunk in hunks {
                let old = hunk.lines.filter { $0.mark != (reverse ? "-" : "+") }.map(\.value)
                let new = hunk.lines.filter { $0.mark != (reverse ? "+" : "-") }.map(\.value)
                let count = reverse ? hunk.newCount : hunk.oldCount, start = reverse ? hunk.newStart : hunk.oldStart
                let targetCount = reverse ? hunk.oldCount : hunk.newCount, targetStart = reverse ? hunk.oldStart : hunk.newStart
                let offset = count == 0 ? start : start - 1, targetOffset = targetCount == 0 ? targetStart : targetStart - 1
                guard offset >= cursor, offset <= source.count, old.count <= source.count - offset else { throw Unsupported("The recorded hunk range does not match the file.") }
                output.append(contentsOf: source[cursor..<offset])
                guard output.count == targetOffset, Array(source[offset..<offset + old.count]) == old else { throw Unsupported("The exact recorded hunk text no longer matches.") }
                output.append(contentsOf: new); cursor = offset + old.count
            }
            output.append(contentsOf: source[cursor...])
            guard output.dropLast().allSatisfy(\.newline) else { throw Unsupported("The diff places text after a missing final newline.") }
            return output
        }
    }

    /// File and parent descriptors stay owned through the final version check and atomic rename.
    /// External writers do not share a filesystem transaction; no await occurs between the
    /// last descriptor/path check and publication.
    private final class OpenFile {
        let target: BackendFilesystemAuthority.Target, parent: Int32, file: Int32, name: String
        init(_ target: BackendFilesystemAuthority.Target) throws {
            self.target = target; name = target.path.lastPathComponent
            let parentURL = target.path.deletingLastPathComponent()
            let parentFD = try BackendFilesystemAuthority.openStable(.init(root: target.root, path: parentURL, relative: BackendFilesystemAuthority.relative(parentURL, to: target.root)), directory: true)
            let fileFD = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fileFD >= 0 else { Darwin.close(parentFD); throw NativeRPCError(code: "diff-file", message: "The reviewed file could not be opened without following links.") }
            parent = parentFD; file = fileFD
        }
        deinit { Darwin.close(file); Darwin.close(parent) }
        private func attributes() throws -> (stat, stat) {
            let parentURL = target.path.deletingLastPathComponent()
            // Compare directory identity through the same no-follow capability walk.
            // Raw F_GETPATH spelling can differ from Foundation's canonical URL spelling
            // (for example /var and /private/var) without the directory having moved.
            let namedParent = try BackendFilesystemAuthority.openStable(.init(root: target.root, path: parentURL,
                relative: BackendFilesystemAuthority.relative(parentURL, to: target.root)), directory: true)
            defer { Darwin.close(namedParent) }
            var info = stat(), folder = stat(), entry = stat(), namedFolder = stat()
            guard fstat(file, &info) == 0, fstat(parent, &folder) == 0, fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximumFileBytes,
                  info.st_dev == entry.st_dev, info.st_ino == entry.st_ino,
                  entry.st_mode & S_IFMT == S_IFREG, entry.st_nlink == 1,
                  folder.st_mode & S_IFMT == S_IFDIR, fstat(namedParent, &namedFolder) == 0,
                  namedFolder.st_mode & S_IFMT == S_IFDIR, folder.st_dev == namedFolder.st_dev, folder.st_ino == namedFolder.st_ino else {
                throw NativeRPCError(code: "diff-file", message: "The reviewed file is linked, moved, replaced, nonregular or exceeds the text limit.")
            }
            guard info.st_flags == 0, info.st_mode & 0o6000 == 0 else {
                throw NativeRPCError(code: "diff-metadata", message: "This file has privileged mode bits or BSD flags that cannot be safely preserved by a staged text edit.")
            }
            return (info, folder)
        }
        private struct Metadata: Equatable {
            let acl: Data, attributes: [String: Data]
            var hash: String {
                get throws {
                    let values = attributes.keys.sorted().map { NativeRPCValue.array([.string($0), .string(attributes[$0]!.base64EncodedString())]) }
                    return BackendChatDiffActions.hash(try NativeRPCValue.array([.string(acl.base64EncodedString()), .array(values)]).encodedJSON())
                }
            }
        }
        private static func metadata(_ descriptor: Int32) throws -> Metadata {
            func refusal() -> NativeRPCError { .init(code: "diff-metadata", message: "The file's ACL or extended attributes could not be read and preserved within the metadata limit.") }
            let namesSize = flistxattr(descriptor, nil, 0, 0)
            guard namesSize >= 0, namesSize <= 65_536 else { throw refusal() }
            var namesData = Data(count: namesSize)
            let namesCount = namesData.withUnsafeMutableBytes { flistxattr(descriptor, $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count, 0) }
            guard namesCount >= 0, namesCount <= namesSize else { throw refusal() }
            let rawNames = namesData.prefix(namesCount).split(separator: 0)
            guard rawNames.count <= 128 else { throw refusal() }
            var attributes: [String: Data] = [:], total = 0
            for raw in rawNames {
                guard let name = String(data: Data(raw), encoding: .utf8) else { throw refusal() }
                let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
                guard size >= 0, size <= 262_144, total + size <= 1_048_576 else { throw refusal() }
                var value = Data(count: size)
                let count = value.withUnsafeMutableBytes { fgetxattr(descriptor, name, $0.baseAddress, $0.count, 0, 0) }
                guard count == size else { throw refusal() }
                attributes[name] = value; total += size
            }
            let aclData: Data
            if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                let size = acl_size(acl)
                guard size >= 0, size <= 65_536 else { throw refusal() }
                var data = Data(count: size)
                let copied = data.withUnsafeMutableBytes { acl_copy_ext($0.baseAddress, acl, $0.count) }
                guard copied >= 0, copied <= size else { throw refusal() }
                aclData = Data(data.prefix(copied))
            } else if errno == ENOENT { aclData = Data() }
            else { throw refusal() }
            return Metadata(acl: aclData, attributes: attributes)
        }
        private func version(_ info: stat, _ folder: stat, bytes: Data, metadata: Metadata) throws -> Version {
            Version(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), parentDevice: UInt64(folder.st_dev), parentInode: UInt64(folder.st_ino),
                owner: info.st_uid, group: info.st_gid,
                mode: UInt16(info.st_mode & 0o7777), size: Int64(info.st_size), modified: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                changed: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec), hash: BackendChatDiffActions.hash(bytes), metadataHash: try metadata.hash)
        }
        func read() throws -> (bytes: Data, version: Version) {
            let (before, folder) = try attributes()
            let firstMetadata = try Self.metadata(file)
            var data = Data(), buffer = [UInt8](repeating: 0, count: 32 * 1024)
            while data.count <= maximumFileBytes {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { pread(file, $0.baseAddress!, $0.count, off_t(data.count)) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0, data.count + max(0, count) <= maximumFileBytes else { throw NativeRPCError(code: "diff-file", message: "The reviewed file changed or exceeded its byte limit.") }
                if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            let (after, afterFolder) = try attributes()
            let first = try version(before, folder, bytes: data, metadata: firstMetadata)
            let last = try version(after, afterFolder, bytes: data, metadata: Self.metadata(file))
            guard first == last, data.count == after.st_size else { throw NativeRPCError(code: "diff-conflict", message: "The file changed during its version read.") }
            return (data, last)
        }
        func publish(_ replacement: Data, expected: Version) throws {
            let temporary = ".td-chat-diff-" + UUID().uuidString + ".part"
            let output = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw NativeRPCError(code: "diff-write", message: "The conditional file write could not be staged.") }
            var published = false
            defer {
                if !published {
                    // Only our unpublished staging inode is changed during cleanup. A copied
                    // deny-delete ACL must not strand a private partial file in the project.
                    if let empty = acl_init(0) { _ = acl_set_fd_np(output, empty, ACL_TYPE_EXTENDED); acl_free(UnsafeMutableRawPointer(empty)) }
                    _ = fchmod(output, 0o600)
                    var held = stat(), named = stat()
                    if fstat(output, &held) == 0, fstatat(parent, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                       held.st_dev == named.st_dev, held.st_ino == named.st_ino { unlinkat(parent, temporary, 0) }
                }
                Darwin.close(output)
            }
            var offset = 0
            while offset < replacement.count {
                try Task.checkCancellation()
                let count = replacement.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), replacement.count - offset) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NativeRPCError(code: "diff-write", message: "The conditional file write could not be completed.") }
                offset += count
            }
            let sourceMetadata = try Self.metadata(file)
            // Local copyfile.h: METADATA = STAT | ACL | XATTR, with no DATA flag.
            // Both endpoints are already-owned regular-file descriptors.
            guard fcopyfile(file, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw NativeRPCError(code: "diff-metadata", message: "The file's ownership, ACL and extended attributes could not be copied safely. Nothing was published.")
            }
            var copied = stat()
            guard fstat(output, &copied) == 0, copied.st_uid == expected.owner, copied.st_gid == expected.group,
                  copied.st_mode & 0o7777 == mode_t(expected.mode), copied.st_flags == 0,
                  try Self.metadata(output) == sourceMetadata, futimes(output, nil) == 0, fsync(output) == 0 else {
                throw NativeRPCError(code: "diff-metadata", message: "The staged file did not preserve the exact ownership, mode, ACL and extended attributes. Nothing was published.")
            }
            try BackendChatDiffActions.requireVersion(read().version, expected)
            try Task.checkCancellation()
            guard renameat(parent, temporary, parent, name) == 0 else { throw NativeRPCError(code: "diff-write", message: "The conditional file write could not be published.") }
            published = true
            _ = fsync(parent)
        }
    }
}
