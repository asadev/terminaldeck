import Foundation
import Darwin
import TerminalDeckNativeCore

/// Every read and every write lane F makes in a folder a person owns (a project folder, an AI account's home),
/// and in this Mac's own copy of the Cloud's boot files. The rules live here and nowhere else:
///
/// - The folder itself is the person's choice (its own path may pass through their links). BELOW it no link is
///   ever followed: each step is opened relative to the folder before it, with O_NOFOLLOW.
/// - A name must be on the disk byte for byte. A name that differs only in letter case, or in how an accented
///   letter is stored (a "twin"), stops the read or the write. This is checked from the folder's own listing, so
///   it holds on disks that tell `A` from `a` as well as on those that do not.
/// - A new file gets its final name by link(2), which never replaces anything: a file, a link or a folder that
///   holds the name wins.
/// - An existing file is replaced only by swapping the new one in and checking what came OUT; if that is not what
///   was expected it is swapped back, so a save that landed in between is never lost.
/// - Nothing is run, sourced or linked to. A written file is created 0644 (before the umask); a script (its first two
///   bytes `#!`) is created 0755, so a guard or a skill's script keeps working on every Mac (Asad, 19 Nov: "the guard
///   should be traveling"). Runnable is decided by the bytes alone, the same on every Mac.
enum BackendCloudBootFilesDisk {
    enum Found: Sendable, Equatable {
        case absent
        case file(Data)
        /// Short codes: link, twin, in-the-way, too-large, name, unreadable, unreachable.
        case blocked(String)
    }
    /// Why a write did not happen: link, twin, in-the-way, changed, name, unreadable, unreachable, unwritable.
    struct Stop: Error, Equatable, Sendable { let reason: String }
    enum Lookup: Sendable, Equatable { case exact, twin, absent }

    struct Walk: Sendable {
        struct Entry: Sendable, Equatable { let relative: String; let bytes: Int64; let hash: String }
        /// The boot files found, each read once and fingerprinted.
        var files: [Entry] = []
        /// Here, but not a boot file this version carries (a link, too large, not text, a refused name).
        /// Such a path is never read as "removed".
        var present: Set<String> = []
        /// Left out on purpose, by short code: link, too-large, not-text, hidden, never, rebuildable.
        var excluded: [String: Int] = [:]
        /// Should have been read and was not, by short code: unreadable, unreachable, twin, name, too-many, too-deep.
        var gaps: [String: Int] = [:]
        /// False when something could not be listed: no removal is ever concluded from such a walk.
        var reliable = true
        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    }

    // MARK: Names

    /// How the disk may treat two names as one: composed form, letter case folded.
    static func fold(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }
    static func same(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }

    /// The names a folder holds, as stored. nil when it cannot be listed.
    static func names(in folder: Int32) -> [String]? {
        let copy = dup(folder)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        rewinddir(stream)
        var found: [String] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { field in
                field.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { found.append(name) }
        }
        return found
    }

    static func lookup(_ folder: Int32, _ name: String) -> Lookup? {
        guard let listed = names(in: folder) else { return nil }
        if listed.contains(where: { same($0, name) }) { return .exact }
        let wanted = fold(name)
        return listed.contains(where: { fold($0) == wanted }) ? .twin : .absent
    }

    static func openRoot(_ root: URL) -> Int32? {
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        return descriptor >= 0 ? descriptor : nil
    }

