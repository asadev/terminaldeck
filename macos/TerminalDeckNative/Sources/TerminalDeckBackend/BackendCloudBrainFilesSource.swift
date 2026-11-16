import Foundation
import Darwin
import TerminalDeckNativeCore

/// What arrived from another device, after its whole-resource hash was checked.
public struct BackendCloudBrainFilesIncoming: Sendable {
    public let sourceId: String
    public let relative: String
    public let bytes: Data
    public let projectId: String?
    public let rootId: String?
    public let originDevice: String
}

/// Where an owner wants a verified incoming file. The engine performs the write itself: create-only, read back,
/// never over different bytes (those are kept beside it as a conflict).
public enum BackendCloudBrainFilesPlacement: Sendable {
    case write(URL, Data)
    /// Machine-bound or inert-by-design history: kept readable in the Cloud archive area, never projected live.
    case archiveOnly(String)
    /// Destination not known on this Mac yet (for example a project folder that has no path here). Retried later.
    case waiting(String)
}

public enum BackendCloudBrainFilesProjection: Sendable {
    /// The same relative path under this device's root, optionally with runtime-only fields neutralised.
    case createOnly(transform: (@Sendable (String, Data) throws -> Data)?)
    case archiveOnly(String)
    case custom(@Sendable (BackendCloudBrainFilesIncoming) async throws -> BackendCloudBrainFilesPlacement)
}

