import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// File descriptors keep parent-directory swaps and symbolic links from escaping
/// the selected tree while reading. Hidden files are content; only our marker is not.
enum BackendSkillVersionFiles {
    struct Tree: Sendable { let manifest: [SkillVersionFile]; let data: [String: Data]; let digest: String }
    static let maxFiles = 2_000, maxFileBytes = 8 * 1_024 * 1_024, maxBytes = 32 * 1_024 * 1_024
    static func error(_ message: String) -> NativeRPCError { .init(code: "skill-version-refused", message: message) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func safe(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && path.utf8.count < 1_024 && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func inspect(_ root: URL) throws -> Tree {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw error("The skill folder must be a readable regular directory, not a link.") }; defer { close(fd) }
        var manifest: [SkillVersionFile] = [], contents: [String: Data] = [:], seen = Set<String>(), total = 0
        func walk(_ parent: Int32, prefix: String) throws {
            guard let directory = fdopendir(dup(parent)) else { throw error("A skill directory could not be read.") }; defer { closedir(directory) }
            var names: [String] = []
            errno = 0
            while let item = readdir(directory) {
                let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
                if name != ".", name != ".." { names.append(name) }
            }
            guard errno == 0 else { throw error("The full skill directory could not be read.") }
            for name in names.sorted() {
                if prefix.isEmpty, name == BackendSkillsMirror.marker { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                guard safe(path), seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted, manifest.count < maxFiles else { throw error("The skill has ambiguous paths or more than 2,000 entries. Nothing was saved.") }
                var entry = stat()
                guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { throw error("A skill file changed or could not be read.") }
                let kind = entry.st_mode & S_IFMT, isDir = kind == S_IFDIR
                guard isDir || kind == S_IFREG else { throw error("Links and special files cannot be included in a skill version: " + path) }
                let child = openat(parent, name, O_RDONLY | O_NOFOLLOW | (isDir ? O_DIRECTORY : 0))
                guard child >= 0 else { throw error("A skill file is not readable: " + path) }; defer { close(child) }
                var actual = stat(); guard fstat(child, &actual) == 0, actual.st_mode & S_IFMT == kind else { throw error("A skill entry changed while it was read.") }
                if isDir {
                    manifest.append(.init(path: path, hash: "", bytes: 0, directory: true, executable: true)); try walk(child, prefix: path)
                } else {
                    guard actual.st_size >= 0, actual.st_size <= maxFileBytes else { throw error("A skill file exceeds 8 MB: " + path) }
                    let handle = FileHandle(fileDescriptor: child, closeOnDealloc: false)
                    var data = Data()
                    while true {
                        let chunk = try handle.read(upToCount: 65_536) ?? Data(); if chunk.isEmpty { break }
                        data.append(chunk); guard data.count <= maxFileBytes, total + data.count <= maxBytes else { throw error("The full skill exceeds its file or 32 MB package limit.") }
                    }
                    total += data.count; contents[path] = data
                    manifest.append(.init(path: path, hash: hash(data), bytes: data.count, directory: false, executable: actual.st_mode & 0o111 != 0))
                }
            }
        }
        try walk(fd, prefix: "")
        manifest.sort { $0.path < $1.path }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = hash(try encoder.encode(manifest))
        return .init(manifest: manifest, data: contents, digest: digest)
    }
    static func write(_ tree: Tree, to folder: URL) throws {
        guard mkdir(folder.path, 0o700) == 0 else { throw error("The staging folder already exists or cannot be created.") }
        do {
        for entry in tree.manifest {
            guard safe(entry.path) else { throw error("A saved path is unsafe.") }
            let target = folder.appendingPathComponent(entry.path)
            if entry.directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            else {
                guard let bytes = tree.data[entry.path] else { throw error("A saved file is missing.") }
                try bytes.write(to: target, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: entry.executable ? 0o700 : 0o600], ofItemAtPath: target.path)
            }
        }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    static func findings(_ tree: Tree, command: String) -> [String] {
        var result: [String] = []
        let skills = tree.manifest.filter { !$0.directory && $0.path.lowercased().hasSuffix("skill.md") }
        if skills.count != 1 || skills.first?.path != "SKILL.md" { result.append("The package needs exactly one root SKILL.md.") }
        guard let data = tree.data["SKILL.md"], data.count <= 262_144, let raw = String(data: data, encoding: .utf8) else { return result + ["SKILL.md must be readable UTF-8 under 256 KB."] }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if !text.hasPrefix("---\n") || text.components(separatedBy: "\n---").count < 2 || SkillCommandNames.headerName(text) == nil { result.append("SKILL.md needs complete front matter and a plain name.") }
        do { try SkillCommandNames.requireFile(path: command + "/SKILL.md", text: text, targets: SkillCommandNames.ais) } catch { result.append(error.localizedDescription) }
        return result
    }
    static func markerIdentity(_ target: URL) throws -> String {
        let descriptor = open(target.appendingPathComponent(BackendSkillsMirror.marker).path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw error("The AI mirror ownership marker is missing or linked.") }; defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= 8192 else { throw error("The AI mirror ownership marker is invalid.") }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 8193) ?? Data()
        guard data.count <= 8192 else { throw error("The AI mirror ownership marker is too large.") }
        return "\(attributes.st_dev):\(attributes.st_ino):" + hash(data)
    }
    static func exchange(_ left: URL, _ right: URL) throws {
        guard renameatx_np(AT_FDCWD, left.path, AT_FDCWD, right.path, UInt32(RENAME_SWAP)) == 0 else { throw error("The skill folder could not be atomically exchanged; nothing was adopted.") }
    }
}
