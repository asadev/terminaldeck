import Foundation
import TerminalDeckNativeCore

/// git.ts's complete status/init/diff/read-directory domain. External Git is
/// an ordinary host tool; all orchestration, parsing, limits and scope checks
/// are native. No Node fallback and no global safe.directory mutation.
public struct BackendGitService: Sendable {
    public let authority: BackendFilesystemAuthority
    public let runner: any BackendGitExecuting
    public init(authority: BackendFilesystemAuthority, runner: any BackendGitExecuting) { self.authority = authority; self.runner = runner }
    public func status(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let folder: URL
        do { folder = try await authority.authorize(cwd, context: context) }
        catch let error as NativeRPCError where error.code == "filesystem" {
            return .object([.init("repo", .bool(false)), .init("cwd", .string(cwd)), .init("reason", .string("no-such-folder")), .init("message", .string("Folder does not exist"))])
        }
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return .object([.init("repo", .bool(false)), .init("cwd", .string(cwd)), .init("reason", .string("no-such-folder")), .init("message", .string("Not a folder"))])
        }
        let top = try await call(folder.path, ["rev-parse", "--show-toplevel"], context)
        guard top.ok else { return Self.failure(cwd: cwd, outcome: top) }
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await authority.authorize(root, context: context)
        async let status = call(folder.path, ["status", "--porcelain=v2", "--branch", "-z"], context)
        async let work = call(folder.path, ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv"], context)
        async let index = call(folder.path, ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--cached"], context)
        let values = try await (status, work, index)
        guard values.0.ok, values.1.ok, values.2.ok else { return Self.failure(cwd: cwd, outcome: !values.0.ok ? values.0 : !values.1.ok ? values.1 : values.2) }
        var parsed = Self.parsePorcelain(values.0.stdout)
        Self.applyStats(&parsed.unstaged, Self.parseNumstat(values.1.stdout))
        Self.applyStats(&parsed.staged, Self.parseNumstat(values.2.stdout))
        return .object([.init("repo", .bool(true)), .init("cwd", .string(cwd)), .init("root", .string(root)),
            .init("branch", parsed.branch), .init("staged", .array(parsed.staged)), .init("unstaged", .array(parsed.unstaged)),
            .init("untracked", .array(parsed.untracked)), .init("conflicted", .array(parsed.conflicted)),
            .init("clean", .bool(parsed.staged.isEmpty && parsed.unstaged.isEmpty && parsed.untracked.isEmpty && parsed.conflicted.isEmpty))])
    }
    public func initialize(cwd: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let before = try await status(cwd: cwd, context: context)
        guard before["repo"].bool != true, before["reason"].string == "not-a-repo", before["canInit"].bool == true else { return before }
        let folder = try await authority.authorize(cwd, context: context, intent: .write)
        let result = try await call(folder.path, ["init"], context, writing: true)
        if !result.ok { return Self.failure(cwd: cwd, outcome: result) }
        return try await status(cwd: cwd, context: context)
    }
    public struct DiffOptions: Sendable {
        public let staged: Bool; public let untracked: Bool
        public init(staged: Bool = false, untracked: Bool = false) { self.staged = staged; self.untracked = untracked }
    }
    public func diff(cwd: String, path: String, options: DiffOptions = DiffOptions(), context: NativeRPCContext) async throws -> String {
        let folder = try await authority.authorize(cwd, context: context)
        let top = try await call(folder.path, ["rev-parse", "--show-toplevel"], context)
        guard top.ok else { return "" }
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return "" }
        // TS git.ts repoRelative: `relative(root, resolve(root, path))`, lexically. Not
        // `standardizedFileURL`, which turns git's `/private/var/…` toplevel into
        // `/var/…` and made every path look outside the repository.
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return "" }; parts.removeLast(); continue }
            parts.append(part)
        }
        guard !parts.isEmpty else { return "" }
        let safe = parts.joined(separator: "/")
        _ = try await authority.authorize(root, context: context)
        if options.untracked { _ = try await authority.resolve(root: root, relative: safe, context: context) }
        var args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv"]
        if options.untracked { args += ["--no-index", "--", "/dev/null", safe] }
        else { if options.staged { args.append("--cached") }; args += ["--", safe] }
        let result = try await call(root, args, context)
        return result.ok || (options.untracked && result.exitCode == 1) ? result.stdout : ""
    }
    public func gitDirectory(cwd: String, context: NativeRPCContext) async throws -> String? {
        let folder = try await authority.authorize(cwd, context: context)
        let result = try await call(folder.path, ["rev-parse", "--absolute-git-dir"], context)
        return result.ok ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    public func metadataDirectories(cwd: String, context: NativeRPCContext) async throws -> [String] {
        let folder = try await authority.authorize(cwd, context: context)
        var directories: [String] = []
        if let directory = try await gitDirectory(cwd: cwd, context: context) { directories.append(directory) }
        let common = try await call(folder.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"], context)
        if common.ok {
            let path = common.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), !directories.contains(path) { directories.append(path) }
        }
        return directories
    }
    public func listFiles(cwd: String, context: NativeRPCContext) async throws -> [String]? {
        let folder = try await authority.authorize(cwd, context: context)
        let result = try await runner.run(cwd: folder.path, arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], context: context,
            writing: false, timeoutMilliseconds: 8_000, maximumBytes: 32 * 1024 * 1024)
        return result.ok ? result.stdout.components(separatedBy: "\0").filter { !$0.isEmpty } : nil
    }
    public func workspaceCommand(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool = true) async throws -> BackendGitOutcome {
        let folder = try await authority.authorize(cwd, context: context, intent: writing ? .write : .read)
        return try await runner.run(cwd: folder.path, arguments: arguments, context: context, writing: writing,
            timeoutMilliseconds: 300_000, maximumBytes: 16 * 1024 * 1024)
    }
    private func call(_ folder: String, _ arguments: [String], _ context: NativeRPCContext, writing: Bool = false) async throws -> BackendGitOutcome {
        try await runner.run(cwd: folder, arguments: arguments, context: context, writing: writing,
            timeoutMilliseconds: 8_000, maximumBytes: 16 * 1024 * 1024)
    }
    public struct Parsed: Sendable {
        public var branch: NativeRPCValue
        public var staged: [NativeRPCValue] = [], unstaged: [NativeRPCValue] = [], untracked: [NativeRPCValue] = [], conflicted: [NativeRPCValue] = []
    }
    public static func parsePorcelain(_ output: String) -> Parsed {
        let records = output.components(separatedBy: "\0")
        var branch = NativeRPCValue.object([.init("name", .null), .init("detached", .bool(false)), .init("oid", .null), .init("upstream", .null), .init("ahead", .number(0)), .init("behind", .number(0))])
        var result = Parsed(branch: branch), i = 0
        while i < records.count {
            let record = records[i]; i += 1
            guard let tag = record.first else { continue }
            if tag == "#" {
                let parts = record.components(separatedBy: " "), value = record.components(separatedBy: " ").dropFirst(2).joined(separator: " ")
                switch parts.dropFirst().first {
                case "branch.oid": branch = branch.setting("oid", value == "(initial)" ? .null : .string(value))
                case "branch.head": branch = branch.setting("detached", .bool(value == "(detached)")).setting("name", value == "(detached)" ? .null : .string(value))
                case "branch.upstream": branch = branch.setting("upstream", .string(value))
                case "branch.ab":
                    let values = value.split(separator: " ").map(String.init)
                    if values.count == 2 { branch = branch.setting("ahead", .number(Double(values[0].dropFirst()) ?? 0)).setting("behind", .number(Double(values[1].dropFirst()) ?? 0)) }
                default: break
                }; continue
            }
            if tag == "?" { result.untracked.append(file(String(record.dropFirst(2)), group: "untracked", code: "?")); continue }
            let parts = record.components(separatedBy: " ")
            let xy = parts.count > 1 ? Array(parts[1]) : [".", "."]
            guard xy.count >= 2 else { continue }
            if tag == "u" { result.conflicted.append(file(parts.dropFirst(10).joined(separator: " "), group: "conflicted", code: String(xy))); continue }
            if tag == "1" {
                let path = parts.dropFirst(8).joined(separator: " ")
                if xy[0] != "." { result.staged.append(file(path, group: "staged", code: String(xy[0]))) }
                if xy[1] != "." { result.unstaged.append(file(path, group: "unstaged", code: String(xy[1]))) }
            } else if tag == "2" {
                let previous = i < records.count ? records[i] : ""; i += 1
                let path = parts.dropFirst(9).joined(separator: " ")
                let score = parts.count > 8 ? Int(parts[8].dropFirst()) : nil
                if xy[0] != "." { result.staged.append(file(path, group: "staged", code: String(xy[0]), previous: previous, score: score)) }
                if xy[1] != "." { result.unstaged.append(file(path, group: "unstaged", code: String(xy[1]))) }
            }
        }
        result.branch = branch
        return result
    }
    public static func parseNumstat(_ output: String) -> [String: NativeRPCValue] {
        let records = output.components(separatedBy: "\0"); var result: [String: NativeRPCValue] = [:], i = 0
        while i < records.count {
            let fields = records[i].components(separatedBy: "\t"); i += 1
            guard fields.count >= 3 else { continue }
            var path = fields.dropFirst(2).joined(separator: "\t"), previous: String?
            if path.isEmpty { previous = i < records.count ? records[i] : ""; path = i + 1 < records.count ? records[i + 1] : ""; i += 2 }
            let binary = fields[0] == "-" || fields[1] == "-"
            result[path] = .object([.init("origPath", previous.map(NativeRPCValue.string) ?? .null),
                .init("insertions", .number(binary ? 0 : Double(fields[0]) ?? 0)), .init("deletions", .number(binary ? 0 : Double(fields[1]) ?? 0)), .init("binary", .bool(binary))])
        }
        return result
    }
    private static func applyStats(_ files: inout [NativeRPCValue], _ stats: [String: NativeRPCValue]) {
        for index in files.indices { if let path = files[index]["path"].string, let stat = stats[path] { files[index] = files[index].setting("insertions", stat["insertions"]).setting("deletions", stat["deletions"]).setting("binary", stat["binary"]) } }
    }
    private static func file(_ path: String, group: String, code: String, previous: String? = nil, score: Int? = nil) -> NativeRPCValue {
        let kinds = ["A": "added", "M": "modified", "D": "deleted", "R": "renamed", "C": "copied", "T": "typechange", "U": "conflicted", "?": "untracked"]
        return .object([.init("path", .string(path)), .init("origPath", previous.map(NativeRPCValue.string) ?? .null), .init("group", .string(group)),
            .init("code", .string(code)), .init("kind", .string(group == "conflicted" ? "conflicted" : kinds[code] ?? "unknown")),
            .init("score", score.map { .number(Double($0)) } ?? .null), .init("insertions", .null), .init("deletions", .null), .init("binary", .bool(false))])
    }
    private static func failure(cwd: String, outcome: BackendGitOutcome) -> NativeRPCValue {
        let reason: String, message: String; var canInit = false
        if outcome.missing { reason = "git-missing"; message = "git is not installed, or not on the login PATH" }
        else if outcome.stderr.localizedCaseInsensitiveContains("detected dubious ownership") {
            reason = "not-a-repo"; message = "git will not read this repository because the folder belongs to another user. Add this folder to Git's trusted safe.directory list, then refresh."
        } else if outcome.stderr.localizedCaseInsensitiveContains("not a git repository") {
            reason = "not-a-repo"; message = "This folder is not a git repository. Source control can create one."; canInit = true
        } else { reason = "error"; message = outcome.timedOut ? "The Git operation exceeded its time/output limit." : outcome.stderr.isEmpty ? "git failed" : outcome.stderr }
        var fields: [NativeRPCValue.Field] = [.init("repo", .bool(false)), .init("cwd", .string(cwd)), .init("reason", .string(reason)), .init("message", .string(message))]
        if canInit { fields.append(.init("canInit", .bool(true))) }
        return .object(fields)
    }
}