/// One owner folder of a file-shaped brain row. Everything is explicit: no home scanning, no guessed roots.
public struct BackendCloudBrainFilesSource: Sendable {
    public let sourceId: String
    public let root: URL
    /// Relative glob patterns (`*` within one name, `**` across folders). Anything else under the root is not this row's data.
    public let include: [String]
    /// Runtime-only items excluded by design (locks, sockets, helper executables). They are not counted as missing.
    public let exclude: [String]
    public let excludeExecutables: Bool
    /// Text-only rows report binary files as blocked with this reason instead of uploading them.
    public let binaryBlockedReason: String?
    /// Absent root: true when the folder simply was never created (the parent exists); false when it must exist.
    public let optional: Bool
    public let projection: BackendCloudBrainFilesProjection
    /// Project identity for a relative path, attached to its operations so another Mac can place it by its own path map.
    public let project: (@Sendable (String) -> (projectId: String, rootId: String)?)?
    /// The one rule (14 Nov): when set, a new version's stamp is this time (ms) for the path, never later than now and
    /// never earlier than its parent's stamp, instead of the moment it was recorded. Boot files give the modification
    /// time of the person's own file. nil = the moment it was recorded (every other row, unchanged).
    public let modifiedAt: (@Sendable (String) -> Int64?)?
    public init(sourceId: String, root: URL, include: [String], exclude: [String] = [], excludeExecutables: Bool = false,
                binaryBlockedReason: String? = nil, optional: Bool = true, projection: BackendCloudBrainFilesProjection,
                project: (@Sendable (String) -> (projectId: String, rootId: String)?)? = nil,
                modifiedAt: (@Sendable (String) -> Int64?)? = nil) {
        self.sourceId = sourceId; self.root = root; self.include = include; self.exclude = exclude
        self.excludeExecutables = excludeExecutables; self.binaryBlockedReason = binaryBlockedReason; self.optional = optional
        self.projection = projection; self.project = project; self.modifiedAt = modifiedAt
    }
    static func validSourceId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 96, !id.hasPrefix("-"), !id.hasSuffix("/"), !id.contains("//") else { return false }
        return id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 47 }
    }
    func included(_ relative: String) -> Bool {
        include.contains { BackendCloudBrainFilesGlob.matches($0, relative) } && !exclude.contains { BackendCloudBrainFilesGlob.matches($0, relative) }
    }
    func mayContain(directory relative: String) -> Bool {
        !exclude.contains { BackendCloudBrainFilesGlob.matches($0, relative) } && include.contains { BackendCloudBrainFilesGlob.couldContain($0, directory: relative) }
    }
    /// A key's path must be one this source may hold; a cloud record cannot place an arbitrary file (for example an auth file).
    static func safeRelative(_ relative: String) -> Bool {
        guard !relative.isEmpty, relative.utf8.count <= 1024, !relative.hasPrefix("/"), !relative.contains("\0"), !relative.contains("\\") else { return false }
        return relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

enum BackendCloudBrainFilesGlob {
    static func matches(_ pattern: String, _ path: String) -> Bool {
        match(pattern.split(separator: "/")[...], path.split(separator: "/")[...])
    }
    private static func match(_ p: ArraySlice<Substring>, _ s: ArraySlice<Substring>) -> Bool {
        guard let head = p.first else { return s.isEmpty }
        if head == "**" {
            if match(p.dropFirst(), s) { return true }
            return !s.isEmpty && match(p, s.dropFirst())
        }
        guard let name = s.first, fnmatch(String(head), String(name), 0) == 0 else { return false }
        return match(p.dropFirst(), s.dropFirst())
    }
    /// True when something below `directory` could match the pattern; lets a walk skip unrelated trees (for example transcripts).
    static func couldContain(_ pattern: String, directory: String) -> Bool {
        prefix(pattern.split(separator: "/")[...], directory.split(separator: "/")[...])
    }
    private static func prefix(_ p: ArraySlice<Substring>, _ d: ArraySlice<Substring>) -> Bool {
        guard let name = d.first else { return !p.isEmpty }
        guard let head = p.first else { return false }
        if head == "**" { return true }
        guard fnmatch(String(head), String(name), 0) == 0 else { return false }
        return prefix(p.dropFirst(), d.dropFirst())
    }
}

/// A complete, uncapped enumeration of one source root. Unreadable or linked items are counted, never silently skipped.
struct BackendCloudBrainFilesWalk: Sendable {
    var files: [String] = []
    var bytes: Int64 = 0
    var blocked: [String] = []
    /// False when the root (or something under it) could not be enumerated: removals must not be inferred then.
    var reliable = true

    private final class Problems: @unchecked Sendable { var unreadable = 0 }

    static func run(_ source: BackendCloudBrainFilesSource) -> BackendCloudBrainFilesWalk {
        var walk = BackendCloudBrainFilesWalk()
        let fm = FileManager.default, root = source.root
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            var parentIsDirectory: ObjCBool = false
            let parent = root.deletingLastPathComponent()
            if source.optional, fm.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue { return walk }
            walk.blocked = ["This folder is not reachable on this Mac."]; walk.reliable = false; return walk
        }
        guard isDirectory.boolValue else { walk.blocked = ["This source is not a folder."]; walk.reliable = false; return walk }
        let problems = Problems()
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in
            problems.unreadable += 1; return true
        }) else { walk.blocked = ["This folder could not be read."]; walk.reliable = false; return walk }
        let base = root.path
        let resolvedRoot = root.resolvingSymlinksInPath().path
        var links = 0, binary = 0
        for case let url as URL in e {
            guard url.path.hasPrefix(base + "/") else { problems.unreadable += 1; continue }
            let relative = String(url.path.dropFirst(base.count + 1))
            guard let info = try? url.resourceValues(forKeys: Set(keys)) else { problems.unreadable += 1; continue }
            if info.isSymbolicLink == true {
                // The enumerator never descends a link. A link back inside this root is an alias of content that is walked anyway.
                if source.included(relative) || source.mayContain(directory: relative) {
                    let target = url.resolvingSymlinksInPath().path
                    if !target.hasPrefix(resolvedRoot + "/") { links += 1 }
                }
                continue
            }
            if info.isDirectory == true {
                if !source.mayContain(directory: relative) { e.skipDescendants() }
                continue
            }
            guard info.isRegularFile == true, source.included(relative) else { continue }
            if source.excludeExecutables, fm.isExecutableFile(atPath: url.path) { continue }
            if source.binaryBlockedReason != nil, !isText(url) { binary += 1; continue }
            walk.files.append(relative)
            walk.bytes += Int64(info.fileSize ?? 0)
        }
        walk.files.sort()
        if links > 0 { walk.blocked.append("\(links) linked item\(links == 1 ? " is" : "s are") not followed.") }
        if problems.unreadable > 0 { walk.blocked.append("\(problems.unreadable) item\(problems.unreadable == 1 ? "" : "s") could not be read."); walk.reliable = false }
        if binary > 0, let reason = source.binaryBlockedReason { walk.blocked.append("\(binary) non-text file\(binary == 1 ? "" : "s"): " + reason) }
        return walk
    }
    static func isText(_ url: URL) -> Bool {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return false }
        return !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }
}

/// One registered project folder on this Mac, from the project registry and the device path map (§5.3).
public struct BackendCloudBrainProjectRoot: Sendable, Equatable {
    public let projectId: String
    public let rootId: String
    public let path: URL
    public init(projectId: String, rootId: String, path: URL) { self.projectId = projectId; self.rootId = rootId; self.path = path }
}

/// Neutral helpers shared by the file-row factories.
enum BackendCloudBrainFilesNames {
    static let locks = ["**/*.lock", "**/*.pid", "**/*.sock", "**/*.socket", "**/.DS_Store", "**/.td-cloud-*"]
    /// Reversible, source-id-safe token (lowercase hex of the UTF-8 bytes); long values use a stable hash.
    static func token(_ value: String) -> String {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        return hex.count <= 80 ? hex : "h" + String(BackendCloudBrainMemoryHash.bytes(Data(value.utf8)).prefix(40))
    }
    static func untoken(_ token: String) -> String? {
        guard !token.hasPrefix("h"), token.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = token.startIndex
        while index < token.endIndex {
            let next = token.index(index, offsetBy: 2)
            guard let byte = UInt8(token[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
