import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// task-workspaces.ts / workspace-store.ts / workspace-names.ts. Worktrees
/// remain tied to task identity and exact commits. Removal preserves dirty or
/// in-use work and never deletes the branch. Persistence needs the facade's
/// existing exclusive Store ownership, so Node and native never both write.
public actor BackendWorkspaceService {
    private let userData: URL
    private let git: BackendGitService
    private let ownership: NativeStateStore.Ownership
    private var loaded = false
    private var records: [String: NativeRPCValue] = [:], refusals: [String: NativeRPCValue] = [:]
    private var held: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    public init(userData: URL, git: BackendGitService, ownership: NativeStateStore.Ownership = .readOnly) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/"), userData.path != "/" else { throw NativeRPCError.invalidArguments("Workspaces need the app's own absolute data root") }
        self.userData = userData.standardizedFileURL; self.git = git; self.ownership = ownership
    }
    public var writable: Bool { ownership == .exclusive || ownership == .memory }
    public func folderFor(taskID: String, project: String, useWorkspace: Bool, title: String = "", context: NativeRPCContext) async throws -> String? {
        await enter(taskID); defer { leave(taskID) }
        try load(); try requireWriter()
        let actual = try await git.authority.authorize(project, context: context).path
        if let existing = try await current(taskID, context: context) {
            guard existing["project"].string == actual else {
                if useWorkspace { try refuse(taskID, project: actual, reason: "This task already has a workspace for another project. Remove that workspace before making one for the new folder.") }
                return nil
            }
            if existing["state"].string == "kept" { try put(existing.setting("state", .string("active")).setting("reason", .null)) }
            return folder(existing)
        }
        if !useWorkspace { refusals[taskID] = nil; try persist(); return nil }
        let top = try await git.workspaceCommand(cwd: actual, arguments: ["rev-parse", "--show-toplevel"], context: context, writing: false)
        guard top.ok else { try refuse(taskID, project: actual, reason: "Git could not find a usable repository, so this task runs in its project folder. \(top.stderr)"); return nil }
        let repo = try BackendFilesystemAuthority.canonical(URL(fileURLWithPath: top.stdout.trimmingCharacters(in: .whitespacesAndNewlines))).path
        guard !BackendFilesystemAuthority.within(URL(fileURLWithPath: repo), userData.resolvingSymlinksInPath()) else {
            try refuse(taskID, project: actual, reason: "A repository inside this app's own storage is not given a workspace."); return nil
        }
        let head = try await git.workspaceCommand(cwd: repo, arguments: ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], context: context, writing: false)
        guard head.ok else { try refuse(taskID, project: actual, reason: "This repository has no commits yet, so the task runs in its project folder."); return nil }
        let base = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var branch: String?
        for attempt in 1...50 {
            try Task.checkCancellation()
            let candidate = Self.branch(title: title, taskID: taskID, attempt: attempt)
            let taken = try await git.workspaceCommand(cwd: repo, arguments: ["show-ref", "--verify", "--quiet", "refs/heads/" + candidate], context: context, writing: false)
            if !taken.ok && taken.exitCode == 1 { branch = candidate; break }
            if !taken.ok && taken.exitCode != 1 { try refuse(taskID, project: actual, reason: "Git could not check workspace branch availability. \(taken.stderr)"); return nil }
        }
        guard let branch else { try refuse(taskID, project: actual, reason: "Every task workspace branch name is already taken."); return nil }
        let parent = userData.appendingPathComponent("workspaces").appendingPathComponent(Self.digest(repo, count: 16))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var destination: URL?
        for attempt in 1...50 {
            let path = parent.appendingPathComponent(Self.folderName(taskID, attempt: attempt))
            if !FileManager.default.fileExists(atPath: path.path) { destination = path; break }
        }
        guard let destination else { try refuse(taskID, project: actual, reason: "Every task workspace folder name is already taken."); return nil }
        let added = try await git.workspaceCommand(cwd: repo, arguments: ["worktree", "add", "--quiet", "-b", branch, destination.path, base], context: context)
        guard added.ok else { try refuse(taskID, project: actual, reason: "Git could not create the workspace, so this task runs in the project folder. \(added.stderr)"); return nil }
        let at = Self.now()
        let record = NativeRPCValue.object([.init("taskId", .string(taskID)), .init("repo", .string(repo)), .init("path", .string(destination.resolvingSymlinksInPath().path)),
            .init("branch", .string(branch)), .init("project", .string(actual)), .init("base", .string(base)), .init("createdAt", .number(at)),
            .init("state", .string("active")), .init("reason", .null), .init("updatedAt", .number(at))])
        try put(record)
        return folder(record)
    }
    public func view(taskID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        await enter(taskID); defer { leave(taskID) }; try load()
        _ = try await current(taskID, context: context)
        return viewNow(taskID)
    }
    public func folderToOpen(taskID: String, context: NativeRPCContext) async throws -> String? {
        let value = try await view(taskID: taskID, context: context)["workspace"]
        return value["state"].string == "removed" ? nil : value["folder"].string
    }
    public func remove(taskID: String, liveFolders: [String], context: NativeRPCContext) async throws -> NativeRPCValue {
        await enter(taskID); defer { leave(taskID) }; try load(); try requireWriter()
        guard let found = records[taskID], found["state"].string != "removed", let path = found["path"].string, let repo = found["repo"].string else {
            return outcome(false, "This task has no workspace to remove.", taskID)
        }
        let root = userData.appendingPathComponent("workspaces").resolvingSymlinksInPath()
        guard BackendFilesystemAuthority.within(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(), root) else {
            return try keep(found, "The recorded workspace is outside this app's managed workspace folder, so it was kept.")
        }
        if !FileManager.default.fileExists(atPath: path) { _ = try await prune(found, context: context); return outcome(true, records[taskID]?["reason"].string ?? "Its folder is gone.", taskID) }
        if liveFolders.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { return try keep(found, "A session is still running in this workspace. Stop it before removing the workspace.") }
        let status = try await git.workspaceCommand(cwd: path, arguments: ["status", "--porcelain", "--ignore-submodules=none"], context: context, writing: false)
        guard status.ok else { return try keep(found, "Git could not read the workspace, so it was kept. \(status.stderr)") }
        let changes = status.stdout.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !changes.isEmpty { return try keep(found, "It has \(changes.count) uncommitted changes (\(changes.prefix(5).map { String($0.dropFirst(3)) }.joined(separator: ", "))), so it was kept. Commit or discard them before removing it.") }
        let removed = try await git.workspaceCommand(cwd: repo, arguments: ["worktree", "remove", path], context: context)
        guard removed.ok else { return try keep(found, "Git would not remove the workspace, so it was kept. \(removed.stderr)") }
        let reason = "Removed. Its branch \(found["branch"].string ?? "") stays in \(repo), with every commit made on it."
        try put(found.setting("state", .string("removed")).setting("reason", .string(reason)))
        return outcome(true, reason, taskID)
    }
    public func pruneVanished(context: NativeRPCContext) async throws {
        try load(); try requireWriter()
        for id in records.keys.sorted() {
            await enter(id)
            do { _ = try await current(id, context: context); leave(id) } catch { leave(id); throw error }
        }
    }
    public func liveFolders() throws -> [String] {
        try load(); var folders: Set<String> = []
        for record in records.values where record["state"].string != "removed" {
            if let path = record["path"].string, FileManager.default.fileExists(atPath: path) { folders.insert(path); folders.insert(folder(record)) }
        }
        return folders.sorted()
    }
    private func load() throws {
        guard !loaded else { return }
        let file = userData.appendingPathComponent("workspaces.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data: NativeRPCValue
            do { data = try NativeRPCValue.parseJSON(try Data(contentsOf: file), maximumBytes: 8 * 1024 * 1024) }
            catch {
                // Unreadable: moved aside, never written over. If the move fails it stays where it is.
                let aside = file.deletingLastPathComponent().appendingPathComponent("workspaces.json.unreadable-\(Int(Date().timeIntervalSince1970 * 1000))")
                try? FileManager.default.moveItem(at: file, to: aside)
                loaded = true
                return
            }
            guard (data["v"].number ?? 1) == 1 else { throw NativeRPCError(code: "workspace", message: "The workspace records use an unsupported format") }
            for row in data["workspaces"].elements ?? [] {
                if let id = row["taskId"].string, ["repo", "path", "branch", "project", "base"].allSatisfy({ row[$0].string != nil }),
                   ["active", "kept", "removed"].contains(row["state"].string ?? "") { records[id] = row }
            }
            for row in data["refused"].elements ?? [] { if let id = row["taskId"].string { refusals[id] = row } }
        }
        loaded = true
    }
    private func requireWriter() throws { guard writable else { throw NativeRPCError(code: "read-only", message: "Node still owns workspace persistence; native mutations are not enabled") } }
    private func put(_ record: NativeRPCValue) throws {
        guard let id = record["taskId"].string else { throw NativeRPCError.invalidArguments("The workspace has no task identity") }
        records[id] = record.setting("updatedAt", .number(Self.now())); refusals[id] = nil; try persist()
    }
    private func refuse(_ taskID: String, project: String, reason: String) throws {
        refusals[taskID] = .object([.init("taskId", .string(taskID)), .init("project", .string(project)), .init("reason", .string(reason)), .init("at", .number(Self.now()))]); try persist()
    }
    private func persist() throws {
        try requireWriter()
        for old in records.values.filter({ $0["state"].string == "removed" }).sorted(by: { ($0["updatedAt"].number ?? 0) > ($1["updatedAt"].number ?? 0) }).dropFirst(200) { if let id = old["taskId"].string { records[id] = nil } }
        for old in refusals.values.sorted(by: { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }).dropFirst(200) { if let id = old["taskId"].string { refusals[id] = nil } }
        guard ownership != .memory else { return }
        let data = NativeRPCValue.object([.init("v", .number(1)), .init("workspaces", .array(records.values.sorted { ($0["taskId"].string ?? "") < ($1["taskId"].string ?? "") })), .init("refused", .array(Array(refusals.values)))])
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        try data.encodedJSON(pretty: true).write(to: userData.appendingPathComponent("workspaces.json"), options: .atomic)
    }
    private func current(_ id: String, context: NativeRPCContext) async throws -> NativeRPCValue? {
        guard let record = records[id], record["state"].string != "removed", let path = record["path"].string else { return nil }
        if FileManager.default.fileExists(atPath: path) { return record }
        if writable { _ = try await prune(record, context: context) }
        return nil
    }
    private func prune(_ record: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        if let repo = record["repo"].string, FileManager.default.fileExists(atPath: repo), let path = record["path"].string {
            let removal = try await git.workspaceCommand(cwd: repo, arguments: ["worktree", "remove", path], context: context)
            // A folder that is already gone cannot be removed; clear git's note of it, ignoring any failure.
            if !removal.ok { _ = try? await git.workspaceCommand(cwd: repo, arguments: ["worktree", "prune"], context: context) }
        }
        let removed = record.setting("state", .string("removed")).setting("reason", .string("Its folder was deleted outside the app. Its branch and commits remain in the repository."))
        try put(removed); return removed
    }
    private func folder(_ record: NativeRPCValue) -> String {
        let path = record["path"].string ?? "", repo = record["repo"].string ?? "", project = record["project"].string ?? ""
        if project.hasPrefix(repo + "/") {
            let nested = URL(fileURLWithPath: path).appendingPathComponent(String(project.dropFirst(repo.count + 1))).path
            if FileManager.default.fileExists(atPath: nested) { return nested }
        }
        return path
    }
    private func viewNow(_ id: String) -> NativeRPCValue { .object([.init("workspace", records[id].map { $0.setting("folder", .string(folder($0))) } ?? .null), .init("refusal", refusals[id]?["reason"] ?? .null)]) }
    private func outcome(_ ok: Bool, _ message: String, _ id: String) -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message)), .init("view", viewNow(id))]) }
    private func keep(_ record: NativeRPCValue, _ reason: String) throws -> NativeRPCValue { try put(record.setting("state", .string("kept")).setting("reason", .string(reason))); return outcome(false, reason, record["taskId"].string ?? "") }
    private func enter(_ id: String) async {
        if !held.contains(id) { held.insert(id); return }
        await withCheckedContinuation { waiting[id, default: []].append($0) }
    }
    private func leave(_ id: String) { if var queue = waiting[id], !queue.isEmpty { let first = queue.removeFirst(); waiting[id] = queue; first.resume() } else { waiting[id] = nil; held.remove(id) } }
    private static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }
    private static func digest(_ value: String, count: Int) -> String { String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(count)) }
    private static func branch(title: String, taskID: String, attempt: Int) -> String {
        let folded = title.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) }.map(String.init).joined().lowercased()
        let raw = folded.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slug = String(raw.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "td/" + (slug.isEmpty ? "task" : slug) + "-" + digest(taskID, count: 8) + (attempt == 1 ? "" : "-\(attempt)")
    }
    private static func folderName(_ id: String, attempt: Int) -> String {
        let raw = id.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String((raw.isEmpty ? "task" : raw).prefix(48)) + "-" + digest(id, count: 8) + (attempt == 1 ? "" : "-\(attempt)")
    }
}
