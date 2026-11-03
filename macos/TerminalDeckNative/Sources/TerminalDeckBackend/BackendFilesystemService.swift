import Foundation
import Darwin
import TerminalDeckNativeCore

public actor BackendFilesystemService {
    public struct ListOptions: Sendable { public let showIgnored: Bool; public let withStats: Bool
        public init(showIgnored: Bool = false, withStats: Bool = false) { self.showIgnored = showIgnored; self.withStats = withStats } }
    public typealias GitFileListing = @Sendable (String, NativeRPCContext) async throws -> [String]?
    public nonisolated let authority: BackendFilesystemAuthority
    private let gitFiles: GitFileListing?
    private struct Cache: Sendable { let at: Date; let limit: Int; let value: NativeRPCValue }
    private var cache: [String: Cache] = [:]
    private var cacheOrder: [String] = []
    private var searches: [String: (id: UUID, task: Task<NativeRPCValue, any Error>)] = [:]
    public init(authority: BackendFilesystemAuthority, gitFiles: GitFileListing? = nil) { self.authority = authority; self.gitFiles = gitFiles }

    public func list(root: String, relative: String = "", options: ListOptions = ListOptions(), context: NativeRPCContext) async throws -> NativeRPCValue {
        let target = try await authority.resolve(root: root, relative: relative, context: context)
        let result = try await detached { try Self.list(target, relative: relative, options: options) }
        _ = try await authority.authorize(target.path.path, context: context)
        return result
    }
    public func read(root: String, relative: String, context: NativeRPCContext, refuseCredentials: Bool = false) async throws -> NativeRPCValue {
        let target = try await authority.resolve(root: root, relative: relative, context: context)
        if refuseCredentials && (BackendFilesystemIgnore.credentialPath(relative) || BackendFilesystemIgnore.credentialPath(target.relative)) {
            throw NativeRPCError(code: "access-denied", message: "Credential-shaped files are not returned through tools")
        }
        let result = try await detached { try Self.read(target, relative: relative) }
        _ = try await authority.authorize(target.path.path, context: context)
        return result
    }
    public func isDirectory(_ path: String, context: NativeRPCContext) async throws -> Bool {
        let url = try await authority.authorize(path, context: context)
        var info = stat()
        return stat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
    public func invalidate(root: String? = nil) {
        if let root { cache[URL(fileURLWithPath: root).standardizedFileURL.path] = nil; cacheOrder.removeAll { $0 == root } }
        else { cache.removeAll(); cacheOrder.removeAll() }
    }
    public func cancel(ownerID: String) { searches.removeValue(forKey: ownerID)?.task.cancel() }
    public func removeOwner(_ ownerID: String) { cancel(ownerID: ownerID) }

    /// Source file-search response, 30s LRU capped at eight roots. A new search
    /// cancels this owner's prior one; callers still reauthorize cached roots.
    public func projectFiles(root: String, refresh: Bool = false, limit: Int = 10_000,
                             context: NativeRPCContext, home: String? = nil, maxDepth: Int = 12, ignoreDirs: Set<String>? = nil) async throws -> NativeRPCValue {
        let target = try await authority.resolve(root: root, relative: "", context: context)
        let ignored = ignoreDirs ?? Self.searchIgnored, plainOptions = maxDepth == 12 && ignoreDirs == nil
        guard target.root.path != "/", target.root.path != home else { throw NativeRPCError.invalidArguments("Quick open requires a project folder, not the root/home") }
        let cap = min(max(limit, 1), 50_000)
        let key = target.root.path
        cancel(ownerID: context.ownerID)
        if !refresh, plainOptions, let hit = cache[key], Date().timeIntervalSince(hit.at) < 30,
           hit.value["truncated"].bool != true || hit.limit >= cap { return hit.value }
        let request = UUID()
        let listing = gitFiles
        let task = Task<NativeRPCValue, any Error> {
            let start = Date()
            if let listing, let files = try await listing(key, context) {
                try Task.checkCancellation()
                var seen: Set<String> = []
                let kept = files.filter { path in
                    !path.hasPrefix("/") && !path.split(separator: "/").contains("..") &&
                    !path.split(separator: "/").dropLast().contains(where: { ignored.contains(String($0)) }) && seen.insert(path).inserted
                }
                return Self.fileList(root: key, files: Array(kept.prefix(cap)), truncated: kept.count > cap, source: "git", start: start)
            }
            let work = Task.detached(priority: .utility) { try Self.walk(target, limit: cap, start: start, maxDepth: maxDepth, ignored: ignored) }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        searches[context.ownerID] = (request, task)
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            _ = try await authority.authorize(key, context: context)
            if plainOptions {
                cache[key] = Cache(at: Date(), limit: cap, value: value)
                cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
                while cacheOrder.count > 8 { cache[cacheOrder.removeFirst()] = nil }
            }
            if searches[context.ownerID]?.id == request { searches[context.ownerID] = nil }
            return value
        } catch { if searches[context.ownerID]?.id == request { searches[context.ownerID] = nil }; throw error }
    }

    public func ignore(root: String, action: String, path: String? = nil, directory: Bool = false,
                       paths: [String] = [], context: NativeRPCContext) async throws -> NativeRPCValue {
        let target = try await authority.resolve(root: root, relative: "", context: context)
        return try await detached {
            let (matcher, sources, tagged) = try Self.ignoreFiles(target.root)
            switch action {
            case "overview": return .object([.init("root", .string(target.root.path)), .init("sources", .array(sources)), .init("ruleCount", .number(Double(matcher.rules.count)))])
            case "filter":
                let selected = try paths.prefix(2_000).map { try Self.relativeArgument($0) }
                let kept = selected.filter { !matcher.ignored($0, directory: false) }
                return .object([.init("cwd", .string(root)), .init("kept", .array(kept.map(NativeRPCValue.string))),
                    .init("hidden", .array(selected.filter { !kept.contains($0) }.map(NativeRPCValue.string)))])
            case "explain":
                let path = try Self.relativeArgument(path ?? "")
                let parts = path.split(separator: "/").map(String.init)
                let always = parts.contains(".git") || parts.contains("node_modules")
                var ignored = always, rule = NativeRPCValue.null, ancestor = NativeRPCValue.null
                if !always {
                    for index in parts.indices {
                        let last = index == parts.count - 1, prefix = parts[...index].joined(separator: "/")
                        ignored = false; rule = .null
                        for tag in tagged where tag.rule.matches(prefix, directory: last ? directory : true) {
                            ignored = !tag.rule.negated
                            rule = .object([.init("source", .string(tag.rule.source)), .init("file", .string(tag.file)), .init("line", .number(Double(tag.line))), .init("negated", .bool(tag.rule.negated))])
                        }
                        if !last && ignored { ancestor = .string(prefix); break }
                    }
                }
                return .object([.init("relPath", .string(path)), .init("ignored", .bool(ignored)), .init("rule", rule),
                    .init("viaAncestor", ancestor), .init("alwaysIgnored", .bool(always))])
            default: throw NativeRPCError.invalidArguments("Unknown ignore action")
            }
        }
    }

    private func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func relativeArgument(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains("..") else { throw NativeRPCError.invalidArguments("A project file path must be relative and have no '..'") }
        return path
    }
    private struct TaggedRule: Sendable { let rule: BackendFilesystemIgnore.Rule; let file: String; let line: Int }
    private static func ignoreFiles(_ root: URL) throws -> (BackendFilesystemIgnore, [NativeRPCValue], [TaggedRule]) {
        var texts: [String] = [], sources: [NativeRPCValue] = [], tagged: [TaggedRule] = []
        for name in [".gitignore", ".deckignore"] {
            try Task.checkCancellation()
            let file = root.appendingPathComponent(name)
            if let target = try? BackendFilesystemAuthority.canonical(file), BackendFilesystemAuthority.within(target, root),
               let info = try? target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), info.isRegularFile == true,
               let size = info.fileSize, size <= 256 * 1024,
               let data = try? boundedContents(.init(root: root, path: target, relative: BackendFilesystemAuthority.relative(target, to: root)), maximum: 256 * 1024),
               let text = String(data: data, encoding: .utf8) {
                texts.append(text)
                let rules = text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                    BackendFilesystemIgnore.compile(line).map { TaggedRule(rule: $0, file: name, line: index + 1) }
                }
                tagged += rules
                sources.append(.object([.init("file", .string(name)), .init("path", .string(file.path)), .init("present", .bool(true)), .init("skipped", .null), .init("ruleCount", .number(Double(rules.count)))]))
            } else {
                let present = FileManager.default.fileExists(atPath: file.path)
                let tooLarge = ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 256 * 1024
                sources.append(.object([.init("file", .string(name)), .init("path", .string(file.path)), .init("present", .bool(present)),
                    .init("skipped", tooLarge ? .string("too-large") : .null), .init("ruleCount", .number(0))]))
            }
        }
        return (BackendFilesystemIgnore(texts: texts), sources, tagged)
    }
    private static func boundedContents(_ target: BackendFilesystemAuthority.Target, maximum: Int) throws -> Data {
        let descriptor = try BackendFilesystemAuthority.openStable(target)
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum else { throw NativeRPCError.invalidArguments("The bounded source is not a supported regular file") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
            if count == 0 { return bytes }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, bytes.count + count <= maximum else { throw NativeRPCError(code: "filesystem", message: "The bounded file read failed or exceeded its supported size") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
    }

    private struct Entry: Sendable {
        let name: String; let relative: String; var directory: Bool; let symbolic: Bool; var blocked: Bool
        var modified: Double?; var bytes: Int64?
        var wire: NativeRPCValue {
            var fields: [NativeRPCValue.Field] = [.init("name", .string(name)), .init("relPath", .string(relative)),
                .init("kind", .string(directory ? "dir" : "file")), .init("symlink", .bool(symbolic)), .init("blocked", .bool(blocked))]
            if let modified { fields.append(.init("modifiedAt", .number(modified))) }
            if let bytes { fields.append(.init("bytes", .number(Double(bytes)))) }
            return .object(fields)
        }
    }
    private static func list(_ target: BackendFilesystemAuthority.Target, relative: String, options: ListOptions) throws -> NativeRPCValue {
        let fd = try BackendFilesystemAuthority.openStable(target, directory: true)
        guard let directory = fdopendir(fd) else { Darwin.close(fd); throw NativeRPCError(code: "filesystem", message: "The bounded folder could not be enumerated") }
        defer { closedir(directory) }
        let (ignore, _, _) = try ignoreFiles(target.root)
        var entries: [Entry] = []
        while let raw = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &raw.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(raw.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if [".", "..", ".git", "node_modules"].contains(name) { continue }
            let path = target.path.appendingPathComponent(name)
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let symbolic = info.st_mode & S_IFMT == S_IFLNK
            var row = Entry(name: name, relative: relative.isEmpty ? name : relative + "/" + name,
                directory: info.st_mode & S_IFMT == S_IFDIR, symbolic: symbolic,
                blocked: ![S_IFDIR, S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT))
            if symbolic {
                if let resolved = try? BackendFilesystemAuthority.canonical(path), stat(resolved.path, &info) == 0 {
                    row.directory = info.st_mode & S_IFMT == S_IFDIR
                    row.blocked = !BackendFilesystemAuthority.within(resolved, target.root) || (row.directory && BackendFilesystemAuthority.within(target.path, resolved))
                } else { row.blocked = true; row.directory = false }
            }
            if !options.showIgnored && ignore.ignored(row.relative, directory: row.directory) { continue }
            if options.withStats && !row.blocked {
                row.bytes = Int64(info.st_size)
                row.modified = Double(info.st_mtimespec.tv_sec) * 1_000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
            }
            entries.append(row)
        }
        entries.sort {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.compare($1.name, options: [.numeric, .caseInsensitive, .diacriticInsensitive]) == .orderedAscending
        }
        let truncated = entries.count > 2_000
        entries = Array(entries.prefix(2_000))
        var fields: [NativeRPCValue.Field] = [.init("relPath", .string(relative)), .init("entries", .array(entries.map(\.wire))), .init("truncated", .bool(truncated))]
        if options.withStats {
            let candidates = entries.filter { !$0.directory && !$0.blocked }
            var selected: Entry?
            for expression in [#"^readme(\.|$)"#, #"^index\.[a-z]+$"#, #"^main\.[a-z]+$"#, #"^(claude|agents|contributing|changelog)\.md$"#, #"^package\.json$"#] {
                let named = candidates.filter { $0.name.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil }
                if !named.isEmpty { selected = named.max { ($0.modified ?? 0) < ($1.modified ?? 0) }; break }
            }
            if selected == nil { selected = candidates.filter { $0.modified != nil }.max { ($0.modified ?? 0) < ($1.modified ?? 0) } }
            fields.append(.init("defaultFile", selected.map { .string($0.relative) } ?? .null))
        }
        return .object(fields)
    }

    private static func read(_ target: BackendFilesystemAuthority.Target, relative: String) throws -> NativeRPCValue {
        let fd = try BackendFilesystemAuthority.openStable(target)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeRPCError(code: "filesystem", message: "The requested path is not a regular readable file") }
        let limit = 2 * 1024 * 1024
        if info.st_size > limit { return .object([.init("kind", .string("too-large")), .init("relPath", .string(relative)), .init("bytes", .number(Double(info.st_size))), .init("limit", .number(Double(limit)))]) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeRPCError(code: "filesystem", message: "The file could not be read (POSIX status \(errno))") }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > limit { return .object([.init("kind", .string("too-large")), .init("relPath", .string(relative)), .init("bytes", .number(Double(data.count))), .init("limit", .number(Double(limit)))]) }
        }
        if data.prefix(8_192).contains(0) { return .object([.init("kind", .string("binary")), .init("relPath", .string(relative)), .init("bytes", .number(Double(data.count)))]) }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.isEmpty ? 0 : text.utf8.filter { $0 == 10 }.count + (text.hasSuffix("\n") ? 0 : 1)
        return .object([.init("kind", .string("text")), .init("relPath", .string(relative)), .init("text", .string(text)), .init("bytes", .number(Double(data.count))), .init("lines", .number(Double(lines)))])
    }
    private static func fileList(root: String, files: [String], truncated: Bool, source: String, start: Date) -> NativeRPCValue {
        .object([.init("root", .string(root)), .init("files", .array(files.map(NativeRPCValue.string))), .init("truncated", .bool(truncated)),
            .init("source", .string(source)), .init("tookMs", .number(Date().timeIntervalSince(start) * 1_000))])
    }
    private static func walk(_ target: BackendFilesystemAuthority.Target, limit: Int, start: Date, maxDepth: Int = 12, ignored: Set<String> = searchIgnored) throws -> NativeRPCValue {
        var queue: [(URL, String, Int)] = [(target.root, "", 0)], files: [String] = [], index = 0, truncated = false
        while index < queue.count {
            try Task.checkCancellation()
            let (folder, relative, depth) = queue[index]; index += 1
            if files.count >= limit { truncated = true; break }
            let descriptor: Int32
            do { descriptor = try BackendFilesystemAuthority.openStable(.init(root: target.root, path: folder, relative: relative), directory: true) }
            catch { continue }
            guard let directory = fdopendir(descriptor) else { Darwin.close(descriptor); continue }
            defer { closedir(directory) }
            while let child = readdir(directory) {
                try Task.checkCancellation()
                if files.count >= limit { truncated = true; break }
                let name = withUnsafePointer(to: &child.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: Int(child.pointee.d_namlen) + 1) { String(cString: $0) } }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let kind = info.st_mode & S_IFMT, path = relative.isEmpty ? name : relative + "/" + name
                if kind == S_IFDIR {
                    if !ignored.contains(name), depth < maxDepth { queue.append((folder.appendingPathComponent(name), path, depth + 1)) }
                } else if kind == S_IFREG { files.append(path) }
            }
        }
        return fileList(root: target.root.path, files: files, truncated: truncated, source: "walk", start: start)
    }
    private static let searchIgnored: Set<String> = [".git", ".hg", ".svn", "node_modules", "bower_components", ".venv", "venv", "__pycache__", ".mypy_cache", ".pytest_cache", ".tox", "dist", "build", "out", "target", "coverage", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".cache", ".gradle", ".idea", "DerivedData", "Pods", ".terraform", ".serverless", ".yarn", ".pnpm-store"]
}
