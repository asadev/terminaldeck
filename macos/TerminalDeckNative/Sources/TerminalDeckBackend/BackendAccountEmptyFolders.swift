import Darwin
import Foundation
import TerminalDeckNativeCore

/// Removes only the two shapes left by a failed account Add: an empty directory, or a directory
/// containing only the projects link this app makes. Every filesystem operation stays on open,
/// no-follow directory descriptors. There is no recursive delete and no history file is opened.
enum BackendAccountEmptyFolders {
    private struct ProfileReferences {
        let bytes: Data?
        let ids: Set<String>
        let directories: Set<String>

        func contains(_ directory: String, name: String) -> Bool {
            ids.contains(name) || directories.contains { $0 == directory || $0.hasPrefix(directory + "/") }
        }
    }

    static func existsWithoutFollowing(_ path: String) -> Bool {
        var info = stat()
        return Darwin.lstat(path, &info) == 0 || errno != ENOENT
    }

    static func clean(configuration: BackendAccountConfiguration, now: Date, minimumAge: TimeInterval) throws -> [String] {
        guard let references = try references(configuration) else { return [] }
        let root = configuration.profilesRoot
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if rootFD < 0 { if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return [] }; throw failure() }
        defer { Darwin.close(rootFD) }
        var removed: [String] = []
        for name in try entries(rootFD).sorted() {
            // These are the app's slug ids, never hidden folders, another root, or a path.
            guard name.range(of: "^[a-z0-9][a-z0-9-]{0,35}$", options: .regularExpression) != nil else { continue }
            let directory = root.appendingPathComponent(name).standardizedFileURL.path
            guard !references.contains(directory, name: name) else { continue }
            var info = stat()
            guard fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            // An old helper can be making a draft before it has written profiles.json. Leave recent
            // folders alone; failed-create cleanup handles a draft owned by this process immediately.
            guard now.timeIntervalSince1970 - modified >= max(0, minimumAge) else { continue }
            if try remove(rootFD: rootFD, name: name, configuration: configuration, expected: info, stillUnreferenced: {
                guard let current = try self.references(configuration) else { return false }
                return current.bytes == references.bytes && !current.contains(directory, name: name)
            }) { removed.append(name) }
        }
        return removed
    }

    /// Only for a directory this create attempt made itself. A pre-existing/adopted folder never
    /// reaches this call, and any content other than the known projects link prevents removal.
    static func removeDraft(_ path: String, configuration: BackendAccountConfiguration) throws -> Bool {
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let parent = directory.deletingLastPathComponent().path
        guard [configuration.profilesRoot.path, configuration.accountLoginsRoot.path].contains(parent) else { return false }
        let rootFD = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootFD >= 0 else { return false }
        defer { Darwin.close(rootFD) }
        var info = stat()
        let name = directory.lastPathComponent
        guard fstatat(rootFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return try remove(rootFD: rootFD, name: name, configuration: configuration, expected: info, stillUnreferenced: {
            guard let current = try references(configuration) else { return false }
            return !current.contains(directory.path, name: name)
        })
    }

    private static func references(_ configuration: BackendAccountConfiguration) throws -> ProfileReferences? {
        let file = configuration.dataDirectory.appendingPathComponent("profiles.json")
        let bytes: Data?
        do { bytes = try BackendAccountFiles.boundedRead(file, maximum: 4 * 1024 * 1024) }
        catch { return nil }
        guard let bytes else { return ProfileReferences(bytes: nil, ids: [], directories: []) }
        guard let raw = try? NativeRPCValue.parseJSON(bytes), raw.fields != nil,
              raw["version"].isNullish || raw["version"].number.map({ $0 <= 1 }) == true,
              raw["profiles"].isNullish || raw["profiles"].elements != nil else { return nil }
        var ids = Set<String>(), directories = Set<String>()
        // Include every raw row, even one the profile parser does not understand. A newer or damaged
        // account entry is not permission to clean its folder.
        for row in raw["profiles"].elements ?? [] {
            guard row.fields != nil, let id = row["id"].string, !id.isEmpty,
                  let directory = row["configDir"].string, directory.hasPrefix("/"), !directory.contains("\0") else { return nil }
            ids.insert(id)
            let url = URL(fileURLWithPath: directory).standardizedFileURL
            directories.insert(url.path)
            directories.insert(url.resolvingSymlinksInPath().path)
        }
        return ProfileReferences(bytes: bytes, ids: ids, directories: directories)
    }

    private static func remove(rootFD: Int32, name: String, configuration: BackendAccountConfiguration,
                               expected: stat, stillUnreferenced: () throws -> Bool) throws -> Bool {
        let folderFD = openat(rootFD, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard folderFD >= 0 else { return false }
        defer { Darwin.close(folderFD) }
        var opened = stat()
        guard fstat(folderFD, &opened) == 0, same(expected, opened) else { return false }
        let children = try entries(folderFD)
        guard children.isEmpty || children == ["projects"] else { return false }
        var link: stat?
        var linkTarget: String?
        if !children.isEmpty {
            var info = stat()
            guard fstatat(folderFD, "projects", &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFLNK else { return false }
            var buffer = [CChar](repeating: 0, count: 4097)
            let count = buffer.withUnsafeMutableBufferPointer { readlinkat(folderFD, "projects", $0.baseAddress, 4096) }
            guard count > 0, count < 4096 else { return false }
            let target = String(cString: buffer)
            let absolute = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : configuration.profilesRoot.appendingPathComponent(name).appendingPathComponent(target)
            let ownProjects = URL(fileURLWithPath: configuration.systemDirectory("claude")).appendingPathComponent("projects").standardizedFileURL
            guard absolute.standardizedFileURL == ownProjects else { return false }
            link = info
            linkTarget = target
        }
        guard try stillUnreferenced() else { return false }
        var current = stat()
        guard fstatat(rootFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0, same(expected, current),
              try entries(folderFD) == children else { return false }
        if let link {
            var currentLink = stat()
            guard fstatat(folderFD, "projects", &currentLink, AT_SYMLINK_NOFOLLOW) == 0, same(link, currentLink),
                  unlinkat(folderFD, "projects", 0) == 0 else { return false }
        }
        // A concurrent writer adding any file makes this fail safely. Never use removeItem here.
        if unlinkat(rootFD, name, AT_REMOVEDIR) == 0 { return true }
        // If a writer added history after the checks, keep its shared-projects link too. symlinkat
        // creates only an absent name and cannot overwrite anything that writer installed.
        if let linkTarget { _ = symlinkat(linkTarget, folderFD, "projects") }
        return false
    }

    private static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode
    }

    private static func entries(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw failure() }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw failure() }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result.sorted()
    }

    private static func failure() -> BackendAccountFailure {
        BackendAccountFailure("Empty account folders could not be checked. Open Settings › Coding AIs and try again after reopening Terminal Deck.")
    }
}