    /// What stands where a folder was expected.
    private static func obstacle(_ folder: Int32, _ name: String) -> String {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return "unreadable" }
        if (info.st_mode & S_IFMT) == S_IFLNK { return "link" }
        return (info.st_mode & S_IFMT) == S_IFDIR ? "unreadable" : "in-the-way"
    }

    /// Opens the folders named by `parts`, one below the other, starting at `root`. Returns the last one's
    /// descriptor (the caller closes it), or nil when one is missing and `create` is false. With `create`, a
    /// missing folder is made (0755 before the umask).
    static func descend(_ root: Int32, _ parts: [String], create: Bool) throws -> Int32? {
        var current = dup(root)
        guard current >= 0 else { throw Stop(reason: "unreadable") }
        for name in parts {
            guard let found = lookup(current, name) else { close(current); throw Stop(reason: "unreadable") }
            if found == .twin { close(current); throw Stop(reason: "twin") }
            if found == .absent {
                guard create else { close(current); return nil }
                if mkdirat(current, name, 0o755) != 0, errno != EEXIST { close(current); throw Stop(reason: "unwritable") }
            }
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let reason = obstacle(current, name)
                close(current)
                throw Stop(reason: reason)
            }
            close(current)
            current = next
        }
        return current
    }

    // MARK: Read

    static func read(root: URL, relative: String, cap: Int = CloudBootFilesFormat.maximumFileBytes) -> Found {
        guard let parts = CloudBootFilesRules.parts(relative), let name = parts.last, !name.isEmpty else { return .blocked("name") }
        guard let top = openRoot(root) else { return .blocked("unreachable") }
        defer { close(top) }
        do {
            guard let folder = try descend(top, Array(parts.dropLast()), create: false) else { return .absent }
            defer { close(folder) }
            return read(folder, name, cap: cap)
        } catch let stop as Stop { return .blocked(stop.reason) } catch { return .blocked("unreadable") }
    }

    static func read(_ folder: Int32, _ name: String, cap: Int) -> Found {
        guard let found = lookup(folder, name) else { return .blocked("unreadable") }
        if found == .absent { return .absent }
        if found == .twin { return .blocked("twin") }
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 { return .blocked(errno == ELOOP ? "link" : "unreadable") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .blocked("unreadable") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .blocked("in-the-way") }
        // A second hard name could be a way to read (or to seem to change) some other file.
        guard info.st_nlink == 1 else { return .blocked("link") }
        guard info.st_size <= off_t(cap) else { return .blocked("too-large") }
        guard let bytes = contents(descriptor, limit: cap) else { return .blocked("unreadable") }
        return bytes.count <= cap ? .file(bytes) : .blocked("too-large")
    }

    private static func contents(_ descriptor: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    /// True when a name on the way to `relative`, or its own name, is held by a twin.
    static func twin(root: URL, relative: String) -> Bool {
        guard let parts = CloudBootFilesRules.parts(relative), let name = parts.last, let top = openRoot(root) else { return false }
        defer { close(top) }
        do {
            guard let folder = try descend(top, Array(parts.dropLast()), create: false) else { return false }
            defer { close(folder) }
            return lookup(folder, name) == .twin
        } catch let stop as Stop { return stop.reason == "twin" } catch { return false }
    }

    // MARK: Write

    /// A script: starts with `#!`. Written runnable (0755 before the umask).
    static func isScript(_ bytes: Data) -> Bool { bytes.count >= 2 && bytes[bytes.startIndex] == 0x23 && bytes[bytes.startIndex + 1] == 0x21 }

    /// A setup file (settings, guard, Codex folder) whose text holds a password, key or token never travels as plain text:
    /// it stays on its Mac and is counted ("secret"), asked on the sending Mac and again before a write.
    static func setupHoldsSecret(kind: CloudBootFilesPlaceKind, relative: String, bytes: Data) -> Bool {
        guard CloudBootFilesRules.secretChecked(kind: kind, relative: relative) else { return false }
        return BackendSharedRedact.containsKnownSecret(String(decoding: bytes, as: UTF8.self))
    }

    /// The new bytes under a private name in the same folder, synchronised. Returns that name.
    private static func stage(_ folder: Int32, _ bytes: Data) throws -> String {
        let name = ".td-cloud-" + UUID().uuidString.lowercased()
        let descriptor = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, isScript(bytes) ? 0o755 : 0o644)
        guard descriptor >= 0 else { throw Stop(reason: "unwritable") }
        var failed = false
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress.map { $0 + offset }, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    break
                }
                offset += count
            }
        }
        if !failed, fsync(descriptor) != 0 { failed = true }
        close(descriptor)
        if failed {
            unlinkat(folder, name, 0)
            throw Stop(reason: "unwritable")
        }
        return name
    }

    private static func open(_ root: URL, _ relative: String, create: Bool) throws -> (folder: Int32, name: String) {
        guard let parts = CloudBootFilesRules.parts(relative), let name = parts.last, !name.isEmpty else { throw Stop(reason: "name") }
        guard let top = openRoot(root) else { throw Stop(reason: "unreachable") }
        defer { close(top) }
        guard let folder = try descend(top, Array(parts.dropLast()), create: create) else { throw Stop(reason: "changed") }
        return (folder, name)
    }

    /// A NEW file. Throws `changed` when anything already holds the name, `twin` when a twin does.
    static func create(root: URL, relative: String, bytes: Data) throws {
        let place = try open(root, relative, create: true)
        defer { close(place.folder) }
        guard let found = lookup(place.folder, place.name) else { throw Stop(reason: "unreadable") }
        guard found == .absent else { throw Stop(reason: found == .twin ? "twin" : "changed") }
        let staged = try stage(place.folder, bytes)
        let linked = linkat(place.folder, staged, place.folder, place.name, 0)
        let code = errno
        unlinkat(place.folder, staged, 0)
        guard linked == 0 else { throw Stop(reason: code == EEXIST ? "changed" : "unwritable") }
        fsync(place.folder)
        guard case .file(let written) = read(place.folder, place.name, cap: bytes.count), written == bytes else { throw Stop(reason: "changed") }
    }

    /// Replaces a file whose bytes have the fingerprint `expecting`, and nothing else. Returns the bytes replaced.
    @discardableResult
    static func replace(root: URL, relative: String, bytes: Data, expecting: String) throws -> Data {
        let place = try open(root, relative, create: false)
        defer { close(place.folder) }
        guard let found = lookup(place.folder, place.name) else { throw Stop(reason: "unreadable") }
        guard found == .exact else { throw Stop(reason: found == .twin ? "twin" : "changed") }
        // Looked at first: a link, a folder or other bytes under the name end it here, before anything is staged.
        guard case .file(let current) = read(place.folder, place.name, cap: CloudBootFilesFormat.maximumFileBytes),
              BackendCloudBrainMemoryHash.bytes(current) == expecting else { throw Stop(reason: "changed") }
        let staged = try stage(place.folder, bytes)
        if renameatx_np(place.folder, staged, place.folder, place.name, UInt32(RENAME_SWAP)) == 0 {
            // `staged` now names what was there. Only the expected bytes may go.
            if case .file(let previous) = read(place.folder, staged, cap: CloudBootFilesFormat.maximumFileBytes),
               BackendCloudBrainMemoryHash.bytes(previous) == expecting {
                unlinkat(place.folder, staged, 0)
                fsync(place.folder)
                return previous
            }
            // An edit, a link or a folder: put it back exactly as it was.
            if renameatx_np(place.folder, staged, place.folder, place.name, UInt32(RENAME_SWAP)) == 0 { unlinkat(place.folder, staged, 0) }
            throw Stop(reason: "changed")
        }
        let code = errno
        // A disk that cannot swap two names: check, then rename over it.
        guard code == ENOTSUP || code == EINVAL,
              case .file(let previous) = read(place.folder, place.name, cap: CloudBootFilesFormat.maximumFileBytes),
              BackendCloudBrainMemoryHash.bytes(previous) == expecting else {
            unlinkat(place.folder, staged, 0)
            throw Stop(reason: code == ENOTSUP || code == EINVAL ? "changed" : "unwritable")
        }
        guard renameat(place.folder, staged, place.folder, place.name) == 0 else {
            unlinkat(place.folder, staged, 0)
            throw Stop(reason: "unwritable")
        }
        fsync(place.folder)
        return previous
    }

    /// Removes only the exact bytes named, without following links. The owner must save keeper bytes BEFORE
    /// calling this on a person's instruction file as well as on its private copy.
    static func removeCopy(root: URL, relative: String, expecting: String) throws {
        let place = try open(root, relative, create: false)
        defer { close(place.folder) }
        guard case .file(let previous) = read(place.folder, place.name, cap: CloudBootFilesFormat.maximumFileBytes),
              BackendCloudBrainMemoryHash.bytes(previous) == expecting else { throw Stop(reason: "changed") }
        guard unlinkat(place.folder, place.name, 0) == 0 else { throw Stop(reason: "unwritable") }
        fsync(place.folder)
    }

    // MARK: Walk

    /// The boot files of one place, by the list in `CloudBootFilesRules`. Only the listed top-level files and the
    /// listed folders are opened. Of anything else in the place, at most its NAME is seen (in the listing of the
    /// place's top folder and of `.claude`, `.agents`, `.codex`, `.gemini`); it is never opened, read or entered.
    static func walk(root: URL, kind: CloudBootFilesPlaceKind) -> Walk {
        var walk = Walk()
        guard let top = openRoot(root) else {
            walk.reliable = false
            walk.gaps["unreachable", default: 0] += 1
            return walk
        }
        defer { close(top) }
        for name in CloudBootFilesRules.files(kind) {
            guard let found = lookup(top, name) else {
                walk.reliable = false
                walk.gaps["unreadable", default: 0] += 1
                continue
            }
            if found == .twin { walk.gaps["twin", default: 0] += 1 }
            if found == .exact { file(top, name, relative: name, kind: kind, into: &walk) }
        }
        // Setup files by exact path (`.claude/settings.json`, ...): only their own folder is opened, never followed.
        for path in CloudBootFilesRules.setupFiles(kind) {
            let parts = path.split(separator: "/").map(String.init)
            guard let name = parts.last else { continue }
            do {
                guard let opened = try descend(top, Array(parts.dropLast()), create: false) else { continue }
                defer { close(opened) }
                guard let found = lookup(opened, name) else { walk.reliable = false; walk.gaps["unreadable", default: 0] += 1; continue }
                if found == .twin { walk.gaps["twin", default: 0] += 1 }
                if found == .exact { file(opened, name, relative: path, kind: kind, into: &walk) }
            } catch let stop as Stop {
                if stop.reason == "link" { walk.excluded["link", default: 0] += 1 }
                else { walk.reliable = false; walk.gaps[stop.reason, default: 0] += 1 }
            } catch { walk.reliable = false }
        }
        for folder in CloudBootFilesRules.folders(kind) {
            do {
                guard let opened = try descend(top, folder.split(separator: "/").map(String.init), create: false) else { continue }
                defer { close(opened) }
                scan(opened, prefix: folder + "/", kind: kind, depth: 1, into: &walk)
            } catch let stop as Stop {
                if stop.reason == "link" { walk.excluded["link", default: 0] += 1 }
                else {
                    walk.reliable = false
                    walk.gaps[stop.reason, default: 0] += 1
                }
            } catch { walk.reliable = false }
        }
        return walk
    }

    private static func scan(_ folder: Int32, prefix: String, kind: CloudBootFilesPlaceKind, depth: Int, into walk: inout Walk) {
        guard let listed = names(in: folder) else {
            walk.reliable = false
            walk.gaps["unreadable", default: 0] += 1
            return
        }
        var folds: Set<String> = []
        for name in listed.sorted() {
            let relative = prefix + name
            // Two names the other Mac's disk would hold as one: the first is carried, the second is reported.
            guard folds.insert(fold(name)).inserted else {
                walk.gaps["twin", default: 0] += 1
                walk.present.insert(relative)
                continue
            }
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT {
                    walk.reliable = false
                    walk.gaps["unreadable", default: 0] += 1
                }
                continue
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                file(folder, name, relative: relative, kind: kind, into: &walk)
                continue
            }
            if name.utf8.first == UInt8(ascii: ".") { walk.excluded["hidden", default: 0] += 1; continue }
            let lower = name.lowercased()
            if CloudBootFilesRules.neverFolderNames.contains(lower) { walk.excluded["never", default: 0] += 1; continue }
            if CloudBootFilesRules.rebuildableFolderNames.contains(lower) { walk.excluded["rebuildable", default: 0] += 1; continue }
            guard depth < CloudBootFilesFormat.maximumFolderDepth else { walk.gaps["too-deep", default: 0] += 1; continue }
            let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else {
                walk.reliable = false
                walk.gaps["unreadable", default: 0] += 1
                continue
            }
            scan(child, prefix: relative + "/", kind: kind, depth: depth + 1, into: &walk)
            close(child)
        }
    }

    private static func file(_ folder: Int32, _ name: String, relative: String, kind: CloudBootFilesPlaceKind, into walk: inout Walk) {
        if let refusal = CloudBootFilesRules.refusal(kind: kind, relative: relative) {
            switch refusal {
            case .hidden, .never, .rebuildable: walk.excluded[refusal.rawValue, default: 0] += 1
            case .path, .notListed: walk.gaps["name", default: 0] += 1
            }
            walk.present.insert(relative)
            return
        }
        guard walk.files.count < CloudBootFilesFormat.maximumFilesPerPlace else {
            walk.gaps["too-many", default: 0] += 1
            walk.present.insert(relative)
            return
        }
        switch read(folder, name, cap: CloudBootFilesFormat.maximumFileBytes) {
        case .absent: return
        case .file(let bytes):
            guard CloudBootFilesRules.isText(bytes) else {
                walk.excluded["not-text", default: 0] += 1
                walk.present.insert(relative)
                return
            }
            if setupHoldsSecret(kind: kind, relative: relative, bytes: bytes) {
                walk.excluded["secret", default: 0] += 1
                walk.present.insert(relative)
                return
            }
            walk.files.append(.init(relative: relative, bytes: Int64(bytes.count), hash: BackendCloudBrainMemoryHash.bytes(bytes)))
        case .blocked(let reason):
            walk.present.insert(relative)
            // A pipe, a device or a folder under a file's name is not text either.
            if reason == "link" || reason == "too-large" { walk.excluded[reason, default: 0] += 1 }
            else if reason == "in-the-way" { walk.excluded["not-text", default: 0] += 1 }
            else {
                walk.gaps[reason, default: 0] += 1
                if reason == "unreadable" { walk.reliable = false }
            }
        }
    }
}
