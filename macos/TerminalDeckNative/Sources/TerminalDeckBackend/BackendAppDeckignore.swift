import Foundation
import Darwin
import TerminalDeckNativeCore

/// deckignore.ts's bounded files, source/line explanations and 64-entry LRU.
/// The existing filesystem rule compiler remains the sole pattern engine.
public actor BackendAppDeckignore {
    public static let maxBytes = 256 * 1024, maxCachedProjects = 64
    public struct TaggedRule: Sendable {
        public let rule: BackendFilesystemIgnore.Rule, file: String, line: Int
        public var wire: NativeRPCValue { .object([.init("source", .string(rule.source)), .init("file", .string(file)), .init("line", .number(Double(line))), .init("negated", .bool(rule.negated))]) }
    }
    public final class Project: Sendable {
        public let root: String, rules: [TaggedRule], sources: [NativeRPCValue]
        init(root: String, rules: [TaggedRule], sources: [NativeRPCValue]) { self.root = root; self.rules = rules; self.sources = sources }
        public func explain(_ relative: String, directory: Bool) -> NativeRPCValue {
            func result(_ ignored: Bool = false, _ rule: TaggedRule? = nil, _ ancestor: String? = nil, _ always: Bool = false) -> NativeRPCValue {
                .object([.init("relPath", .string(relative)), .init("ignored", .bool(ignored)), .init("rule", rule?.wire ?? .null),
                    .init("viaAncestor", ancestor.map(NativeRPCValue.string) ?? .null), .init("alwaysIgnored", .bool(always))])
            }
            let segments = relative.split(separator: "/").map(String.init)
            if segments.isEmpty { return result() }
            if segments.contains("node_modules") || segments.contains(".git") { return result(true, nil, nil, true) }
            for index in segments.indices {
                let last = index == segments.count - 1, prefix = segments[...index].joined(separator: "/")
                var hidden = false; var deciding: TaggedRule?
                for tagged in rules where tagged.rule.matches(prefix, directory: last ? directory : true) { hidden = !tagged.rule.negated; deciding = tagged }
                if last { return result(hidden, deciding) }
                if hidden { return result(true, deciding, prefix) }
            }
            return result()
        }
        public func ignored(_ path: String, directory: Bool) -> Bool { explain(path, directory: directory)["ignored"].bool == true }
        public func skipDirectory(_ path: String) -> Bool { !path.isEmpty && ignored(path, directory: true) }
        public func keepFile(_ path: String) -> Bool { !ignored(path, directory: false) }
        public var overview: NativeRPCValue { .object([.init("root", .string(root)), .init("sources", .array(sources)), .init("ruleCount", .number(Double(rules.count)))]) }
    }
    private struct Cached: Sendable { let project: Project, stamp: String }
    private var cache: [String: Cached] = [:], recency: [String] = []
    public init() {}
    public func load(root: String, includeGitignore: Bool = true) -> Project {
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        var rules: [TaggedRule] = [], sources: [NativeRPCValue] = []
        for file in includeGitignore ? [".gitignore", ".deckignore"] : [".deckignore"] {
            let loaded = Self.read(root: root, file: file); rules += loaded.1; sources.append(loaded.0)
        }
        return Project(root: root, rules: rules, sources: sources)
    }
    public func ignore(root: String, includeGitignore: Bool = true) -> Project {
        let resolved = URL(fileURLWithPath: root).standardizedFileURL.path, key = (includeGitignore ? "g:" : "-:") + URL(fileURLWithPath: root).standardizedFileURL.path
        let files = includeGitignore ? [".gitignore", ".deckignore"] : [".deckignore"]
        let stamp = files.map { file -> String in
            var info = stat(); let path = URL(fileURLWithPath: resolved).appendingPathComponent(file).path
            guard stat(path, &info) == 0 else { return file + ":-" }
            return "\(file):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_size)"
        }.joined(separator: "|")
        if let hit = cache[key], hit.stamp == stamp { touch(key); return hit.project }
        let project = load(root: resolved, includeGitignore: includeGitignore)
        cache[key] = Cached(project: project, stamp: stamp); touch(key)
        while recency.count > Self.maxCachedProjects { cache[recency.removeFirst()] = nil }
        return project
    }
    public func invalidate(root: String? = nil) {
        if let root {
            let resolved = URL(fileURLWithPath: root).standardizedFileURL.path
            for key in ["g:" + resolved, "-:" + resolved] { cache[key] = nil; recency.removeAll { $0 == key } }
        } else { cache.removeAll(); recency.removeAll() }
    }
    public func filter(root: String, files: [String], includeGitignore: Bool = true) -> [String] {
        let project = ignore(root: root, includeGitignore: includeGitignore); return files.filter(project.keepFile)
    }
    private func touch(_ key: String) { recency.removeAll { $0 == key }; recency.append(key) }
    private static func read(root: String, file: String) -> (NativeRPCValue, [TaggedRule]) {
        let path = URL(fileURLWithPath: root).appendingPathComponent(file).path
        func source(_ present: Bool, _ count: Int = 0, _ skipped: String? = nil) -> NativeRPCValue {
            .object([.init("file", .string(file)), .init("path", .string(path)), .init("present", .bool(present)), .init("ruleCount", .number(Double(count))), .init("skipped", skipped.map(NativeRPCValue.string) ?? .null)])
        }
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return (source(false), []) }; defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return (source(false), []) }
        guard info.st_size <= maxBytes else { return (source(true, 0, "too-large"), []) }
        var bytes = Data(count: min(Int(info.st_size), maxBytes) + 1), filled = 0
        let count = bytes.count
        while filled < count {
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: filled), count - filled) }
            if amount < 0 { if errno == EINTR { continue }; return (source(false), []) }
            if amount == 0 { break }; filled += amount
        }
        guard filled <= maxBytes else { return (source(true, 0, "too-large"), []) }
        let text = String(decoding: bytes.prefix(filled), as: UTF8.self)
        var rules: [TaggedRule] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let rule = BackendFilesystemIgnore.compile(line) { rules.append(TaggedRule(rule: rule, file: file, line: index + 1)) }
        }
        return (source(true, rules.count), rules)
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, service: BackendAppDeckignore,
                                allowedRoot: @escaping @Sendable (String, NativeRPCContext) async throws -> Bool) async throws -> [String] {
        let channels = ["deckignore:overview", "deckignore:explain", "deckignore:filter", "deckignore:invalidate"]
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                try context.require("files.read")
                if channel == "deckignore:invalidate" { await service.invalidate(root: context.argument(0, in: args).string); return .missing }
                let root = URL(fileURLWithPath: try context.argument(0, in: args).requireString("root")).standardizedFileURL.path
                guard try await allowedRoot(root, context) else { throw NativeRPCError(code: "access-denied", message: "that folder is not an open project") }
                if channel == "deckignore:overview" { return await service.ignore(root: root).overview }
                if channel == "deckignore:explain" {
                    let relative = try context.argument(1, in: args).requireString("relPath")
                    return await service.ignore(root: root).explain(relative, directory: context.argument(2, in: args).bool == true)
                }
                let list = try context.argument(1, in: args).requireArray("paths")
                return .array(await service.filter(root: root, files: list.compactMap(\.string)).map(NativeRPCValue.string))
            }
        }
        return channels
    }
}
