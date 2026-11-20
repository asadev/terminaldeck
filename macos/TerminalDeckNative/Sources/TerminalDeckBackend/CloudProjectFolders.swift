import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// FOLDERS THAT TRAVEL WITH THE PROJECT (Asad, 19 Nov 2026: "the Commands and all this stuff should travel to all the
/// team notes, tools, logs, and other things also. Everything should be same ... So everything should travel. including
/// actually pictures and everything don't worry about cloud limits.").
///
/// Every top-level folder of every project on this Mac travels to every device of the account, all kinds of files, with
/// no size or day cap of ours. Left out only what is rebuilt or comes from git (code checkouts, `.git`, build outputs and
/// caches, installers, package folders, the .NET SDK), the system's own scratch files (`.DS_Store` and the like) and links.
/// Carried by the Cloud folder's owner (`BackendCloudFolder`, kind `CloudFileKind.projectFolders`, row I26) over many
/// roots (`CloudFolderRoots`): a record's path is `<project key>/<folder>/<path in it>`; the key is made from the
/// project's id, so every Mac places it in ITS folder of that project.
public enum CloudProjectFoldersRules {
    public static let inventoryRow = "I26"
    /// "Every Mac understands project-folder records" (`DeckMemoryStore.cloudFeatureAnnounce`); no dot allowed.
    public static let feature = "projectfolders"
    public static let format = 1
    /// The switch (this Mac's defaults). On unless someone set it off; nobody is asked.
    public static let switchKey = "cloud.projectFoldersTravel"
    public static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: switchKey) as? Bool ?? true }

    /// An override (optional): one folder name per line in this file of the project (it travels with the project's
    /// instruction files). Absent: every top-level folder.
    public static let listFile = ".terminaldeck/travel-folders"
    /// What is rebuilt or comes from git: never travels, at any depth.
    public static let neverFolders: Set<String> = CloudFolderRules.rebuildableFolders.union(
        ["code", ".git", "build", "build-cache", "installers", "dist", ".next", ".turbo", ".cache", "dotnet", "dotnet-nuget", ".nuget",
         ".swiftpm", ".wrangler", "xcuserdata"])
    /// The system's own scratch files and half-written downloads.
    public static let junkNames: Set<String> = [".ds_store", ".localized", "icon\r", "thumbs.db", "desktop.ini", ".spotlight-v100", ".trashes", ".fseventsd"]
    public static let junkPrefixes = ["._", ".~lock", "~$", ".td-cloud-", ".terminaldeck-stage-"]
    public static let junkEndings = [".swp", ".swo", ".swx", ".crdownload", ".download", ".part", ".partial", ".icloud"]

    public static let exclusions = [
        "Every folder of your projects travels, with every kind of file.",
        "Left out: code checkouts, build outputs and caches, installers and package folders (they are made again on each device), links, and the system's own scratch files."
    ]

    /// The key of a project in a record's path: "p" and 16 hex of the project's id. The same on every Mac.
    public static func key(projectId: String) -> String {
        "p" + SHA256.hash(data: Data(("td-project-folders\n" + projectId).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    static func isKey(_ text: String) -> Bool {
        text.utf8.count == 17 && text.hasPrefix("p") && text.dropFirst().allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
    static func junk(_ lowerName: String) -> Bool {
        junkNames.contains(lowerName) || junkPrefixes.contains { lowerName.hasPrefix($0) } || junkEndings.contains { lowerName.hasSuffix($0) }
    }

    /// The top-level folders of this project that travel: every real folder (no link, not hidden, not on the never list),
    /// or the names in the override file. A folder that is a code checkout (it holds `.git`) never travels.
    public static func folders(projectRoot: URL) -> [String] {
        let fm = FileManager.default
        var names: [String]
        if let data = fm.contents(atPath: projectRoot.appendingPathComponent(listFile).path), let text = String(data: data, encoding: .utf8) {
            names = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        } else {
            names = ((try? fm.contentsOfDirectory(atPath: projectRoot.path)) ?? []).sorted()
        }
        var out: [String] = []
        for name in names where !name.contains("/") && !name.hasPrefix(".") && !neverFolders.contains(name.lowercased()) && !out.contains(name) {
            let url = projectRoot.appendingPathComponent(name, isDirectory: true)
            guard realFolder(url), !isCheckout(url) else { continue }
            out.append(name)
        }
        return out
    }
    public static func realFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
    /// A folder with `.git` in it (a folder, or the file of a worktree) is a code checkout.
    public static func isCheckout(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.appendingPathComponent(".git").path, &info) == 0
    }

    /// A project whose folder is itself a code checkout (`.git` at its root): the files git TRACKS come from GitHub and
    /// never travel (Asad, 19 Nov: "we are not uploading the code ... code is going already to GitHub"); untracked files
    /// (local notes, pictures, a local `.env`, uploads) still do. Read once per look with `git ls-files -z` (no network).
    /// nil when git cannot answer: then nothing of that project travels in this look (never code by mistake).
    public static func trackedFiles(projectRoot: URL) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectRoot.path, "ls-files", "-z", "--full-name"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Set(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    /// nil when the file at `relative` (`<key>/<folder>/<path>`) travels. Asked on the sending Mac and on arrival.
    public static func refusal(_ relative: String) -> CloudFolderSkip? {
        guard CloudBootFilesRules.cleanRelative(relative), let parts = CloudBootFilesRules.parts(relative), parts.count >= 3,
              parts.count <= CloudFolderFormat.maximumDepth + 2, isKey(parts[0]) else { return .name }
        if parts[1].hasPrefix(".") { return .hidden }
        for name in parts.dropFirst().dropLast() where neverFolders.contains(name.lowercased()) { return .rebuildable }
        if junk(parts[parts.count - 1].lowercased()) { return .temporary }
        return nil
    }
}

/// Where the owner's paths live on this Mac. One folder (the Cloud folder: a path is relative to it), or many (project
/// folders: the first part of a path is a project key, the rest is relative to that project's folder). The many-roots
/// map changes when projects are added or moved; the owner reads it at every step.
public final class CloudFolderRoots: @unchecked Sendable {
    private let lock = NSLock()
    public let single: URL?
    private var many: [String: URL] = [:]
    public init(single: URL) { self.single = single }
    public init(many: [String: URL]) { single = nil; self.many = many }
    public var isMany: Bool { single == nil }
    public func set(_ next: [String: URL]) { lock.withLock { many = next } }
    public var all: [String: URL] { lock.withLock { many } }
    /// The folder and the path inside it. nil: a project not on this Mac (its files wait in the private copy).
    public func locate(_ path: String) -> (root: URL, relative: String)? {
        if let single { return (single, path) }
        guard let slash = path.firstIndex(of: "/") else { return nil }
        guard let root = lock.withLock({ many[String(path[..<slash])] }) else { return nil }
        let rest = String(path[path.index(after: slash)...])
        return rest.isEmpty ? nil : (root, rest)
    }
}

extension CloudFolderDisk {
    static func caseClash(_ roots: CloudFolderRoots, _ path: String) -> Bool { roots.locate(path).map { caseClash($0.root, $0.relative) } ?? false }
    static func fileFolderClash(_ roots: CloudFolderRoots, _ path: String) -> Bool { roots.locate(path).map { fileFolderClash($0.root, $0.relative) } ?? false }
    static func stamp(_ roots: CloudFolderRoots, _ path: String) -> Stamp? { roots.locate(path).flatMap { stamp($0.root, $0.relative) } }
    static func read(_ roots: CloudFolderRoots, _ path: String) -> Read { roots.locate(path).map { read($0.root, $0.relative) } ?? .blocked }
    static func modified(_ roots: CloudFolderRoots, _ path: String) -> Int64? { roots.locate(path).flatMap { modified($0.root, $0.relative) } }
    static func setModified(_ roots: CloudFolderRoots, _ path: String, _ at: Int64) {
        if let place = roots.locate(path) { setModified(place.root, place.relative, at) }
    }
    static func write(_ roots: CloudFolderRoots, _ path: String, bytes: Data, expecting: String?, cloneFrom: URL? = nil) throws {
        guard let place = roots.locate(path) else { throw CloudFailure.unavailable }
        try write(place.root, place.relative, bytes: bytes, expecting: expecting, cloneFrom: cloneFrom)
    }
    static func remove(_ roots: CloudFolderRoots, _ path: String, expecting: String) throws {
        guard let place = roots.locate(path) else { throw CloudFailure.unavailable }
        try remove(place.root, place.relative, expecting: expecting)
    }
    /// The file's own place on disk (for an APFS clone into the private copy). nil for a project not on this Mac.
    static func url(_ roots: CloudFolderRoots, _ path: String) -> URL? { roots.locate(path).map { $0.root.appendingPathComponent($0.relative) } }
}

extension CloudFolderWalk {
    /// One look over every root. One folder: as before. Many: each project's travelling folders, paths under its key.
    static func run(_ roots: CloudFolderRoots, kind: CloudFileKind) -> CloudFolderWalk {
        if let single = roots.single { return run(single, kind: kind) }
        var walk = CloudFolderWalk()
        for (key, root) in roots.all.sorted(by: { $0.key < $1.key }) {
            guard CloudProjectFoldersRules.realFolder(root) else { continue }
            // The project folder is a code checkout itself: what git tracks never travels.
            var tracked: Set<String>?
            if CloudProjectFoldersRules.isCheckout(root) {
                guard let files = CloudProjectFoldersRules.trackedFiles(projectRoot: root) else { walk.reliable = false; continue }
                tracked = files
            }
            for name in CloudProjectFoldersRules.folders(projectRoot: root) {
                let part = run(root.appendingPathComponent(name, isDirectory: true), kind: kind, prefix: key + "/" + name + "/",
                               tracked: tracked, trackedPrefix: name + "/")
                walk.merge(part)
                if walk.files.count > kind.maximumFiles { walk.reliable = false; return walk }
            }
        }
        return walk
    }
    mutating func merge(_ other: CloudFolderWalk) {
        files.merge(other.files) { first, _ in first }
        for (why, count) in other.skipped { skipped[why, default: 0] += count }
        secretNames += other.secretNames; spellingNames += other.spellingNames
        excludedPaths.formUnion(other.excludedPaths)
        bytes += other.bytes
        if !other.present || !other.reliable { reliable = false }
    }
}
